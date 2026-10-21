import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct JournalWorkspaceTests {
    @Test(.freshHome) func resultTabsFollowWhetherAMeetingIsSelected() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(NSSize(width: 1340, height: 820))
        app.show()
        await library.settled()
        let picker = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.result-tabs" })
        let pages = try #require(library.contentView.allDescendants.first { $0 is NSTabView })
        #expect(picker.isHiddenOrHasHiddenAncestor)
        #expect(pages.isHiddenOrHasHiddenAncestor)

        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"title":"Planning"}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        library.refresh()
        await library.settled()
        #expect(!picker.isHiddenOrHasHiddenAncestor)
        #expect(!pages.isHiddenOrHasHiddenAncestor)
        let search = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "no matching meeting"
        _ = NSApplication.shared.sendAction(try #require(search.action), to: search.target, from: search)
        #expect(picker.isHiddenOrHasHiddenAncestor)
        #expect(pages.isHiddenOrHasHiddenAncestor)
        library.applyFilter(.allMeetings, clearSearch: true)
        #expect(!picker.isHiddenOrHasHiddenAncestor)
        #expect(!pages.isHiddenOrHasHiddenAncestor)
    }

    @Test(.freshHome, arguments: [180, 248])
    func hoveredMeetingUsesTheSameHighlightWidthAsSelection(width: Int) throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: Home.current.url, hostWindow: app.panel)
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSTableView }.first)
        let row = try #require(library.tableView(table, rowViewForRow: 0))
        row.frame = NSRect(x: 0, y: 0, width: width, height: 62)
        row.backgroundColor = .clear
        func paintedColumns(_ draw: () -> Void) throws -> [Int] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 62,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSColor.clear.setFill()
            row.bounds.fill(using: .copy)
            draw()
            return (0..<width).filter { (bitmap.colorAt(x: $0, y: 31)?.alphaComponent ?? 0) > 0.1 }
        }
        let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        row.mouseEntered(with: entered)
        let hover = try paintedColumns { row.drawBackground(in: row.bounds) }
        row.isSelected = true
        let selection = try paintedColumns { row.drawSelection(in: row.bounds) }
        #expect(hover == selection)
        #expect(selection == Array(1..<(width - 1)))
        let selectedBackground = try paintedColumns { row.drawBackground(in: row.bounds) }
        #expect(selectedBackground.isEmpty, "Hover must not darken an already selected row")
        row.isSelected = false
        row.mouseExited(with: entered)
        let cleared = try paintedColumns { row.drawBackground(in: row.bounds) }
        #expect(cleared.isEmpty)
    }

    @Test(.freshHome, .speaking(.russian))
    func eachMeetingShowsItsOwnDateAndTimeWithoutGrouping() throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        for (name, date) in [("first", "2026-10-21T10:00:00Z"), ("second", "2026-10-21T11:00:00Z"), ("third", "2026-10-20T10:00:00Z")] {
            let dir = root.appendingPathComponent(date)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["title": name, "started": date]).write(to: dir.appendingPathComponent("meta.json"))
        }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? MeetingTableView }.first)
        #expect(table.numberOfRows == 3)
        let dates = ["2026-10-21T11:00:00Z", "2026-10-21T10:00:00Z", "2026-10-20T10:00:00Z"]
        for index in 0..<table.numberOfRows {
            let row = try #require(library.tableView(table, viewFor: nil, row: index))
            let date = try #require(row.allDescendants.first { $0.identifier?.rawValue == "meeting.list-date" } as? NSTextField)
            #expect(date.stringValue == MeetingPresentation.date(ISO8601DateFormatter().date(from: dates[index])))
            #expect(!date.stringValue.isEmpty)
            #expect(library.tableView(table, heightOfRow: index) == 62)
        }
    }

    @Test(.freshHome, arguments: [false, true]) func openingWindowDoesNotFocusSearch(bringToFront: Bool) async throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: Home.current.url, hostWindow: app.panel)
        app.libraryProvider = { library }
        if bringToFront { app.bringToFront() } else { app.show(); app.panel.makeKey() }
        await library.settled()
        let search = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSSearchField }.first)
        let initial = try #require(app.panel.initialFirstResponder)
        #expect(app.panel.firstResponder === initial)
        #expect(search.currentEditor() == nil, "Opening the window must not start editing the search field")
        let input = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: app.panel.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        app.panel.sendEvent(input)
        #expect(search.stringValue.isEmpty, "Typing before choosing a field must not start a search")
        app.panel.selectNextKeyView(nil)
        #expect(app.panel.firstResponder !== initial, "Tab must move to an interactive control")

        for unmodified in ["f", "а"] {
            app.panel.makeFirstResponder(initial)
            let find = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: app.panel.windowNumber, context: nil,
                characters: "f", charactersIgnoringModifiers: unmodified, isARepeat: false, keyCode: 3))
            #expect(app.panel.performKeyEquivalent(with: find))
            #expect(search.currentEditor() != nil, "Explicit keyboard navigation to search remains available")
        }
        app.bringToFront()
        #expect(search.currentEditor() != nil, "Reactivating the window preserves a user's chosen focus")
    }

    @Test(.freshHome, .speaking(.russian)) func playerAndProcessingActionsFollowAcceptanceLayout() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.moveItem(at: SessionFixture.make(), to: dir)
        try TestAudio.write(to: dir.appendingPathComponent("mic.caf"), seconds: 0.1) { _, _ in 0 }
        try SessionState.amend(dir, with: ["files": ["mic": "mic.caf"]])
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(NSSize(width: 1340, height: 820))
        app.show()
        await library.settled()
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let views = library.contentView.allDescendants
        let title = try #require(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "meeting.title" })
        let player = try #require(views.first { $0.identifier?.rawValue == "meeting.playback" })
        let tabs = try #require(views.first { $0.identifier?.rawValue == "meeting.result-tabs" })
        let inspector = try #require(views.first { $0.identifier?.rawValue == "meeting.inspector-content" })
        let document = try #require(views.first { $0.identifier?.rawValue == "meeting.document" })
        for (rowID, buttonID, label) in [
            ("meeting.processing-transcript", "meeting.retranscribe", "Расшифровать повторно"),
            ("meeting.processing-summary", "meeting.generate-summary", "Создать сводку"),
        ] {
            let row = try #require(inspector.allDescendants.first { $0.identifier?.rawValue == rowID } as? NSStackView)
            let button = try #require(row.arrangedSubviews.last as? NSButton)
            let stage = try #require(row.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
            #expect(button.identifier?.rawValue == buttonID)
            #expect(button.title.isEmpty && button.image != nil && button.imagePosition == .imageOnly)
            #expect(button.accessibilityLabel() == label)
            #expect(button.toolTip == label)
            #expect(button.isEnabled)
            #expect(button.frame.minX > stage.frame.maxX)
            #expect(abs(button.frame.maxX - row.bounds.maxX) < 1)
            #expect(!document.allDescendants.contains { $0 === button })
        }
        let inspectorLabels = inspector.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(!inspectorLabels.contains { $0.contains("Из настроек:") })
        #expect(title.font?.familyName == NSFont.systemFont(ofSize: 34).familyName)
        let titleRect = title.convert(title.bounds, to: nil)
        let playerRect = player.convert(player.bounds, to: nil)
        let tabsRect = tabs.convert(tabs.bounds, to: nil)
        #expect(titleRect.minY > playerRect.maxY)
        #expect(playerRect.minY > tabsRect.maxY)
        #expect(!views.compactMap { $0 as? NSPopUpButton }.contains { $0.itemTitles.contains("mic.caf") })
        let sidebar = try #require(app.panel.contentView?.allDescendants.first { $0 is SidebarView })
        let importButton = try #require(sidebar.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "journal.import" })
        #expect(importButton.isBordered)
        #expect(importButton.frame.height >= 40)

        try SessionClaim.acquire(dir, stage: .transcribe)
        defer { SessionClaim.release(dir) }
        library.refresh()
        await library.settled()
        for id in ["meeting.retranscribe", "meeting.generate-summary"] {
            let button = try #require(inspector.allDescendants.first { $0.identifier?.rawValue == id } as? NSButton)
            #expect(!button.isEnabled)
            #expect(button.toolTip == "Дождитесь завершения обработки.")
        }
        let settings = try #require(inspector.allDescendants.first { $0.identifier?.rawValue == "meeting.processing-settings" } as? NSButton)
        #expect(settings.title == "Настройки →")
        _ = NSApp.sendAction(try #require(settings.action), to: settings.target, from: settings)
        #expect(app.navigation.destination == .transcription)
    }

    @Test(.freshHome, .speaking(.russian)) func processingSettingsFollowCurrentConfiguration() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: SessionFixture.make(), to: root.appendingPathComponent("meeting"))
        try Home.current.writeConfig([
            "transcription": ["enabled": true, "engine": "gigaam", "local_engine": "gigaam", "model": "v2",
                              "cloud": "openai", "local_diarization": true, "diarization_model": "ls-eend-ami",
                              "openai": ["model": "configured-transcription-model"],
                              "assemblyai": ["speech_model": "best"]],
            "summary": ["enabled": true, "backend": "codex-cli"],
        ])
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        let settings = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.processing-configuration" } as? NSTextField)
        for (engine, model, diarization) in [
            ("gigaam", "GigaAM v3", "LS-EEND AMI"),
            ("whisper", "Whisper large-v3-turbo", "LS-EEND AMI"),
            ("parakeet", "Parakeet v2", "LS-EEND AMI"),
            ("openai", "OpenAI · configured-transcription-model", "Встроенная в OpenAI"),
            ("elevenlabs", "ElevenLabs · scribe_v2", "Встроенная в ElevenLabs"),
            ("assemblyai", "AssemblyAI · best", "Встроенная в AssemblyAI"),
        ] {
            #expect(Config.update(path: ["transcription", "engine"], value: engine))
            library.refresh()
            await library.settled()
            let available = Config.cloudEngines.contains(engine) || Platform.supportsLocalModels
            #expect(settings.stringValue == "Расшифровка: \(available ? model : "Отключена")\nДиаризация: \(available ? diarization : "Отключена")\nСводка: Codex")
        }
        #expect(Config.update(path: ["transcription", "engine"], value: "auto"))
        library.refresh()
        await library.settled()
        #expect(settings.stringValue == "Расшифровка: OpenAI · configured-transcription-model" + (Platform.supportsLocalModels ? " → GigaAM v3" : "")
            + "\nДиаризация: Встроенная в OpenAI" + (Platform.supportsLocalModels ? " / LS-EEND AMI" : "") + "\nСводка: Codex")

        #expect(Config.update(path: ["transcription", "engine"], value: "gigaam"))
        #expect(Config.update(path: ["transcription", "local_diarization"], value: false))
        library.refresh()
        await library.settled()
        #expect(settings.stringValue.contains("\nДиаризация: Отключена\n"))
        #expect(Config.update(path: ["transcription", "enabled"], value: false))
        #expect(Config.update(path: ["summary", "enabled"], value: false))
        library.refresh()
        await library.settled()
        #expect(settings.stringValue == "Расшифровка: Отключена\nДиаризация: Отключена\nСводка: Отключена")
        #expect(Config.update(path: ["summary", "enabled"], value: true))
        #expect(Config.update(path: ["summary", "backend"], value: "none"))
        library.refresh()
        await library.settled()
        #expect(settings.stringValue.hasSuffix("Сводка: Отключена"))
    }
    @Test func transcriptReflowsAfterDocumentWidthChanges() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let view = MeetingTranscriptView()
        window.contentView = view
        view.update(transcript: .init(engine: "test", model: "test", created_at: "", segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: String(repeating: "A meeting paragraph that wraps across several lines. ", count: 4)),
        ]), names: nil, participants: [], canEdit: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let table = try #require(view.documentView as? NSTableView)
        let narrowHeight = table.rect(ofRow: 0).height
        window.setContentSize(NSSize(width: 900, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 0).height < narrowHeight)
        #expect(table.rect(ofRow: 0).height < 120)
    }

    @Test(.freshHome) func selectingMeetingFromSettingsKeepsSearchAndUsesThatMeeting() throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        for name in ["Planning one", "Planning two"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["title": name]).write(to: dir.appendingPathComponent("meta.json"))
        }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(NSSize(width: 1340, height: 820))
        app.show()
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let search = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "Planning"
        _ = NSApplication.shared.sendAction(try #require(search.action), to: search.target, from: search)
        app.navigate(.summary)
        app.panel.setContentSize(NSSize(width: 760, height: 680))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? MeetingTableView }.first)
        table.selectRowIndexes([1], byExtendingSelection: false)
        _ = NSApplication.shared.sendAction(try #require(table.action), to: table.target, from: table)
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(app.panel.contentLayoutRect.width <= 762)
        #expect(app.navigation.destination == .allMeetings)
        #expect(search.stringValue == "Planning")
        #expect(table.selectedRow == 1)
        let title = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "meeting.title" })
        #expect(title.stringValue == "Planning one")
        #expect(!title.isHiddenOrHasHiddenAncestor)
    }

    @Test(.freshHome) func journalKeepsLibraryAndRecordingControlsWhileInSettings() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: Home.current.url, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.update(state: .recording, elapsed: "03:42")
        app.navigate(.general)
        let views = try #require(app.panel.contentView).allDescendants
        let sidebar = try #require(views.first { $0 is SidebarView })
        #expect(sidebar.allDescendants.contains { $0 is MeetingTableView })
        let bar = try #require(views.first { $0.identifier?.rawValue == "recording-bar" })
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(!bar.isHiddenOrHasHiddenAncestor)
        let rect = bar.convert(bar.bounds, to: app.panel.contentView)
        #expect(rect.midY > app.panel.contentLayoutRect.height / 2, "Recording controls stay above the document")
        #expect(views.contains { $0.identifier?.rawValue == "settings.navigation" && !$0.isHiddenOrHasHiddenAncestor })
    }

    @Test(.freshHome, .speaking(.russian)) func sectionBreadcrumbsNavigateAndThereIsNoIdleFooter() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: Home.current.url, hostWindow: app.panel)
        app.libraryProvider = { library }
        func crumb() throws -> NSButton {
            try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "journal.breadcrumb" })
        }
        let meetings = try crumb()
        #expect(meetings.title == "Встречи")
        #expect(!meetings.isHiddenOrHasHiddenAncestor)
        let search = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "test"
        _ = NSApplication.shared.sendAction(try #require(meetings.action), to: meetings.target, from: meetings)
        #expect(search.stringValue.isEmpty)
        app.navigate(.calendar)
        let settings = try crumb()
        #expect(settings.title == "Настройки")
        _ = NSApplication.shared.sendAction(try #require(settings.action), to: settings.target, from: settings)
        #expect(app.navigation.destination == .general)
        let texts = app.panel.contentView?.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        #expect(!texts.contains("Запись не идёт"))
        #expect(!texts.contains("Файлы в папке встреч"))
    }

    @Test(.freshHome, .speaking(.russian)) func liveMetersExplicitlyReportMissingFunctionality() throws {
        let app = ApplicationWindow()
        app.update(state: .recording, elapsed: "00:01")
        app.showActiveRecording()
        defer { app.hide() }
        let fields = try #require(app.panel.contentView).allDescendants.compactMap { $0 as? NSTextField }
        #expect(fields.filter { $0.stringValue == "Функция пока не реализована" }.count == 2)
    }

    @Test(.freshHome) func documentAndInspectorRemainReachableAtNarrowWidth() throws {
        let dir = Home.current.url.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"title":"Обсуждение нового сайта и планирование следующего квартала"}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        try TestAudio.write(to: dir.appendingPathComponent("microphone.caf"), seconds: 0.1) { _, _ in 0 }
        try SessionState.amend(dir, with: ["files": ["mic": "microphone.caf"]])
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: Home.current.url, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.show()
        app.panel.setContentSize(NSSize(width: 760, height: 680))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let views = try #require(app.panel.contentView).allDescendants
        let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "meeting.inspector" })
        let inspector = try #require(views.first { $0.identifier?.rawValue == "meeting.inspector-content" })
        #expect(inspector.isHiddenOrHasHiddenAncestor)
        #expect(app.panel.contentLayoutRect.width <= 762, "before opening inspector")
        _ = NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button)
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(!inspector.isHiddenOrHasHiddenAncestor)
        #expect(app.panel.contentLayoutRect.width <= 762, "after opening inspector")
        library.beginRenamingMeeting()
        #expect(app.panel.contentLayoutRect.width <= 762, "before layout after rename")
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let title = try #require(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "meeting.title" })
        #expect(title.isEditable)
        #expect(!title.isHiddenOrHasHiddenAncestor)
        #expect(app.panel.contentLayoutRect.width <= 762)
        let tabs = try #require(views.compactMap { $0 as? NSTabView }.first)
        #expect(tabs.tabViewItems.map { $0.identifier as? String } == ["summary", "transcript"])
    }

    @Test(.freshHome, .speaking(.english)) func selectingActiveRecordingClearsPreviousSpeakerEditors() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("completed")
        try FileManager.default.moveItem(at: SessionFixture.make(), to: dir)
        try SessionState.amend(dir, with: [SessionState.Key.speakersStatus: "failed"])
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        await library.settled()
        #expect(library.contentView.allDescendants.contains { $0 is MeetingSpeakerView })
        let finish = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }.first { $0.title == "Finish processing" })
        #expect(!finish.isHidden)
        library.setActiveRecording(.init(dir: root.appendingPathComponent("active"), title: "Active", started: Date(), paused: false, liveStatus: .live))
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? MeetingTableView }.first)
        table.selectRowIndexes([0], byExtendingSelection: false)
        #expect(library.currentActions.isRecording)
        #expect(!library.contentView.allDescendants.contains { $0 is MeetingSpeakerView })
        #expect(finish.isHidden && !finish.isEnabled)
    }

    @Test(.freshHome(config: #"{"summary":{"backend":"ollama"}}"#), .speaking(.russian))
    func pendingSummaryIsVisiblyWaiting() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: SessionFixture.make(), to: root.appendingPathComponent("meeting"))
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        await library.settled()
        let inspector = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.inspector-content" })
        let labels = inspector.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("Ожидание: Подготовка сводки"))
    }
}
