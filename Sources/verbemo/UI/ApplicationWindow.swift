import AppKit

/// The only ordinary application window. Runtime work outlives its content.
@MainActor
final class ApplicationWindow: NSObject, NSWindowDelegate {
    let panel: NSWindow
    private let calendar: CalendarWatcher
    private let sidebar = SidebarView()
    private var workspaceSplit: WorkspaceSplitController!
    private let libraryToggle = NSButton()
    private let primaryActions = NSStackView()
    private let primaryRecord = NSButton()
    private let primarySettings = NSButton()

    private let recordingBar = RecordingBarView()
    private let activityBar = ActivityStatusBar()
    private let toolbar = NSStackView()
    private let title = NSButton()
    private let heading = NSTextField(labelWithString: "")
    private let contentHost = NSView()
    private let settingsNavigation = JournalSettingsNavigation()
    private let allSettings = NSButton()
    private let settingsBackRow = NSStackView()
    private var settingsOverview = false
    private var settingsWasCompact = false
    private var settingsReturnDestination: ApplicationNavigationState.Destination = .allMeetings
    private var settingsLibraryCollapsed = false
    private var settingsLibraryWidth = JournalStyle.sidebarWidth
    private weak var settingsReturnFocus: NSView?
    private var compactSettings: Bool { panel.contentLayoutRect.width < 980 }
    private var showingLive = false
    private lazy var live = LiveTranscriptContent()
    private lazy var liveView: LiveTranscriptView = {
        let view = LiveTranscriptView(content: live.contentView, recordingBar: recordingBar)
        view.onError = { [weak self] in self?.activityBar.reportError($0) }
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
    private var settingsServiceViews: [NSView] = []
    var mcp: MCPController? { didSet { if settingsBuilt { settings.mcp = mcp } } }
    private var stopping = false
    lazy var settings: SettingsController = {
        settingsBuilt = true
        let settings = SettingsController(hostWindow: panel, calendar: calendar)
        settings.mcp = mcp
        settings.isProcessing = { [weak self] in self?.isProcessing?() == true }
        settings.isRecording = { [weak self] in self?.recordingBarIsVisible == true }
        settingsServiceViews = settings.serviceViews
        activityBar.setServiceViews(live.serviceViews + (libraryProvider?()?.serviceViews ?? []) + settingsServiceViews)
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
    var onQuit: () -> Void = { NSApp.terminate(nil) }
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
    var onCancelImport: (() -> Void)? { didSet { activityBar.onCancelImport = onCancelImport } }
    var recordingTitle: String {
        get { recordingBar.title }
        set { recordingBar.title = newValue; liveView.title = newValue }
    }
    private var appearance: AppearanceController?
    private var presentedSetup: SetupPage?
    private var keepsDockIcon = Config.dockIcon()
    var toolbarIsHidden: Bool { toolbar.isHidden }
    var primaryActionsAreVisible: Bool { !primaryActions.isHiddenOrHasHiddenAncestor }
    var recordingBarIsVisible: Bool { !recordingBar.isHidden }
    var isVisible: Bool { panel.isVisible && !panel.isMiniaturized }

    init(calendar: CalendarWatcher = CalendarWatcher()) {
        self.calendar = calendar
        panel = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.target = self
        panel.standardWindowButton(.miniaturizeButton)?.action = #selector(minimize)
        (panel as? WorkspaceWindow)?.onFindMeeting = { [weak self] in
            guard let self, self.navigation.destination.isMeetings, !self.showingLive else { return false }
            return self.libraryProvider?()?.focusMeetingSearch() == true
        }
        panel.title = "Verbemo"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = JournalStyle.paper
        panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true
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
        title.heightAnchor.constraint(equalToConstant: 32).isActive = true
        heading.font = .systemFont(ofSize: 12)
        heading.textColor = JournalStyle.muted
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        libraryToggle.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        libraryToggle.isBordered = false
        libraryToggle.target = self
        libraryToggle.action = #selector(toggleLibrary)
        libraryToggle.identifier = .init("workspace.toggle-library")
        libraryToggle.toolTip = localised("Hide meeting list", "Скрыть список встреч")
        libraryToggle.setAccessibilityLabel(libraryToggle.toolTip)
        libraryToggle.setAccessibilityValue(1)
        let importButton = NSButton()
        for (button, label, symbol, identifier, action, key) in [
            (primaryRecord, localised("New recording", "Новая запись"), "record.circle", "journal.new-recording", #selector(primaryRecordClicked), "n"),
            (importButton, localised("Import", "Импорт"), "square.and.arrow.down", "journal.import", #selector(primaryImportClicked), ""),
            (primarySettings, localised("Settings", "Настройки"), "slider.horizontal.3", "journal.settings", #selector(primarySettingsClicked), ","),
        ] {
            button.title = label
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.identifier = .init(identifier)
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.keyEquivalent = key
            button.keyEquivalentModifierMask = .command
            button.target = self
            button.action = action
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            primaryActions.addArrangedSubview(button)
        }
        primaryRecord.bezelColor = StudioStyle.accent
        primaryRecord.contentTintColor = StudioStyle.paper
        primaryActions.spacing = 8
        toolbar.setViews([libraryToggle, title, heading, spacer, primaryActions], in: .center)
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 8, right: 24)
        toolbar.heightAnchor.constraint(equalToConstant: 48).isActive = true
        settingsNavigation.identifier = .init("settings.categories")
        settingsNavigation.onSelect = { [weak self] destination in
            self?.settingsOverview = false
            self?.navigate(destination)
            if self?.compactSettings == true { self?.panel.makeFirstResponder(self?.allSettings) }
        }
        allSettings.title = localised("All settings", "Все разделы")
        allSettings.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        allSettings.imagePosition = .imageLeading
        allSettings.isBordered = false
        allSettings.identifier = .init("settings.all-categories")
        allSettings.heightAnchor.constraint(equalToConstant: 32).isActive = true
        allSettings.target = self
        allSettings.action = #selector(showSettingsCategories)
        settingsBackRow.setViews([allSettings, SetupLayout.spacer()], in: .center)
        settingsBackRow.edgeInsets = .init(top: 8, left: 24, bottom: 0, right: 24)
        settingsBackRow.isHidden = true
        let divider = NSBox(); divider.boxType = .separator
        let right = NSStackView(views: [settingsBackRow, contentHost])
        right.orientation = .vertical
        right.distribution = .fill
        right.spacing = 0
        right.alignment = .leading
        right.detachesHiddenViews = true
        contentHost.setContentHuggingPriority(.init(1), for: .vertical)
        for view in right.arrangedSubviews { view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        workspaceSplit = WorkspaceSplitController(sidebar: sidebar, content: right)
        let root = workspaceSplit.view
        let container = WorkspaceSurface(JournalStyle.paper)
        root.setContentHuggingPriority(.init(1), for: .vertical)
        let statusDivider = NSBox()
        statusDivider.boxType = .separator
        let stack = NSStackView(views: [toolbar, divider, root, statusDivider, activityBar])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor), stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        workspaceSplit.splitView.setPosition(JournalStyle.sidebarWidth, ofDividerAt: 0)
        panel.initialFirstResponder = container
        appearance = AppearanceController(window: panel)
        panel.contentMinSize = NSSize(width: 760, height: 600)
        panel.setFrameAutosaveName("name.ekho.verbemo.workspace")
        if panel.frame.origin == .zero { panel.center() }
        activityBar.setServiceViews(live.serviceViews)
        navigate(.allMeetings)
    }
    @objc private func primaryRecordClicked() { newRecording() }
    @objc private func primaryImportClicked() { onChooseImport?() }
    @objc private func primarySettingsClicked() {
        navigate(.general)
        if compactSettings { settingsOverview = true; displaySettings() }
        settingsReturnFocus = primarySettings
    }
    @objc private func showSettingsCategories() {
        settingsOverview = true
        displaySettings()
        panel.makeFirstResponder(settingsNavigation.selectedButton)
    }
    @objc private func toggleLibrary() {
        if workspaceSplit.libraryItem.isCollapsed {
            if navigation.destination.isMeetings { expandLibrary(width: settingsLibraryWidth) }
            else { workspaceSplit.libraryItem.isCollapsed = false }
        } else {
            if navigation.destination.isMeetings { settingsLibraryWidth = sidebar.frame.width }
            workspaceSplit.libraryItem.isCollapsed = true
        }
        updateLibraryToggle()
        libraryProvider?()?.updateCompactLayout()
    }
    private func updateLibraryToggle() {
        let collapsed = workspaceSplit.libraryItem.isCollapsed
        let inSettings = !navigation.destination.isMeetings && presentedSetup == nil
        libraryToggle.isHidden = inSettings && compactSettings
        libraryToggle.toolTip = inSettings
            ? (collapsed ? localised("Show settings categories", "Показать разделы настроек") : localised("Hide settings categories", "Скрыть разделы настроек"))
            : (collapsed ? localised("Show meeting list", "Показать список встреч") : localised("Hide meeting list", "Скрыть список встреч"))
        libraryToggle.setAccessibilityLabel(libraryToggle.toolTip)
        libraryToggle.setAccessibilityValue(collapsed ? 0 : 1)
    }
    private func restoreLibrarySidebar() {
        sidebar.mount(libraryProvider?()?.listContentView ?? NSView())
        settingsBackRow.isHidden = true
        settingsNavigation.isHidden = true
        expandLibrary(width: settingsLibraryWidth)
        workspaceSplit.libraryItem.isCollapsed = settingsLibraryCollapsed
        updateLibraryToggle()
        libraryProvider?()?.updateCompactLayout()
    }
    private func expandLibrary(width preferred: CGFloat) {
        // Settle the document's adaptive inspector before AppKit evaluates its minimum width.
        panel.contentView?.layoutSubtreeIfNeeded()
        libraryProvider?()?.updateCompactLayout()
        panel.contentView?.layoutSubtreeIfNeeded()
        let maximum = panel.contentLayoutRect.width - workspaceSplit.splitViewItems[1].minimumThickness - workspaceSplit.splitView.dividerThickness
        let originalMaximum = workspaceSplit.libraryItem.maximumThickness
        let limit = max(workspaceSplit.libraryItem.minimumThickness, min(originalMaximum, maximum))
        let width = max(workspaceSplit.libraryItem.minimumThickness, min(preferred, limit))
        // Constraint-based expansion keeps the user's window size instead of restoring an old frame.
        let behavior = workspaceSplit.libraryItem.collapseBehavior
        workspaceSplit.libraryItem.collapseBehavior = .useConstraints
        workspaceSplit.libraryItem.isCollapsed = false
        workspaceSplit.splitView.setPosition(width, ofDividerAt: 0)
        workspaceSplit.libraryItem.collapseBehavior = behavior
    }
    private func displaySettings(refreshContent: Bool = true) {
        settingsWasCompact = compactSettings
        settingsNavigation.isHidden = false
        settingsNavigation.presentOverview(compactSettings && settingsOverview)
        settingsNavigation.select(navigation.destination)
        settingsBackRow.isHidden = !compactSettings || settingsOverview
        if compactSettings {
            workspaceSplit.libraryItem.isCollapsed = true
            if settingsOverview {
                mount(settingsNavigation)
                updateHeading()
                updateLibraryToggle()
                return
            }
        } else {
            settingsOverview = false
            settingsBackRow.isHidden = true
            sidebar.mount(settingsNavigation)
            workspaceSplit.libraryItem.isCollapsed = false
        }
        let content: NSView
        if !refreshContent, let current = contentHost.subviews.first, current !== settingsNavigation {
            content = current
        } else {
            content = navigation.destination == .about
                ? SetupLayout.scroller(around: about.contentView) : settings.content(for: navigation.destination)
        }
        mount(content)
        updateHeading()
        updateLibraryToggle()
    }
    func windowDidResize(_ notification: Notification) {
        guard !stopping, !navigation.destination.isMeetings, presentedSetup == nil,
              settingsWasCompact != compactSettings else { return }
        displaySettings(refreshContent: false)
    }
    private func connectLibrary() {
        guard let library = libraryProvider?() else { return }
        activityBar.setServiceViews(live.serviceViews + library.serviceViews + settingsServiceViews)
        library.activeRecordingView = liveView
        if navigation.destination.isMeetings { sidebar.mount(library.listContentView) }
        library.setMeetingSelectionActive(navigation.destination.isMeetings)
        library.onSelectMeeting = { [weak self, weak library] in
            guard let self, let library else { return }
            library.setMeetingSelectionActive(true)
            self.showingLive = false
            let returning = !self.navigation.destination.isMeetings
            self.navigation.navigate(library.currentFilter)
            self.toolbar.isHidden = false
            self.settingsNavigation.isHidden = true
            self.updateHeading()
            library.updateCompactLayout()
            self.mount(library.contentView)
            if returning { self.restoreLibrarySidebar() }
        }
        library.onNavigateSettings = { [weak self] in self?.navigate($0) }
    }
    func navigate(_ destination: ApplicationNavigationState.Destination, clearSearch: Bool = false) {
        guard !stopping else { return }
        let previous = navigation.destination
        let enteringSettings = previous.isMeetings
        if enteringSettings && !destination.isMeetings {
            settingsReturnDestination = previous
            settingsLibraryCollapsed = workspaceSplit.libraryItem.isCollapsed
            if !settingsLibraryCollapsed { settingsLibraryWidth = sidebar.frame.width }
            settingsReturnFocus = (panel.firstResponder as? NSTextView)?.delegate as? NSView ?? panel.firstResponder as? NSView
        }
        settingsOverview = false
        showingLive = false
        navigation.navigate(destination)
        libraryProvider?()?.setMeetingSelectionActive(destination.isMeetings)
        toolbar.isHidden = false
        updateHeading()
        let content: NSView
        if destination.isMeetings, let library = libraryProvider?() {
            library.refresh()
            library.applyFilter(destination, clearSearch: clearSearch)
            content = library.contentView
        } else if destination == .about {
            displaySettings()
            return
        } else if !destination.isMeetings {
            if (enteringSettings || previous == .about) && isVisible { settings.reload() }
            displaySettings()
            return
        } else {
            content = NSTextField(labelWithString: localised("No meetings yet", "Встреч пока нет"))
        }
        mount(content)
        if destination.isMeetings && !previous.isMeetings { restoreLibrarySidebar() }
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
        workspaceSplit.libraryItem.isCollapsed = true
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
        title.title = destination.isMeetings ? "Verbemo" : localised("Back to meetings", "К встречам")
        title.image = destination.isMeetings ? nil : NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        title.imagePosition = .imageLeading
        title.font = .systemFont(ofSize: destination.isMeetings ? 17 : 12, weight: destination.isMeetings ? .semibold : .regular)
        title.setAccessibilityLabel(destination.isMeetings ? localised("All meetings", "Все встречи") : title.title)
        primarySettings.state = destination.isMeetings ? .off : .on
        heading.stringValue = "/  " + (settingsOverview && compactSettings ? localised("Settings", "Настройки") : destination.title)
        heading.isHidden = destination == .allMeetings
    }
    func presentSetup(_ setup: SetupPage) {
        guard !stopping else { return }
        showingLive = false
        toolbar.isHidden = false
        settingsNavigation.isHidden = true
        settingsBackRow.isHidden = true
        if !navigation.destination.isMeetings { sidebar.mount(libraryProvider?()?.listContentView ?? NSView()) }
        mount(setup.contentView)
        presentedSetup = setup
        setup.prepare()
        bringToFront()
    }
    func showActiveRecording() {
        guard recordingBarIsVisible else { return }
        showingLive = true
        let returning = !navigation.destination.isMeetings
        navigation.navigate(.allMeetings)
        libraryProvider?()?.setMeetingSelectionActive(true)
        navigation.showsDetail = true
        navigation.resultTab = "transcript"
        toolbar.isHidden = false
        updateHeading()
        settingsNavigation.isHidden = true
        if let library = libraryProvider?(), library.selectActiveRecording() {
            mount(library.contentView)
            library.updateCompactLayout()
        } else {
            mount(liveView)
        }
        if returning { restoreLibrarySidebar() }
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
    @objc func minimize() {
        if keepsDockIcon { panel.miniaturize(nil) }
        else { hide() }
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
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if Config.menuBarIcon() { hide() }
        else { onQuit() }
        return false
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
        primaryRecord.isEnabled = state == .idle
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
        activityBar.showImport(update)
    }
    func finishImport(_ result: MediaImportCoordinator.Result) {
        activityBar.finishImport(result)
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
    @objc private func sectionClicked() {
        if navigation.destination.isMeetings { showAll() }
        else {
            navigate(settingsReturnDestination)
            if let focus = settingsReturnFocus, focus.window === panel, !focus.isHiddenOrHasHiddenAncestor {
                panel.makeFirstResponder(focus)
            } else { panel.makeFirstResponder(primarySettings) }
        }
    }
    func newRecording() {
        guard !stopping else { return }
        guard !recordingBarIsVisible, panel.attachedSheet == nil else { return }
        let sheet = NewRecordingSheet(calendarEnabled: Config.useCalendar(), loadCalendar: recordingCalendar)
        sheet.calendarPicker.onError = { [weak self] error in self?.activityBar.reportError(error.localizedDescription) }
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
    private let destinations: [ApplicationNavigationState.Destination] = [.general, .recording, .transcription, .summary, .calendar, .storage, .mcp, .about]
    private var buttons: [NSButton] = []
    private var widths: [NSLayoutConstraint] = []
    var selectedButton: NSButton? { buttons.first { $0.state == .on } }
    var onSelect: ((ApplicationNavigationState.Destination) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(localised("Settings categories", "Разделы настроек"))
        for (index, destination) in destinations.enumerated() {
            let title = switch destination {
            case .summary: localised("Summaries", "Сводки")
            case .storage: localised("Files & models", "Файлы и модели")
            default: destination.title
            }
            let button = SettingsCategoryButton(title: title, target: self, action: #selector(selected(_:)))
            button.image = NSImage(systemSymbolName: destination.symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.isBordered = false
            button.setButtonType(.toggle)
            button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(title)
            button.toolTip = title
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.tag = index
            button.identifier = .init("settings.tab.\(destination.rawValue)")
            addArrangedSubview(button)
            buttons.append(button)
            let width = button.widthAnchor.constraint(equalTo: widthAnchor)
            width.isActive = true
            widths.append(width)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        addArrangedSubview(spacer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func select(_ destination: ApplicationNavigationState.Destination) {
        guard let index = destinations.firstIndex(of: destination) else { return }
        for (offset, button) in buttons.enumerated() {
            button.state = offset == index ? .on : .off
            button.contentTintColor = offset == index ? StudioStyle.accent : StudioStyle.ink
            button.needsDisplay = true
        }
    }
    func presentOverview(_ value: Bool) {
        let inset: CGFloat = value ? 24 : 0
        edgeInsets = .init(top: 12, left: inset, bottom: 12, right: inset)
        for width in widths { width.constant = -2 * inset }
    }
    @objc private func selected(_ sender: NSControl) {
        let index = sender.tag
        guard destinations.indices.contains(index) else { return }
        onSelect?(destinations[index])
    }
}

@MainActor
private final class SettingsCategoryButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            StudioStyle.selection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
