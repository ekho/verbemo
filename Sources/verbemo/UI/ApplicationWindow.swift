import AppKit

/// The only ordinary application window. Runtime work outlives its content.
@MainActor
final class ApplicationWindow: NSObject, NSWindowDelegate {
    let panel: NSWindow
    private let sidebar = SidebarView()
    private let recordingBar = RecordingBarView()
    private let toolbar = NSStackView()
    private let title = NSButton()
    private let heading = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private let contentHost = NSView()
    private let settingsNavigation = JournalSettingsNavigation()
    private var showingLive = false
    private lazy var live = LiveTranscriptContent()
    private lazy var liveView: LiveTranscriptView = {
        let view = LiveTranscriptView(content: live.contentView)
        view.readAudioLevels = { [weak self] in self?.readAudioLevels?() ?? (.off, .off) }
        view.onRename = { [weak self] name in
            guard let self, let rename = self.onRenameRecording else { throw CocoaError(.fileNoSuchFile) }
            try rename(name)
            self.recordingTitle = name
        }
        return view
    }()
    var isProcessing: (() -> Bool)?
    var readAudioLevels: (() -> (mic: AudioMeter.Reading, system: AudioMeter.Reading))?
    var onRenameRecording: ((String) throws -> Void)?
    lazy var settings: SettingsController = {
        let settings = SettingsController(hostWindow: panel)
        settings.isProcessing = { [weak self] in self?.isProcessing?() == true }
        settings.isRecording = { [weak self] in self?.recordingBarIsVisible == true }
        return settings
    }()
    private lazy var about = AboutPage()
    var onCheckForUpdates: (() -> Void)? { didSet { about.onCheckForUpdates = onCheckForUpdates } }
    var updatesAvailable = false { didSet { about.updatesAvailable = updatesAvailable } }
    var onOpenFolder: (() -> Void)? { didSet { settings.setup.onOpenFolder = onOpenFolder } }
    private(set) var navigation = ApplicationNavigationState()
    var libraryProvider: (() -> MeetingLibraryController?)? {
        didSet { connectLibrary(); if navigation.destination.isMeetings { navigate(navigation.destination) } }
    }
    var onToggle: (() -> Void)?
    var onStartRecording: ((String, CalendarWatcher.Meeting?) -> Void)?
    var recordingCalendar: ((Date) async -> NewRecordingSheet.CalendarOptions?)?
    var calendarSearch: CalendarEventPicker.Loader?
    var calendarResolve: CalendarEventPicker.Resolver?
    private(set) var recordingSheet: NewRecordingSheet?
    var onTogglePause: (() -> Void)?
    var onToggleAutoRecord: (() -> Void)?
    var onToggleLive: ((Bool) -> Void)? { didSet { live.onToggleLive = onToggleLive } }
    var onChooseImport: (() -> Void)?
    var onImportFiles: (([URL]) -> Void)? { didSet { live.onImportFiles = onImportFiles } }
    var onCancelImport: (() -> Void)? { didSet { live.onCancelImport = onCancelImport } }
    var recordingTitle: String {
        get { recordingBar.title }
        set { recordingBar.title = newValue; liveView.title = newValue }
    }
    private var appearance: AppearanceController?
    private var keepsDockIcon = Config.dockIcon()
    var toolbarIsHidden: Bool { toolbar.isHidden }
    var primaryActionsAreVisible: Bool { !sidebar.isHidden }
    var recordingBarIsVisible: Bool { !recordingBar.isHidden }
    var isVisible: Bool { panel.isVisible && !panel.isMiniaturized }

    override init() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "Verbemo"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = JournalStyle.paper
        panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true
        sidebar.onNavigate = { [weak self] in self?.navigate($0) }
        sidebar.onStart = { [weak self] in self?.newRecording() }
        sidebar.onImport = { [weak self] in self?.onChooseImport?() }
        sidebar.onToggleAutomatic = { [weak self] in self?.onToggleAutoRecord?() }
        recordingBar.onOpen = { [weak self] in self?.showActiveRecording() }
        recordingBar.onPause = { [weak self] in self?.pauseRecording() }
        recordingBar.onStop = { [weak self] in self?.stopRecording() }
        title.isBordered = false
        title.alignment = .left
        title.font = .systemFont(ofSize: 12)
        title.contentTintColor = JournalStyle.muted
        title.target = self
        title.action = #selector(sectionClicked)
        title.identifier = .init("journal.breadcrumb")
        title.cell?.wraps = false
        title.cell?.lineBreakMode = .byTruncatingTail
        heading.font = .systemFont(ofSize: 12)
        heading.textColor = JournalStyle.muted
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        toolbar.setViews([title, heading, spacer, actions], in: .center)
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
        toolbar.heightAnchor.constraint(equalToConstant: 48).isActive = true
        settingsNavigation.identifier = .init("settings.navigation")
        settingsNavigation.onSelect = { [weak self] in self?.navigate($0) }
        let divider = NSBox(); divider.boxType = .separator
        let right = NSStackView(views: [toolbar, divider, recordingBar, settingsNavigation, contentHost])
        right.orientation = .vertical
        right.distribution = .fill
        right.spacing = 0
        right.alignment = .leading
        right.detachesHiddenViews = true
        contentHost.setContentHuggingPriority(.init(1), for: .vertical)
        for view in right.arrangedSubviews { view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        let root = NSStackView(views: [sidebar, right])
        root.orientation = .horizontal
        root.distribution = .fill
        root.alignment = .top
        root.spacing = 0
        sidebar.widthAnchor.constraint(equalToConstant: JournalStyle.sidebarWidth).isActive = true
        sidebar.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        let container = WorkspaceSurface(JournalStyle.paper)
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor), root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor), root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container
        panel.initialFirstResponder = container
        appearance = AppearanceController(window: panel)
        panel.contentMinSize = NSSize(width: 760, height: 600)
        panel.setFrameAutosaveName("name.ekho.verbemo.workspace")
        if panel.frame.origin == .zero { panel.center() }
        navigate(.allMeetings)
    }
    private func connectLibrary() {
        guard let library = libraryProvider?() else { return }
        sidebar.mountLibrary(library.listContentView)
        library.onSelectMeeting = { [weak self, weak library] in
            guard let self, let library else { return }
            self.showingLive = false
            self.navigation.navigate(library.currentFilter)
            self.sidebar.select(library.currentFilter)
            self.toolbar.isHidden = false
            self.settingsNavigation.isHidden = true
            self.updateHeading()
            self.actions.setViews([library.toolbarContent], in: .center)
            library.updateCompactLayout()
            self.mount(library.contentView)
        }
        library.onNavigateSettings = { [weak self] in self?.navigate($0) }
    }
    func navigate(_ destination: ApplicationNavigationState.Destination) {
        showingLive = false
        navigation.navigate(destination)
        sidebar.select(destination)
        toolbar.isHidden = destination == .about
        updateHeading()
        actions.isHidden = false
        settingsNavigation.isHidden = destination.isMeetings || destination == .about
        settingsNavigation.select(destination)
        let content: NSView
        if destination.isMeetings, let library = libraryProvider?() {
            library.refresh()
            library.applyFilter(destination)
            actions.setViews([library.toolbarContent], in: .center)
            content = library.contentView
        } else if destination == .about {
            content = SetupLayout.scroller(around: about.contentView)
        } else if !destination.isMeetings {
            let about = NSButton(title: localised("About", "О приложении"), target: self, action: #selector(showAbout))
            about.isBordered = false
            actions.setViews([about], in: .center)
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
    private func updateHeading() {
        let destination = navigation.destination
        title.title = destination.isMeetings ? localised("Meetings", "Встречи") : localised("Settings", "Настройки")
        heading.stringValue = "/  " + destination.title
        heading.isHidden = destination == .allMeetings
    }
    func presentSetup(_ setup: SetupPage) {
        showingLive = false
        toolbar.isHidden = true
        settingsNavigation.isHidden = true
        actions.isHidden = true
        mount(setup.contentView)
        setup.prepare()
        bringToFront()
    }
    func showActiveRecording() {
        guard recordingBarIsVisible else { return }
        showingLive = true
        navigation.navigate(.allMeetings)
        navigation.showsDetail = true
        navigation.resultTab = "transcript"
        toolbar.isHidden = false
        updateHeading()
        actions.setViews([], in: .center)
        settingsNavigation.isHidden = true
        sidebar.select(.allMeetings)
        mount(liveView)
    }
    func show() {
        if navigation.destination.isMeetings { libraryProvider?()?.refresh() }
        updateActivationPolicy(windowVisible: true)
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFront(nil)
    }
    func bringToFront() {
        show()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    func hide() {
        panel.orderOut(nil)
        updateActivationPolicy(windowVisible: false)
    }
    func applyDockPreference() {
        keepsDockIcon = Config.dockIcon()
        updateActivationPolicy(windowVisible: isVisible)
    }
    private func updateActivationPolicy(windowVisible: Bool) {
        let wanted: NSApplication.ActivationPolicy = keepsDockIcon || windowVisible ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        // Restoring a regular app must also restore its own menu bar.
        if wanted == .regular, windowVisible { NSApp.activate(ignoringOtherApps: true) }
    }
    func windowDidMiniaturize(_ notification: Notification) {
        updateActivationPolicy(windowVisible: false)
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        updateActivationPolicy(windowVisible: true)
    }
    func windowWillClose(_ notification: Notification) {
        updateActivationPolicy(windowVisible: false)
    }
    func update(state: MenuBarController.State, elapsed: String?) {
        let wasRecording = recordingBarIsVisible
        recordingBar.update(state: state, elapsed: elapsed)
        liveView.refreshAudioLevels()
        if wasRecording && state == .idle && showingLive { navigate(.allMeetings) }
        sidebar.updateRecording(state != .idle)
        if state != .idle { recordingSheet?.cancel() }
    }
    func updateAutoRecord(enabled: Bool, decision: String?) {
        sidebar.updateAutomatic(enabled, reason: decision)
    }
    func updateLive(_ snapshot: LiveTranscriptionCoordinator.Snapshot) { live.updateLive(snapshot) }
    func updateLivePreference(enabled: Bool) { live.updateLivePreference(enabled: enabled) }
    func updateConfigProblem(_ headline: String?) { live.updateConfigProblem(headline) }
    func updateImport(_ update: MediaImportCoordinator.Update) { live.updateImport(update) }
    func finishImport(_ result: MediaImportCoordinator.Result) { live.finishImport(result); libraryProvider?()?.sessionsChanged() }
    func startRecording() {
        guard !recordingBarIsVisible else { return }
        onToggle?()
        if recordingBarIsVisible { showActiveRecording() }
    }
    func pauseRecording() { if recordingBarIsVisible { onTogglePause?() } }
    func stopRecording() { if recordingBarIsVisible { onToggle?() } }
    @objc private func showAll() { navigation.showAllMeetings(); libraryProvider?()?.applyFilter(.allMeetings, clearSearch: true); navigate(.allMeetings) }
    @objc private func sectionClicked() { if navigation.destination.isMeetings { showAll() } else { navigate(.general) } }
    @objc private func showAbout() { navigate(.about) }
    func newRecording() {
        guard !recordingBarIsVisible, panel.attachedSheet == nil else { return }
        let sheet = NewRecordingSheet(calendarEnabled: Config.useCalendar(), loadCalendar: recordingCalendar)
        if let calendarSearch { sheet.calendarPicker.loadEvents = calendarSearch }
        sheet.calendarPicker.resolveEvent = calendarResolve
        recordingSheet = sheet
        sheet.onComplete = { [weak self, weak sheet] result in
            guard let self, let sheet else { return }
            self.panel.endSheet(sheet.panel)
            self.recordingSheet = nil
            switch result {
            case .start(let title, let meeting):
                guard !self.recordingBarIsVisible else { return }
                self.onStartRecording?(title, meeting)
                if self.recordingBarIsVisible { self.showActiveRecording() }
            case .settings: self.navigate(.recording)
            case .cancel: break
            }
        }
        panel.beginSheet(sheet.panel) { _ in sheet.panel.orderOut(nil) }
        sheet.load()
    }

}

@MainActor
private final class WorkspaceSurface: JournalSurface {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
}

@MainActor
private final class JournalSettingsNavigation: NSStackView {
    private let destinations: [ApplicationNavigationState.Destination] = [.general, .recording, .transcription, .summary, .calendar, .storage]
    private let tabs = NSStackView()
    private var buttons: [JournalSettingsTab] = []
    private var tabsWidth: CGFloat = 48 + 5 * 16
    private let compact = NSPopUpButton()
    var onSelect: ((ApplicationNavigationState.Destination) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 14, right: 24)
        tabs.spacing = 16
        setClippingResistancePriority(.defaultLow, for: .horizontal)
        tabs.setClippingResistancePriority(.defaultLow, for: .horizontal)
        tabs.identifier = .init("settings.tabs")
        tabs.setAccessibilityRole(.tabGroup)
        tabs.setAccessibilityLabel(localised("Settings sections", "Разделы настроек"))
        compact.identifier = .init("settings.sections")
        let symbols = ["slider.horizontal.3", "mic", "text.bubble", "checklist", "calendar", "folder"]
        for (index, destination) in destinations.enumerated() {
            let title = switch destination {
            case .summary: localised("Summary", "Сводка")
            case .storage: localised("Files & models", "Файлы и модели")
            default: destination.title
            }
            let button = JournalSettingsTab(title: title, target: self, action: #selector(selected(_:)))
            button.tag = index
            button.identifier = .init("settings.tab.\(destination.rawValue)")
            button.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.isBordered = false
            button.setButtonType(.toggle)
            button.setAccessibilityRole(.radioButton)
            button.font = .systemFont(ofSize: 13, weight: .semibold)
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
            let width = button.intrinsicContentSize.width + 12
            let preferredWidth = button.widthAnchor.constraint(equalToConstant: width)
            preferredWidth.priority = .defaultHigh
            preferredWidth.isActive = true
            tabsWidth += width
            tabs.addArrangedSubview(button)
            buttons.append(button)
            compact.addItem(withTitle: title)
            compact.lastItem?.image = button.image
        }
        compact.target = self
        compact.action = #selector(selected(_:))
        compact.setAccessibilityLabel(localised("Settings section", "Раздел настроек"))
        compact.isHidden = true
        addArrangedSubview(tabs)
        addArrangedSubview(compact)
        addArrangedSubview(SetupLayout.spacer())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func select(_ destination: ApplicationNavigationState.Destination) {
        guard let index = destinations.firstIndex(of: destination) else { return }
        for (offset, button) in buttons.enumerated() {
            button.state = offset == index ? .on : .off
            button.font = .systemFont(ofSize: 13, weight: offset == index ? .semibold : .regular)
            button.contentTintColor = offset == index ? JournalStyle.ink : JournalStyle.muted
            button.needsDisplay = true
        }
        compact.selectItem(at: index)
    }
    @objc private func selected(_ sender: NSControl) {
        let index = sender === compact ? compact.indexOfSelectedItem : sender.tag
        guard destinations.indices.contains(index) else { return }
        onSelect?(destinations[index])
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let narrow = newSize.width < tabsWidth
        tabs.isHidden = narrow
        compact.isHidden = !narrow
    }
}

@MainActor
private final class JournalSettingsTab: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if state == .on {
            JournalStyle.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: isFlipped ? bounds.height - 3 : 0,
                                            width: bounds.width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
