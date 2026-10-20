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
    private lazy var live = StatusWindow(hostWindow: panel)
    lazy var settings: SettingsWindow = {
        let settings = SettingsWindow(hostWindow: panel)
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
        set { recordingBar.title = newValue }
    }
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
        recordingBar.onPause = { [weak self] in self?.onTogglePause?() }
        recordingBar.onStop = { [weak self] in self?.onToggle?() }
        title.isBordered = false
        title.alignment = .left
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.target = self
        title.action = #selector(showAll)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        toolbar.setViews([title, NSView(), actions], in: .center)
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
        toolbar.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let right = NSStackView(views: [toolbar, contentHost])
        right.orientation = .vertical
        right.spacing = 0
        right.alignment = .leading
        contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        toolbar.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        contentHost.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        let body = NSStackView(views: [sidebar, right])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 0
        sidebar.widthAnchor.constraint(equalToConstant: 190).isActive = true
        sidebar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let root = NSStackView(views: [recordingBar, body])
        root.orientation = .vertical
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
        panel.contentMinSize = NSSize(width: 700, height: 600)
        panel.setFrameAutosaveName("name.ekho.verbemo.workspace")
        if panel.frame.origin == .zero { panel.center() }
        navigate(.allMeetings)
    }
    func navigate(_ destination: ApplicationNavigationState.Destination) {
        navigation.navigate(destination)
        sidebar.select(destination)
        toolbar.isHidden = destination == .about
        title.title = destination.title
        title.isEnabled = destination.isMeetings
        actions.isHidden = destination != .allMeetings
        let content: NSView
        if destination.isMeetings, let library = libraryProvider?() {
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
        navigation.showsDetail = true
        navigation.resultTab = "transcript"
        toolbar.isHidden = false
        title.title = ApplicationNavigationState.Destination.allMeetings.title
        actions.isHidden = false
        sidebar.select(.allMeetings)
        mount(live.contentView)
    }
    func show() { panel.orderFront(nil) }
    func bringToFront() { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
    func hide() { panel.orderOut(nil) }
    func update(state: MenuBarController.State, elapsed: String?) {
        recordingBar.update(state: state, elapsed: elapsed)
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
    func updateImport(_ update: MediaImportCoordinator.Update) { bringToFront() }
    func finishImport(_ result: MediaImportCoordinator.Result) {}
    @objc private func showAll() { navigation.showAllMeetings(); navigate(.allMeetings) }
    @objc private func importClicked() { onChooseImport?() }
    @objc private func startClicked() { onToggle?(); showActiveRecording() }
}
