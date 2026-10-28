import AppKit

/// The Journal meeting list, document and inspector hosted by ApplicationWindow.
@MainActor
final class MeetingLibraryController: NSObject, NSTextFieldDelegate {
    struct RetranscriptionEngine {
        let id: String
        let title: String
    }

    static var retranscriptionEngines: [RetranscriptionEngine] { [
        .init(id: "parakeet", title: "Parakeet"),
        .init(id: "whisper", title: "Whisper"),
        .init(id: "gigaam", title: "GigaAM"),
        .init(id: "nemotron", title: "Nemotron 3.5 ASR"),
        .init(id: "assemblyai", title: "AssemblyAI"),
        .init(id: "openai", title: "OpenAI"),
        .init(id: "elevenlabs", title: "ElevenLabs"),
    ] }

    var onImportFiles: (([URL]) -> Void)?
    var onCancelImport: (() -> Void)?
    var onResumeDiarization: (@MainActor (URL, DiarizationState.Request) async throws -> Void)?
    var onRetryDiarization: ((URL) async throws -> Void)?
    var onSkipDiarization: ((URL) async throws -> Void)?
    private var root: URL
    private let panel: NSWindow
    private(set) var contentView = NSView()
    private(set) var listContentView = NSView()
    let toolbarContent = NSStackView()
    var onSelectMeeting: (() -> Void)?
    var onNavigateSettings: ((ApplicationNavigationState.Destination) -> Void)?
    var currentFilter: ApplicationNavigationState.Destination { meetingFilter }
    private let filterPicker = NSPopUpButton()
    private let resultPicker = NSStackView()
    private let inspectorButton = NSButton()
    private let pipeline = NSStackView()
    private let route = NSTextField(wrappingLabelWithString: "")
    private let cancelProcessingButton = NSButton()
    private let processingStatus = NSTextField(wrappingLabelWithString: "")
    private let processingCancellation: MeetingProcessingCancellation
    private var processingMonitor: Task<Void, Never>?
    private var terminating = false
    private var inspectorRequested: Bool?
    private var reloadingList = false
    private var meetingSelectionActive = true
    private var rememberedMeeting: URL?
    private let pasteboard: NSPasteboard
    private let table = MeetingTableView()
    private var activeRecording: MeetingPresentation.ActiveRecording?
    var onOpenActiveRecording: (() -> Void)?
    var onRenameActiveRecording: ((String) throws -> Void)?
    private let openActiveButton = NSButton()
    func setActiveRecording(_ value: MeetingPresentation.ActiveRecording?) {
        guard activeRecording != value else { return }
        let refreshDetail = selected == nil || selected?.dir == activeRecording?.dir || selected?.dir == value?.dir
        activeRecording = value
        show(allItems, refreshDetail: refreshDetail)
    }
    private var allItems: [SessionInventory.Item] = []
    private var meetingFilter: ApplicationNavigationState.Destination = .allMeetings
    private let search = MeetingSearchField()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let clearSearch = NSButton()
    private let emptyView = NSStackView()
    private var meetingMenu = NSMenu()
    private let audioPlayer = MeetingPlaybackView()
    private let moreButton = NSButton()
    private let regenerateButton = NSButton()
    private let repeatButton = NSButton()
    private var journalColumns: JournalColumns?
    private let documentHost = NSView()
    private var meetingDocument: NSView?
    var activeRecordingView: LiveTranscriptView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let view = activeRecordingView {
                view.translatesAutoresizingMaskIntoConstraints = false
                documentHost.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: documentHost.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: documentHost.trailingAnchor),
                    view.topAnchor.constraint(equalTo: documentHost.topAnchor),
                    view.bottomAnchor.constraint(equalTo: documentHost.bottomAnchor),
                ])
            }
            showDetail()
        }
    }
    private var inspectorWidth: NSLayoutConstraint?
    private let scroll = NSScrollView()
    private var displayChanges: ConfigWatch.Token?

    private let calendarView = MeetingCalendarView()
    let calendarPicker = CalendarEventPicker()
    var calendarSearch: CalendarEventPicker.Loader? { didSet { calendarPicker.loadEvents = calendarSearch } }
    var calendarResolve: CalendarEventPicker.Resolver? { didSet { calendarPicker.resolveEvent = calendarResolve } }
    private let meetingTranscript = MeetingTranscriptView()
    private var plainTranscriptScroll: NSView?
    private let detailMeta = NSTextField(labelWithString: "")
    private let detailTitle = NSTextField(labelWithString: "")
    private let titleDoubleClick = NSClickGestureRecognizer()
    private let detailError = NSTextField(wrappingLabelWithString: "")
    private var renamingSession: URL?
    private let diarizationLabel = NSTextField(labelWithString: "")
    private let retryDiarizationButton = NSButton()
    private let skipDiarizationButton = NSButton()
    private let speakersStack = FlippedStackView()
    private let finishButton = NSButton()
    private let detailTabs = NSTabView()
    private let versionSelector = NSPopUpButton()
    private var versions: [TranscriptVersions.Version] = []
    private var versionSession: URL?
    private var versionKey: String?
    private var selectedVersion: TranscriptVersions.Version? {
        let index = versionSelector.indexOfSelectedItem
        return versions.indices.contains(index) ? versions[index] : nil
    }
    private var artifactDirectory: URL? { selectedVersion?.dir ?? selected?.dir }
    private func key(_ version: TranscriptVersions.Version) -> String {
        version.dir.path + (version.isRequest ? "#request" : "#result")
    }
    private let summaryText = NSTextView()
    private let transcriptText = NSTextView()
    private let busyLabel = NSTextField(labelWithString: "")
    private let importStatus = MediaImportStatusView()

    private var items: [SessionInventory.Item] = []
    private var selected: SessionInventory.Item? {
        if !meetingSelectionActive { return items.first { $0.dir == rememberedMeeting } }
        return table.selectedRow >= 0 && table.selectedRow < items.count
            ? items[table.selectedRow]
            : nil
    }
    /// Naming and summarizing take a while and talk to the network; the
    /// buttons stay disabled meanwhile so a second click can't start the same
    /// work twice.
    var onActivityChange: (() -> Void)?
    private let deletion = SessionDeletionController()
    private let deletionNotice = NSStackView()
    private let deletionLabel = NSTextField(labelWithString: "")
    private var undoDeletionID: UUID?
    var isProcessing: Bool { working || deletion.hasWork || processingCancellation.hasPending }
    func cancelPendingDeletion() { deletion.cancelAll(); onActivityChange?() }
    private var summarySheet: SummaryRegenerationSheet?
    private var summaryDirectory: URL?
    private var working = false { didSet { onActivityChange?() } }

    init(root: URL, pasteboard: NSPasteboard = .general,
         operations: ProcessingOperations = .shared, hostWindow: NSWindow) {
        processingCancellation = MeetingProcessingCancellation(operations: operations)
        self.root = root
        self.pasteboard = pasteboard
        panel = hostWindow
        super.init()
        buildTable()
        displayChanges = ConfigWatch.Token(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.table.reloadData() } }, center: NSWorkspace.shared.notificationCenter)
        contentView = buildLayout()
        meetingTranscript.onPlayFrom = { [weak self] seconds in self?.audioPlayer.play(from: seconds) }
        // Populate the first view synchronously; later scans run off the main thread.
        show(SessionInventory.scan(root: root))
        processingCancellation.onChange = { [weak self] in
            guard let self, !self.terminating else { return }
            self.updateCancellationControls()
            self.onActivityChange?()
            if self.processingCancellation.outcome != nil { self.reload() }
        }
        processingMonitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateCancellationControls()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    deinit { processingMonitor?.cancel() }

    /// Stop UI-owned work synchronously; the application awaits these after its processing barrier.
    func stopForTermination() -> [Task<Void, Never>] {
        terminating = true
        audioPlayer.setMeeting(nil)
        calendarPicker.cancel()
        let monitor = processingMonitor
        monitor?.cancel()
        processingMonitor = nil
        cancelPendingDeletion()
        scans += 1
        let scans = Array(scansInFlight.values)
        for task in scans { task.cancel() }
        scan = nil
        var cleanup = scans + processingCancellation.stopObserving()
        if let monitor { cleanup.append(monitor) }
        cleanup.append(deletion.stopForTermination())
        cleanup.append(Task { [audioPlayer] in await audioPlayer.settled() })
        if let task = summarySheet?.task { task.cancel(); cleanup.append(task) }
        return cleanup
    }

    // MARK: - building

    private func buildTable() {
        table.addTableColumn(NSTableColumn(identifier: .init("meeting-card")))
        table.headerView = nil
        table.selectionHighlightStyle = .regular
        table.backgroundColor = JournalStyle.sidebar
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.action = #selector(meetingClicked)
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.menu = meetingMenu
        meetingMenu.delegate = self
        meetingMenu.autoenablesItems = false
        table.onContext = { [weak self] row in
            guard let self, row < self.items.count else { return }
            self.table.selectRowIndexes([row], byExtendingSelection: false)
            self.showDetail()
            self.onSelectMeeting?()
        }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }

    private func buildLayout() -> NSView {
        busyLabel.font = .systemFont(ofSize: 11)
        busyLabel.textColor = .secondaryLabelColor
        diarizationLabel.font = .systemFont(ofSize: 11)
        diarizationLabel.textColor = .secondaryLabelColor
        diarizationLabel.lineBreakMode = .byWordWrapping
        diarizationLabel.maximumNumberOfLines = 3
        diarizationLabel.identifier = .init("diarization.status")
        for (button, title, action) in [
            (retryDiarizationButton, localised("Retry diarization", "Повторить диаризацию"),
             #selector(retryDiarizationClicked)),
            (skipDiarizationButton, localised("Skip diarization", "Пропустить диаризацию"),
             #selector(skipDiarizationClicked)),
            (finishButton, localised("Finish processing", "Доделать"), #selector(finishClicked)),
            (cancelProcessingButton, localised("Cancel processing", "Отменить обработку"), #selector(cancelProcessingClicked)),
        ] as [(NSButton, String, Selector)] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        cancelProcessingButton.identifier = .init("meeting.cancel-processing")
        processingStatus.identifier = .init("meeting.processing-status")
        processingStatus.font = .systemFont(ofSize: 11)
        processingStatus.textColor = JournalStyle.muted
        retryDiarizationButton.identifier = .init("diarization.retry")
        skipDiarizationButton.identifier = .init("diarization.skip")

        for (button, id, action) in [
            (repeatButton, "meeting.retranscribe", #selector(repeatTranscriptClicked)),
            (regenerateButton, "meeting.generate-summary", #selector(regenerateClicked)),
        ] {
            button.identifier = .init(id)
            button.title = ""
            button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        speakersStack.orientation = .vertical
        speakersStack.alignment = .leading
        speakersStack.spacing = 8
        speakersStack.identifier = .init("meeting.participants")

        for (id, label, view) in [
            ("summary", localised("Summary", "Сводка"), previewScroll(summaryText)),
            ("transcript", localised("Transcript", "Расшифровка"), transcriptContent()),
            ("participants", localised("Participants", "Участники"), SetupLayout.scroller(around: speakersStack)),
        ] as [(String, String, NSView)] {
            let tab = NSTabViewItem(identifier: id)
            tab.label = label
            tab.view = textPane(content: view)
            detailTabs.addTabViewItem(tab)
        }

        versionSelector.identifier = .init("transcript-versions")
        versionSelector.target = self
        versionSelector.action = #selector(versionSelected(_:))
        versionSelector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let diarizationActions = NSStackView(views: [retryDiarizationButton, skipDiarizationButton])
        diarizationActions.orientation = .horizontal
        diarizationActions.spacing = 8
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: localised("Meeting actions", "Действия со встречей"))
        moreButton.setAccessibilityLabel(localised("Meeting actions", "Действия со встречей"))
        moreButton.isBordered = false
        moreButton.target = self
        moreButton.action = #selector(moreClicked(_:))
        let titleRow = NSStackView(views: [detailTitle])
        detailTitle.identifier = .init("meeting.title")
        detailTitle.delegate = self
        detailTitle.target = self
        detailTitle.action = #selector(saveMeetingTitle)
        titleDoubleClick.numberOfClicksRequired = 2
        titleDoubleClick.target = self
        titleDoubleClick.action = #selector(beginRenamingMeeting)
        detailTitle.addGestureRecognizer(titleDoubleClick)
        detailError.textColor = .systemOrange
        detailError.font = .systemFont(ofSize: 12)
        detailError.isHidden = true
        calendarView.setContentHuggingPriority(.required, for: .vertical)
        titleRow.spacing = 12
        detailTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openActiveButton.title = localised("Open current recording", "Открыть текущую запись")
        openActiveButton.target = self
        openActiveButton.action = #selector(openActiveRecording)
        openActiveButton.isHidden = true
        detailTabs.tabViewType = .noTabsNoBorder
        resultPicker.spacing = 16
        for (index, (id, title, symbol)) in [
            ("summary", localised("Summary", "Сводка"), "checklist"),
            ("transcript", localised("Transcript", "Расшифровка"), "text.bubble"),
            ("participants", localised("Participants", "Участники"), "person.2"),
        ].enumerated() {
            let button = JournalTabButton(title: title, symbol: symbol, target: self, action: #selector(resultSelected(_:)))
            button.tag = index
            button.identifier = .init("meeting.result.\(id)")
            button.select(index == 0)
            resultPicker.addArrangedSubview(button)
        }
        resultPicker.identifier = .init("meeting.result-tabs")
        resultPicker.setAccessibilityRole(.tabGroup)
        resultPicker.setAccessibilityLabel(localised("Meeting result", "Результат встречи"))
        let versionActions = NSStackView(views: [resultPicker, NSView(), versionSelector])
        versionActions.orientation = .horizontal
        versionActions.spacing = 8
        let detail = NSStackView(views: [detailMeta, titleRow, detailError, openActiveButton, audioPlayer, versionActions, detailTabs, busyLabel])
        detail.orientation = .vertical
        detail.distribution = .fill
        detail.alignment = .leading
        detail.spacing = 10
        detailMeta.textColor = .secondaryLabelColor
        detailMeta.font = .systemFont(ofSize: 12)
        detailTitle.font = JournalStyle.titleFont()
        detailTitle.textColor = JournalStyle.ink
        detailTitle.maximumNumberOfLines = 2
        detailTitle.lineBreakMode = .byWordWrapping
        NSLayoutConstraint.activate([
            versionSelector.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor),
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        return buildJournal(detail: detail, diarizationActions: diarizationActions)
    }

    private func transcriptContent() -> NSView {
        let host = NSView()
        let plain = previewScroll(transcriptText)
        plainTranscriptScroll = plain
        for view in [plain, meetingTranscript] {
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        meetingTranscript.isHidden = true
        return host
    }
    /// Split and tab views own frames; a stack must only lay out inside them.
    private static func frameOwnedPane(_ content: NSView) -> NSView {
        let host = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }
    private func showCalendar(for item: SessionInventory.Item?) {
        let metadata = item.flatMap { MeetingCalendarMetadata.read(from: $0.dir) }
        calendarView.update(metadata)
        calendarPicker.isHidden = item == nil
        guard let item else { calendarPicker.cancel(); detailMeta.stringValue = ""; return }
        calendarPicker.update(date: item.started ?? Date(), snapshot: metadata, contextID: item.dir.path,
                              enabled: activeRecording?.dir != item.dir && !working && !SessionClaim.isHeld(item.dir))
        calendarPicker.onSelect = { [weak self] meeting in
            try MeetingCalendarMetadata.associate(meeting, in: item.dir)
            self?.reload()
        }
        let duration = item.duration.map { localised("\(Int($0 / 60)) min", "\(Int($0 / 60)) мин") }
        let invited = metadata?.isConfirmed == true ? metadata.map { localised("Invited: \($0.participants.count)", "Приглашены: \($0.participants.count)") } : nil
        detailMeta.stringValue = [MeetingPresentation.date(item.started), duration, invited].compactMap { $0 }.joined(separator: " · ")
        calendarView.onOpen = { [weak self] in
            guard let self, let metadata, let reason = CalendarEventOpener.open(metadata) else { return }
            let alert = NSAlert(); alert.messageText = reason; alert.beginJournalSheetModal(for: self.panel)
        }

    }

    var currentActions: MeetingActionState {
        let item = selected
        let dir = artifactDirectory
        let ready = selectedVersion?.isRequest != true && dir.flatMap(PostProcessor.readTranscript) != nil
            && (dir.map { DiarizationState.persisted(in: $0).isFinal } ?? false)
        var state = MeetingActionState(transcriptReady: ready, summaryReady: summaryToCopy != nil,
            hasAudio: item?.hasAudio == true, isRecording: activeRecording?.dir == item?.dir && activeRecording != nil,
            isBusy: working || (item.map { SessionClaim.isHeld($0.dir) } ?? false),
            configReadable: !Config.settingsUnknown, transcriptionEnabled: Config.transcriptionEnabled(),
            summaryEnabled: PostProcessor.Policy.configured.summary)
        state.hasPendingTranscript = item.map { TranscriptVersions.isRequested($0.dir) } ?? false
        return state
    }

    func applyFilter(_ filter: ApplicationNavigationState.Destination, clearSearch: Bool = false) {
        meetingFilter = filter
        filterPicker.selectItem(at: [.allMeetings, .processing, .attention].firstIndex(of: filter) ?? 0)
        if clearSearch { search.stringValue = "" }
        show(allItems)
    }
    func setMeetingSelectionActive(_ active: Bool) {
        guard meetingSelectionActive != active else { return }
        rememberedMeeting = selected?.dir ?? rememberedMeeting
        meetingSelectionActive = active
        show(allItems)
    }
    @discardableResult
    func selectActiveRecording() -> Bool {
        guard let activeRecording else { return false }
        setMeetingSelectionActive(true)
        applyFilter(.allMeetings, clearSearch: true)
        guard let row = items.firstIndex(where: { $0.dir == activeRecording.dir }) else { return false }
        reloadingList = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        reloadingList = false
        table.scrollRowToVisible(row)
        showDetail()
        return true
    }
    func updateCompactLayout() {
        guard let columns = journalColumns else { return }
        let compact = min(columns.bounds.width, max(0, panel.contentLayoutRect.width - JournalStyle.sidebarWidth)) < 850
        let visible = inspectorRequested ?? !compact
        inspectorWidth?.isActive = !compact
        columns.arrangedSubviews[0].isHidden = compact && visible
        columns.arrangedSubviews[1].isHidden = compact || !visible
        columns.arrangedSubviews[2].isHidden = !visible
        inspectorButton.state = visible ? .on : .off
        inspectorButton.setAccessibilityValue(visible ? 1 : 0)
    }
    @objc private func toggleInspector() {
        guard let columns = journalColumns else { return }
        inspectorRequested = columns.arrangedSubviews[2].isHidden
        updateCompactLayout()
    }
    @objc private func resultSelected(_ sender: NSButton) {
        for case let button as JournalTabButton in resultPicker.arrangedSubviews { button.select(button === sender) }
        detailTabs.selectTabViewItem(withIdentifier: ["summary", "transcript", "participants"][sender.tag])
    }
    @objc private func filterSelected() {
        let filters: [ApplicationNavigationState.Destination] = [.allMeetings, .processing, .attention]
        applyFilter(filters[filterPicker.indexOfSelectedItem])
        onSelectMeeting?()
    }
    @objc private func processingSettings() { onNavigateSettings?(.transcription) }
    @objc private func showCopyMenu(_ sender: NSButton) {
        makeCopyMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    func makeCopyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, title) in [localised("Summary · Text", "Сводка · Текст"), localised("Summary · Markdown", "Сводка · Markdown"), localised("Transcript · Text", "Расшифровка · Текст"), localised("Transcript · Markdown", "Расшифровка · Markdown")].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(copyFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = currentActions.reason(for: index < 2 ? .copySummary : .copyTranscript) == nil
            menu.addItem(item)
        }
        return menu
    }
    @objc private func copyFromMenu(_ sender: NSMenuItem) {
        copyMeetingContent(transcript: sender.tag >= 2, plainText: sender.tag % 2 == 0)
    }
    @objc private func searchChanged() { show(allItems) }
    @objc private func meetingClicked() {
        if let selected, selected.dir == activeRecording?.dir { onOpenActiveRecording?(); return }
        onSelectMeeting?()
    }
    @objc private func openActiveRecording() { onOpenActiveRecording?() }
    @objc private func moreClicked(_ sender: NSButton) {
        menuWillOpen(meetingMenu)
        meetingMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func meetingAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MeetingActionState.Action(rawValue: raw),
              currentActions.reason(for: action) == nil else { updateButtons(); return }
        switch action {
        case .rename: beginRenamingMeeting()
        case .copyTranscript: copyMeetingContent(transcript: true, plainText: true)
        case .retranscribe: confirmRetranscription(engine: nil)
        case .copySummary: copyMeetingContent(transcript: false, plainText: true)
        case .regenerateSummary: regenerateSummary()
        case .openFolder: openFolderClicked()
        case .openTranscript: openTranscriptClicked()
        case .delete: deleteClicked()
        }
    }
    private func textPane(content: NSView) -> NSView {
        let pane = NSStackView(views: [content])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 10
        pane.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 10, right: 10)
        for view in pane.arrangedSubviews { view.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -20).isActive = true }
        return Self.frameOwnedPane(pane)
    }
    private static func summaryMethodName(_ backend: String) -> String {
        switch backend {
        case "codex-cli": "Codex"
        case "claude-cli": "Claude Code"
        case "ollama": "Ollama"
        case "openai-api": "OpenAI API"
        case "anthropic-api": "Anthropic API"
        case "none": localised("Disabled", "Отключена")
        default: localised("Automatic", "Автоматически")
        }
    }
    @objc private func repeatTranscriptClicked() { guard currentActions.reason(for: .retranscribe) == nil else { return }; confirmRetranscription(engine: nil) }
    @objc private func regenerateClicked() { regenerateSummary() }
    private func regenerateSummary() {
        guard currentActions.reason(for: .regenerateSummary) == nil, let dir = artifactDirectory,
              let item = selected, panel.attachedSheet == nil else { updateButtons(); return }
        working = true
        updateButtons()
        if summaryDirectory == dir, let summarySheet {
            summarySheet.selectionChanged()
            panel.beginSheet(summarySheet.window)
            return
        }
        let sheet = SummaryRegenerationSheet(onSettings: { [weak self] in self?.onNavigateSettings?(.summary) }, run: { request in
            try await PostProcessor.regenerateSummary(dir, request: request)
        }, onFailure: { [weak self] error in
            guard let self else { return }
            working = false
            reload()
            say(error.localizedDescription, about: item)
        }, completion: { [weak self] in
            guard let self else { return }
            summarySheet = nil
            summaryDirectory = nil
            working = false
            reload()
        })
        summarySheet = sheet
        summaryDirectory = dir
        panel.beginSheet(sheet.window)
    }
    @objc func beginRenamingMeeting() {
        guard let item = selected else { return }
        if journalColumns?.arrangedSubviews.first?.isHidden == true { inspectorRequested = false }
        updateCompactLayout()
        if item.dir == activeRecording?.dir, let activeRecordingView {
            activeRecordingView.beginRenaming()
            return
        }
        renamingSession = item.dir
        detailTitle.stringValue = item.title ?? item.name
        detailTitle.isEditable = true
        detailTitle.isBezeled = true
        detailTitle.drawsBackground = true
        titleDoubleClick.isEnabled = false
        detailTitle.selectText(nil)
    }
    @objc private func saveMeetingTitle() {
        guard let dir = renamingSession, let item = selected, item.dir == dir else { cancelTitleEdit(); return }
        let title = detailTitle.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            detailError.stringValue = localised("Enter a meeting name.", "Введите название встречи.")
            detailError.isHidden = false
            return
        }
        do {
            if item.dir == activeRecording?.dir { try onRenameActiveRecording?(title) }
            else { try SessionState.amend(item.dir, with: ["title": title]) }
            cancelTitleEdit()
            detailTitle.abortEditing()
            reload()
        }
        catch { detailError.stringValue = error.localizedDescription; detailError.isHidden = false }
    }
    private func cancelTitleEdit() {
        renamingSession = nil
        titleDoubleClick.isEnabled = true
        detailTitle.isEditable = false
        detailTitle.isBezeled = false
        detailTitle.drawsBackground = false
        detailError.isHidden = true
        detailTitle.stringValue = selected.map { $0.title ?? $0.name } ?? ""
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === detailTitle, renamingSession != nil else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelTitleEdit(); panel.makeFirstResponder(nil); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { saveMeetingTitle(); return true }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === detailTitle, renamingSession != nil { saveMeetingTitle() }
    }
    private func copyMeetingContent(transcript: Bool, plainText: Bool) {
        guard currentActions.reason(for: transcript ? .copyTranscript : .copySummary) == nil,
              let dir = artifactDirectory else { updateButtons(); return }
        let markdown: String?
        if transcript { markdown = PostProcessor.readTranscript(dir)?.rendered(title: selected?.title ?? "", names: SpeakerNames.read(from: dir)) ?? (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) }
        else { markdown = summaryToCopy }
        if let markdown { _ = Self.copyContent(markdown, plainText: plainText, to: pasteboard) }
    }
    @discardableResult
    static func copyContent(_ markdown: String, plainText: Bool, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString(plainText ? MarkdownPreview.render(markdown).string : markdown, forType: .string)
    }

    private func previewScroll(_ text: NSTextView) -> NSScrollView {
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.font = .systemFont(ofSize: 13)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 12)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    /// Show another recordings folder: the one Setup has just moved verbemo to.
    func setRoot(_ folder: URL) {
        root = folder
        table.deselectAll(nil)
        reload()
    }

    func updateImport(_ update: MediaImportCoordinator.Update) {
        importStatus.update(update)
    }

    func finishImport(_ result: MediaImportCoordinator.Result) {
        importStatus.finish(result)
        reload()
    }

    // MARK: - data

    /// The scan in flight, if one is, and a count that says which scan is
    /// the latest: an older one finishing late must not overwrite a newer
    /// one's answer.
    private var scan: Task<Void, Never>?
    private var scans = 0
    private var scansInFlight: [Int: Task<Void, Never>] = [:]

    /// Read the folder again, off the main thread.
    ///
    /// `SessionInventory.scan` reads every session's meta.json and parses its
    /// transcript, and on the main thread that was a window that stopped
    /// answering for as long as the archive took to read — on every opening,
    /// every rename and every delete, and growing with every meeting kept.
    private func reload() {
        guard !terminating else { return }
        scans += 1
        let generation = scans
        let root = self.root
        // Carried across by hand: a detached task does not inherit the home
        // a test scoped, and the scan reads the config for what is owed.
        let home = Home.current
        scan = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                Home.$scoped.withValue(home) { SessionInventory.scan(root: root) }
            }.value
            guard let self else { return }
            self.scansInFlight.removeValue(forKey: generation)
            guard !Task.isCancelled, generation == self.scans, !self.terminating else { return }
            self.show(found)
            self.scan = nil
        }
        scansInFlight[generation] = scan
    }

    /// Wait for the latest scan to be on screen. For tests, which would
    /// otherwise have to guess how long reading a folder takes.
    func settled() async {
        while let scan { await scan.value }
    }

    /// Something changed in the recordings folder that this window did not
    /// do itself — a transcript or a summary finished. Read again if anybody
    /// is looking; a closed window reads when it opens.
    func sessionsChanged() {
        guard panel.isVisible else { return }
        reload()
    }

    func refresh() { reload() }

    func activityTitle(for dir: URL) -> String {
        activityTitles[dir] ?? dir.lastPathComponent
    }
    private var activityTitles: [URL: String] = [:]
    var attentionCount: Int {
        allItems.filter { item in
            !deletion.isPending(item.dir) && (item.unreadableDiarization || item.diarization?.status == .failed
                || [item.transcript, item.speakers, item.summary].contains { if case .failed = $0 { true } else { false } })
        }.count + (activeRecording?.needsAttention == true ? 1 : 0)
    }

    /// A status-menu link must select its meeting even with a search/filter active.
    func reveal(_ dir: URL) async -> Bool {
        applyFilter(.allMeetings, clearSearch: true)
        reload()
        await settled()
        guard let row = items.firstIndex(where: { $0.dir.standardizedFileURL.path == dir.standardizedFileURL.path }) else { return false }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        showDetail()
        return true
    }

    private func show(_ found: [SessionInventory.Item], refreshDetail: Bool = true) {
        reloadingList = true
        defer { reloadingList = false }
        let previous = selected?.dir ?? rememberedMeeting
        allItems = found.filter { $0.dir != activeRecording?.dir }
        activityTitles = Dictionary(allItems.map { ($0.dir.standardizedFileURL.resolvingSymlinksInPath(), $0.title ?? $0.name) }, uniquingKeysWith: { first, _ in first })
        let inventory = (activeRecording.map { [$0.item] } ?? []) + allItems
        items = inventory.filter { !deletion.isPending($0.dir) && MeetingPresentation.matches($0, filter: meetingFilter, query: search.stringValue, active: activeRecording) }
        emptyView.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        clearSearch.isHidden = search.stringValue.isEmpty
        emptyLabel.stringValue = !search.stringValue.isEmpty ? localised("No meetings match your search.", "По вашему запросу встреч не найдено.")
            : meetingFilter == .processing ? localised("Nothing is being processed right now.", "Сейчас ничего не обрабатывается.")
            : meetingFilter == .attention ? localised("No meetings need your attention.", "Нет встреч, требующих действий.")
            : localised("No meetings yet. Start a recording or import an audio file.", "Встреч пока нет. Начните запись или импортируйте аудиофайл.")
        table.reloadData()
        if meetingSelectionActive {
            if let previous, let row = items.firstIndex(where: { $0.dir == previous }) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            } else if !items.isEmpty {
                table.selectRowIndexes([0], byExtendingSelection: false)
            }
            rememberedMeeting = nil
        } else {
            table.deselectAll(nil)
        }
        if refreshDetail || selected?.dir != previous { showDetail() }
        updateCompactLayout()
    }
    @objc private func clearSearchClicked() { search.stringValue = ""; show(allItems) }

    @objc private func versionSelected(_ sender: NSPopUpButton) {
        versionKey = selectedVersion.map(key)
        showDetail()
    }

    private func showDetail() {
        let live = activeRecording.map { selected?.dir == $0.dir } ?? false
        meetingDocument?.isHidden = live && activeRecordingView != nil
        activeRecordingView?.isHidden = !live
        openActiveButton.isHidden = true
        resultPicker.isHidden = selected == nil
        detailTabs.isHidden = selected == nil
        if renamingSession != selected?.dir { cancelTitleEdit() }
        speakersStack.arrangedSubviews.forEach {
            speakersStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        defer { updateInspector() }
        if let activeRecording, selected?.dir == activeRecording.dir {
            showCalendar(for: selected)
            detailTitle.stringValue = activeRecording.title
            moreButton.isEnabled = true
            versions = []
            versionSelector.removeAllItems()
            versionSelector.isHidden = true
            audioPlayer.setMeeting(nil)
            detailTabs.isHidden = true
            diarizationLabel.isHidden = true
            retryDiarizationButton.isHidden = true
            skipDiarizationButton.isHidden = true
            finishButton.isHidden = true
            finishButton.isEnabled = false
            summaryText.string = ""
            transcriptText.string = ""
            openActiveButton.isHidden = false
            busyLabel.stringValue = activeRecording.paused ? localised("Recording paused", "Запись приостановлена") : localised("Recording in progress", "Идёт запись")
            return
        }
        showCalendar(for: selected)
        meetingTranscript.isHidden = true
        plainTranscriptScroll?.isHidden = false
        audioPlayer.setMeeting(selected?.dir)
        if versionSession != selected?.dir {
            versionSession = selected?.dir
            versionKey = nil
        }
        versions = selected.map { TranscriptVersions.read($0.dir) } ?? []
        versionSelector.removeAllItems()
        for (index, version) in versions.enumerated() {
            let item = NSMenuItem(title: "\(index + 1) · \(version.title)", action: nil, keyEquivalent: "")
            item.toolTip = "\(version.engine) · \(version.model) · \(version.createdAt)"
            versionSelector.menu?.addItem(item)
        }
        if let index = versions.firstIndex(where: { key($0) == versionKey }) {
            versionSelector.selectItem(at: index)
        } else if let index = versions.lastIndex(where: { !$0.isRequest }) {
            versionSelector.selectItem(at: index)
        }
        versionSelector.isHidden = versions.count < 2
        versionKey = selectedVersion.map(key)

        guard let item = selected else {
            detailTitle.stringValue = items.isEmpty
                ? localised("No recordings yet", "Записей пока нет")
                : localised("Select a recording", "Выберите запись")
            summaryText.string = ""
            transcriptText.string = ""
            diarizationLabel.isHidden = true
            retryDiarizationButton.isHidden = true
            skipDiarizationButton.isHidden = true
            updateButtons()
            return
        }

        if renamingSession == nil { detailTitle.stringValue = item.title ?? item.name }
        detailTitle.toolTip = item.title ?? item.name
        updateDiarization(for: item)
        let dir = artifactDirectory ?? item.dir
        if let request = selectedVersion, request.isRequest {
            summaryText.string = ""
            transcriptText.string = request.title
            if case .failed(let reason) = request.state { transcriptText.string += "\n\n" + reason }
            summaryText.identifier = nil
            transcriptText.identifier = nil
            updateButtons()
            return
        }
        let summary = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        var summaryPreview = summary ?? (item.summary == .off
            ? localised("Summaries are off.", "Создание сводки выключено.")
            : localised("No summary yet.", "Сводка не создавалась."))
        summaryText.identifier = summary == nil ? nil : .init("meeting-words")
        if summary != nil && !PostProcessor.hasCurrentSummary(dir) {
            summaryPreview = localised(
                "This summary belongs to the previous transcript.\n\n",
                "Это сводка предыдущей расшифровки.\n\n") + summaryPreview
        }
        summaryText.textStorage?.setAttributedString(MarkdownPreview.render(summaryPreview, fontSize: 15))
        let transcript = PostProcessor.readTranscript(dir)
        let markdown = try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        let transcriptPreview = markdown ?? transcript?.rendered(
            title: item.title ?? item.name, names: SpeakerNames.read(from: dir))
            ?? localised("No transcript yet.", "Расшифровки пока нет.")
        transcriptText.textStorage?.setAttributedString(MarkdownPreview.render(transcriptPreview, fontSize: 15))
        transcriptText.identifier = markdown != nil || transcript != nil ? .init("meeting-words") : nil
        for text in [summaryText, transcriptText] { text.scrollToBeginningOfDocument(nil) }
        guard let transcript else {
            updateButtons()
            return
        }

        let names = SpeakerNames.read(from: dir)
        let calendar = MeetingCalendarMetadata.read(from: item.dir)
        let diarized = DiarizationState.read(dir).map { $0.status == .completed }
            ?? (!Config.localEngines.contains(transcript.engine) || Set(transcript.segments.map(\.speaker)).count > 2)
        let participantChoices = calendar?.isConfirmed == true ? calendar!.participants : []
        let canEdit = !working && !SessionClaim.isHeld(item.dir) && !TranscriptVersions.isRequested(item.dir)
            && DiarizationState.persisted(in: dir).isFinal
        meetingTranscript.onAssign = { [weak self] speaker, participant, name in
            try PostProcessor.setSpeakerParticipant(speaker, participant: participant, name: name, in: dir)
            Task { @MainActor [weak self] in self?.showDetail() }
        }
        meetingTranscript.update(transcript: transcript, names: names, participants: participantChoices,
                                 canEdit: canEdit, canPlay: !audioPlayer.isHidden, canMatchParticipants: diarized)
        meetingTranscript.isHidden = false
        plainTranscriptScroll?.isHidden = true
        let hint = NSTextField(wrappingLabelWithString: localised(
            "Listen to a voice, then choose a participant or type a name. The assignment applies to all their lines in this transcript version.",
            "Прослушайте голос, затем выберите участника или введите имя. Сопоставление применяется ко всем его репликам в этой версии расшифровки."))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = JournalStyle.muted
        speakersStack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: speakersStack.widthAnchor).isActive = true
        for sample in SessionInventory.samples(transcript: transcript, names: names) {
            let row = speakerRow(sample, in: dir, transcript: transcript, names: names,
                                 participants: diarized || sample.label == "me" ? participantChoices : [])
            speakersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: speakersStack.widthAnchor).isActive = true
        }
        updateButtons()
    }

    private func speakerRow(_ sample: SessionInventory.Sample, in dir: URL, transcript: Transcript, names: SpeakerNames?, participants: [CalendarParticipant]) -> NSView {
        let title = MeetingTranscriptView.speakerTitle(sample.label, in: transcript.segments)
        let canEdit = !working && !SessionClaim.isHeld(selected?.dir ?? dir)
            && !TranscriptVersions.isRequested(selected?.dir ?? dir) && DiarizationState.persisted(in: dir).isFinal
        let editor = SpeakerAssignmentEditor(speaker: sample.label, title: title,
            entry: SpeakerNames.isUnknown(sample.label) ? nil : names?.speakers[sample.label],
            participants: participants, canEdit: canEdit, inline: false)
        editor.onAssign = { [weak self] participant, name in
            try PostProcessor.setSpeakerParticipant(sample.label, participant: participant, name: name, in: dir)
            Task { @MainActor [weak self] in self?.showDetail() }
        }
        let play = NSButton(title: localised("Listen", "Прослушать"), target: self, action: #selector(playSpeaker(_:)))
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        play.imagePosition = .imageLeading
        play.bezelStyle = .rounded
        play.identifier = .init("speaker.play")
        play.tag = transcript.segments.first(where: { $0.speaker == sample.label })?.start_ms ?? 0
        play.isEnabled = !audioPlayer.isHidden
        play.setAccessibilityLabel(localised("Listen to ", "Прослушать: ") + title)
        let head = NSStackView(views: [editor, play])
        head.spacing = 8
        let quotes = NSTextField(wrappingLabelWithString: [sample.first,
            sample.longest == sample.first ? nil : sample.longest].compactMap { $0 }.joined(separator: "\n"))
        quotes.font = .systemFont(ofSize: 12)
        quotes.textColor = .secondaryLabelColor
        quotes.maximumNumberOfLines = 4
        quotes.lineBreakMode = .byTruncatingTail
        quotes.preferredMaxLayoutWidth = 400
        let contents = NSStackView(views: [head, quotes])
        contents.orientation = .vertical
        contents.alignment = .leading
        contents.spacing = 8
        for view in [head, quotes] { view.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true }
        return MeetingSpeakerView(title: title + localised(" · \(sample.turns) turns", " · реплик: \(sample.turns)"), editor: contents)
    }
    @objc private func playSpeaker(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        audioPlayer.play(from: Double(sender.tag) / 1000)
    }

    private func updateButtons() {
        let item = selected
        moreButton.isEnabled = item != nil
        finishButton.isEnabled = !working && (selectedVersion?.isRequest == true
            ? item?.transcript.isOutstanding ?? false
            : artifactDirectory.map { !PostProcessor.outstanding($0, retryFailed: true).isEmpty } ?? item?.isOutstanding ?? false)
        finishButton.isHidden = !finishButton.isEnabled
        let state = item.flatMap { DiarizationState.read($0.dir) }
        let actionable = !working && item?.unreadableDiarization != true
            && state?.retainsAudio == true && state?.status != .running
            && item.map { !TranscriptVersions.isRequested($0.dir) } == true
        retryDiarizationButton.isEnabled = actionable && onRetryDiarization != nil
        skipDiarizationButton.isEnabled = actionable && onSkipDiarization != nil
        busyLabel.isHidden = !working
        busyLabel.stringValue = working ? localised("working…", "работаю…") : ""
        let actions = currentActions
        let summaryAction = summaryToCopy == nil ? localised("Generate summary", "Создать сводку") : localised("Regenerate summary", "Перегенерировать сводку")
        let transcriptAction = localised("Transcribe again", "Расшифровать повторно")
        regenerateButton.setAccessibilityLabel(summaryAction)
        regenerateButton.isEnabled = actions.reason(for: .regenerateSummary) == nil
        regenerateButton.toolTip = actions.reason(for: .regenerateSummary) ?? summaryAction
        repeatButton.setAccessibilityLabel(transcriptAction)
        repeatButton.isEnabled = actions.reason(for: .retranscribe) == nil
        repeatButton.toolTip = actions.reason(for: .retranscribe) ?? transcriptAction
    }

    private func updateDiarization(for item: SessionInventory.Item) {
        if item.unreadableDiarization {
            diarizationLabel.isHidden = false
            diarizationLabel.stringValue = localised(
                "Diarization: saved model request cannot be read. Processing is blocked.",
                "Диаризация: не удалось прочитать сохранённый запрос модели. Обработка заблокирована.")
            diarizationLabel.toolTip = diarizationLabel.stringValue
            retryDiarizationButton.isHidden = true
            skipDiarizationButton.isHidden = true
            return
        }
        guard let state = DiarizationState.read(item.dir) else {
            diarizationLabel.isHidden = true
            retryDiarizationButton.isHidden = true
            skipDiarizationButton.isHidden = true
            return
        }
        diarizationLabel.isHidden = false
        diarizationLabel.stringValue = Self.diarizationLine(state)
        diarizationLabel.toolTip = diarizationLabel.stringValue
        let actions = state.retainsAudio && state.status != .running
            && !TranscriptVersions.isRequested(item.dir)
        retryDiarizationButton.isHidden = !actions
        let needsModel = !DiarizationModelStore.isReady(at: DiarizationModelStore.shared(for: state.request.model).directory, model: state.request.model)
        retryDiarizationButton.title = needsModel ? localised("Download and continue", "Скачать и продолжить") : localised("Retry diarization", "Повторить диаризацию")
        skipDiarizationButton.isHidden = !actions
    }

    static func diarizationLine(_ state: DiarizationState) -> String {
        let stage: String
        switch state.status {
        case .pending: stage = localised("pending", "ожидает")
        case .running: stage = localised("running", "выполняется")
        case .deferred: stage = localised("waiting for model", "ожидает модель")
        case .failed: stage = localised("failed", "ошибка")
        case .partial: stage = localised("incomplete", "не завершена")
        case .completed: stage = localised("complete", "готова")
        case .skipped: stage = localised("skipped", "пропущена")
        case .notApplicable: stage = localised("not applicable", "не применяется")
        }
        var parts = [localised("Diarization: ", "Диаризация: ") + stage]
        if state.confirmedSpeakers > 0 {
            parts.append(localised("\(state.confirmedSpeakers) confirmed speakers",
                                   "подтверждённых говорящих: \(state.confirmedSpeakers)"))
        }
        if state.hasUnknown { parts.append(localised("some speech has no speaker",
                                                     "часть речи без говорящего")) }
        if let rejected = state.rejectedTurnCount, rejected > 0 {
            parts.append(localised("ignored \(rejected) invalid speaker turns",
                                   "пропущено некорректных отрезков речи: \(rejected)"))
        }
        if state.retainsAudio {
            parts.append(localised("audio kept for retry", "звук сохранён для повтора"))
        }
        if let reason = state.reason, !reason.isEmpty { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    @objc private func retryDiarizationClicked() {
        guard let item = selected, let action = onRetryDiarization else { return }
        working = true
        updateButtons()
        Task {
            do {
                if let state = DiarizationState.read(item.dir), let resume = onResumeDiarization,
                   !DiarizationModelStore.isReady(at: DiarizationModelStore.shared(for: state.request.model).directory, model: state.request.model) {
                    busyLabel.stringValue = localised("Downloading \(state.request.model.title)…", "Загрузка \(state.request.model.title)…")
                    try await MeetingModelDownload.continueDiarization(item.dir, resume: resume)
                } else { try await action(item.dir) }
            } catch { say(error.localizedDescription, about: item) }
            working = false
            reload()
        }
    }

    @objc private func skipDiarizationClicked() {
        guard let item = selected, let action = onSkipDiarization else { return }
        working = true
        updateButtons()
        Task {
            do { try await action(item.dir) } catch { say(error.localizedDescription, about: item) }
            working = false
            reload()
        }
    }

    // MARK: - actions

    /// What Finish processing does about one recording.
    enum Decision: Equatable {
        /// A transcript exists and something after it is still owed.
        case finish
        /// No transcript, but audio to make one from.
        case transcribe(clearingFirst: Bool)
        /// Nothing can be done, and this is the sentence that says why.
        case refuse(String)
        /// Everything that could be done has been.
        case nothingOwed
    }

    /// Which of those it is, decided before anything is run or shown.
    ///
    /// Through `PostProcessor.plan` rather than around it: a button that
    /// reached its own conclusion about a folder is the bug this replaces —
    /// for a settled recording with no transcript this one used to run the
    /// post-processing that needs one, get nothing back, and say nothing
    /// about it. What is left here is the part the window owns, which is
    /// which of the plans it can carry out and in whose language it answers.
    /// A function of its own because `runModal` blocks, and because a
    /// sentence nothing can call is a sentence nothing can check.
    static func decision(
        for item: SessionInventory.Item,
        policy: PostProcessor.Policy = .configured,
        transcriptionEnabled: Bool = Config.transcriptionEnabled()
    ) -> Decision {
        switch PostProcessor.plan(for: item, transcriptionEnabled: transcriptionEnabled) {
        case .refuse(let why):
            return .refuse(why.described)
        case .transcribe(let clearingFirst):
            return .transcribe(clearingFirst: clearingFirst)
        case .finish:
            if !PostProcessor.outstanding(item.dir, policy: policy, retryFailed: true).isEmpty { return .finish }
            if let refusal = PostProcessor.manualSummaryRefusal(item.dir) { return .refuse(refusal.described) }
            return .nothingOwed
        }
    }

    /// Said when the button was pressed and there was nothing to press it
    /// for. A property of its own because two places say it — the decision
    /// made before the work, and the work coming back empty afterwards — and
    /// they must say the same thing.
    static var nothingOwedLine: String {
        localised(
            "Everything that can be done here is already done.",
            "Всё, что можно было сделать, уже сделано.")
    }

    @objc private func finishClicked() {
        guard let item = selected else { return }
        if let version = selectedVersion, !version.isRequest, version.dir != item.dir {
            finishManually(version.dir, about: item)
            return
        }
        switch Self.decision(for: item) {
        case .refuse(let why):
            say(why, about: item)

        case .nothingOwed:
            say(Self.nothingOwedLine, about: item)

        // Asked without a confirmation, unlike Re-transcribe: there is no
        // transcript here for the work to throw away.
        case .transcribe(let clearingFirst):
            if clearingFirst, let why = Self.retranscriptionRefusal(for: item.dir) {
                say(why, about: item)
                return
            }
            if clearingFirst { PostProcessor.markForRetranscription(item.dir) }
            onRetranscribe?(item.dir)
            reload()

        case .finish:
            finishManually(item.dir, about: item)
        }
    }

    private func finishManually(_ dir: URL, about item: SessionInventory.Item) {
        working = true
        updateButtons()
        Task {
            let result = await PostProcessor.finishManually(dir)
            working = false
            reload()
            say(result.described, about: item)
        }
    }

    /// What to say when Finish processing came back having done nothing.
    ///
    /// Not always good news, which is how it used to read: the work also
    /// comes back empty when another verbemo — or this one's own queue — has
    /// the session, and when the config file broke after the button was
    /// offered. Only once both are ruled out does it mean what it says, or
    /// that the transcript could not be read, which the log has.
    static func nothingDoneLine(for dir: URL) -> String {
        if let reason = Config.unreadableReason {
            return PostProcessor.Refusal.configUnreadable(reason).described
        }
        if let holder = SessionClaim.holder(dir), holder.isAlive {
            return SessionClaim.Busy(session: dir.lastPathComponent, holder: holder).described
        }
        return nothingOwedLine
    }

    /// Why a recording cannot be cleared for re-transcription right now, or
    /// nil when it can. Asked before anything is written: the engine choice
    /// used to be stored first and the clearing then refused in silence, so
    /// the recording kept its transcript, gained an engine nobody saw take
    /// effect, and the window said nothing.
    static func retranscriptionRefusal(for dir: URL) -> String? {
        if let reason = Config.unreadableReason {
            return PostProcessor.Refusal.configUnreadable(reason).described
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".recording.json").path) {
            return localised("Stop recording before deleting it.", "Перед удалением остановите запись.")
        }
        guard SessionClaim.isHeld(dir) else { return nil }
        return SessionClaim.Busy(session: dir.lastPathComponent, holder: SessionClaim.holder(dir))
            .described
    }

    /// An answer with nothing to decide: the recording it is about, and one
    /// sentence saying what happened to it.
    private func say(_ sentence: String, about item: SessionInventory.Item) {
        guard !terminating else { return }
        let alert = NSAlert()
        alert.messageText = item.title ?? item.name
        alert.informativeText = sentence
        alert.addButton(withTitle: localised("OK", "Ладно"))
        alert.beginJournalSheetModal(for: panel)
    }

    private func confirmRetranscription(engine: String?) {
        guard let item = selected, item.hasAudio else { return }
        let alert = NSAlert()
        alert.messageText = localised(
            "Transcribe \(item.title ?? item.name) again?",
            "Расшифровать «\(item.title ?? item.name)» заново?")
        alert.informativeText = localised(
            """
            A new transcript is made from the audio. The current transcript, its speaker \
            names and summary remain available as a separate version.
            """,
            """
            Из звука будет сделана новая расшифровка. Нынешняя расшифровка, имена \
            участников и сводка сохранятся отдельным вариантом.
            """)
        let options = RetranscriptionOptionsView(session: item.dir, engine: engine)
        alert.accessoryView = options
        alert.addButton(withTitle: localised("Transcribe again", "Расшифровать заново"))
        alert.addButton(withTitle: localised("Cancel", "Отмена")).keyEquivalent = "\u{1b}"
        options.onValidation = { [weak alert] valid in alert?.buttons.first?.isEnabled = valid }
        options.changed()
        Task { @MainActor in
            guard panel.attachedSheet == nil else { return }
            guard await alert.beginJournalSheetModal(for: panel) == .alertFirstButtonReturn,
                  let request = options.request else { return }
            if let why = await RetranscriptionOptionsView.refusal(for: request) {
                say(why, about: item)
                return
            }
            if let why = Self.markForRetranscription(item.dir, engine: request.engine, request: request) {
                say(why, about: item)
                return
            }
            onRetranscribe?(item.dir)
            reload()
        }
    }

    /// Clear a recording for re-transcription with the engine chosen for it,
    /// or say why not. The engine is written only once the clearing is sure
    /// to happen.
    @discardableResult
    static func markForRetranscription(_ dir: URL, engine: String?,
                                      request: TranscriptVersions.Request? = nil) -> String? {
        if let why = retranscriptionRefusal(for: dir) { return why }
        let choice = request ?? .capture(engine: engine ?? EngineResolver.configuredEngine(for: dir))
        guard PostProcessor.markForRetranscription(dir, request: choice) else {
            return retranscriptionRefusal(for: dir) ?? nothingOwedLine
        }
        return nil
    }

    @objc private func openTranscriptClicked() {
        guard selected != nil else { return }
        guard let dir = artifactDirectory, selectedVersion?.isRequest != true,
              let file = Self.readableTranscript(in: dir) else { return }
        Self.openTranscript(file,
            openDefault: { file in
                guard NSWorkspace.shared.urlForApplication(toOpen: file) != nil else { return false }
                return NSWorkspace.shared.open(file)
            },
            openTextEdit: { file in
                guard let textEdit = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.apple.TextEdit"
                ) else {
                    let alert = NSAlert()
                    alert.messageText = localised(
                        "Could not open the transcript", "Не удалось открыть расшифровку")
                    alert.informativeText = file.path
                    alert.beginJournalSheetModal(for: self.panel)
                    return
                }
                NSWorkspace.shared.open(
                    [file], withApplicationAt: textEdit,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error {
                        Task { @MainActor in NSAlert(error: error).beginJournalSheetModal(for: self.panel, completionHandler: nil) }
                    }
                }
            })
    }

    private var summaryToCopy: String? {
        guard selectedVersion?.isRequest != true, let dir = artifactDirectory,
              let text = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func readableTranscript(in dir: URL) -> URL? {
        let file = dir.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let transcript = PostProcessor.readTranscript(dir) else { return nil }
        do {
            try transcript.writeMarkdown(to: dir, names: SpeakerNames.read(from: dir))
            return file
        } catch {
            return nil
        }
    }

    static func openTranscript(
        _ file: URL,
        openDefault: (URL) -> Bool,
        openTextEdit: (URL) -> Void
    ) {
        if !openDefault(file) { openTextEdit(file) }
    }

    @objc private func openFolderClicked() {
        guard let item = selected else { return }
        Analytics.track(.artifactOpened, [
            .artifact: .text(Analytics.Artifact.sessionFolder.rawValue),
        ])
        NSWorkspace.shared.open(item.dir)
    }

    /// To the Trash, never `rm`. These are meetings: the cost of a mistaken
    /// delete is somebody's only record of a conversation, and the Trash is
    /// what makes that recoverable.
    @objc private func deleteClicked() {
        guard let item = selected else { return }
        if let why = Self.deleteRefusal(for: item.dir) {
            say(why, about: item)
            return
        }
        let alert = NSAlert()
        alert.messageText = localised("Delete \(item.title ?? item.name)?", "Удалить «\(item.title ?? item.name)»?")
        alert.informativeText = localised(
            "The audio and all transcript versions will move to the macOS Trash after a short Undo period.",
            "Аудио и все версии расшифровки будут перемещены в корзину macOS. В течение нескольких секунд удаление можно отменить.")
        alert.addButton(withTitle: localised("Delete", "Удалить"))
        alert.addButton(withTitle: localised("Cancel", "Отмена")).keyEquivalent = "\u{1b}"
        Task { @MainActor [self] in
            guard panel.attachedSheet == nil else { return }
            guard await alert.beginJournalSheetModal(for: panel) == .alertFirstButtonReturn else { return }
            do {
                let id = try deletion.schedule(item.dir) { [weak self] result in
                    guard let self else { return }
                    self.deletionNotice.isHidden = true
                    self.onActivityChange?()
                    self.reload()
                    if case .failure(let error) = result { NSAlert(error: error).beginJournalSheetModal(for: self.panel) }
                }
                undoDeletionID = id
                deletionLabel.stringValue = localised("Meeting deleted", "Встреча удалена")
                deletionNotice.isHidden = false
                onActivityChange?()
                show(allItems)
            } catch { NSAlert(error: error).beginJournalSheetModal(for: panel, completionHandler: nil) }
        }
    }

    @objc private func undoDeletion() {
        guard let id = undoDeletionID, deletion.undo(id) else { return }
        undoDeletionID = nil
        deletionNotice.isHidden = true
        onActivityChange?()
        reload()
    }

    /// Why a session cannot go to the Trash now, or nil when it can.
    ///
    /// A session being transcribed or summarised is a folder something is
    /// still writing into. Moved out from under it, the work fails against a
    /// path that is gone, and whatever it was about to write lands nowhere —
    /// or, for a recording-only archive, the audio is half-compressed in the
    /// Trash. The claim file is what says somebody has it, this process or
    /// the command line.
    static func deleteRefusal(for dir: URL) -> String? {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".recording.json").path) {
            return localised("Stop recording before deleting it.", "Перед удалением остановите запись.")
        }
        guard SessionClaim.isHeld(dir) else { return nil }
        return localised(
            "verbemo is working on this recording right now — transcribing or summarising it. "
                + "Delete it once that has finished.",
            "verbemo сейчас работает с этой записью — расшифровывает её или создаёт сводку. "
                + "Удалите её, когда это закончится.")
    }

    /// Called when a session is queued for transcription again, so the daemon
    /// can pick it up without waiting for the next launch.
    var onRetranscribe: ((URL) -> Void)?
    private static func transcriptionModelName(_ engine: String) -> String {
        switch engine {
        case "parakeet": "Parakeet \(Config.transcriptionModel())"
        case "whisper": "Whisper large-v3-turbo"
        case "gigaam": "GigaAM v3"
        case "nemotron": "Nemotron 3.5 ASR · 1120 ms"
        case "openai": "OpenAI · \(Config.openAITranscriptionModel())"
        case "elevenlabs": "ElevenLabs · scribe_v2"
        case "assemblyai": "AssemblyAI" + (Config.assemblyAISpeechModel().map { " · " + $0 } ?? "")
        default: RecordingsEngineName.name(engine)
        }
    }

}

extension MeetingLibraryController: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === meetingMenu else { return }
        let rendered = MeetingActionsMenu.make(state: currentActions, target: self, action: #selector(meetingAction(_:)))
        menu.removeAllItems()
        for item in rendered.items { rendered.removeItem(item); menu.addItem(item) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        return MeetingListView(item: items[row], active: activeRecording)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingList else { return }
        if table.selectedRow >= 0 {
            meetingSelectionActive = true
            rememberedMeeting = nil
        }
        showDetail()
        onSelectMeeting?()
    }
}

@MainActor
private extension MeetingLibraryController {
    func buildJournal(detail: NSStackView, diarizationActions: NSStackView) -> NSView {
        search.placeholderString = localised("Find a meeting", "Найти встречу")
        search.setAccessibilityLabel(localised("Find a meeting", "Найти встречу"))
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.focusRingType = .default
        search.backgroundColor = JournalStyle.inset
        search.textColor = JournalStyle.ink
        for filter in [ApplicationNavigationState.Destination.allMeetings, .processing, .attention] {
            filterPicker.addItem(withTitle: filter == .allMeetings ? localised("All", "Все") : filter.title)
        }
        filterPicker.isBordered = false
        filterPicker.font = .systemFont(ofSize: 11)
        filterPicker.target = self
        filterPicker.action = #selector(filterSelected)
        filterPicker.setAccessibilityLabel(localised("Filter meetings", "Фильтр встреч"))
        filterPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let listHeading = NSStackView(views: [JournalStyle.caption(localised("MEETINGS", "ВСТРЕЧИ")), NSView(), filterPicker])
        emptyLabel.identifier = .init("meeting-list.empty")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = JournalStyle.muted
        clearSearch.title = localised("Clear search", "Очистить поиск")
        clearSearch.target = self
        clearSearch.action = #selector(clearSearchClicked)
        emptyView.setViews([emptyLabel, clearSearch, NSView()], in: .center)
        emptyView.orientation = .vertical
        emptyView.spacing = 12
        emptyView.isHidden = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let list = NSStackView(views: [search, listHeading, scroll, emptyView])
        list.orientation = .vertical
        list.distribution = .fill
        list.alignment = .leading
        list.spacing = 16
        for view in list.arrangedSubviews { view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        listContentView = Self.frameOwnedPane(list)

        let copy = NSButton(title: localised("Copy", "Копировать"), target: self, action: #selector(showCopyMenu(_:)))
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.imagePosition = .imageLeading
        copy.isBordered = false
        copy.font = .systemFont(ofSize: 12)
        copy.identifier = .init("meeting.copy")
        inspectorButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        inspectorButton.setAccessibilityLabel(localised("Show or hide meeting details", "Показать или скрыть детали встречи"))
        inspectorButton.identifier = .init("meeting.inspector")
        inspectorButton.isBordered = false
        inspectorButton.target = self
        inspectorButton.action = #selector(toggleInspector)
        toolbarContent.setViews([copy, moreButton, inspectorButton], in: .center)
        toolbarContent.spacing = 20
        detail.edgeInsets = NSEdgeInsets(top: 36, left: 40, bottom: 18, right: 40)
        // The document's arranged views fill its readable column, without setting a window minimum.
        for constraint in detail.constraints where constraint.firstAttribute == .width { constraint.isActive = false }
        for view in detail.arrangedSubviews { view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -80).isActive = true }
        detailTitle.maximumNumberOfLines = 2
        detailMeta.textColor = JournalStyle.muted
        detail.setCustomSpacing(12, after: detailMeta)
        detail.setCustomSpacing(24, after: detail.arrangedSubviews[1])
        detailTabs.setContentHuggingPriority(.init(1), for: .vertical)
        versionSelector.font = .systemFont(ofSize: 11)
        versionSelector.isBordered = false
        versionSelector.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        pipeline.orientation = .vertical
        pipeline.alignment = .leading
        pipeline.spacing = 12
        route.identifier = .init("meeting.processing-configuration")
        route.font = .systemFont(ofSize: 11)
        route.textColor = JournalStyle.muted
        let settings = NSButton(title: localised("Settings →", "Настройки →"), target: self, action: #selector(processingSettings))
        settings.identifier = .init("meeting.processing-settings")
        settings.isBordered = false
        settings.alignment = .left
        settings.font = .systemFont(ofSize: 11)
        let inspector = FlippedStackView(views: [
            JournalStyle.caption(localised("MEETING DETAILS", "ДЕТАЛИ ВСТРЕЧИ")),
            JournalStyle.caption(localised("CALENDAR", "КАЛЕНДАРЬ")), calendarView,
            calendarPicker,
            SetupLayout.hairline(), JournalStyle.caption(localised("PROCESSING", "ОБРАБОТКА")), pipeline,
            diarizationLabel, diarizationActions, finishButton, cancelProcessingButton, processingStatus,
            SetupLayout.hairline(), JournalStyle.caption(localised("PROCESSING SETTINGS", "НАСТРОЙКИ ОБРАБОТКИ")), route, settings,
        ])
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 18
        inspector.edgeInsets = NSEdgeInsets(top: 30, left: 22, bottom: 24, right: 22)
        for view in inspector.arrangedSubviews { view.widthAnchor.constraint(equalTo: inspector.widthAnchor, constant: -44).isActive = true }
        diarizationActions.orientation = .vertical
        diarizationActions.alignment = .leading
        for button in [retryDiarizationButton, skipDiarizationButton, finishButton] { button.font = .systemFont(ofSize: 11) }
        let inspectorScroll = SetupLayout.scroller(around: inspector)
        let inspectorSurface = JournalSurface(JournalStyle.inset)
        inspectorSurface.identifier = .init("meeting.inspector-content")
        inspectorScroll.translatesAutoresizingMaskIntoConstraints = false
        inspectorSurface.addSubview(inspectorScroll)
        NSLayoutConstraint.activate([
            inspectorScroll.leadingAnchor.constraint(equalTo: inspectorSurface.leadingAnchor), inspectorScroll.trailingAnchor.constraint(equalTo: inspectorSurface.trailingAnchor),
            inspectorScroll.topAnchor.constraint(equalTo: inspectorSurface.topAnchor), inspectorScroll.bottomAnchor.constraint(equalTo: inspectorSurface.bottomAnchor),
        ])
        let document = Self.frameOwnedPane(detail)
        meetingDocument = document
        document.translatesAutoresizingMaskIntoConstraints = false
        documentHost.addSubview(document)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: documentHost.leadingAnchor), document.trailingAnchor.constraint(equalTo: documentHost.trailingAnchor),
            document.topAnchor.constraint(equalTo: documentHost.topAnchor), document.bottomAnchor.constraint(equalTo: documentHost.bottomAnchor),
        ])
        documentHost.identifier = .init("meeting.document")
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let columns = JournalColumns(views: [documentHost, divider, inspectorSurface])
        columns.identifier = .init("meeting.columns")
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fill
        columns.spacing = 0
        for view in columns.arrangedSubviews { view.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true }
        inspectorWidth = inspectorSurface.widthAnchor.constraint(equalToConstant: 270)
        journalColumns = columns
        columns.onResize = { [weak self] in self?.updateCompactLayout() }
        columns.setContentHuggingPriority(.init(1), for: .vertical)
        importStatus.onCancel = { [weak self] in self?.onCancelImport?() }
        let undo = NSButton(title: localised("Undo", "Отменить"), target: self, action: #selector(undoDeletion))
        deletionNotice.setViews([deletionLabel, undo], in: .center)
        deletionNotice.spacing = 10
        deletionNotice.edgeInsets = NSEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
        deletionNotice.isHidden = true
        let content = NSStackView(views: [importStatus, columns, deletionNotice])
        content.orientation = .vertical
        content.distribution = .fill
        content.spacing = 0
        content.alignment = .leading
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let container = MediaDropView()
        container.onFiles = { [weak self] in self?.onImportFiles?($0) }
        let frame = Self.frameOwnedPane(content)
        frame.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(frame)
        NSLayoutConstraint.activate([
            frame.leadingAnchor.constraint(equalTo: container.leadingAnchor), frame.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            frame.topAnchor.constraint(equalTo: container.topAnchor), frame.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    @objc private func cancelProcessingClicked() {
        processingCancellation.select(selected?.dir)
        processingCancellation.cancel()
        updateCancellationControls()
    }

    private func updateCancellationControls() {
        guard !terminating else { return }
        processingCancellation.select(selected?.dir)
        let cancelling = processingCancellation.isCancelling
        cancelProcessingButton.isHidden = !processingCancellation.canCancel && !cancelling
        cancelProcessingButton.isEnabled = processingCancellation.canCancel
        cancelProcessingButton.title = cancelling ? localised("Cancelling…", "Отменяется…")
            : localised("Cancel processing", "Отменить обработку")
        let message: String
        if cancelling { message = localised("Cancelling…", "Отменяется…") }
        else {
            switch processingCancellation.outcome {
            case .cancelled:
                message = localised("Processing cancelled. Completed results are preserved.", "Обработка отменена. Готовые результаты сохранены.")
            case .completed:
                message = localised("Processing completed before cancellation.", "Обработка успела завершиться до отмены.")
            case .failed(let reason):
                message = localised("Processing error: ", "Ошибка обработки: ") + reason
            case nil: message = ""
            }
        }
        processingStatus.isHidden = message.isEmpty
        if processingStatus.stringValue != message {
            processingStatus.stringValue = message
            NSAccessibility.post(element: processingStatus, notification: .valueChanged)
        }
    }

    func updateInspector() {
        pipeline.arrangedSubviews.forEach { pipeline.removeArrangedSubview($0); $0.removeFromSuperview() }
        if let item = selected {
            for stage in MeetingPresentation.stages(item, active: activeRecording).filter({ $0.symbol != "calendar" }) {
                let image = MeetingListView.icon(stage)
                let title = stage.symbol == "mic" && activeRecording?.dir != item.dir && !item.hasAudio ? localised("Audio not retained", "Аудио не сохранено") : stage.title
                let label = NSTextField(wrappingLabelWithString: (stage.state == .pending ? localised("Waiting: ", "Ожидание: ") : "") + title)
                label.font = .systemFont(ofSize: 11)
                label.setContentHuggingPriority(.init(1), for: .horizontal)
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let row = NSStackView(views: [image, label])
                row.spacing = 10
                if stage.symbol == "doc.text" {
                    row.identifier = .init("meeting.processing-transcript")
                    row.addArrangedSubview(repeatButton)
                } else if stage.symbol == "checklist" {
                    row.identifier = .init("meeting.processing-summary")
                    row.addArrangedSubview(regenerateButton)
                }
                pipeline.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: pipeline.widthAnchor).isActive = true
            }
        }
        if speakersStack.arrangedSubviews.isEmpty {
            let message = NSTextField(wrappingLabelWithString: localised("Speakers appear after transcription.", "Участники появятся после расшифровки."))
            message.font = .systemFont(ofSize: 12)
            message.textColor = JournalStyle.muted
            speakersStack.addArrangedSubview(message)
            message.widthAnchor.constraint(equalTo: speakersStack.widthAnchor).isActive = true
        }
        updateButtons()
        updateCancellationControls()
        let choice = TranscriptionChoice.read(engine: Config.transcriptionEngine(),
            cloudProvider: Config.transcriptionCloudProvider(), enabled: Config.transcriptionEnabled(),
            localModels: Platform.supportsLocalModels, localEngine: Config.transcriptionLocalEngine())
        let transcription = [choice.cloud ? Self.transcriptionModelName(choice.provider) : nil,
                             choice.local ? Self.transcriptionModelName(choice.localEngine) : nil].compactMap { $0 }
        let diarization = [choice.cloud ? localised("Built into ", "Встроенная в ") + RecordingsEngineName.name(choice.provider) : nil,
                           choice.local && Config.localDiarizationEnabled() ? Config.diarizationModel().title : nil].compactMap { $0 }
        let disabled = localised("Disabled", "Отключена")
        route.stringValue = localised("Transcription: ", "Расшифровка: ") + (transcription.isEmpty ? disabled : transcription.joined(separator: " → "))
            + "\n" + localised("Diarization: ", "Диаризация: ") + (diarization.isEmpty ? disabled : diarization.joined(separator: " / "))
            + "\n" + localised("Summary: ", "Сводка: ") + (Config.summary().enabled ? Self.summaryMethodName(Config.summary().backend) : disabled)
    }

}

extension MeetingLibraryController {
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        62
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        JournalMeetingRow()
    }
}

@MainActor
private final class MeetingSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    private final class Cell: NSSearchFieldCell {
        override func draw(withFrame frame: NSRect, in controlView: NSView) {
            // The native bezel ignores backgroundColor.
            let bezel = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: frame.height / 2, yRadius: frame.height / 2)
            JournalStyle.inset.setFill()
            bezel.fill()
            JournalStyle.line.setStroke()
            bezel.lineWidth = 1
            bezel.stroke()
            super.drawInterior(withFrame: frame, in: controlView)
        }
    }
}

@MainActor
private final class JournalMeetingRow: NSTableRowView {
    private var hover = false
    private var tracking: NSTrackingArea?
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if hover && !isSelected { drawHighlight(JournalStyle.selection.withAlphaComponent(0.5)) }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        drawHighlight(JournalStyle.selection)
    }
    private func drawHighlight(_ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
private final class JournalColumns: NSStackView {
    var onResize: (() -> Void)?
    private var lastWidth: CGFloat = -1
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if lastWidth != newSize.width { lastWidth = newSize.width; onResize?() }
    }
}
