import AppKit

/// The only ordinary application window. Runtime work outlives its content.
@MainActor
final class ApplicationWindow: NSObject {
    let panel: NSWindow
    private let sidebar = SidebarView()
    private let recordingBar = RecordingBarView()
    private let toolbar = NSStackView()
    private let title = NSButton()
    private let actions = NSStackView()
    private let start = NSButton()
    private let contentHost = NSView()
    private var showingLive = false
    private lazy var live = StatusWindow(hostWindow: panel)
    private lazy var liveView: LiveTranscriptView = {
        let view = LiveTranscriptView(content: live.contentView)
        view.onRename = { [weak self] name in
            guard let self, let rename = self.onRenameRecording else { throw CocoaError(.fileNoSuchFile) }
            try rename(name)
            self.recordingTitle = name
        }
        return view
    }()
    var isProcessing: (() -> Bool)?
    var onRenameRecording: ((String) throws -> Void)?
    lazy var settings: SettingsWindow = {
        let settings = SettingsWindow(hostWindow: panel)
        settings.isProcessing = { [weak self] in self?.isProcessing?() == true }
        settings.isRecording = { [weak self] in self?.recordingBarIsVisible == true }
        return settings
    }()
    private lazy var about = AboutWindow(hostWindow: panel)
    private(set) var navigation = ApplicationNavigationState()
    var libraryProvider: (() -> RecordingsWindow?)? {
        didSet { if navigation.destination.isMeetings { navigate(navigation.destination) } }
    }
    var onToggle: (() -> Void)? { didSet { live.onToggle = onToggle } }
    var onTogglePause: (() -> Void)? { didSet { live.onTogglePause = onTogglePause } }
    var onToggleAutoRecord: (() -> Void)? { didSet { live.onToggleAutoRecord = onToggleAutoRecord } }
    var onToggleLive: ((Bool) -> Void)? { didSet { live.onToggleLive = onToggleLive } }
    var onOpenFolder: (() -> Void)? { didSet { live.onOpenFolder = onOpenFolder } }
    var onShowRecordings: (() -> Void)? { didSet { live.onShowRecordings = onShowRecordings } }
    var onChooseImport: (() -> Void)? { didSet { live.onChooseImport = onChooseImport } }
    var onImportFiles: (([URL]) -> Void)? { didSet { live.onImportFiles = onImportFiles } }
    var onCancelImport: (() -> Void)? { didSet { live.onCancelImport = onCancelImport } }
    var recordingTitle: String {
        get { recordingBar.title }
        set { recordingBar.title = newValue; liveView.title = newValue }
    }
    private var appearance: AppearanceController?
    var toolbarIsHidden: Bool { toolbar.isHidden }
    var primaryActionsAreVisible: Bool { !actions.isHidden }
    var recordingBarIsVisible: Bool { !recordingBar.isHidden }
    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Verbemo"
        panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true
        sidebar.onNavigate = { [weak self] in self?.navigate($0) }
        recordingBar.onOpen = { [weak self] in self?.showActiveRecording() }
        recordingBar.onPause = { [weak self] in self?.pauseRecording() }
        recordingBar.onStop = { [weak self] in self?.stopRecording() }
        title.isBordered = false
        title.alignment = .left
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.target = self
        title.action = #selector(showAll)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.cell?.wraps = false
        title.cell?.lineBreakMode = .byTruncatingTail
        let importButton = NSButton(title: localised("Import", "Импортировать"), target: self, action: #selector(importClicked))
        importButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        importButton.imagePosition = .imageLeading
        importButton.bezelStyle = .rounded
        start.title = localised("New recording", "Новая запись")
        start.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        start.imagePosition = .imageLeading
        start.bezelStyle = .rounded
        start.target = self
        start.action = #selector(startClicked)
        actions.setViews([importButton, start], in: .center)
        actions.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        toolbar.setViews([title, spacer, actions], in: .center)
        toolbar.distribution = .fill
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
        toolbar.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let right = NSStackView(views: [toolbar, contentHost])
        right.orientation = .vertical
        right.distribution = .fill
        right.spacing = 0
        right.alignment = .leading
        contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        toolbar.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        contentHost.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        let body = NSStackView(views: [sidebar, right])
        body.orientation = .horizontal
        body.distribution = .fill
        body.alignment = .top
        body.spacing = 0
        sidebar.widthAnchor.constraint(equalToConstant: 190).isActive = true
        sidebar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let root = NSStackView(views: [recordingBar, body])
        root.orientation = .vertical
        root.distribution = .fill
        root.spacing = 0
        root.alignment = .leading
        root.detachesHiddenViews = true
        recordingBar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        let container = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor), root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor), root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container
        appearance = AppearanceController(window: panel)
        panel.contentMinSize = NSSize(width: 700, height: 600)
        panel.setFrameAutosaveName("name.ekho.verbemo.workspace")
        if panel.frame.origin == .zero { panel.center() }
        navigate(.allMeetings)
    }
    func navigate(_ destination: ApplicationNavigationState.Destination) {
        showingLive = false
        navigation.navigate(destination)
        sidebar.select(destination)
        toolbar.isHidden = destination == .about
        title.title = destination.title
        title.isEnabled = destination.isMeetings && destination != .allMeetings
        actions.isHidden = destination != .allMeetings
        let content: NSView
        if destination.isMeetings, let library = libraryProvider?() {
            library.refresh()
            library.applyFilter(destination)
            library.onDetailVisibilityChange = { [weak self] visible in
                guard let self, self.navigation.destination.isMeetings else { return }
                self.title.isEnabled = self.showingLive || visible || self.navigation.destination != .allMeetings
            }
            content = library.contentView
        } else if destination == .about {
            content = SetupLayout.scroller(around: about.contentView)
        } else if !destination.isMeetings {
            content = settings.content(for: destination)
        } else {
            content = NSTextField(labelWithString: localised("No meetings yet", "Встреч пока нет"))
        }
        mount(content)
    }
    private func mount(_ view: NSView) {
        if view.superview === contentHost { return }
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentHost.topAnchor), view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor), view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
        ])
    }
    func showActiveRecording() {
        guard recordingBarIsVisible else { return }
        showingLive = true
        navigation.navigate(.allMeetings)
        navigation.showsDetail = true
        navigation.resultTab = "transcript"
        toolbar.isHidden = false
        title.title = ApplicationNavigationState.Destination.allMeetings.title
        title.isEnabled = true
        actions.isHidden = false
        sidebar.select(.allMeetings)
        mount(liveView)
    }
    func show() { if navigation.destination.isMeetings { libraryProvider?()?.refresh() }; panel.orderFront(nil) }
    func bringToFront() { if navigation.destination.isMeetings { libraryProvider?()?.refresh() }; NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
    func hide() { panel.orderOut(nil) }
    func update(state: MenuBarController.State, elapsed: String?) {
        let wasRecording = recordingBarIsVisible
        recordingBar.update(state: state, elapsed: elapsed)
        if wasRecording && state == .idle && showingLive { navigate(.allMeetings) }
        start.isEnabled = state == .idle
        live.update(state: state, elapsed: elapsed)
    }
    func updateAutoRecord(enabled: Bool, decision: String?) {
        sidebar.updateAutomatic(enabled, reason: decision)
        live.updateAutoRecord(enabled: enabled, decision: decision)
    }
    func updateLive(_ snapshot: LiveTranscriptionCoordinator.Snapshot) { live.updateLive(snapshot) }
    func updateLivePreference(enabled: Bool) { live.updateLivePreference(enabled: enabled) }
    func updateConfigProblem(_ headline: String?) { live.updateConfigProblem(headline) }
    func updateTranscription(_ text: String?) { live.updateTranscription(text) }
    func updateImport(_ update: MediaImportCoordinator.Update) { live.updateImport(update) }
    func finishImport(_ result: MediaImportCoordinator.Result) { libraryProvider?()?.sessionsChanged() }
    func startRecording() {
        guard !recordingBarIsVisible else { return }
        onToggle?()
        if recordingBarIsVisible { showActiveRecording() }
    }
    func pauseRecording() { if recordingBarIsVisible { onTogglePause?() } }
    func stopRecording() { if recordingBarIsVisible { onToggle?() } }
    @objc private func showAll() { navigation.showAllMeetings(); libraryProvider?()?.applyFilter(.allMeetings, clearSearch: true); navigate(.allMeetings) }
    @objc private func importClicked() { onChooseImport?() }
    @objc private func startClicked() { startRecording() }
}
