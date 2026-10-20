import AppKit
import AVKit

/// The list of recordings, and what is still owed on each of them.
///
/// The program's other windows are about the present — am I recording, what
/// are the settings. This one is about the archive: what has been recorded,
/// what has been done to it, and what a person can do about the gaps. It is
/// also the only place naming can be corrected, which is the part that can't
/// be automated away — a model that isn't sure leaves the label alone on
/// purpose, and this is where somebody who was there fills it in.
@MainActor
final class RecordingsWindow: NSObject {
    struct RetranscriptionEngine {
        let id: String
        let title: String
    }

    static var retranscriptionEngines: [RetranscriptionEngine] { [
        .init(id: "parakeet", title: "Parakeet"),
        .init(id: "whisper", title: "Whisper"),
        .init(id: "gigaam", title: "GigaAM"),
        .init(id: "assemblyai", title: "AssemblyAI"),
        .init(id: "openai", title: "OpenAI"),
        .init(id: "elevenlabs", title: "ElevenLabs"),
    ] }

    var onImportFiles: (([URL]) -> Void)?
    var onCancelImport: (() -> Void)?
    var onChooseImport: (() -> Void)?
    var onResumeDiarization: ((URL, DiarizationState.Request) async throws -> Void)?
    var onRetryDiarization: ((URL) async throws -> Void)?
    var onSkipDiarization: ((URL) async throws -> Void)?
    private var root: URL
    private let panel: NSWindow
    private let embedded: Bool
    private(set) var contentView = NSView()
    private let pasteboard: NSPasteboard
    private let table = MeetingTableView()
    private var activeRecording: MeetingPresentation.ActiveRecording?
    var onOpenActiveRecording: (() -> Void)?
    var onRenameActiveRecording: ((String) throws -> Void)?
    private let openActiveButton = NSButton()
    func setActiveRecording(_ value: MeetingPresentation.ActiveRecording?) {
        guard activeRecording != value else { return }
        activeRecording = value
        show(allItems)
    }
    private var allItems: [SessionInventory.Item] = []
    private var meetingFilter: ApplicationNavigationState.Destination = .allMeetings
    private let search = NSSearchField()
    private var meetingMenu = NSMenu()
    private let audioPlayer = AVPlayerView()
    private let audioSelector = NSPopUpButton()
    private let audioRow = NSStackView()
    private var audioFiles: [URL] = []
    private let moreButton = NSButton()
    private let regenerateButton = NSButton()
    private let repeatButton = NSButton()
    private let summaryHint = NSTextField(labelWithString: "")
    private let transcriptHint = NSTextField(labelWithString: "")
    private var contentCopyButtons: [NSButton] = []
    private var librarySplit: NSSplitView?
    private var libraryList: NSView?
    private var libraryDetail: NSView?
    private var showsMeetingDetail = false
    var onDetailVisibilityChange: ((Bool) -> Void)?
    private let scroll = NSScrollView()
    private var displayChanges: ConfigWatch.Token?

    private let calendarView = MeetingCalendarView()
    private let meetingTranscript = MeetingTranscriptView()
    private var plainTranscriptScroll: NSView?
    private let detailMeta = NSTextField(labelWithString: "")
    private let detailTitle = NSTextField(labelWithString: "")
    private let diarizationLabel = NSTextField(labelWithString: "")
    private let retryDiarizationButton = NSButton()
    private let skipDiarizationButton = NSButton()
    private let openingLabel = NSTextField(labelWithString: "")
    private let speakersStack = NSStackView()
    private let finishButton = NSButton()
    private let retranscribeButton = NSButton()
    private let openTranscriptButton = NSButton()
    private let copySummaryButton = NSButton()
    private var copyReset: Task<Void, Never>?
    private let openFolderButton = NSButton()
    private let deleteButton = NSButton()
    private let importButton = NSButton()
    private let openRootButton = NSButton()
    private let rootPath = NSTextField(labelWithString: "")
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
    private let retranscriptionMenu = NSMenu()

    private var items: [SessionInventory.Item] = []
    private var selected: SessionInventory.Item? {
        table.selectedRow >= 0 && table.selectedRow < items.count
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
    var isProcessing: Bool { working || deletion.hasWork }
    func cancelPendingDeletion() { deletion.cancelAll(); onActivityChange?() }
    private var working = false { didSet { onActivityChange?() } }

    init(root: URL, pasteboard: NSPasteboard = .general, hostWindow: NSWindow? = nil) {
        self.root = root
        self.pasteboard = pasteboard
        embedded = hostWindow != nil
        panel = hostWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        if !embedded {
        panel.title = localised("Recordings", "Записи")
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("name.ekho.verbemo.recordings")
        panel.contentMinSize = NSSize(width: 860, height: 560)

        }
        buildTable()
        displayChanges = ConfigWatch.Token(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.table.reloadData() } }, center: NSWorkspace.shared.notificationCenter)
        contentView = buildLayout()
        if !embedded {
            panel.contentView = contentView
            if panel.frame.origin == .zero { panel.center() }
        }
        // The first list is read here, on the spot: the window is built once,
        // the first time somebody asks for it, and a window that opened empty
        // and filled in a moment later would be a first picture of it that
        // is wrong. Every later look is `reload`, off the main thread.
        show(SessionInventory.scan(root: root))
    }

    func show() {
        if !panel.isVisible {
            Analytics.track(.artifactOpened, [
                .artifact: .text(Analytics.Artifact.recordingsWindow.rawValue),
            ])
        }
        reload()
        panel.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// The window's own content, and the list inside it, for the suite that
    /// builds this window in both languages and looks for a sentence left
    /// behind in one of them. The list needs its own way in: the table draws
    /// its cells from the data source rather than from views, so a walk of
    /// the window's subviews goes straight past every row in it.
    var view: NSView? { contentView }

    var listLines: [String] {
        table.tableColumns.map(\.title) + items.flatMap { item in
            table.tableColumns.map { Self.cell(item, column: $0.identifier.rawValue) ?? "" }
        }
    }

    // MARK: - building

    private func buildTable() {
        // The identifier is the program's name for a column and stays
        // English; the title is what a person reads.
        let columns: [(String, String, CGFloat)] = [
            ("when", localised("When", "Когда"), 130),
            ("meeting", localised("Meeting", "Встреча"), 250),
            ("transcript", localised("Transcript", "Расшифровка"), 150),
            ("names", localised("Names", "Имена"), 110),
            ("summary", localised("Summary", "Сводка"), 90),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        if embedded {
            for column in table.tableColumns { table.removeTableColumn(column) }
            table.addTableColumn(NSTableColumn(identifier: .init("meeting-card")))
            table.headerView = nil
            table.selectionHighlightStyle = .none
            table.backgroundColor = .windowBackgroundColor
            table.rowHeight = 94
            table.intercellSpacing = NSSize(width: 0, height: 7)
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.action = #selector(meetingClicked)
        }
        table.usesAlternatingRowBackgroundColors = !embedded
        if !embedded { table.rowHeight = 22 }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = embedded ? nil : #selector(openFolderClicked)
        retranscriptionMenu.delegate = self
        for engine in Self.retranscriptionEngines {
            let item = NSMenuItem(
                title: localised("Re-transcribe with ", "Расшифровать через ") + engine.title,
                action: #selector(retranscribeWithEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = engine.id
            retranscriptionMenu.addItem(item)
        }
        table.menu = embedded ? meetingMenu : retranscriptionMenu
        meetingMenu.delegate = self
        meetingMenu.autoenablesItems = false
        table.onContext = { [weak self] row in
            guard let self, row < self.items.count else { return }
            self.table.selectRowIndexes([row], byExtendingSelection: false)
            self.showDetail()
        }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }

    private func buildLayout() -> NSView {
        detailTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        openingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        // What was said in the meeting, which is the one thing in any of
        // verbemo's windows that is not verbemo's to translate. Named so that the
        // suite looking for English left in a Russian window knows to walk
        // past it rather than report a person's own words as untranslated.
        openingLabel.identifier = NSUserInterfaceItemIdentifier("meeting-words")
        openingLabel.textColor = .secondaryLabelColor
        openingLabel.lineBreakMode = .byTruncatingTail
        openingLabel.maximumNumberOfLines = 1
        // NSTabView derives its minimum width from this pane's fitting size.
        // The excerpt can truncate at any width; its full text must not become
        // the window's minimum width, even during that fitting calculation.
        openingLabel.setContentCompressionResistancePriority(
            .init(NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1),
            for: .horizontal)
        busyLabel.font = .systemFont(ofSize: 11)
        busyLabel.textColor = .secondaryLabelColor
        diarizationLabel.font = .systemFont(ofSize: 11)
        diarizationLabel.textColor = .secondaryLabelColor
        diarizationLabel.lineBreakMode = .byWordWrapping
        diarizationLabel.maximumNumberOfLines = 3
        diarizationLabel.identifier = .init("diarization.status")
        for (button, title, action) in [
            (retryDiarizationButton, localised("Retry speaker separation", "Повторить разделение"),
             #selector(retryDiarizationClicked)),
            (skipDiarizationButton, localised("Skip speaker separation", "Пропустить разделение"),
             #selector(skipDiarizationClicked)),
        ] as [(NSButton, String, Selector)] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        retryDiarizationButton.identifier = .init("diarization.retry")
        skipDiarizationButton.identifier = .init("diarization.skip")

        speakersStack.orientation = .vertical
        speakersStack.alignment = .leading
        speakersStack.spacing = 6

        for (button, title, action) in [
            (importButton, localised("Import…", "Импортировать…"), #selector(chooseImportClicked)),
            (openRootButton, localised("Open recordings folder", "Открыть папку записей"),
             #selector(openRootClicked)),
            (finishButton, localised("Finish processing", "Доделать"), #selector(finishClicked)),
            (retranscribeButton,
             localised("Re-transcribe", "Расшифровать заново"), #selector(retranscribeClicked)),
            (openTranscriptButton,
             localised("Open transcript", "Открыть расшифровку"), #selector(openTranscriptClicked)),
            (copySummaryButton,
             localised("Copy summary", "Скопировать сводку"), #selector(copySummaryClicked)),
            (openFolderButton, localised("Open folder", "Открыть папку"), #selector(openFolderClicked)),
            (deleteButton, localised("Delete", "Удалить"), #selector(deleteClicked)),
        ] as [(NSButton, String, Selector)] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        importButton.identifier = NSUserInterfaceItemIdentifier("choose-media-import")
        openTranscriptButton.identifier = NSUserInterfaceItemIdentifier("open-transcript")
        copySummaryButton.identifier = .init("copy-summary")
        copySummaryButton.keyEquivalent = "c"
        copySummaryButton.keyEquivalentModifierMask = [.command, .shift]
        copySummaryButton.toolTip = localised("Copy summary (⇧⌘C)", "Скопировать сводку (⇧⌘C)")
        openRootButton.identifier = NSUserInterfaceItemIdentifier("open-recordings-folder")
        rootPath.stringValue = root.path
        rootPath.font = .systemFont(ofSize: 11)
        rootPath.textColor = .secondaryLabelColor
        rootPath.lineBreakMode = .byTruncatingMiddle
        rootPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rootPath.toolTip = root.path
        let toolbar = NSStackView(views: [importButton, openRootButton, NSView(), rootPath])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.heightAnchor.constraint(equalTo: importButton.heightAnchor).isActive = true

        let processingButtons = NSStackView(views: [
            finishButton, retranscribeButton, openTranscriptButton,
            openFolderButton, deleteButton,
        ])
        processingButtons.orientation = .horizontal
        processingButtons.spacing = 8
        processingButtons.heightAnchor.constraint(equalTo: finishButton.heightAnchor).isActive = true

        let detailScroll = NSScrollView()
        detailScroll.documentView = speakersStack
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        speakersStack.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        NSLayoutConstraint.activate([
            speakersStack.leadingAnchor.constraint(
                equalTo: detailScroll.contentView.leadingAnchor, constant: 4),
            speakersStack.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            speakersStack.trailingAnchor.constraint(
                equalTo: detailScroll.contentView.trailingAnchor, constant: -8),
        ])

        let speakersContent = NSStackView(views: [openingLabel, detailScroll])
        speakersContent.orientation = .vertical
        speakersContent.distribution = .fill
        speakersContent.alignment = .leading
        speakersContent.spacing = 8
        speakersContent.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        NSLayoutConstraint.activate([
            openingLabel.widthAnchor.constraint(equalTo: speakersContent.widthAnchor, constant: -20),
            detailScroll.widthAnchor.constraint(equalTo: speakersContent.widthAnchor, constant: -20),
        ])
        // NSTabView owns its content view's frame. A stack view calculates
        // its own frame during layout, accumulating the tab's inset on each
        // update if used directly. Keep that layout inside a plain tab view.
        let speakersPane = NSView()
        speakersContent.translatesAutoresizingMaskIntoConstraints = false
        speakersPane.addSubview(speakersContent)
        NSLayoutConstraint.activate([
            speakersContent.leadingAnchor.constraint(equalTo: speakersPane.leadingAnchor),
            speakersContent.trailingAnchor.constraint(equalTo: speakersPane.trailingAnchor),
            speakersContent.topAnchor.constraint(equalTo: speakersPane.topAnchor),
            speakersContent.bottomAnchor.constraint(equalTo: speakersPane.bottomAnchor),
        ])
        for (id, label, view) in [
            ("summary", localised("Summary", "Сводка"), previewScroll(summaryText)),
            ("transcript", localised("Transcript", "Расшифровка"), embedded ? transcriptContent() : previewScroll(transcriptText)),
            ("speakers", localised("Speakers", "Участники"), speakersPane),
        ] as [(String, String, NSView)] {
            let tab = NSTabViewItem(identifier: id)
            tab.label = label
            tab.view = embedded && id != "speakers" ? textPane(id: id, content: view) : view
            detailTabs.addTabViewItem(tab)
        }

        versionSelector.identifier = .init("transcript-versions")
        versionSelector.target = self
        versionSelector.action = #selector(versionSelected(_:))
        versionSelector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let versionActions = NSStackView(views: embedded ? [versionSelector] : [versionSelector, NSView(), copySummaryButton])
        versionActions.orientation = .horizontal
        versionActions.spacing = 8
        let diarizationActions = NSStackView(views: [retryDiarizationButton, skipDiarizationButton])
        diarizationActions.orientation = .horizontal
        diarizationActions.spacing = 8
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: localised("Meeting actions", "Действия со встречей"))
        moreButton.setAccessibilityLabel(localised("Meeting actions", "Действия со встречей"))
        moreButton.isBordered = false
        moreButton.target = self
        moreButton.action = #selector(moreClicked(_:))
        let titleRow = NSStackView(views: [detailTitle, NSView(), moreButton])
        titleRow.spacing = 12
        detailTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        audioPlayer.controlsStyle = .inline
        audioPlayer.setAccessibilityLabel(localised("Recording playback", "Прослушивание записи"))
        audioPlayer.heightAnchor.constraint(equalToConstant: 40).isActive = true
        audioPlayer.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        audioSelector.target = self
        audioSelector.action = #selector(audioSelected)
        audioSelector.setAccessibilityLabel(localised("Audio track", "Аудиодорожка"))
        audioRow.addArrangedSubview(audioSelector)
        audioRow.addArrangedSubview(audioPlayer)
        audioRow.spacing = 8
        openActiveButton.title = localised("Open current recording", "Открыть текущую запись")
        openActiveButton.target = self
        openActiveButton.action = #selector(openActiveRecording)
        openActiveButton.isHidden = true
        let detail = NSStackView(views: embedded
            ? [titleRow, detailMeta, calendarView, audioRow, openActiveButton, diarizationLabel, diarizationActions, versionActions, detailTabs, openTranscriptButton, busyLabel]
            : [detailTitle, diarizationLabel, diarizationActions, versionActions, detailTabs, processingButtons, busyLabel])
        detail.orientation = .vertical
        detail.distribution = .fill
        detail.alignment = .leading
        detail.spacing = 10
        detail.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        if embedded {
            titleRow.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
            calendarView.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
            detailMeta.textColor = .secondaryLabelColor
            detailMeta.font = .systemFont(ofSize: 12)
            detailTitle.font = .systemFont(ofSize: 23, weight: .semibold)
            detailTitle.maximumNumberOfLines = 0
            detailTitle.lineBreakMode = .byWordWrapping
        }
        NSLayoutConstraint.activate([
            detailTitle.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor),
            diarizationLabel.widthAnchor.constraint(equalTo: detail.widthAnchor),
            detailTabs.widthAnchor.constraint(equalTo: detail.widthAnchor),
            versionActions.widthAnchor.constraint(equalTo: detail.widthAnchor),
            versionSelector.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor),
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        detailTabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let split = MeetingLibrarySplitView()
        split.isVertical = embedded
        split.dividerStyle = .thin
        split.autosaveName = "name.ekho.verbemo.recordings.split"
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        if embedded {
            search.placeholderString = localised("Find a meeting", "Найти встречу")
            search.setAccessibilityLabel(localised("Find a meeting", "Найти встречу"))
            search.target = self
            search.action = #selector(searchChanged)
            search.sendsSearchStringImmediately = true
            search.sendsWholeSearchString = false
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            let list = NSStackView(views: [search, scroll])
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 12
            list.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 0, right: 8)
            search.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true
            scroll.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true
            list.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            split.addArrangedSubview(list)
            libraryList = list
            libraryDetail = detail
            librarySplit = split
            split.onResize = { [weak self] in self?.updateCompactLayout() }
        } else { split.addArrangedSubview(scroll) }
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        importStatus.onCancel = { [weak self] in self?.onCancelImport?() }
        let undo = NSButton(title: localised("Undo", "Отменить"), target: self, action: #selector(undoDeletion))
        deletionNotice.addArrangedSubview(deletionLabel)
        deletionNotice.addArrangedSubview(undo)
        deletionNotice.spacing = 10
        deletionNotice.isHidden = true
        let content = NSStackView(views: [
            importStatus, split, deletionNotice,
        ])
        if !embedded { content.insertArrangedSubview(toolbar, at: 0) }
        content.orientation = .vertical
        content.distribution = .fill
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 6, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = MediaDropView()
        container.onFiles = { [weak self] urls in self?.onImportFiles?(urls) }
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // The workspace owns the only import / new-recording toolbar.
            importStatus.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            split.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
        ])
        if !embedded { toolbar.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true }
        return container
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
    private func showCalendar(for item: SessionInventory.Item?) {
        let metadata = item.flatMap { MeetingCalendarMetadata.read(from: $0.dir) }
        calendarView.update(metadata)
        guard let item else { detailMeta.stringValue = ""; return }
        let duration = item.duration.map { localised("\(Int($0 / 60)) min", "\(Int($0 / 60)) мин") }
        let invited = metadata?.isConfirmed == true ? metadata.map { localised("Invited: \($0.participants.count)", "Приглашены: \($0.participants.count)") } : nil
        detailMeta.stringValue = [MeetingPresentation.date(item.started), duration, invited].compactMap { $0 }.joined(separator: " · ")
        calendarView.onConfirm = { [weak self] in
            try MeetingCalendarMetadata.confirm(in: item.dir)
            self?.reload()
        }
        calendarView.onOpen = {
            guard let metadata, let reason = CalendarEventOpener.open(metadata) else { return }
            let alert = NSAlert(); alert.messageText = reason; alert.runModal()
        }
        calendarView.onParticipants = { [weak self] in self?.detailTabs.selectTabViewItem(withIdentifier: "speakers") }
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
        if clearSearch { search.stringValue = ""; showsMeetingDetail = false }
        show(allItems)
    }
    private func updateCompactLayout() {
        guard let split = librarySplit, let list = libraryList, let detail = libraryDetail else { return }
        let compact = split.bounds.width < 730
        list.isHidden = compact && showsMeetingDetail
        detail.isHidden = compact && !showsMeetingDetail
        if !compact && split.bounds.width > 0 { split.setPosition(min(290, split.bounds.width * 0.4), ofDividerAt: 0) }
        onDetailVisibilityChange?(showsMeetingDetail)
    }
    @objc private func searchChanged() { show(allItems) }
    @objc private func meetingClicked() {
        if let selected, selected.dir == activeRecording?.dir { onOpenActiveRecording?(); return }
        showsMeetingDetail = selected != nil; updateCompactLayout()
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
        case .rename: renameMeeting()
        case .copyTranscript: copyMeetingContent(transcript: true, plainText: true)
        case .retranscribe: confirmRetranscription(engine: nil)
        case .copySummary: copyMeetingContent(transcript: false, plainText: true)
        case .regenerateSummary: regenerateSummary()
        case .openFolder: openFolderClicked()
        case .delete: deleteClicked()
        }
    }
    private func textPane(id: String, content: NSView) -> NSView {
        let isTranscript = id == "transcript"
        let repeatAction = isTranscript ? repeatButton : regenerateButton
        repeatAction.title = isTranscript ? localised("Transcribe again", "Расшифровать повторно") : localised("Regenerate summary", "Перегенерировать сводку")
        repeatAction.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        repeatAction.imagePosition = .imageLeading
        repeatAction.bezelStyle = .rounded
        repeatAction.target = self
        repeatAction.action = isTranscript ? #selector(repeatTranscriptClicked) : #selector(regenerateClicked)
        let copies = [true, false].map { plain -> NSButton in
            let button = NSButton(title: plain ? localised("Text", "Текст") : "Markdown", target: self, action: #selector(copyContentClicked(_:)))
            button.bezelStyle = .rounded
            button.tag = (isTranscript ? 2 : 0) + (plain ? 0 : 1)
            button.image = NSImage(systemSymbolName: plain ? "doc.on.doc" : "doc.text", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel((isTranscript ? localised("Copy transcript as ", "Копировать расшифровку как ") : localised("Copy summary as ", "Копировать сводку как ")) + (plain ? localised("text", "текст") : "Markdown"))
            contentCopyButtons.append(button)
            return button
        }
        let actions = NSStackView(views: [repeatAction, NSView()] + copies)
        actions.spacing = 8
        let hint = isTranscript ? transcriptHint : summaryHint
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let pane = NSStackView(views: [actions, hint, content])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 10
        pane.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 10, right: 10)
        for view in [actions, hint, content] { view.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -20).isActive = true }
        return pane
    }
    private static func summaryMethodName(_ backend: String) -> String {
        switch backend {
        case "codex-cli": "Codex"
        case "claude-cli": "Claude Code"
        case "ollama": "Ollama"
        case "openai-api": "OpenAI API"
        case "anthropic-api": "Anthropic API"
        case "none": localised("Disabled", "Выключено")
        default: localised("Automatic", "Автоматически")
        }
    }
    @objc private func repeatTranscriptClicked() { guard currentActions.reason(for: .retranscribe) == nil else { return }; confirmRetranscription(engine: nil) }
    @objc private func regenerateClicked() { regenerateSummary() }
    private func regenerateSummary() {
        guard currentActions.reason(for: .regenerateSummary) == nil, let dir = artifactDirectory else { updateButtons(); return }
        working = true
        updateButtons()
        table.reloadData()
        Task { [weak self] in
            guard let self else { return }
            do { try await PostProcessor.regenerateSummary(dir) }
            catch { await NSAlert(error: error).beginSheetModal(for: panel) }
            working = false
            reload()
        }
    }
    private func renameMeeting() {
        guard let item = selected else { return }
        let alert = NSAlert()
        alert.messageText = localised("Rename meeting", "Переименовать встречу")
        let field = NSTextField(string: item.title ?? item.name)
        field.frame.size = NSSize(width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: localised("Save", "Сохранить"))
        alert.addButton(withTitle: localised("Cancel", "Отмена"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { NSSound.beep(); return }
        do {
            if item.dir == activeRecording?.dir { try onRenameActiveRecording?(title) }
            else { try SessionState.amend(item.dir, with: ["title": title]) }
            reload()
        }
        catch { NSAlert(error: error).beginSheetModal(for: panel) }
    }
    @objc private func copyContentClicked(_ sender: NSButton) { copyMeetingContent(transcript: sender.tag >= 2, plainText: sender.tag % 2 == 0) }
    private func copyMeetingContent(transcript: Bool, plainText: Bool) {
        guard currentActions.reason(for: transcript ? .copyTranscript : .copySummary) == nil,
              let dir = artifactDirectory else { updateButtons(); return }
        let markdown: String?
        if transcript { markdown = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? PostProcessor.readTranscript(dir)?.rendered(title: selected?.title ?? "", names: SpeakerNames.read(from: dir)) }
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
        text.textContainerInset = NSSize(width: 12, height: 12)
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
        rootPath.stringValue = folder.path
        rootPath.toolTip = folder.path
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

    /// Read the folder again, off the main thread.
    ///
    /// `SessionInventory.scan` reads every session's meta.json and parses its
    /// transcript, and on the main thread that was a window that stopped
    /// answering for as long as the archive took to read — on every opening,
    /// every rename and every delete, and growing with every meeting kept.
    private func reload() {
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
            guard let self, generation == self.scans else { return }
            self.show(found)
            self.scan = nil
        }
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

    private func show(_ found: [SessionInventory.Item]) {
        let previous = selected?.dir
        allItems = found.filter { $0.dir != activeRecording?.dir }
        let inventory = (activeRecording.map { [$0.item] } ?? []) + allItems
        items = inventory.filter { !deletion.isPending($0.dir) && (!embedded || MeetingPresentation.matches($0, filter: meetingFilter, query: search.stringValue, active: activeRecording)) }
        table.reloadData()
        if let previous, let row = items.firstIndex(where: { $0.dir == previous }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !items.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        showDetail()
        updateCompactLayout()
    }

    @objc private func audioSelected() {
        audioPlayer.player?.pause()
        let index = audioSelector.indexOfSelectedItem
        audioPlayer.player = audioFiles.indices.contains(index) ? AVPlayer(url: audioFiles[index]) : nil
    }

    @objc private func versionSelected(_ sender: NSPopUpButton) {
        versionKey = selectedVersion.map(key)
        showDetail()
    }

    private func showDetail() {
        openActiveButton.isHidden = true
        detailTabs.isHidden = false
        if let activeRecording, selected?.dir == activeRecording.dir {
            showCalendar(for: selected)
            detailTitle.stringValue = activeRecording.title
            moreButton.isEnabled = true
            versions = []
            versionSelector.removeAllItems()
            versionSelector.isHidden = true
            audioRow.isHidden = true
            detailTabs.isHidden = true
            diarizationLabel.isHidden = true
            retryDiarizationButton.isHidden = true
            skipDiarizationButton.isHidden = true
            openTranscriptButton.isHidden = true
            summaryText.string = ""
            transcriptText.string = ""
            openActiveButton.isHidden = false
            busyLabel.stringValue = activeRecording.paused ? localised("Recording paused", "Запись приостановлена") : localised("Recording in progress", "Идёт запись")
            return
        }
        openTranscriptButton.isHidden = false
        if embedded {
            showCalendar(for: selected)
            meetingTranscript.isHidden = true
            plainTranscriptScroll?.isHidden = false
        }
        if embedded {
            let files = selected.map { MeetingPresentation.audioFiles($0.dir) } ?? []
            if files != audioFiles {
                audioPlayer.player?.pause()
                audioFiles = files
                audioSelector.removeAllItems()
                audioSelector.addItems(withTitles: files.map(\.lastPathComponent))
                audioSelected()
            }
            audioRow.isHidden = files.isEmpty
        }
        copyReset?.cancel()
        copySummaryButton.title = localised("Copy summary", "Скопировать сводку")
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

        speakersStack.arrangedSubviews.forEach {
            speakersStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let item = selected else {
            detailTitle.stringValue = items.isEmpty
                ? localised("No recordings yet", "Записей пока нет")
                : localised("Select a recording", "Выберите запись")
            openingLabel.stringValue = ""
            summaryText.string = ""
            transcriptText.string = ""
            diarizationLabel.isHidden = true
            retryDiarizationButton.isHidden = true
            skipDiarizationButton.isHidden = true
            updateButtons()
            return
        }

        detailTitle.stringValue = item.title ?? item.name
        updateDiarization(for: item)
        let dir = artifactDirectory ?? item.dir
        if let request = selectedVersion, request.isRequest {
            summaryText.string = ""
            openingLabel.stringValue = ""
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
        summaryText.textStorage?.setAttributedString(MarkdownPreview.render(summaryPreview))
        let transcript = PostProcessor.readTranscript(dir)
        let markdown = try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        let transcriptPreview = markdown ?? transcript?.rendered(
            title: item.title ?? item.name, names: SpeakerNames.read(from: dir))
            ?? localised("No transcript yet.", "Расшифровки пока нет.")
        transcriptText.textStorage?.setAttributedString(MarkdownPreview.render(transcriptPreview))
        transcriptText.identifier = markdown != nil || transcript != nil ? .init("meeting-words") : nil
        for text in [summaryText, transcriptText] { text.scrollToBeginningOfDocument(nil) }
        guard let transcript else {
            openingLabel.stringValue = item.transcript == .pending
                ? localised("Not transcribed yet.", "Ещё не расшифровано.")
                : localised(
                    "No transcript — nothing to name.",
                    "Расшифровки нет — некому давать имена.")
            updateButtons()
            return
        }

        let names = SpeakerNames.read(from: dir)
        if embedded, let calendar = MeetingCalendarMetadata.read(from: item.dir), calendar.isConfirmed {
            let invited = NSTextField(wrappingLabelWithString: localised("Invited from Calendar — attendance is not confirmed", "Приглашённые из календаря — присутствие не подтверждено"))
            invited.font = .systemFont(ofSize: 13, weight: .semibold)
            speakersStack.addArrangedSubview(invited)
            for person in calendar.participants {
                let label = NSTextField(wrappingLabelWithString: person.name + (person.email.map { " · " + $0 } ?? "") + (person.organizer == true ? localised(" · Organizer", " · Организатор") : ""))
                label.isSelectable = true
                speakersStack.addArrangedSubview(label)
            }
            let diarized = DiarizationState.read(dir).map { $0.status == .completed } ?? (!Config.localEngines.contains(transcript.engine) || Set(transcript.segments.map(\.speaker)).count > 2)
            if diarized {
                meetingTranscript.update(transcript: transcript, names: names, participants: calendar.participants, canEdit: !working && !SessionClaim.isHeld(item.dir) && DiarizationState.persisted(in: dir).isFinal)
                meetingTranscript.onMap = { [weak self] speaker, participant in
                    try PostProcessor.setSpeakerParticipant(speaker, participant: participant, in: dir)
                    self?.showDetail()
                }
                meetingTranscript.isHidden = false
                plainTranscriptScroll?.isHidden = true
            }
        }
        openingLabel.stringValue = SessionInventory.opening(of: transcript, names: names)
            .replacingOccurrences(of: "\n", with: " · ")
        for sample in SessionInventory.samples(transcript: transcript, names: names) {
            speakersStack.addArrangedSubview(speakerRow(sample, in: dir))
        }
        updateButtons()
    }

    /// One speaker: what they said, and a field for who they are.
    ///
    /// Both samples are shown because they answer different questions — the
    /// first line is where somebody gets greeted by name, and the longest turn
    /// is what identifies a person by what they were talking about when nobody
    /// said any names at all.
    private func speakerRow(_ sample: SessionInventory.Sample, in dir: URL) -> NSView {
        let label = NSTextField(labelWithString: SpeakerNames.described(label: sample.label))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let field = NSTextField(string: sample.name ?? "")
        field.placeholderString = localised("name", "имя")
        field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        field.target = self
        field.action = #selector(nameEdited(_:))
        field.identifier = .init("\(dir.path)\n\(sample.label)")

        let turns = localised("\(sample.turns) turns", "реплик: \(sample.turns)")
        let provenance = NSTextField(labelWithString: sample.source.map {
            "\($0.described) · " + turns
        } ?? turns)
        provenance.font = .systemFont(ofSize: 10)
        provenance.textColor = .tertiaryLabelColor

        let head = NSStackView(views: [label, field, provenance])
        head.orientation = .horizontal
        head.spacing = 8

        let quotes = NSTextField(wrappingLabelWithString: [
            sample.first.isEmpty
                ? nil : localised("first: ", "первая: ") + sample.first,
            sample.longest == sample.first || sample.longest.isEmpty
                ? nil : localised("longest: ", "самая длинная: ") + sample.longest,
        ].compactMap { $0 }.joined(separator: "\n"))
        quotes.font = .systemFont(ofSize: 11)
        quotes.textColor = .secondaryLabelColor
        quotes.lineBreakMode = .byTruncatingTail
        quotes.maximumNumberOfLines = 4
        quotes.preferredMaxLayoutWidth = 640

        let row = NSStackView(views: [head, quotes])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    private func updateButtons() {
        let item = selected
        moreButton.isEnabled = item != nil
        finishButton.isEnabled = !working && (selectedVersion?.isRequest == true
            ? item?.transcript.isOutstanding ?? false
            : artifactDirectory.map { !PostProcessor.outstanding($0).isEmpty } ?? item?.isOutstanding ?? false)
        retranscribeButton.isEnabled = !working && (item?.hasAudio ?? false)
        openTranscriptButton.isEnabled = selectedVersion?.isRequest != true && (artifactDirectory.map {
            PostProcessor.readTranscript($0) != nil || FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("transcript.md").path)
        } ?? false)
        copySummaryButton.isEnabled = summaryToCopy != nil
        openFolderButton.isEnabled = item != nil
        deleteButton.isEnabled = !working && item != nil
        let state = item.flatMap { DiarizationState.read($0.dir) }
        let actionable = !working && item?.unreadableDiarization != true
            && state?.retainsAudio == true && state?.status != .running
        retryDiarizationButton.isEnabled = actionable && onRetryDiarization != nil
        skipDiarizationButton.isEnabled = actionable && onSkipDiarization != nil
        busyLabel.isHidden = !working
        busyLabel.stringValue = working ? localised("working…", "работаю…") : ""
        if embedded {
            let state = currentActions
            regenerateButton.isEnabled = state.reason(for: .regenerateSummary) == nil
            regenerateButton.toolTip = state.reason(for: .regenerateSummary)
            repeatButton.isEnabled = state.reason(for: .retranscribe) == nil
            repeatButton.toolTip = state.reason(for: .retranscribe)
            for button in contentCopyButtons {
                button.isEnabled = state.reason(for: button.tag < 2 ? .copySummary : .copyTranscript) == nil
            }
            summaryHint.stringValue = Self.summaryMethodName(Config.summary().backend)
            transcriptHint.stringValue = RecordingsEngineName.name(Config.transcriptionLocalEngine())
                + (Config.localDiarizationEnabled() ? " · " + Config.diarizationModel().title : "")
        }
    }

    private func updateDiarization(for item: SessionInventory.Item) {
        if item.unreadableDiarization {
            diarizationLabel.isHidden = false
            diarizationLabel.stringValue = localised(
                "Speaker separation: saved model request cannot be read. Processing is blocked.",
                "Разделение говорящих: не удалось прочитать сохранённый запрос модели. Обработка заблокирована.")
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
        retryDiarizationButton.isHidden = !actions
        let needsModel = !DiarizationModelStore.isReady(at: DiarizationModelStore.shared(for: state.request.model).directory, model: state.request.model)
        retryDiarizationButton.title = needsModel ? localised("Download and continue", "Скачать и продолжить") : localised("Retry speaker separation", "Повторить разделение")
        skipDiarizationButton.isHidden = !actions
    }

    static func diarizationLine(_ state: DiarizationState) -> String {
        let stage: String
        switch state.status {
        case .pending: stage = localised("pending", "ожидает")
        case .running: stage = localised("running", "выполняется")
        case .deferred: stage = localised("waiting for model", "ожидает модель")
        case .failed: stage = localised("failed", "ошибка")
        case .partial: stage = localised("incomplete", "не завершено")
        case .completed: stage = localised("complete", "готово")
        case .skipped: stage = localised("skipped", "пропущено")
        case .notApplicable: stage = localised("not applicable", "не применяется")
        }
        var parts = [localised("Speaker separation: ", "Разделение говорящих: ") + stage]
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

    /// The row-level action belongs only beside a failed transcript whose
    /// source audio still exists. A generic action column would put buttons
    /// beside healthy rows and make the failure harder, not easier, to act on.
    static func inlineRetranscribeTitle(for item: SessionInventory.Item) -> String? {
        guard case .failed = item.transcript, item.hasAudio else { return nil }
        return localised("Re-transcribe", "Расшифровать заново")
    }

    // MARK: - actions

    @objc private func nameEdited(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.components(separatedBy: "\n")
        guard parts.count == 2 else { return }
        PostProcessor.rename(parts[1], to: sender.stringValue, in: URL(fileURLWithPath: parts[0]))
        reload()
    }

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
            return PostProcessor.outstanding(item.dir, policy: policy).isEmpty
                ? .nothingOwed
                : .finish
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
            working = true
            updateButtons()
            Task {
                await PostProcessor.finish(version.dir)
                working = false
                reload()
            }
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
            working = true
            updateButtons()
            Task {
                let work = await PostProcessor.finish(item.dir)
                working = false
                reload()
                if work.isEmpty { say(Self.nothingDoneLine(for: item.dir), about: item) }
            }
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
        let alert = NSAlert()
        alert.messageText = item.title ?? item.name
        alert.informativeText = sentence
        alert.addButton(withTitle: localised("OK", "Ладно"))
        alert.runModal()
    }

    /// Confirm recognition because a cloud engine can incur a charge. Existing
    /// results survive both successful and failed attempts.
    @objc private func retranscribeClicked() {
        confirmRetranscription(engine: nil)
    }

    @objc private func retranscribeWithEngine(_ sender: NSMenuItem) {
        confirmRetranscription(engine: sender.representedObject as? String)
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
        alert.addButton(withTitle: localised("Transcribe again", "Расшифровать заново"))
        alert.addButton(withTitle: localised("Cancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let why = Self.markForRetranscription(item.dir, engine: engine) {
            say(why, about: item)
            return
        }
        onRetranscribe?(item.dir)
        reload()
    }

    /// Clear a recording for re-transcription with the engine chosen for it,
    /// or say why not. The engine is written only once the clearing is sure
    /// to happen.
    @discardableResult
    static func markForRetranscription(_ dir: URL, engine: String?) -> String? {
        if let why = retranscriptionRefusal(for: dir) { return why }
        let previous = SessionState.value(dir, SessionState.Key.transcriptionEngine)
        if let engine {
            SessionState.update(dir, with: [SessionState.Key.transcriptionEngine: engine])
        }
        guard PostProcessor.markForRetranscription(dir) else {
            // Taken between the question and the clearing: put the choice
            // back as it was, and say so.
            if engine != nil {
                SessionState.update(dir, with: [SessionState.Key.transcriptionEngine: previous])
            }
            return retranscriptionRefusal(for: dir) ?? nothingOwedLine
        }
        return nil
    }

    @objc private func inlineRetranscribeClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        table.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        showDetail()
        retranscribeClicked()
    }

    @objc private func chooseImportClicked() { onChooseImport?() }

    @objc private func openRootClicked() {
        Analytics.track(.artifactOpened, [
            .artifact: .text(Analytics.Artifact.recordingsRoot.rawValue),
        ])
        NSWorkspace.shared.open(root)
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
                    alert.runModal()
                    return
                }
                NSWorkspace.shared.open(
                    [file], withApplicationAt: textEdit,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error {
                        Task { @MainActor in NSAlert(error: error).runModal() }
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

    @objc private func copySummaryClicked() {
        guard let summary = summaryToCopy else {
            updateButtons()
            return
        }
        guard Self.copy(summary: summary, to: pasteboard) else { return }
        copyReset?.cancel()
        let title = localised("Copy summary", "Скопировать сводку")
        copySummaryButton.title = localised("Copied", "Скопировано")
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copySummaryButton.title = title
        }
    }

    @discardableResult
    static func copy(
        summary: String, to pasteboard: NSPasteboard,
        rtf: (NSAttributedString) throws -> Data = { rendered in
            try rendered.data(from: NSRange(location: 0, length: rendered.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
    ) -> Bool {
        let rendered = NSMutableAttributedString(attributedString: MarkdownPreview.render(summary))
        let range = NSRange(location: 0, length: rendered.length)
        // Normalize paragraph boundaries as NSTextStorage does for the preview.
        rendered.fixAttributes(in: range)
        // A preview's dynamic label colour becomes fixed in RTF, including white from a dark window.
        rendered.removeAttribute(.foregroundColor, range: range)
        let data = try? rtf(rendered)
        pasteboard.declareTypes(data == nil ? [.string] : [.string, .rtf], owner: nil)
        guard pasteboard.setString(summary, forType: .string) else { return false }
        if let data { pasteboard.setData(data, forType: .rtf) }
        return true
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
        alert.addButton(withTitle: localised("Cancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let id = try deletion.schedule(item.dir) { [weak self] result in
                guard let self else { return }
                self.deletionNotice.isHidden = true
                self.onActivityChange?()
                self.reload()
                if case .failure(let error) = result { NSAlert(error: error).runModal() }
            }
            undoDeletionID = id
            deletionLabel.stringValue = localised("Meeting deleted", "Встреча удалена")
            deletionNotice.isHidden = false
            onActivityChange?()
            show(allItems)
        } catch { NSAlert(error: error).runModal() }
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
}

extension RecordingsWindow: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if embedded && menu === meetingMenu {
            let rendered = MeetingActionsMenu.make(state: currentActions, target: self, action: #selector(meetingAction(_:)))
            menu.removeAllItems()
            for item in rendered.items { rendered.removeItem(item); menu.addItem(item) }
            return
        }
        let enabled = selected?.hasAudio == true && !working
        for item in menu.items { item.isEnabled = enabled }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(
        _ tableView: NSTableView,
        objectValueFor tableColumn: NSTableColumn?,
        row: Int
    ) -> Any? {
        guard row < items.count, let column = tableColumn?.identifier.rawValue else { return nil }
        return Self.cell(items[row], column: column)
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < items.count, let column = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        if embedded { return MeetingListView(item: item, active: activeRecording) }
        let label = NSTextField(labelWithString: Self.cell(item, column: column) ?? "")
        label.lineBreakMode = .byTruncatingTail

        guard column == "transcript", let title = Self.inlineRetranscribeTitle(for: item) else {
            return label
        }

        let retry = NSButton(
            title: title, target: self, action: #selector(inlineRetranscribeClicked(_:)))
        retry.bezelStyle = .rounded
        retry.controlSize = .mini
        retry.tag = row

        let cell = NSStackView(views: [label, retry])
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 6
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retry.setContentCompressionResistancePriority(.required, for: .horizontal)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetail()
    }

    /// One cell, as words. Apart from the data source this is what
    /// `listLines` reads, so that the suite and the window cannot disagree
    /// about what a row says.
    static func cell(_ item: SessionInventory.Item, column: String) -> String? {
        switch column {
        case "when":
            return item.started.map { SessionInventory.Item.stamp.string(from: $0) } ?? item.name
        case "meeting":
            let length = item.duration.map {
                localised(" · \(Int($0 / 60))m", " · \(Int($0 / 60)) мин")
            } ?? ""
            return (item.title ?? item.name) + length
        case "transcript":
            return item.transcript.described + (item.engine.map { " (\($0))" } ?? "")
        case "names":
            guard let counts = item.namedSpeakers, counts.total > 0 else {
                return item.speakers.described
            }
            return "\(counts.named)/\(counts.total)"
        case "summary":
            return item.summary.described
        default:
            return nil
        }
    }
}
