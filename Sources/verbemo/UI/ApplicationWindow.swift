import AppKit

/// The only ordinary application window. Runtime work outlives its content.
@MainActor
final class ApplicationWindow: NSObject, NSWindowDelegate {
    let panel: NSWindow
    private let calendar: CalendarWatcher
    private let sidebar = SidebarView()
    private let recordingBar = RecordingBarView()
    private let activityBar = ActivityStatusBar()
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
    private var settingsBuilt = false
    private var stopping = false
    lazy var settings: SettingsController = {
        settingsBuilt = true
        let settings = SettingsController(hostWindow: panel, calendar: calendar)
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
    private var presentedSetup: SetupPage?
    private var keepsDockIcon = Config.dockIcon()
    var toolbarIsHidden: Bool { toolbar.isHidden }
    var primaryActionsAreVisible: Bool { !sidebar.isHidden }
    var recordingBarIsVisible: Bool { !recordingBar.isHidden }
    var isVisible: Bool { panel.isVisible && !panel.isMiniaturized }

    init(calendar: CalendarWatcher = CalendarWatcher()) {
        self.calendar = calendar
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
        activityBar.onToggleAutomatic = { [weak self] in self?.onToggleAutoRecord?() }
        activityBar.onRecording = { [weak self] in self?.showActiveRecording() }
        activityBar.onQueue = { [weak self] in self?.navigate(.processing, clearSearch: true) }
        activityBar.onAttention = { [weak self] in self?.navigate(.attention, clearSearch: true) }
        activityBar.onAccess = { [weak self] in self?.navigate($0) }
        activityBar.onJob = { [weak self] dir in
            guard let self else { return }
            self.navigate(.allMeetings)
            if let dir { Task { [weak self] in _ = await self?.libraryProvider?()?.reveal(dir) } }
        }
        activityBar.readAudioLevels = { [weak self] in self?.readAudioLevels?() ?? (.off, .off) }
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
        let statusDivider = NSBox()
        statusDivider.boxType = .separator
        for view in [statusDivider, activityBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor), root.bottomAnchor.constraint(equalTo: statusDivider.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor), root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor), statusDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusDivider.bottomAnchor.constraint(equalTo: activityBar.topAnchor),
            activityBar.leadingAnchor.constraint(equalTo: container.leadingAnchor), activityBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            activityBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        library.activeRecordingView = liveView
        sidebar.mountLibrary(library.listContentView)
        library.setMeetingSelectionActive(navigation.destination.isMeetings)
        library.onSelectMeeting = { [weak self, weak library] in
            guard let self, let library else { return }
            library.setMeetingSelectionActive(true)
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
    func navigate(_ destination: ApplicationNavigationState.Destination, clearSearch: Bool = false) {
        guard !stopping else { return }
        let enteringSettings = navigation.destination.isMeetings || navigation.destination == .about
        showingLive = false
        navigation.navigate(destination)
        libraryProvider?()?.setMeetingSelectionActive(destination.isMeetings)
        sidebar.select(destination)
        toolbar.isHidden = destination == .about
        updateHeading()
        actions.isHidden = false
        settingsNavigation.isHidden = destination.isMeetings || destination == .about
        settingsNavigation.select(destination)
        let content: NSView
        if destination.isMeetings, let library = libraryProvider?() {
            library.refresh()
            library.applyFilter(destination, clearSearch: clearSearch)
            actions.setViews([library.toolbarContent], in: .center)
            content = library.contentView
        } else if destination == .about {
            content = SetupLayout.scroller(around: about.contentView)
        } else if !destination.isMeetings {
            if enteringSettings && isVisible { settings.reload() }
            let about = NSButton(title: localised("About", "О приложении"), target: self, action: #selector(showAbout))
            about.isBordered = false
            actions.setViews([about], in: .center)
            content = settings.content(for: destination)
        } else {
            content = NSTextField(labelWithString: localised("No meetings yet", "Встреч пока нет"))
        }
        mount(content)
    }
    func stopForTermination() -> [Task<Void, Never>] {
        stopping = true
        activityBar.stop()
        finishSetup()
        recordingSheet?.cancel()
        if let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .cancel) }
        return settingsBuilt ? settings.stopForTermination() : []
    }

    func showStopping(_ text: String) {
        toolbar.isHidden = true
        sidebar.isHidden = true
        recordingBar.isHidden = true
        settingsNavigation.isHidden = true
        let note = NSTextField(labelWithString: text)
        note.alignment = .center
        note.font = .systemFont(ofSize: 16)
        note.identifier = .init("application.stopping")
        mount(note)
    }

    private func mount(_ view: NSView) {
        if view.superview === contentHost { return }
        finishSetup()
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
        guard !stopping else { return }
        showingLive = false
        toolbar.isHidden = true
        settingsNavigation.isHidden = true
        actions.isHidden = true
        mount(setup.contentView)
        presentedSetup = setup
        setup.prepare()
        bringToFront()
    }
    func showActiveRecording() {
        guard recordingBarIsVisible else { return }
        showingLive = true
        navigation.navigate(.allMeetings)
        libraryProvider?()?.setMeetingSelectionActive(true)
        navigation.showsDetail = true
        navigation.resultTab = "transcript"
        toolbar.isHidden = false
        updateHeading()
        actions.isHidden = false
        settingsNavigation.isHidden = true
        sidebar.select(.allMeetings)
        if let library = libraryProvider?(), library.selectActiveRecording() {
            actions.setViews([library.toolbarContent], in: .center)
            mount(library.contentView)
            library.updateCompactLayout()
        } else {
            actions.setViews([], in: .center)
            mount(liveView)
        }
    }
    func show() {
        if navigation.destination.isMeetings { libraryProvider?()?.refresh() }
        else if !isVisible && navigation.destination != .about { settings.reload() }
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
        if presentedSetup != nil { navigate(.allMeetings) }
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
        if presentedSetup != nil { navigate(.allMeetings) }
        updateActivationPolicy(windowVisible: false)
    }
    private func finishSetup() {
        let setup = presentedSetup
        presentedSetup = nil
        setup?.finish()
    }
    func update(state: MenuBarController.State, elapsed: String?) {
        guard !stopping else { return }
        let wasRecording = recordingBarIsVisible
        recordingBar.update(state: state, elapsed: elapsed)
        activityBar.updateRecording(state, elapsed: elapsed)
        liveView.refreshAudioLevels()
        if wasRecording && state == .idle && showingLive { navigate(.allMeetings) }
        sidebar.updateRecording(state != .idle)
        if state != .idle { recordingSheet?.cancel() }
    }
    func updateAutoRecord(enabled: Bool, decision: String?, blocked: Bool = false) {
        activityBar.updateAutomatic(enabled, reason: decision, blocked: blocked)
    }
    func updateActivity(_ operations: [ProcessingOperations.Snapshot], access: ActivityAccess) {
        let library = libraryProvider?()
        activityBar.updateWork(operations) { [weak library] in library?.activityTitle(for: $0) ?? $0.lastPathComponent }
        activityBar.updateAccess(access)
        activityBar.updateAttention(count: library?.attentionCount ?? 0, detail: Config.unreadableReason)
    }
    func updateLive(_ snapshot: LiveTranscriptionCoordinator.Snapshot) { live.updateLive(snapshot) }
    func updateLivePreference(enabled: Bool) { live.updateLivePreference(enabled: enabled) }
    func updateConfigProblem(_ headline: String?) { live.updateConfigProblem(headline) }
    func updateImport(_ update: MediaImportCoordinator.Update) {
        live.updateImport(update)
        activityBar.updateImport(MediaImportPresentation.progress(update))
    }
    func finishImport(_ result: MediaImportCoordinator.Result) {
        activityBar.updateImport(nil)
        live.finishImport(result)
        libraryProvider?()?.sessionsChanged()
    }
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
        guard !stopping else { return }
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
    private var buttons: [JournalTabButton] = []
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
            let button = JournalTabButton(title: title, symbol: symbols[index], target: self, action: #selector(selected(_:)))
            button.tag = index
            button.identifier = .init("settings.tab.\(destination.rawValue)")
            tabsWidth += button.intrinsicContentSize.width + 12
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
            button.select(offset == index)
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
