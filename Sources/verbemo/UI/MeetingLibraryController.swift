import AppKit
import SwiftUI

/// The Journal meeting list, document and inspector hosted by ApplicationWindow.
@MainActor
final class MeetingLibraryController: NSObject, NSSearchFieldDelegate {
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
    var onResumeDiarization: (@MainActor (URL, DiarizationState.Request) async throws -> Void)?
    var onRetryDiarization: ((URL) async throws -> Void)?
    var onSkipDiarization: ((URL) async throws -> Void)?
    private var root: URL
    private let panel: NSWindow
    private(set) var contentView = NSView()
    private(set) var listContentView = NSView()
    let toolbarContent = NSStackView()
    private let titleActions = NSStackView()
    var onSelectMeeting: (() -> Void)?
    var onNavigateSettings: ((ApplicationNavigationState.Destination) -> Void)?
    var currentFilter: ApplicationNavigationState.Destination { meetingFilter }
    private let filterButton = LibraryFilterButton()
    private let filterPopover = NSPopover()
    private var filterOptions: [NSButton] = []
    private let measuringListTitle = MeetingListView.titleLabel("")
    private let resultPicker = NSStackView()
    let meetingHeaderState = StudioMeetingHeaderState()
    private let meetingSearch = StudioSearchField()
    private var meetingHeader: NSHostingView<StudioMeetingHeader>?
    func focusMeetingSearch() -> Bool {
        guard !contentView.isHiddenOrHasHiddenAncestor, meetingSearch.isEnabled, panel.attachedSheet == nil else { return false }
        if meetingSearch.isHiddenOrHasHiddenAncestor {
            inspectorRequested = false
            updateCompactLayout()
        }
        guard !meetingSearch.isHiddenOrHasHiddenAncestor else { return false }
        return panel.makeFirstResponder(meetingSearch)
    }
    private func syncMeetingSearchHeader() {
        if meetingSearch.stringValue != meetingSearchQuery { meetingSearch.stringValue = meetingSearchQuery }
        meetingSearch.isEnabled = currentSearchContext != nil
        meetingHeaderState.searchEnabled = meetingSearch.isEnabled
        meetingHeaderState.versionsEnabled = !versions.isEmpty
        meetingSearch.toolTip = meetingSearch.isEnabled ? nil : localised(
            "A readable transcript or summary is required.", "Поиск появится, когда будет готова расшифровка или сводка.")
        meetingSearch.setAccessibilityHelp(meetingSearch.toolTip)
        if !meetingSearch.isEnabled, meetingSearch.currentEditor() != nil {
            panel.makeFirstResponder(resultPicker.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.state == .on })
        }
        meetingHeaderState.matchCount = meetingSearchHits.count
        meetingHeaderState.matchIndex = meetingSearchIndex
        meetingHeaderState.hasQuery = !meetingSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        meetingHeader?.isHidden = selected == nil || activeRecording?.dir == selected?.dir
    }
    @objc private func meetingSearchChanged() {
        if meetingSearch.stringValue != meetingSearchQuery { setMeetingSearchQuery(meetingSearch.stringValue) }
    }
    private let inspectorButton = NSButton()
    private let pipeline = NSStackView()
    private let route = NSTextField(wrappingLabelWithString: "")
    private let cancelProcessingButton = NSButton()
    private let processingStatus = NSTextField(labelWithString: "")
    private let resultNotice = NSView()
    private let dismissNotice = NSButton()
    private var noticeKey = ""
    private var noticeDismissed = false
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
    var onAssociateActiveRecording: ((URL, CalendarWatcher.Meeting?) throws -> Void)?
    private let openActiveButton = NSButton()
    func setActiveRecording(_ value: MeetingPresentation.ActiveRecording?) {
        guard activeRecording != value else { return }
        let refreshDetail = selected == nil || selected?.dir == activeRecording?.dir || selected?.dir == value?.dir
        activeRecording = value
        if libraryQuery.isEmpty { show(allItems, refreshDetail: refreshDetail) }
        else { restartLibrarySearch() }
    }
    private var allItems: [SessionInventory.Item] = []
    private var meetingFilter: ApplicationNavigationState.Destination = .allMeetings
    private let search = StudioSearchField()
    private let librarySearchStatus = NSTextField(labelWithString: "")
    private var librarySearchTask: Task<Void, Never>?
    private var librarySearchTasks: [Int: Task<Void, Never>] = [:]
    private var librarySearchGeneration = 0
    private var libraryHits: [URL: MeetingLibrarySearch.Hit]?
    private var librarySearchPending = false
    private var libraryUnreadable = 0
    private var libraryNavigationFailed = false
    private var libraryQuery: String { search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let clearSearch = NSButton()
    private let emptyView = NSStackView()
    private var meetingMenu = NSMenu()
    private let audioPlayer = MeetingPlaybackView()
    private let moreButton = NSButton()
    private let regenerateButton = NSButton()
    private let repeatButton = NSButton()
    private let summaryCreateButton = NSButton()
    private let summaryEmptyActions = NSStackView()
    private let summaryAvailability = NSTextField(wrappingLabelWithString: "")
    private var journalColumns: JournalColumns?
    private let documentHost = JournalSurface(StudioStyle.paper)
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
    private let inspectorDivider = InspectorDivider()
    private var preferredInspectorWidth: CGFloat = 270
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
    private let detailError = NSTextField(labelWithString: "")
    private var renamingSession: URL?
    private let diarizationLabel = NSTextField(wrappingLabelWithString: "")
    private let diarizationActions = NSStackView()
    private let retryDiarizationButton = NSButton()
    private let skipDiarizationButton = NSButton()
    private let speakersStack = FlippedStackView()
    private struct SpeakerRowsContext: Equatable {
        let generation: MeetingSearchContext?
        let names: [String: SpeakerNames.Entry]?
        let participants: [CalendarParticipant]
        let editingBlocker: String?
        let canPlay: Bool
        let canMatch: Bool
    }
    private var renderedSpeakerRows: SpeakerRowsContext?
    private func clearSpeakerRows() {
        renderedSpeakerRows = nil
        speakersStack.arrangedSubviews.forEach {
            speakersStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }
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
    struct MeetingSearchHit: Equatable { let tab: String; let segment: Int?; let range: NSRange }
    private struct MeetingReadingPosition {
        let tab: String
        let summary: NSPoint
        let plainTranscript: NSPoint
        let transcript: MeetingTranscriptView.ReadingPosition?
    }
    private struct LibraryReadingPosition {
        let dir: URL
        let version: String?
        let context: MeetingSearchContext?
        let position: MeetingReadingPosition
        let query: String
        let index: Int?
        let origin: MeetingReadingPosition?
    }
    private var libraryReadingPosition: LibraryReadingPosition?
    private func saveLibraryReadingPosition() {
        guard meetingSelectionActive, let selected else { return }
        libraryReadingPosition = .init(dir: selected.dir, version: versionKey, context: currentSearchContext,
            position: captureMeetingReadingPosition(), query: meetingSearchQuery, index: meetingSearchIndex, origin: searchOrigin)
    }
    private func applyLibraryResults() {
        guard meetingSelectionActive else { show(allItems); return }
        if selected?.dir == libraryReadingPosition?.dir,
           currentSearchContext == libraryReadingPosition?.context { saveLibraryReadingPosition() }
        let saved = libraryReadingPosition
        libraryReadingPosition = nil
        if let saved { versionSession = saved.dir; versionKey = saved.version }
        show(allItems, preferredSelection: saved?.dir)
        guard let saved, selected?.dir == saved.dir, currentSearchContext == saved.context else { return }
        setMeetingSearchQuery(saved.query)
        if let index = saved.index, meetingSearchHits.indices.contains(index) { revealMeetingSearchHit(at: index) }
        searchOrigin = saved.origin
        restoreMeetingReadingPosition(saved.position)
    }
    private(set) var meetingSearchQuery = ""
    private(set) var meetingSearchHits: [MeetingSearchHit] = []
    private(set) var meetingSearchIndex: Int?
    private var searchTranscript: Transcript?
    private struct MeetingSearchContext: Equatable { let location: String; let transcript: Data }
    private var searchTranscriptData: Data?
    private var displayedSearchContext: MeetingSearchContext?
    private var searchOrigin: MeetingReadingPosition?
    private var currentSearchContext: MeetingSearchContext? {
        guard let selected, let dir = artifactDirectory, selectedVersion?.isRequest != true,
              activeRecording?.dir != selected.dir,
              searchTranscript != nil || transcriptText.identifier != nil || summaryText.identifier != nil else { return nil }
        return MeetingSearchContext(location: selected.dir.path + "\n" + dir.path,
                                    transcript: searchTranscriptData ?? Data(transcriptText.string.utf8))
    }
    private func captureMeetingReadingPosition() -> MeetingReadingPosition {
        .init(tab: detailTabs.selectedTabViewItem?.identifier as? String ?? "summary",
              summary: summaryText.enclosingScrollView?.contentView.bounds.origin ?? .zero,
              plainTranscript: transcriptText.enclosingScrollView?.contentView.bounds.origin ?? .zero,
              transcript: meetingTranscript.readingPosition())
    }
    private func selectResultTab(_ id: String) {
        detailTabs.selectTabViewItem(withIdentifier: id)
        for case let button as JournalTabButton in resultPicker.arrangedSubviews {
            button.select(button.identifier?.rawValue == "meeting.result.\(id)")
        }
    }
    private func restoreMeetingReadingPosition(_ position: MeetingReadingPosition) {
        selectResultTab(position.tab)
        for (text, point) in [(summaryText, position.summary), (transcriptText, position.plainTranscript)] {
            if let scroll = text.enclosingScrollView {
                scroll.contentView.scroll(to: point)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        meetingTranscript.restoreReadingPosition(position.transcript)
    }
    func setMeetingSearchQuery(_ query: String) {
        guard currentSearchContext != nil, currentSearchContext == displayedSearchContext else { return }
        let wasEmpty = meetingSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if wasEmpty && !isEmpty { searchOrigin = captureMeetingReadingPosition() }
        meetingSearchQuery = query
        defer { syncMeetingSearchHeader() }
        rebuildMeetingSearch()
        if isEmpty {
            if let origin = searchOrigin { restoreMeetingReadingPosition(origin) }
            searchOrigin = nil
        }
    }
    private func rebuildMeetingSearch(preservingIndex: Bool = false) {
        let previousHits = meetingSearchHits, previousIndex = meetingSearchIndex
        meetingSearchIndex = nil
        meetingSearchHits = []
        if let transcript = searchTranscript {
            for (index, segment) in transcript.segments.enumerated() {
                meetingSearchHits += MeetingTextSearch.matches(in: segment.text, query: meetingSearchQuery).map {
                    .init(tab: "transcript", segment: index, range: $0)
                }
            }
        } else if transcriptText.identifier != nil {
            meetingSearchHits += MeetingTextSearch.matches(in: transcriptText.string, query: meetingSearchQuery).map {
                .init(tab: "transcript", segment: nil, range: $0)
            }
        }
        if summaryText.identifier != nil {
            meetingSearchHits += MeetingTextSearch.matches(in: summaryText.string, query: meetingSearchQuery).map {
                .init(tab: "summary", segment: nil, range: $0)
            }
        }
        if preservingIndex, previousHits == meetingSearchHits, let index = previousIndex, meetingSearchHits.indices.contains(index) {
            meetingSearchIndex = index
        }
        for text in [summaryText, transcriptText] {
            let full = NSRange(location: 0, length: (text.string as NSString).length)
            text.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            for hit in meetingSearchHits where hit.segment == nil && hit.tab == (text === summaryText ? "summary" : "transcript") {
                text.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25), forCharacterRange: hit.range)
            }
        }
        let focused = meetingSearchIndex.map { meetingSearchHits[$0] }
        meetingTranscript.setSearch(matches: transcriptSearchRanges(), focusedSegment: focused?.segment, focusedRange: focused?.range)
    }
    private func transcriptSearchRanges() -> [Int: [NSRange]] {
        var ranges: [Int: [NSRange]] = [:]
        for hit in meetingSearchHits {
            if let segment = hit.segment { ranges[segment, default: []].append(hit.range) }
        }
        return ranges
    }
    func moveMeetingSearch(forward: Bool) {
        guard currentSearchContext == displayedSearchContext, !meetingSearchHits.isEmpty else { return }
        let count = meetingSearchHits.count
        let index = meetingSearchIndex.map { ($0 + (forward ? 1 : count - 1)) % count } ?? (forward ? 0 : count - 1)
        revealMeetingSearchHit(at: index)
    }
    private func revealMeetingSearchHit(at index: Int) {
        meetingSearchIndex = index
        syncMeetingSearchHeader()
        let hit = meetingSearchHits[index]
        selectResultTab(hit.tab)
        meetingTranscript.setSearch(matches: transcriptSearchRanges(), focusedSegment: hit.segment, focusedRange: hit.range)
        if let segment = hit.segment { meetingTranscript.revealSearchSegment(segment) }
        else {
            let text = hit.tab == "summary" ? summaryText : transcriptText
            text.scrollRangeToVisible(hit.range)
            text.showFindIndicator(for: hit.range)
        }
    }
    private func finishSearchReload(previousPosition: MeetingReadingPosition) {
        defer { syncMeetingSearchHeader() }
        let sameContext = displayedSearchContext != nil && displayedSearchContext == currentSearchContext
        if !sameContext {
            meetingSearchQuery = ""
            searchOrigin = nil
            for text in [summaryText, transcriptText] { text.scrollToBeginningOfDocument(nil) }
        }
        displayedSearchContext = currentSearchContext
        rebuildMeetingSearch(preservingIndex: sameContext)
        if sameContext { restoreMeetingReadingPosition(previousPosition) }
    }
    private let summaryText = NSTextView()
    private let transcriptText = NSTextView()
    private let busyLabel = NSTextField(labelWithString: "")

    private var items: [SessionInventory.Item] = []
    private var selected: SessionInventory.Item? {
        if !meetingSelectionActive { return items.first { $0.dir == rememberedMeeting } }
        return table.selectedRow >= 0 && table.selectedRow < items.count
            ? items[table.selectedRow]
            : nil
    }
    var onActivityChange: (() -> Void)?
    private let deletion = SessionDeletionController()
    var mcpPendingDeletion: Set<String> { Set(allItems.filter { deletion.isPending($0.dir) }.map { $0.dir.lastPathComponent }) }
    private let deletionNotice = NSStackView()
    private let deletionLabel = NSTextField(labelWithString: "")
    var serviceViews: [NSView] { [detailError, resultNotice, deletionNotice, busyLabel, librarySearchStatus] + audioPlayer.serviceViews }
    private var undoDeletionID: UUID?
    var isProcessing: Bool { !workByMeeting.isEmpty || deletion.hasWork || processingCancellation.hasPending }
    func cancelPendingDeletion() { deletion.cancelAll(); onActivityChange?() }
    private var summarySheets: [URL: (version: URL, sheet: SummaryRegenerationSheet)] = [:]
    private var workByMeeting: [URL: String] = [:]
    private let operations: ProcessingOperations
    private var displayedOperations: [ProcessingOperations.Snapshot] = []
    private var selectedWork: String? { selected.flatMap { workByMeeting[$0.dir] } }

    private func isBusy(_ dir: URL) -> Bool {
        workByMeeting[dir] != nil || SessionClaim.isHeld(dir)
            || operations.snapshot().contains { $0.session == dir.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private func setWorking(_ working: Bool, in dir: URL) {
        // An empty value keeps the meeting busy without adding a status message.
        workByMeeting[dir] = working ? "" : nil
        guard !terminating else { return }
        if working {
            detailError.isHidden = true
            detailError.stringValue = ""
            detailError.toolTip = nil
        }
        if selected?.dir == dir { showDetail() }
        onActivityChange?()
    }

    init(root: URL, pasteboard: NSPasteboard = .general,
         operations: ProcessingOperations = .shared, hostWindow: NSWindow) {
        processingCancellation = MeetingProcessingCancellation(operations: operations)
        self.operations = operations
        self.root = root
        self.pasteboard = pasteboard
        panel = hostWindow
        super.init()
        buildTable()
        displayChanges = ConfigWatch.Token(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.table.reloadData(); self?.updateInspector() } }, center: NSWorkspace.shared.notificationCenter)
        contentView = buildLayout()
        meetingTranscript.onPlayFrom = { [weak self] seconds in self?.audioPlayer.play(from: seconds) }
        meetingTranscript.onError = { [weak self] error in self?.showServiceError(error.localizedDescription) }
        calendarPicker.onError = { [weak self] error in self?.showServiceError(error.localizedDescription) }
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
                if let self {
                    let next = operations.snapshot()
                    if !next.elementsEqual(displayedOperations, by: {
                        $0.id == $1.id && $0.kind == $1.kind && $0.state == $1.state && $0.artifactDirectory == $1.artifactDirectory
                    }) {
                        displayedOperations = next
                        reload()
                    }
                }
                self?.updateCancellationControls()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    deinit {
        processingMonitor?.cancel()
        for task in librarySearchTasks.values { task.cancel() }
    }

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
        for task in librarySearchTasks.values { task.cancel(); cleanup.append(task) }
        librarySearchTask = nil
        if let monitor { cleanup.append(monitor) }
        cleanup.append(deletion.stopForTermination())
        cleanup.append(Task { [audioPlayer] in await audioPlayer.settled() })
        for task in summarySheets.values.compactMap({ $0.sheet.task }) {
            task.cancel()
            cleanup.append(task)
        }
        return cleanup
    }

    // MARK: - building

    private func buildTable() {
        table.addTableColumn(NSTableColumn(identifier: .init("meeting-card")))
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.backgroundColor = StudioStyle.sidebar
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
        busyLabel.isHidden = true
        busyLabel.identifier = .init("meeting.work-status")
        diarizationLabel.font = .systemFont(ofSize: 11)
        diarizationLabel.textColor = .secondaryLabelColor
        diarizationLabel.lineBreakMode = .byWordWrapping
        diarizationLabel.identifier = .init("diarization.status")
        for (button, title, symbol, action) in [
            (retryDiarizationButton, localised("Retry diarization", "Повторить диаризацию"),
             "arrow.clockwise", #selector(retryDiarizationClicked)),
            (skipDiarizationButton, localised("Skip diarization", "Пропустить диаризацию"),
             "forward.end", #selector(skipDiarizationClicked)),
            (finishButton, localised("Finish processing", "Доделать"), "play", #selector(finishClicked)),
            (cancelProcessingButton, localised("Cancel processing", "Отменить обработку"), "xmark", #selector(cancelProcessingClicked)),
        ] as [(NSButton, String, String, Selector)] {
            button.title = title
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        cancelProcessingButton.identifier = .init("meeting.cancel-processing")
        processingStatus.identifier = .init("meeting.processing-status")
        processingStatus.font = .systemFont(ofSize: 11)
        processingStatus.textColor = StudioStyle.muted
        processingStatus.lineBreakMode = .byTruncatingTail
        resultNotice.identifier = .init("meeting.result-notice")
        resultNotice.isHidden = true
        dismissNotice.identifier = .init("meeting.dismiss-notice")
        dismissNotice.title = ""
        dismissNotice.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        dismissNotice.imagePosition = .imageOnly
        dismissNotice.isBordered = false
        dismissNotice.toolTip = localised("Dismiss notice", "Скрыть уведомление")
        dismissNotice.setAccessibilityLabel(dismissNotice.toolTip)
        dismissNotice.target = self
        dismissNotice.action = #selector(dismissResultNotice)
        dismissNotice.widthAnchor.constraint(equalToConstant: 22).isActive = true
        dismissNotice.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let noticeRow = NSStackView(views: [processingStatus, dismissNotice])
        noticeRow.distribution = .fill
        noticeRow.alignment = .centerY
        noticeRow.spacing = 8
        processingStatus.setContentHuggingPriority(.defaultLow, for: .horizontal)
        processingStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeRow.translatesAutoresizingMaskIntoConstraints = false
        resultNotice.addSubview(noticeRow)
        NSLayoutConstraint.activate([
            noticeRow.leadingAnchor.constraint(equalTo: resultNotice.leadingAnchor, constant: 10),
            noticeRow.trailingAnchor.constraint(equalTo: resultNotice.trailingAnchor, constant: -6),
            noticeRow.topAnchor.constraint(equalTo: resultNotice.topAnchor),
            noticeRow.bottomAnchor.constraint(equalTo: resultNotice.bottomAnchor),
        ])
        retryDiarizationButton.identifier = .init("diarization.retry")
        skipDiarizationButton.identifier = .init("diarization.skip")

        for (button, id, action) in [
            (repeatButton, "meeting.retranscribe", #selector(repeatTranscriptClicked)),
            (regenerateButton, "meeting.generate-summary", #selector(regenerateClicked)),
        ] {
            button.identifier = .init(id)
            button.title = ""
            button.image = StudioStyle.regenerationImage(symbol: button === repeatButton ? "text.bubble" : "checklist")
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }

        speakersStack.orientation = .vertical
        speakersStack.alignment = .leading
        speakersStack.spacing = 8
        speakersStack.identifier = .init("meeting.participants")

        for (id, label, view) in [
            ("summary", localised("Summary", "Сводка"), summaryContent()),
            ("transcript", localised("Transcript", "Расшифровка"), transcriptContent()),
            ("participants", localised("Participants", "Участники"), SetupLayout.scroller(around: speakersStack)),
        ] as [(String, String, NSView)] {
            let tab = NSTabViewItem(identifier: id)
            tab.label = label
            tab.view = textPane(content: view)
            detailTabs.addTabViewItem(tab)
        }

        versionSelector.identifier = .init("transcript-versions")
        versionSelector.setAccessibilityLabel(localised("Transcript version", "Версия расшифровки"))
        versionSelector.target = self
        versionSelector.action = #selector(versionSelected(_:))
        versionSelector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        diarizationActions.setViews([retryDiarizationButton, skipDiarizationButton], in: .top)
        diarizationActions.orientation = .vertical
        diarizationActions.spacing = 8
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: localised("Meeting actions", "Действия со встречей"))
        moreButton.setAccessibilityLabel(localised("Meeting actions", "Действия со встречей"))
        moreButton.isBordered = false
        moreButton.target = self
        moreButton.action = #selector(moreClicked(_:))
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let titleRow = NSStackView(views: [detailTitle, titleSpacer, titleActions])
        titleActions.setContentHuggingPriority(.required, for: .horizontal)
        titleActions.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailTitle.identifier = .init("meeting.title")
        detailTitle.delegate = self
        detailTitle.target = self
        detailTitle.action = #selector(saveMeetingTitle)
        titleDoubleClick.numberOfClicksRequired = 2
        titleDoubleClick.target = self
        titleDoubleClick.action = #selector(beginRenamingMeeting)
        detailTitle.addGestureRecognizer(titleDoubleClick)
        detailError.textColor = .systemOrange
        detailError.font = .systemFont(ofSize: 11)
        detailError.isHidden = true
        detailError.identifier = .init("meeting.operation-error")
        detailError.lineBreakMode = .byTruncatingTail
        detailError.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            button.selectedTint = StudioStyle.accent
            button.unselectedTint = StudioStyle.muted
            button.markerTint = StudioStyle.accent
            button.select(index == 0)
            resultPicker.addArrangedSubview(button)
        }
        resultPicker.identifier = .init("meeting.result-tabs")
        resultPicker.setAccessibilityRole(.tabGroup)
        resultPicker.setAccessibilityLabel(localised("Meeting result", "Результат встречи"))
        meetingSearch.identifier = .init("meeting.search")
        meetingSearch.placeholderString = localised("Find in this meeting", "Найти в этой встрече")
        meetingSearch.setAccessibilityLabel(localised("Search selected transcript and summary version", "Поиск в выбранной версии расшифровки и сводки"))
        meetingSearch.sendsSearchStringImmediately = true
        meetingSearch.target = self
        meetingSearch.action = #selector(meetingSearchChanged)
        meetingSearch.delegate = self
        meetingHeaderState.onStep = { [weak self] forward in self?.moveMeetingSearch(forward: forward) }
        meetingHeaderState.onClear = { [weak self] in self?.setMeetingSearchQuery("") }
        let header = StudioMeetingHeaderHost(rootView: StudioMeetingHeader(state: meetingHeaderState, versions: versionSelector, tabs: resultPicker, search: meetingSearch))
        header.sizingOptions = [.intrinsicContentSize]
        header.identifier = .init("meeting.studio-header")
        meetingHeader = header
        let detail = NSStackView(views: [detailMeta, titleRow, openActiveButton, audioPlayer, header, detailTabs])
        detail.orientation = .vertical
        detail.distribution = .fill
        detail.alignment = .leading
        detail.spacing = 10
        detailMeta.textColor = .secondaryLabelColor
        detailMeta.font = .systemFont(ofSize: 12)
        detailTitle.font = StudioStyle.titleFont()
        detailTitle.textColor = StudioStyle.ink
        detailTitle.maximumNumberOfLines = 2
        detailTitle.lineBreakMode = .byWordWrapping
        NSLayoutConstraint.activate([
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        return buildJournal(detail: detail)
    }

    private func summaryContent() -> NSView {
        summaryCreateButton.title = localised("Generate summary", "Создать сводку")
        summaryCreateButton.bezelStyle = .rounded
        summaryCreateButton.identifier = .init("meeting.empty-generate-summary")
        summaryCreateButton.target = self
        summaryCreateButton.action = #selector(regenerateClicked)
        summaryAvailability.font = .systemFont(ofSize: 12)
        summaryAvailability.textColor = StudioStyle.muted
        summaryAvailability.identifier = .init("meeting.summary-availability")
        summaryEmptyActions.setViews([summaryCreateButton, summaryAvailability], in: .top)
        summaryEmptyActions.orientation = .vertical
        summaryEmptyActions.alignment = .leading
        summaryEmptyActions.spacing = 8
        summaryAvailability.widthAnchor.constraint(equalTo: summaryEmptyActions.widthAnchor).isActive = true
        let preview = previewScroll(summaryText)
        let stack = NSStackView(views: [summaryEmptyActions, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
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
                              enabled: !isBusy(item.dir))
        calendarPicker.onSelect = { [weak self] meeting in
            guard let self else { throw CancellationError() }
            if activeRecording?.dir == item.dir {
                guard let onAssociateActiveRecording else { throw CocoaError(.fileNoSuchFile) }
                try onAssociateActiveRecording(item.dir, meeting)
            } else {
                try MeetingCalendarMetadata.associate(meeting, in: item.dir)
            }
            reload()
        }
        let duration = item.duration.map { localised("\(Int($0 / 60)) min", "\(Int($0 / 60)) мин") }
        let invited = metadata?.isConfirmed == true ? metadata.map { localised("Invited: \($0.participants.count)", "Приглашены: \($0.participants.count)") } : nil
        detailMeta.stringValue = [MeetingPresentation.date(item.started), duration, invited].compactMap { $0 }.joined(separator: " · ")
        calendarView.onOpen = { [weak self] in
            guard let self, let metadata, let reason = CalendarEventOpener.open(metadata) else { return }
            self.showServiceError(reason)
        }

    }

    var currentActions: MeetingActionState {
        let item = selected
        let dir = artifactDirectory
        let ready = selectedVersion?.isRequest != true && dir.flatMap(PostProcessor.readTranscript)?.segments.isEmpty == false
            && (dir.map { DiarizationState.persisted(in: $0).isFinal } ?? false)
        var state = MeetingActionState(transcriptReady: ready, summaryReady: summaryToCopy != nil,
            hasAudio: item?.hasAudio == true, isRecording: activeRecording?.dir == item?.dir && activeRecording != nil,
            isBusy: item.map { isBusy($0.dir) } ?? false,
            configReadable: !Config.settingsUnknown, transcriptionEnabled: Config.transcriptionEnabled(),
            summaryEnabled: PostProcessor.Policy.configured.summary)
        state.hasPendingTranscript = item.map { TranscriptVersions.isRequested($0.dir) } ?? false
        return state
    }

    func applyFilter(_ filter: ApplicationNavigationState.Destination, clearSearch: Bool = false) {
        meetingFilter = filter
        filterButton.state = filter == .allMeetings ? .off : .on
        filterButton.bezelColor = filter == .allMeetings ? nil : StudioStyle.selection
        filterButton.contentTintColor = filter == .allMeetings ? StudioStyle.ink : StudioStyle.accent
        filterButton.toolTip = localised("Filter meetings: ", "Фильтр встреч: ") + filter.title
        filterButton.setAccessibilityLabel(filterButton.toolTip)
        for option in filterOptions { option.state = option.identifier?.rawValue == "library.filter.\(filter.rawValue)" ? .on : .off }
        if clearSearch { search.stringValue = ""; restartLibrarySearch() }
        else { show(allItems) }
    }
    func setMeetingSelectionActive(_ active: Bool) {
        guard meetingSelectionActive != active else { return }
        if !active { saveLibraryReadingPosition() }
        rememberedMeeting = selected?.dir ?? rememberedMeeting
        meetingSelectionActive = active
        if active { applyLibraryResults() }
        else { show(allItems) }
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
        let compact = columns.bounds.width < 850
        let visible = inspectorRequested ?? !compact
        inspectorWidth?.isActive = !compact
        let maximum = max(270, min(480, columns.bounds.width - 420 - inspectorDivider.bounds.width))
        let width = min(preferredInspectorWidth, maximum)
        inspectorWidth?.constant = width
        inspectorDivider.update(width: width, maximum: maximum)
        columns.arrangedSubviews[0].isHidden = compact && visible
        columns.arrangedSubviews[1].isHidden = compact || !visible
        columns.arrangedSubviews[2].isHidden = !visible
        if inspectorDivider.isHidden, panel.firstResponder === inspectorDivider { panel.selectNextKeyView(inspectorDivider) }
        inspectorButton.state = visible ? .on : .off
        inspectorButton.setAccessibilityValue(visible ? 1 : 0)
    }
    @objc private func toggleInspector() {
        guard let columns = journalColumns else { return }
        inspectorRequested = columns.arrangedSubviews[2].isHidden
        updateCompactLayout()
    }
    @objc private func closeInspector() {
        inspectorRequested = false
        updateCompactLayout()
        panel.makeFirstResponder(inspectorButton)
    }
    @objc private func resultSelected(_ sender: NSButton) {
        for case let button as JournalTabButton in resultPicker.arrangedSubviews { button.select(button === sender) }
        detailTabs.selectTabViewItem(withIdentifier: ["summary", "transcript", "participants"][sender.tag])
    }
    @objc private func showLibraryFilter() {
        filterButton.state = meetingFilter == .allMeetings ? .off : .on
        panel.makeFirstResponder(filterButton)
        filterPopover.show(relativeTo: filterButton.bounds, of: filterButton, preferredEdge: .minY)
    }
    @objc private func filterSelected(_ sender: NSButton) {
        let filters: [ApplicationNavigationState.Destination] = [.allMeetings, .processing, .attention]
        guard filters.indices.contains(sender.tag) else { return }
        applyFilter(filters[sender.tag])
        filterPopover.performClose(nil)
        panel.makeFirstResponder(filterButton)
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
    @objc private func searchChanged() { libraryNavigationFailed = false; restartLibrarySearch() }
    @objc private func meetingClicked() {
        if let selected, selected.dir == activeRecording?.dir { onOpenActiveRecording?(); return }
        revealLibraryHit()
        onSelectMeeting?()
    }
    private func revealLibraryHit() {
        guard let item = selected, let hit = libraryHits?[item.dir],
              hit.source == .transcript || hit.source == .summary else { return }
        guard MeetingLibrarySearch.isCurrent(hit, in: item.dir) else { restartLibrarySearch(); return }
        versionSession = nil
        versionKey = nil
        showDetail()
        guard artifactDirectory == item.dir, currentSearchContext != nil,
              MeetingLibrarySearch.isCurrent(hit, in: item.dir) else {
            libraryNavigationFailed = true
            restartLibrarySearch()
            return
        }
        setMeetingSearchQuery(hit.query)
        let tab = hit.source == .summary ? "summary" : "transcript"
        guard let index = meetingSearchHits.firstIndex(where: { $0.tab == tab && $0.segment == hit.segment }) else {
            libraryNavigationFailed = true
            restartLibrarySearch()
            return
        }
        revealMeetingSearchHit(at: index)
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
        Self.frameOwnedPane(content)
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
        setWorking(true, in: item.dir)
        if let saved = summarySheets[item.dir], saved.version == dir {
            saved.sheet.selectionChanged()
            panel.beginSheet(saved.sheet.window)
            return
        }
        let sheet = SummaryRegenerationSheet(onSettings: { [weak self] in self?.onNavigateSettings?(.summary) }, run: { request in
            try await PostProcessor.regenerateSummary(dir, request: request)
        }, onFailure: { [weak self] error in
            guard let self else { return }
            setWorking(false, in: item.dir)
            reload()
            say(error.localizedDescription, about: item)
        }, completion: { [weak self] in
            guard let self else { return }
            summarySheets.removeValue(forKey: item.dir)
            setWorking(false, in: item.dir)
            reload()
        })
        summarySheets[item.dir] = (dir, sheet)
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
            showServiceError(localised("Enter a meeting name.", "Введите название встречи."))
            return
        }
        do {
            if item.dir == activeRecording?.dir { try onRenameActiveRecording?(title) }
            else { try SessionState.amend(item.dir, with: ["title": title]) }
            cancelTitleEdit()
            detailTitle.abortEditing()
            reload()
        }
        catch { showServiceError(error.localizedDescription) }
    }
    private func cancelTitleEdit() {
        if renamingSession != nil { detailError.isHidden = true }
        renamingSession = nil
        titleDoubleClick.isEnabled = true
        detailTitle.isEditable = false
        detailTitle.isBezeled = false
        detailTitle.drawsBackground = false
        detailTitle.stringValue = selected.map { $0.title ?? $0.name } ?? ""
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === meetingSearch {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                moveMeetingSearch(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { setMeetingSearchQuery(""); return true }
            return false
        }
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
        libraryNavigationFailed = false
        libraryReadingPosition = nil
        table.deselectAll(nil)
        show([])
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
        invalidateLibrarySearch()
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
            self.scan = nil
            self.show(found)
            self.restartLibrarySearch()
        }
        scansInFlight[generation] = scan
    }

    /// Wait for the latest scan to be on screen. For tests, which would
    /// otherwise have to guess how long reading a folder takes.
    func settled() async {
        while scan != nil || librarySearchTask != nil {
            if let scan { await scan.value }
            if let task = librarySearchTask { await task.value }
        }
    }

    private func invalidateLibrarySearch() {
        if libraryReadingPosition == nil, !libraryQuery.isEmpty { saveLibraryReadingPosition() }
        librarySearchGeneration += 1
        librarySearchTask?.cancel()
        librarySearchTask = nil
        libraryHits = nil
        libraryUnreadable = 0
        librarySearchPending = !libraryQuery.isEmpty
        if libraryQuery.isEmpty { libraryNavigationFailed = false }
    }

    private func restartLibrarySearch() {
        invalidateLibrarySearch()
        if libraryQuery.isEmpty { applyLibraryResults(); return }
        show(allItems)
        guard !terminating, !libraryQuery.isEmpty, scan == nil else { return }
        let generation = librarySearchGeneration, query = libraryQuery, root = self.root
        let inventory = (activeRecording.map { [$0.item] } ?? []) + allItems
        let inputs = inventory.map { item in
            MeetingLibrarySearch.Input(dir: item.dir, title: item.title ?? item.name,
                metadata: [item.name, MeetingPresentation.date(item.started)]
                    + (MeetingCalendarMetadata.read(from: item.dir)?.participants.map(\.name) ?? []))
        }
        let task = Task { [weak self] in
            defer {
                self?.librarySearchTasks.removeValue(forKey: generation)
                if self?.librarySearchGeneration == generation { self?.librarySearchTask = nil }
            }
            do {
                try await Task.sleep(for: .milliseconds(150))
                let worker = Task.detached(priority: .userInitiated) { try MeetingLibrarySearch.search(inputs, query: query) }
                let outcome = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, !self.terminating, generation == self.librarySearchGeneration,
                      root == self.root, query == self.libraryQuery else { return }
                self.libraryHits = outcome.hits
                self.libraryUnreadable = outcome.unreadable
                self.librarySearchPending = false
                self.applyLibraryResults()
            } catch { /* Cancelled searches never replace the current query. */ }
        }
        librarySearchTask = task
        librarySearchTasks[generation] = task
    }

    /// Something changed in the recordings folder that this window did not
    /// do itself — a transcript or a summary finished. Read again if anybody
    /// is looking; a closed window reads when it opens.
    func sessionsChanged() {
        guard panel.isVisible else { return }
        reload()
    }

    func refresh() { libraryNavigationFailed = false; reload() }

    func activityTitle(for dir: URL) -> String {
        activityTitles[dir] ?? dir.lastPathComponent
    }
    private var activityTitles: [URL: String] = [:]
    var attentionMeetings: [MeetingPresentation.Attention] {
        let active = activeRecording
        let inventory = (active.map { [$0.item] } ?? []) + allItems
        return inventory.compactMap { item in
            guard !deletion.isPending(item.dir) else { return nil }
            return MeetingPresentation.attention(for: item, active: active)
        }
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

    private func show(_ found: [SessionInventory.Item], refreshDetail: Bool = true, preferredSelection: URL? = nil) {
        reloadingList = true
        defer { reloadingList = false }
        let previous = preferredSelection ?? selected?.dir ?? rememberedMeeting
        allItems = found.filter { $0.dir != activeRecording?.dir }
        activityTitles = Dictionary(allItems.map { ($0.dir.standardizedFileURL.resolvingSymlinksInPath(), $0.title ?? $0.name) }, uniquingKeysWith: { first, _ in first })
        let inventory = (activeRecording.map { [$0.item] } ?? []) + allItems
        items = inventory.filter { item in
            !deletion.isPending(item.dir) && MeetingPresentation.matches(item, filter: meetingFilter, query: "", active: activeRecording)
                && (libraryQuery.isEmpty || (libraryHits.map { $0[item.dir] != nil }
                    ?? MeetingPresentation.matches(item, filter: .allMeetings, query: libraryQuery, active: activeRecording)))
        }
        emptyView.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        clearSearch.isHidden = libraryQuery.isEmpty && meetingFilter == .allMeetings
        librarySearchStatus.stringValue = librarySearchPending ? localised("Searching…", "Поиск…")
            : libraryUnreadable > 0 ? localised("Some materials could not be searched. Try refreshing the library.", "Не удалось проверить часть материалов. Попробуйте обновить библиотеку.")
            : libraryNavigationFailed ? localised("The current result could not be opened. Refresh the library or check the meeting details.", "Не удалось открыть текущий результат. Обновите библиотеку или проверьте детали встречи.") : ""
        librarySearchStatus.isHidden = librarySearchStatus.stringValue.isEmpty
        librarySearchStatus.toolTip = librarySearchStatus.stringValue
        emptyLabel.isHidden = !librarySearchStatus.isHidden
        emptyLabel.stringValue = !libraryQuery.isEmpty ? localised("No meetings match your search.", "По вашему запросу встреч не найдено.")
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
    @objc private func clearSearchClicked() { applyFilter(.allMeetings, clearSearch: true) }

    @objc private func versionSelected(_ sender: NSPopUpButton) {
        versionKey = selectedVersion.map(key)
        showDetail()
        if librarySearchPending { saveLibraryReadingPosition() }
    }

    private func showDetail() {
        summaryEmptyActions.isHidden = true
        let previousPosition = captureMeetingReadingPosition()
        var speakerRowsHandled = false
        searchTranscript = nil
        searchTranscriptData = nil
        defer {
            meetingTranscript.isHidden = searchTranscript == nil
            plainTranscriptScroll?.isHidden = searchTranscript != nil
            if !speakerRowsHandled { clearSpeakerRows() }
            finishSearchReload(previousPosition: previousPosition)
        }
        let live = activeRecording.map { selected?.dir == $0.dir } ?? false
        let actionsHost = live ? activeRecordingView?.meetingActionsHost ?? titleActions : titleActions
        if toolbarContent.superview !== actionsHost {
            (toolbarContent.superview as? NSStackView)?.removeArrangedSubview(toolbarContent)
            toolbarContent.removeFromSuperview()
            actionsHost.addArrangedSubview(toolbarContent)
        }
        toolbarContent.isHidden = selected == nil
        meetingDocument?.isHidden = live && activeRecordingView != nil
        activeRecordingView?.isHidden = !live
        openActiveButton.isHidden = true
        resultPicker.isHidden = selected == nil
        detailTabs.isHidden = selected == nil
        if renamingSession != selected?.dir { cancelTitleEdit() }
        defer { updateInspector() }
        if let activeRecording, selected?.dir == activeRecording.dir {
            showCalendar(for: selected)
            detailTitle.stringValue = activeRecording.title
            detailTitle.toolTip = activeRecording.title
            moreButton.isEnabled = true
            versions = []
            versionSelector.removeAllItems()
            versionSelector.isEnabled = false
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
            busyLabel.isHidden = true
            return
        }
        showCalendar(for: selected)
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
        versionSelector.isEnabled = !versions.isEmpty
        versionKey = selectedVersion.map(key)

        guard let item = selected else {
            detailTitle.toolTip = nil
            detailTitle.stringValue = !items.isEmpty ? localised("Select a recording", "Выберите запись")
                : librarySearchPending ? localised("Searching…", "Поиск…")
                : libraryUnreadable > 0 ? localised("Search incomplete", "Поиск выполнен не полностью")
                : !libraryQuery.isEmpty ? localised("No matching meetings", "Совпадений не найдено")
                : meetingFilter != .allMeetings ? localised("No meetings in this filter", "Нет встреч по выбранному фильтру")
                : localised("No recordings yet", "Записей пока нет")
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
        let stages = MeetingPresentation.stages(item, version: selectedVersion)
        if let request = selectedVersion, request.isRequest {
            summaryText.string = stages.last?.title ?? ""
            summaryEmptyActions.isHidden = false
            transcriptText.string = stages.first { $0.symbol == "doc.text" }?.title ?? request.title
            if case .failed(let reason) = request.state { transcriptText.string += "\n\n" + reason }
            summaryText.identifier = nil
            transcriptText.identifier = nil
            updateButtons()
            return
        }
        let summary = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        var summaryPreview = summary ?? stages.last?.title ?? ""
        summaryEmptyActions.isHidden = summary != nil
        summaryText.identifier = summary == nil ? nil : .init("meeting-words")
        if summary != nil && !PostProcessor.hasCurrentSummary(dir) {
            summaryPreview = localised(
                "This summary belongs to the previous transcript.\n\n",
                "Это сводка предыдущей расшифровки.\n\n") + summaryPreview
        }
        summaryText.textStorage?.setAttributedString(MarkdownPreview.render(summaryPreview, fontSize: 15))
        let transcript = PostProcessor.readTranscript(dir)
        let transcriptData = try? Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        searchTranscript = transcript
        searchTranscriptData = transcriptData
        let markdown = try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        let transcriptPreview = markdown ?? transcript?.rendered(
            title: item.title ?? item.name, names: SpeakerNames.read(from: dir))
            ?? stages.first { $0.symbol == "doc.text" }?.title ?? ""
        transcriptText.textStorage?.setAttributedString(MarkdownPreview.render(transcriptPreview, fontSize: 15))
        transcriptText.identifier = markdown != nil || transcript != nil ? .init("meeting-words") : nil
        guard let transcript else {
            updateButtons()
            return
        }

        let names = SpeakerNames.read(from: dir)
        let calendar = MeetingCalendarMetadata.read(from: item.dir)
        let diarized = DiarizationState.read(dir).map { $0.status == .completed }
            ?? (!Config.localEngines.contains(transcript.engine) || Set(transcript.segments.map(\.speaker)).count > 2)
        let participantChoices = calendar?.isConfirmed == true ? calendar!.participants : []
        let editingBlocker = speakerEditingBlocker(session: item.dir, version: dir)
        let canEdit = editingBlocker == nil
        meetingTranscript.onAssign = { [weak self] speaker, participant, name in
            guard let self, let transcriptData else { throw CocoaError(.fileWriteNoPermission) }
            try self.assignSpeaker(speaker, participant: participant, name: name, session: item.dir, version: dir, expectedTranscript: transcriptData)
        }
        meetingTranscript.update(transcript: transcript, names: names, participants: participantChoices,
                                 canEdit: canEdit, canPlay: !audioPlayer.isHidden, canMatchParticipants: diarized)
        speakerRowsHandled = true
        let speakerContext = SpeakerRowsContext(generation: currentSearchContext, names: names?.speakers,
            participants: participantChoices, editingBlocker: editingBlocker, canPlay: !audioPlayer.isHidden, canMatch: diarized)
        if renderedSpeakerRows != speakerContext {
            clearSpeakerRows()
            let hint = NSTextField(wrappingLabelWithString: editingBlocker ?? localised(
                "Listen to a voice, then choose a participant or type a name. The assignment applies to all their lines in this transcript version.",
                "Прослушайте голос, затем выберите участника или введите имя. Сопоставление применяется ко всем его репликам в этой версии расшифровки."))
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = StudioStyle.muted
            hint.identifier = .init("speaker.editing-help")
            speakersStack.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: speakersStack.widthAnchor).isActive = true
            for sample in SessionInventory.samples(transcript: transcript, names: names) {
                let row = speakerRow(sample, in: dir, transcript: transcript, transcriptData: transcriptData, names: names,
                                     participants: diarized || sample.label == "me" ? participantChoices : [],
                                     editingBlocker: editingBlocker)
                speakersStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: speakersStack.widthAnchor).isActive = true
            }
            renderedSpeakerRows = speakerContext
        }
        updateButtons()
    }

    private func speakerEditingBlocker(session: URL, version: URL) -> String? {
        if isBusy(session) {
            return localised("Participants cannot be edited while this meeting is being processed. Wait or cancel processing.",
                             "Участники недоступны для редактирования, пока запись обрабатывается. Дождитесь завершения или отмените обработку.")
        }
        if TranscriptVersions.isRequested(session) {
            return localised("Participants cannot be edited while a new transcript is queued. Wait or cancel it.",
                             "Участники недоступны для редактирования: новая расшифровка в очереди. Дождитесь её или отмените.")
        }
        let diarization = DiarizationState.persisted(in: version)
        if diarization.isUnreadable {
            return localised("Participant editing is unavailable because the saved diarization state cannot be read.",
                             "Редактирование участников недоступно: не удалось прочитать сохранённое состояние диаризации.")
        }
        if !diarization.isFinal {
            return localised("To edit participants, finish or skip diarization in meeting details. Saved names are preserved.",
                             "Чтобы редактировать участников, завершите или пропустите диаризацию в сведениях о встрече. Сохранённые имена не потеряются.")
        }
        return nil
    }

    func assignSpeaker(_ speaker: String, participant: CalendarParticipant?, name: String?, session: URL, version: URL, expectedTranscript: Data? = nil) throws {
        let unavailable = CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: localised(
            "The meeting or transcript has changed, or editing is temporarily unavailable. Reopen the speaker editor.",
            "Встреча или расшифровка изменилась либо редактирование сейчас недоступно. Откройте редактор говорящего заново.")])
        guard selected?.dir.standardizedFileURL.path == session.standardizedFileURL.path,
              artifactDirectory?.standardizedFileURL.path == version.standardizedFileURL.path, selectedVersion?.isRequest != true,
              speakerEditingBlocker(session: session, version: version) == nil, !SpeakerNames.isUnknown(speaker) else {
            throw unavailable
        }
        if let expectedTranscript {
            guard try Data(contentsOf: version.appendingPathComponent("transcript.json")) == expectedTranscript else {
                throw unavailable
            }
        }
        let editedTab = detailTabs.selectedTabViewItem?.identifier as? String
        try PostProcessor.setSpeakerParticipant(speaker, participant: participant, name: name, in: version)
        Task { @MainActor [weak self] in
            guard let self, self.selected?.dir.standardizedFileURL.path == session.standardizedFileURL.path,
                  self.artifactDirectory?.standardizedFileURL.path == version.standardizedFileURL.path else { return }
            let focused = (self.panel.firstResponder as? NSTextView)?.delegate as? NSView ?? self.panel.firstResponder as? NSView
            let restoreFocus = focused == nil || focused?.isDescendant(of: self.meetingTranscript) == true || focused?.isDescendant(of: self.speakersStack) == true
            self.showDetail()
            if !self.libraryQuery.isEmpty { self.restartLibrarySearch() }
            guard restoreFocus, self.detailTabs.selectedTabViewItem?.identifier as? String == editedTab else { return }
            if editedTab == "transcript" { self.meetingTranscript.focusSpeaker(speaker) }
            if editedTab == "participants",
               let row = self.speakersStack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "speaker-row.\(speaker)" }),
               let contents = (row as? MeetingSpeakerView)?.editor as? NSStackView,
               let head = contents.arrangedSubviews.first as? NSStackView,
               let editor = head.arrangedSubviews.compactMap({ $0 as? SpeakerAssignmentEditor }).first {
                self.panel.makeFirstResponder(editor.choice)
            }
        }
    }
    private func speakerRow(_ sample: SessionInventory.Sample, in dir: URL, transcript: Transcript, transcriptData: Data?, names: SpeakerNames?, participants: [CalendarParticipant], editingBlocker: String?) -> NSView {
        let title = MeetingTranscriptView.speakerTitle(sample.label, in: transcript.segments)
        let session = selected?.dir ?? dir
        let editor = SpeakerAssignmentEditor(speaker: sample.label, title: title,
            entry: SpeakerNames.isUnknown(sample.label) ? nil : names?.speakers[sample.label],
            participants: participants, canEdit: editingBlocker == nil, inline: false)
        editor.choice.toolTip = editingBlocker
        editor.choice.setAccessibilityHelp(editingBlocker)
        editor.onError = { [weak self] error in self?.showServiceError(error.localizedDescription) }
        editor.onAssign = { [weak self] participant, name in
            guard let self, let transcriptData else { throw CocoaError(.fileWriteNoPermission) }
            try self.assignSpeaker(sample.label, participant: participant, name: name, session: session, version: dir, expectedTranscript: transcriptData)
        }
        let count = NSTextField(labelWithString: localised("\(sample.turns) turns", "Реплик: \(sample.turns)"))
        count.font = .systemFont(ofSize: 11)
        count.textColor = StudioStyle.muted
        let colorIndex = MeetingTranscriptView.speakerLabels(in: transcript.segments).firstIndex(of: sample.label)
        let badge = StudioStyle.voiceBadge(StudioStyle.voiceLabel(sample.label), colorIndex: colorIndex)
        let head = NSStackView(views: [badge, editor, NSView(), count])
        head.spacing = 8
        let contents = NSStackView(views: [head])
        contents.orientation = .vertical
        contents.alignment = .leading
        contents.spacing = 8
        contents.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        head.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
        for segment in transcript.segments.filter({ $0.speaker == sample.label }).prefix(3) {
            let play = NSButton(title: "", target: self, action: #selector(playSpeaker(_:)))
            play.image = NSImage(systemSymbolName: "play", accessibilityDescription: nil)
            play.isBordered = false
            play.identifier = .init("speaker.play")
            play.tag = segment.start_ms
            play.isEnabled = !audioPlayer.isHidden
            let stamp = String(format: "%02d:%02d", segment.start_ms / 60_000, (segment.start_ms / 1000) % 60)
            play.toolTip = localised("Play \(title) from \(stamp)", "Прослушать \(title) с \(stamp)")
            play.setAccessibilityLabel(play.toolTip)
            play.widthAnchor.constraint(equalToConstant: 26).isActive = true
            let time = NSTextField(labelWithString: stamp)
            time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            time.textColor = StudioStyle.muted
            let quote = NSTextField(wrappingLabelWithString: segment.text)
            quote.font = .systemFont(ofSize: 13)
            quote.textColor = StudioStyle.ink
            quote.maximumNumberOfLines = 2
            quote.lineBreakMode = .byTruncatingTail
            quote.toolTip = segment.text
            quote.isSelectable = true
            let row = NSStackView(views: [play, time, quote])
            row.alignment = .top
            row.spacing = 8
            contents.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
        }
        contents.addArrangedSubview(SetupLayout.hairline())
        let row = MeetingSpeakerView(editor: contents)
        row.identifier = .init("speaker-row.\(sample.label)")
        return row
    }
    @objc private func playSpeaker(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        audioPlayer.play(from: Double(sender.tag) / 1000)
    }

    private func updateButtons() {
        let item = selected
        let actions = currentActions
        moreButton.isEnabled = item != nil
        finishButton.isEnabled = !actions.isBusy && (selectedVersion?.isRequest == true
            ? item?.transcript.isOutstanding ?? false
            : artifactDirectory.map { !PostProcessor.outstanding($0, retryFailed: true).isEmpty } ?? item?.isOutstanding ?? false)
        finishButton.isHidden = !finishButton.isEnabled
        let state = item.flatMap { DiarizationState.read($0.dir) }
        let actionable = !actions.isBusy && item?.unreadableDiarization != true
            && state?.retainsAudio == true && state?.status != .running
            && artifactDirectory == item?.dir && selectedVersion?.isRequest != true
            && item.map { !TranscriptVersions.isRequested($0.dir) } == true
        retryDiarizationButton.isEnabled = actionable && onRetryDiarization != nil
        skipDiarizationButton.isEnabled = actionable && onSkipDiarization != nil
        let work = selectedWork ?? ""
        busyLabel.isHidden = work.isEmpty
        busyLabel.stringValue = work
        let summaryAction = summaryToCopy == nil ? localised("Generate summary", "Создать сводку") : localised("Regenerate summary", "Перегенерировать сводку")
        let transcriptAction = localised("Transcribe again", "Расшифровать повторно")
        regenerateButton.setAccessibilityLabel(summaryAction)
        regenerateButton.isEnabled = actions.reason(for: .regenerateSummary) == nil
        regenerateButton.toolTip = actions.reason(for: .regenerateSummary) ?? summaryAction
        summaryCreateButton.isEnabled = regenerateButton.isEnabled
        summaryCreateButton.toolTip = regenerateButton.toolTip
        summaryCreateButton.setAccessibilityHelp(actions.reason(for: .regenerateSummary))
        summaryAvailability.stringValue = actions.reason(for: .regenerateSummary) ?? ""
        summaryAvailability.isHidden = summaryAvailability.stringValue.isEmpty
        repeatButton.setAccessibilityLabel(transcriptAction)
        repeatButton.isEnabled = actions.reason(for: .retranscribe) == nil
        repeatButton.toolTip = actions.reason(for: .retranscribe) ?? transcriptAction
    }

    private func updateDiarization(for item: SessionInventory.Item) {
        let dir = artifactDirectory ?? item.dir
        let details = dir == item.dir ? item : SessionInventory.item(for: dir)
        retryDiarizationButton.isHidden = true
        skipDiarizationButton.isHidden = true
        defer {
            diarizationLabel.toolTip = diarizationLabel.stringValue
            diarizationLabel.setAccessibilityLabel(diarizationLabel.stringValue)
        }
        if let version = selectedVersion, version.isRequest {
            diarizationLabel.isHidden = false
            diarizationLabel.stringValue = version.diarization == nil
                ? localised("Diarization not requested", "Диаризация не запрошена")
                : localised("Diarization waits for transcription", "Диаризация ожидает расшифровку")
            return
        }
        if details?.unreadableDiarization == true {
            diarizationLabel.isHidden = false
            diarizationLabel.stringValue = localised(
                "Diarization: saved model request cannot be read. Processing is blocked.",
                "Диаризация: не удалось прочитать сохранённый запрос модели. Обработка заблокирована.")
            diarizationLabel.toolTip = diarizationLabel.stringValue
            retryDiarizationButton.isHidden = true
            skipDiarizationButton.isHidden = true
            return
        }
        let count = details?.namedSpeakers.map { localised("Speakers: \($0.total)", "Говорящих: \($0.total)") }
        guard let state = DiarizationState.read(dir) else {
            diarizationLabel.isHidden = count == nil
            diarizationLabel.stringValue = [details?.isDiarized == true
                ? localised("Diarization: complete", "Диаризация: готова") : nil, count].compactMap { $0 }.joined(separator: " · ")
            return
        }
        diarizationLabel.isHidden = false
        let running = dir == item.dir && operations.snapshot().contains {
            $0.session == item.dir.standardizedFileURL.resolvingSymlinksInPath() && $0.kind == .diarization && $0.state == .running
        }
        diarizationLabel.stringValue = [Self.diarizationLine(state, running: running), count].compactMap { $0 }.joined(separator: "\n")
        diarizationLabel.toolTip = diarizationLabel.stringValue
        let actions = dir == item.dir && state.retainsAudio && state.status != .running
            && !TranscriptVersions.isRequested(item.dir)
        retryDiarizationButton.isHidden = !actions
        let needsModel = !DiarizationModelStore.isReady(at: DiarizationModelStore.shared(for: state.request.model).directory, model: state.request.model)
        retryDiarizationButton.title = needsModel ? localised("Download and continue", "Скачать и продолжить") : localised("Retry diarization", "Повторить диаризацию")
        skipDiarizationButton.isHidden = !actions
    }

    static func diarizationLine(_ state: DiarizationState, running: Bool = false) -> String {
        let stage: String
        switch state.status {
        case .pending where state.hasFailedAttempt:
            stage = localised("last attempt failed — retry or skip", "последняя попытка не удалась — повторите или пропустите")
        case .pending: stage = localised("pending", "ожидает")
        case .running: stage = running ? localised("running", "выполняется") : localised("not finished", "не завершена")
        case .deferred: stage = localised("waiting for model", "ожидает модель")
        case .failed: stage = localised("failed", "ошибка")
        case .partial: stage = localised("incomplete", "не завершена")
        case .completed: stage = localised("complete", "готова")
        case .skipped: stage = localised("skipped", "пропущена")
        case .notApplicable: stage = localised("not applicable", "не применяется")
        }
        var parts = [localised("Diarization: ", "Диаризация: ") + stage]
        if state.confirmedSpeakers > 0 || state.status == .completed {
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
        guard let item = selected, !isBusy(item.dir), let action = onRetryDiarization else { return }
        setWorking(true, in: item.dir)
        Task {
            do {
                if let state = DiarizationState.read(item.dir), let resume = onResumeDiarization,
                   !DiarizationModelStore.isReady(at: DiarizationModelStore.shared(for: state.request.model).directory, model: state.request.model) {
                    workByMeeting[item.dir] = localised("Downloading \(state.request.model.title)…", "Загрузка \(state.request.model.title)…")
                    if selected?.dir == item.dir { updateButtons() }
                    try await MeetingModelDownload.continueDiarization(item.dir, resume: resume)
                } else { try await action(item.dir) }
            } catch { say(error.localizedDescription, about: item) }
            setWorking(false, in: item.dir)
            reload()
        }
    }

    @objc private func skipDiarizationClicked() {
        guard let item = selected, !isBusy(item.dir), let action = onSkipDiarization else { return }
        setWorking(true, in: item.dir)
        Task {
            do { try await action(item.dir) } catch { say(error.localizedDescription, about: item) }
            setWorking(false, in: item.dir)
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
        guard let item = selected, !isBusy(item.dir) else { return }
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
        setWorking(true, in: item.dir)
        Task {
            let result = await PostProcessor.finishManually(dir)
            setWorking(false, in: item.dir)
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
        showServiceError((item.title ?? item.name) + ": " + sentence)
    }

    private func showServiceError(_ message: String) {
        guard !terminating else { return }
        detailError.stringValue = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        detailError.toolTip = message
        detailError.isHidden = false
        NSAccessibility.post(element: detailError, notification: .valueChanged)
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
                    self.showServiceError(localised(
                        "Could not open the transcript", "Не удалось открыть расшифровку") + ": " + file.path)
                    return
                }
                NSWorkspace.shared.open(
                    [file], withApplicationAt: textEdit,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error {
                        Task { @MainActor in self.showServiceError(error.localizedDescription) }
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
                    if case .failure(let error) = result { self.showServiceError(error.localizedDescription) }
                }
                undoDeletionID = id
                deletionLabel.stringValue = localised("Meeting deleted", "Встреча удалена")
                deletionNotice.isHidden = false
                onActivityChange?()
                show(allItems)
            } catch { showServiceError(error.localizedDescription) }
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
        return MeetingListView(item: items[row], active: activeRecording, hit: libraryHits?[items[row].dir])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingList else { return }
        if table.selectedRow >= 0 {
            meetingSelectionActive = true
            rememberedMeeting = nil
            libraryReadingPosition = nil
        }
        showDetail()
        revealLibraryHit()
        if librarySearchPending { saveLibraryReadingPosition() }
        onSelectMeeting?()
    }
}

@MainActor
private extension MeetingLibraryController {
    func buildJournal(detail: NSStackView) -> NSView {
        search.identifier = .init("library.search")
        search.placeholderString = localised("Title, transcript, summary", "Название, расшифровка, сводка")
        search.setAccessibilityLabel(localised("Search the library: titles, transcripts and summaries", "Поиск в библиотеке: названия, расшифровки и сводки"))
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filterButton.identifier = .init("library.filter")
        filterButton.title = ""
        filterButton.bezelStyle = .rounded
        filterButton.isBordered = false
        filterButton.setButtonType(.toggle)
        filterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
        filterButton.imagePosition = .imageOnly
        filterButton.target = self
        filterButton.action = #selector(showLibraryFilter)
        filterButton.widthAnchor.constraint(equalToConstant: StudioStyle.inputHeight).isActive = true
        filterButton.heightAnchor.constraint(equalToConstant: StudioStyle.inputHeight).isActive = true
        let filterHeading = NSTextField(labelWithString: localised("Filter meetings", "Фильтр встреч"))
        filterHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        for (index, filter) in [ApplicationNavigationState.Destination.allMeetings, .processing, .attention].enumerated() {
            let option = NSButton(radioButtonWithTitle: filter.title, target: self, action: #selector(filterSelected(_:)))
            option.identifier = .init("library.filter.\(filter.rawValue)")
            option.alignment = .left
            option.tag = index
            option.state = filter == meetingFilter ? .on : .off
            filterOptions.append(option)
        }
        let filters = NSStackView(views: [filterHeading] + filterOptions)
        filters.orientation = .vertical
        filters.alignment = .leading
        filters.spacing = 10
        filters.edgeInsets = .init(top: 14, left: 14, bottom: 14, right: 14)
        filters.widthAnchor.constraint(equalToConstant: 220).isActive = true
        for option in filterOptions { option.widthAnchor.constraint(equalTo: filters.widthAnchor, constant: -28).isActive = true }
        let controller = NSViewController()
        controller.view = filters
        controller.preferredContentSize = filters.fittingSize
        filterPopover.contentViewController = controller
        filterPopover.behavior = .transient
        filterPopover.animates = false
        filterButton.toolTip = localised("Filter meetings: ", "Фильтр встреч: ") + meetingFilter.title
        filterButton.setAccessibilityLabel(filterButton.toolTip)
        let searchRow = NSStackView(views: [search, filterButton])
        searchRow.spacing = 8
        emptyLabel.identifier = .init("meeting-list.empty")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = StudioStyle.muted
        clearSearch.title = localised("Reset search and filter", "Сбросить поиск и фильтр")
        clearSearch.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        clearSearch.imagePosition = .imageLeading
        clearSearch.identifier = .init("library.reset")
        clearSearch.target = self
        clearSearch.action = #selector(clearSearchClicked)
        emptyView.setViews([emptyLabel, clearSearch, NSView()], in: .center)
        emptyView.orientation = .vertical
        emptyView.spacing = 12
        emptyView.isHidden = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        librarySearchStatus.identifier = .init("library.search-status")
        librarySearchStatus.font = .systemFont(ofSize: 11)
        librarySearchStatus.textColor = StudioStyle.muted
        librarySearchStatus.lineBreakMode = .byTruncatingTail
        librarySearchStatus.isHidden = true
        let list = NSStackView(views: [searchRow, scroll, emptyView])
        list.orientation = .vertical
        list.distribution = .fill
        list.alignment = .leading
        list.spacing = 10
        list.edgeInsets = .init(top: 0, left: 16, bottom: 0, right: 0)
        for view in list.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: view === scroll ? -16 : -32).isActive = true
        }
        listContentView = Self.frameOwnedPane(list)
        listContentView.setAccessibilityElement(true)
        listContentView.setAccessibilityRole(.group)
        listContentView.setAccessibilityLabel(localised("Meeting library", "Библиотека встреч"))

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
        toolbarContent.spacing = 12
        moreButton.identifier = .init("meeting.actions")
        detail.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 12, right: 24)
        // The document's arranged views fill its readable column, without setting a window minimum.
        for constraint in detail.constraints where constraint.firstAttribute == .width { constraint.isActive = false }
        for view in detail.arrangedSubviews { view.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -48).isActive = true }
        detailTitle.maximumNumberOfLines = 2
        detailMeta.textColor = StudioStyle.muted
        detail.setCustomSpacing(4, after: detailMeta)
        detail.setCustomSpacing(12, after: detail.arrangedSubviews[1])
        if let meetingHeader { detail.setCustomSpacing(4, after: meetingHeader) }
        detailTabs.setContentHuggingPriority(.init(1), for: .vertical)
        versionSelector.font = .systemFont(ofSize: 11)
        versionSelector.isBordered = false
        versionSelector.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        pipeline.orientation = .vertical
        pipeline.alignment = .leading
        pipeline.spacing = 12
        route.identifier = .init("meeting.processing-configuration")
        route.font = .systemFont(ofSize: 11)
        route.textColor = StudioStyle.muted
        let settings = NSButton(title: localised("Settings →", "Настройки →"), target: self, action: #selector(processingSettings))
        settings.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        settings.imagePosition = .imageLeading
        settings.identifier = .init("meeting.processing-settings")
        settings.isBordered = false
        settings.alignment = .left
        settings.font = .systemFont(ofSize: 11)
        let closeDetails = StudioActionButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(closeInspector))
        closeDetails.identifier = .init("meeting.inspector-close")
        closeDetails.widthAnchor.constraint(equalToConstant: 26).isActive = true
        closeDetails.heightAnchor.constraint(equalToConstant: 26).isActive = true
        closeDetails.toolTip = localised("Close meeting details", "Закрыть детали встречи")
        closeDetails.setAccessibilityLabel(closeDetails.toolTip)
        calendarPicker.button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        calendarPicker.button.imagePosition = .imageLeading
        let inspectorHeading = NSStackView(views: [calendarPicker, closeDetails])
        inspectorHeading.alignment = .centerY
        inspectorHeading.spacing = 8
        let inspector = FlippedStackView(views: [
            inspectorHeading, calendarView,
            SetupLayout.hairline(), StudioStyle.caption(localised("PROCESSING", "ОБРАБОТКА")), pipeline,
            finishButton, cancelProcessingButton,
            SetupLayout.hairline(), StudioStyle.caption(localised("PROCESSING SETTINGS", "НАСТРОЙКИ ОБРАБОТКИ")), route, settings,
        ])
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 18
        inspector.edgeInsets = NSEdgeInsets(top: 12, left: 22, bottom: 24, right: 22)
        for view in inspector.arrangedSubviews { view.widthAnchor.constraint(equalTo: inspector.widthAnchor, constant: -44).isActive = true }
        diarizationActions.orientation = .vertical
        diarizationActions.alignment = .leading
        for button in [retryDiarizationButton, skipDiarizationButton, finishButton] { button.font = .systemFont(ofSize: 11) }
        let inspectorScroll = SetupLayout.scroller(around: inspector)
        let inspectorSurface = JournalSurface(StudioStyle.inset)
        inspectorSurface.identifier = .init("meeting.inspector-content")
        inspectorSurface.setAccessibilityElement(true)
        inspectorSurface.setAccessibilityRole(.group)
        inspectorSurface.setAccessibilityLabel(localised("Meeting details", "Детали встречи"))
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
        inspectorDivider.onResize = { [weak self] width in
            self?.preferredInspectorWidth = width
            self?.updateCompactLayout()
        }
        let columns = JournalColumns(views: [documentHost, inspectorDivider, inspectorSurface])
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
        let undo = NSButton(title: localised("Undo", "Отменить"), target: self, action: #selector(undoDeletion))
        undo.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        undo.imagePosition = .imageLeading
        deletionNotice.setViews([deletionLabel, undo], in: .center)
        deletionNotice.identifier = .init("meeting.deletion-notice")
        deletionNotice.spacing = 10
        deletionNotice.alignment = .centerY
        deletionLabel.lineBreakMode = .byTruncatingTail
        deletionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        undo.bezelStyle = .inline
        undo.controlSize = .small
        deletionNotice.isHidden = true
        let container = MediaDropView()
        container.onFiles = { [weak self] in self?.onImportFiles?($0) }
        let frame = Self.frameOwnedPane(columns)
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

    @objc private func dismissResultNotice() {
        guard !processingCancellation.isCancelling else { return }
        noticeDismissed = true
        resultNotice.isHidden = true
        if contentView.window === panel {
            panel.makeFirstResponder(resultPicker.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.state == .on })
        }
    }

    private func updateCancellationControls() {
        guard !terminating else { return }
        processingCancellation.select(selected?.dir)
        let cancelling = processingCancellation.isCancelling
        cancelProcessingButton.isHidden = !processingCancellation.canCancel && !cancelling
        cancelProcessingButton.isEnabled = processingCancellation.canCancel
        cancelProcessingButton.title = cancelling ? localised("Cancelling…", "Отменяется…")
            : localised("Cancel processing", "Отменить обработку")
        var message: String
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
        if message.isEmpty, selectedWork == nil, !processingCancellation.canCancel,
           let item = selected, activeRecording?.dir != item.dir {
            if let request = versions.last(where: \.isRequest) {
                message = request.title
                if case .failed(let reason) = request.state { message += ": " + reason }
            } else if case .failed(let reason) = item.transcript {
                message = localised("Transcription error: ", "Ошибка расшифровки: ") + reason
            } else if case .failed(let reason) = item.summary {
                message = localised("Summary error: ", "Ошибка сводки: ") + reason
            } else if item.unreadableDiarization {
                message = localised("The saved speaker analysis could not be read. See meeting details.",
                                    "Не удалось прочитать сохранённый анализ говорящих. Откройте детали встречи.")
            } else if let state = item.diarization, state.hasFailedAttempt || [.deferred, .partial].contains(state.status) {
                message = Self.diarizationLine(state)
            }
            if !message.isEmpty, versions.contains(where: { !$0.isRequest }) || item.summary == .done {
                message += localised(" Completed results are preserved.", " Готовые результаты сохранены.")
            }
        }
        let key = (selected?.dir.path ?? "") + "\n" + message
        if noticeKey != key { noticeKey = key; noticeDismissed = false }
        resultNotice.isHidden = message.isEmpty || noticeDismissed
        dismissNotice.isHidden = cancelling
        let line = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        if processingStatus.stringValue != line || processingStatus.toolTip != message {
            processingStatus.stringValue = line
            processingStatus.toolTip = message
            NSAccessibility.post(element: processingStatus, notification: .valueChanged)
        }
    }

    func updateInspector() {
        pipeline.arrangedSubviews.forEach { pipeline.removeArrangedSubview($0); $0.removeFromSuperview() }
        if let item = selected {
            for stage in MeetingPresentation.stages(item, active: activeRecording, version: selectedVersion).filter({ $0.symbol != "calendar" }) {
                let image = MeetingListView.icon(stage)
                let title = stage.symbol == "mic" && activeRecording?.dir != item.dir && !item.hasAudio ? localised("Audio not retained", "Аудио не сохранено") : stage.title
                let label = NSTextField(wrappingLabelWithString: (stage.state == .pending && stage.symbol != "checklist" ? localised("Waiting: ", "Ожидание: ") : "") + title)
                label.font = .systemFont(ofSize: 11)
                label.setContentHuggingPriority(.init(1), for: .horizontal)
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let row = NSStackView(views: [image, label])
                row.spacing = 10
                var content: NSView = row
                if stage.symbol == "doc.text" {
                    let group = NSStackView(views: [row])
                    group.identifier = .init("meeting.processing-transcript")
                    group.orientation = .vertical
                    group.alignment = .leading
                    group.spacing = 6
                    if activeRecording?.dir != item.dir {
                        row.addArrangedSubview(repeatButton)
                        // Move the existing controls; their recovery handlers and guards stay shared.
                        for view in [diarizationLabel, diarizationActions] {
                            (view.superview as? NSStackView)?.removeArrangedSubview(view)
                            view.removeFromSuperview()
                            group.addArrangedSubview(view)
                        }
                    }
                    for view in group.arrangedSubviews { view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
                    content = group
                } else if stage.symbol == "checklist" {
                    row.identifier = .init("meeting.processing-summary")
                    if activeRecording?.dir != item.dir { row.addArrangedSubview(regenerateButton) }
                }
                pipeline.addArrangedSubview(content)
                content.widthAnchor.constraint(equalTo: pipeline.widthAnchor).isActive = true
            }
        }
        if speakersStack.arrangedSubviews.isEmpty {
            let message = NSTextField(wrappingLabelWithString: localised("Speakers appear after transcription.", "Участники появятся после расшифровки."))
            message.font = .systemFont(ofSize: 12)
            message.textColor = StudioStyle.muted
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
        let configuration = [
            (localised("Transcription: ", "Расшифровка: "), transcription.isEmpty ? disabled : transcription.joined(separator: " → ")),
            (localised("Diarization: ", "Диаризация: "), diarization.isEmpty ? disabled : diarization.joined(separator: " / ")),
            (localised("Summary: ", "Сводка: "), Config.summary().enabled ? Self.summaryMethodName(Config.summary().backend) : disabled),
        ]
        let text = NSMutableAttributedString(string: "")
        for (label, value) in configuration {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]))
            text.append(NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        }
        text.addAttribute(.foregroundColor, value: StudioStyle.muted, range: NSRange(location: 0, length: text.length))
        route.attributedStringValue = text
        route.setAccessibilityLabel(text.string)
    }

}

extension MeetingLibraryController {
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return 62 }
        measuringListTitle.stringValue = items[row].title ?? items[row].name
        measuringListTitle.preferredMaxLayoutWidth = max(1, tableView.tableColumns[0].width - 30)
        let titleHeight = ceil(measuringListTitle.fittingSize.height)
        if let hit = libraryHits?[items[row].dir], hit.source != .title {
            let snippet = MeetingListView.snippetLabel(hit)
            snippet.preferredMaxLayoutWidth = measuringListTitle.preferredMaxLayoutWidth
            return max(62, titleHeight + 50 + ceil(snippet.fittingSize.height))
        }
        return max(62, titleHeight + 46)
    }
    func tableViewColumnDidResize(_ notification: Notification) {
        table.needsLayout = true
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        JournalMeetingRow()
    }
}

@MainActor
private final class LibraryFilterButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        StudioStyle.drawInputBezel(in: bounds)
        super.draw(dirtyRect)
        if state == .on {
            StudioStyle.accent.setFill()
            NSBezierPath(ovalIn: .init(x: bounds.maxX - 8, y: isFlipped ? 4 : bounds.maxY - 8, width: 4, height: 4)).fill()
        }
    }
}

@MainActor
private final class JournalMeetingRow: NSTableRowView {
    private var hover = false
    private var tracking: NSTrackingArea?
    private var scrollChanges: ConfigWatch.Token?
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if hover && !isSelected { drawHighlight(StudioStyle.selection.withAlphaComponent(0.5)) }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        drawHighlight(StudioStyle.selection)
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
        // Replacing a tracking area during scrolling can discard its mouse-exit event.
        updateHover()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollChanges = nil
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollChanges = ConfigWatch.Token(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.updateHover() } })
        }
        updateHover()
    }
    private func updateHover() {
        hover = window.map { $0.isKeyWindow && visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { updateHover() }
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
