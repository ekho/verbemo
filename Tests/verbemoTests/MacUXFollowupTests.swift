import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct MacUXFollowupTests {
    @Test(.speaking(.english)) func unknownSpeakerDoesNotBecomeANumberedVoice() {
        let segments = ["them A", "them ?", "them B", "speaker ?"].map {
            Transcript.Segment(speaker: $0, start_ms: 0, end_ms: 1000, text: "Test")
        }
        #expect(MeetingTranscriptView.speakerTitle("them A", in: segments) == "Speaker 1")
        #expect(MeetingTranscriptView.speakerTitle("them ?", in: segments) == "Speaker unknown")
        #expect(MeetingTranscriptView.speakerTitle("them B", in: segments) == "Speaker 2")
        #expect(MeetingTranscriptView.speakerTitle("speaker ?", in: segments) == "Speaker unknown")
    }

    @Test(.freshHome, .speaking(.english), .enabled(if: Platform.supportsLocalModels))
    func incompleteModelFilesAreNotShownAsInstalled() throws {
        let storage = ModelStorage()
        for model in [storage.parakeet(version: .v3), storage.nemotronModel()] {
            try FileManager.default.createDirectory(at: model.directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: model.directory.appendingPathComponent("metadata.json"))
        }
        let application = ApplicationWindow()
        defer { application.settings.setup.stop(); withExtendedLifetime(application) {} }
        let content = application.settings.content(for: .storage)
        let buttons = content.allDescendants.compactMap { $0 as? NSButton }
        for model in [storage.parakeet(version: .v3), storage.nemotronModel()] {
            let download = try #require(buttons.first { $0.identifier?.rawValue == model.directory.path })
            #expect(download.title == "Download")
            #expect(!download.isHidden && download.isEnabled)
        }
        #expect(!buttons.contains { $0.title == "Delete" })
    }

    @Test(.freshHome) func participantMappingCanBeChangedFromParticipantsAndTranscript() async throws {
        let fixture = try SessionFixture.make(meta: ["title": "Planning", "calendar": [
            "schema_version": 2, "event_id": "test-event", "association": "confirmed", "title": "Planning",
            "participants": [["id": "anna", "name": "Anna", "email": "anna@example.test"]],
        ]])
        let root = fixture.appendingPathExtension("library")
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture, to: dir)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(NSSize(width: 1600, height: 1000))
        app.show()
        await library.settled()
        let tabs = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTabView }.first)
        app.panel.contentView?.layoutSubtreeIfNeeded()
        tabs.selectTabViewItem(withIdentifier: "participants")
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let document = try #require(tabs.selectedTabViewItem?.view?.allDescendants.first { $0.identifier?.rawValue == "meeting.participants" } as? NSStackView)
        let participantsScroll = try #require(document.enclosingScrollView)
        let firstLabel = try #require(document.arrangedSubviews.first)
        let clip = participantsScroll.contentView
        let firstFrame = firstLabel.convert(firstLabel.bounds, to: clip)
        let topGap = clip.isFlipped ? firstFrame.minY - clip.bounds.minY : clip.bounds.maxY - firstFrame.maxY
        #expect(topGap >= -1 && topGap < 40, "participants must start at top, gap: \(topGap)")
        let editor = try #require(document.allDescendants.compactMap { $0 as? SpeakerAssignmentEditor }.first)
        let speaker = try #require(SessionFixture.meeting.first?.speaker)
        editor.choice.selectItem(at: 1)
        editor.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification))
        #expect(SpeakerNames.read(from: dir)?.speakers[speaker]?.participantID == "anna")
        await Task.yield()
        tabs.selectTabViewItem(withIdentifier: "transcript")
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(tabs.selectedTabViewItem?.view?.allDescendants.compactMap { $0 as? MeetingTranscriptView }.first)
        let table = try #require(scroll.documentView as? NSTableView)
        let row = try #require(SessionFixture.meeting.firstIndex { $0.speaker == speaker })
        let cell = try #require(scroll.tableView(table, viewFor: table.tableColumns[0], row: row))
        let other = try #require(cell.allDescendants.compactMap { $0 as? SpeakerAssignmentEditor }.first)
        #expect(other.choice.indexOfSelectedItem == 1)
        #expect(other.link.sendAction(other.link.action, to: other.link.target))
        #expect(!other.choice.isHiddenOrHasHiddenAncestor)
        other.choice.selectItem(at: 0)
        other.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification))
        #expect(SpeakerNames.read(from: dir)?.speakers[speaker]?.participantID == nil)
        #expect(try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8).contains("Anna") == false)
    }

    @Test func calendarTimesUseLocalDatesAndHandleInvalidMetadata() throws {
        let metadata = try #require(MeetingCalendarMetadata(["scheduled_start": "2026-10-20T07:00:00Z", "scheduled_end": "2026-10-20T07:45:00Z"]))
        let zone = try #require(TimeZone(secondsFromGMT: 10800))
        let line = MeetingCalendarView.dateLine(metadata, timeZone: zone)
        #expect(line.contains("20.10.2026 10:00"))
        #expect(line.contains("10:45"))
        #expect(!line.contains("T07:") && !line.contains("Z"))
        let zoned = try #require(MeetingCalendarMetadata(["scheduled_start": "2026-10-20T07:00:00Z", "time_zone": "America/New_York"]))
        #expect(MeetingCalendarView.dateLine(zoned, timeZone: zone).contains("America/New_York"))
        let bad = try #require(MeetingCalendarMetadata(["scheduled_start": "not a date"]))
        #expect(MeetingCalendarView.dateLine(bad, timeZone: zone).isEmpty)
        let overnight = try #require(MeetingCalendarMetadata(["scheduled_start": "2026-10-20T20:30:00Z", "scheduled_end": "2026-10-20T22:00:00Z"]))
        #expect(MeetingCalendarView.dateLine(overnight, timeZone: zone).contains("21.10.2026 01:00"))
    }

    @Test(.freshHome) func emptyFiltersExplainTheirState() throws {
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), hostWindow: app.panel)
        app.libraryProvider = { library }
        for filter in [ApplicationNavigationState.Destination.processing, .attention] {
            app.navigate(filter)
            let label = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "meeting-list.empty" })
            #expect(!label.isHiddenOrHasHiddenAncestor)
            #expect(!label.stringValue.isEmpty)
        }
        app.hide()
    }

    @Test(.freshHome) func renameEditsTheHeadingAndKeepsTheSessionDirectory() async throws {
        let fixture = try SessionFixture.make()
        let root = fixture.appendingPathExtension("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.moveItem(at: fixture, to: dir)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.show()
        await library.settled()
        library.beginRenamingMeeting()
        let heading = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "meeting.title" })
        #expect(heading.isEditable)
        heading.stringValue = "Changed title"
        _ = NSApplication.shared.sendAction(try #require(heading.action), to: heading.target, from: heading)
        await library.settled()
        #expect(SessionState.read(dir)?["title"] as? String == "Changed title")
        #expect(!heading.isEditable)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
    }
    @Test(.freshHome) func firstRunIsACompactPageInTheExistingWindow() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        let setup = SetupPage()
        var finished = 0
        setup.onFinished = { finished += 1 }
        app.presentSetup(setup)
        let page = setup.contentView
        #expect(page.window === app.panel)
        #expect(page.allDescendants.contains { $0.identifier?.rawValue == "access.microphone" })
        #expect(page.allDescendants.contains { $0.identifier?.rawValue == "access.system-audio" })
        #expect(!page.allDescendants.contains { $0 is ChoiceCard || $0 is NSSecureTextField })
        #expect(!page.allDescendants.contains { $0.identifier?.rawValue == "access.login" })
        #expect(page.allDescendants.contains { $0.identifier?.rawValue == "access.calendar" })
        #expect(page.allDescendants.contains { $0 is CalendarSettingsView })
        let footer = try #require(page.subviews.compactMap { $0 as? NSStackView }.first)
        #expect(footer.allDescendants.compactMap { $0 as? NSButton }.isEmpty)
        #expect(footer.allDescendants.compactMap { $0 as? NSTextField }.contains { !$0.stringValue.isEmpty })
        app.navigate(.general)
        #expect(!setup.isVisible)
        #expect(!SetupState.isPending)
        #expect(finished == 1)
        #expect(app.navigation.destination == .general)
        #expect(app.panel.contentView?.allDescendants.contains { $0 === page } == false)
        app.navigate(.allMeetings)
        #expect(finished == 1)
    }

    @Test(.freshHome, arguments: ["hide", "close", "quit"])
    func leavingFirstRunCompletesSetupWithoutFooterButtons(exit: String) {
        let app = ApplicationWindow()
        let setup = SetupPage()
        var finished = 0
        setup.onFinished = { finished += 1 }
        app.presentSetup(setup)
        #expect(SetupState.isPending)
        switch exit {
        case "close": app.panel.performClose(nil)
        case "quit": _ = app.stopForTermination()
        default: app.hide()
        }
        #expect(!SetupState.isPending)
        #expect(finished == 1)
        if exit != "quit" {
            app.show()
            #expect(!setup.isVisible)
            #expect(app.navigation.destination == .allMeetings)
        }
        app.hide()
        #expect(finished == 1)
    }

    @Test(.freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet","model":"v2"}}"#))
    func parakeetVersionLivesInTheCardAndUpdatesItsIdentity() throws {
        let settings = ApplicationWindow().settings
        let page = settings.content(for: .transcription)
        let card = try #require(page.allDescendants.compactMap { $0 as? ChoiceCard }.first { $0.id == "parakeet" })
        #expect(card.accessibilityLabel() == "Parakeet v2")
        let version = try #require(card.allDescendants.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "transcription.model" })
        version.selectItem(withTitle: "v3")
        _ = NSApplication.shared.sendAction(try #require(version.action), to: version.target, from: version)
        #expect(Config.transcriptionModel() == "v3")
        #expect(card.accessibilityLabel() == "Parakeet v3")
        #expect(page.allDescendants.filter { $0.identifier?.rawValue == "transcription.model" }.count == 1)
    }

    @Test(.freshHome(config: #"{"transcription":{"enabled":false},"summary":{"enabled":false}}"#))
    func disabledServicesHideTheirFieldsWithoutLosingValues() throws {
        let settings = ApplicationWindow().settings
        let transcription = settings.content(for: .transcription)
        let key = try #require(transcription.allDescendants.first { $0.identifier?.rawValue == "transcription.key.assemblyai" })
        #expect(key.isHiddenOrHasHiddenAncestor)
        let summary = settings.content(for: .summary)
        let ollama = try #require(summary.allDescendants.first { $0.identifier?.rawValue == "summary.ollama_model" })
        #expect(ollama.isHiddenOrHasHiddenAncestor)
        Config.update(path: ["summary", "ollama_model"], value: "kept-model")
        Config.update(path: ["summary", "backend"], value: "ollama")
        Config.update(path: ["summary", "enabled"], value: true)
        #expect(!ollama.isHiddenOrHasHiddenAncestor)
        #expect((ollama as? NSTextField)?.stringValue == "kept-model")
        Config.update(path: ["summary", "enabled"], value: false)
        #expect(ollama.isHiddenOrHasHiddenAncestor)
        #expect(Config.summary().ollamaModel == "kept-model")
    }

    @Test(.freshHome) func firstTranscriptOpenHasVisibleRowsWithoutResizing() async throws {
        let fixture = try SessionFixture.make(meta: ["title": "Planning", "calendar": [
            "schema_version": 2, "event_id": "test-event", "association": "confirmed",
            "title": "Planning", "scheduled_start": "2026-10-20T07:00:00Z",
            "participants": [["id": "anna", "name": "Anna"]],
        ]])
        let root = fixture.appendingPathExtension("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture, to: root.appendingPathComponent("meeting"))
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(NSSize(width: 790, height: 680))
        app.show()
        let list = try #require(library.listContentView.allDescendants.compactMap { $0 as? MeetingTableView }.first)
        list.selectRowIndexes([0], byExtendingSelection: false)
        _ = NSApplication.shared.sendAction(try #require(list.action), to: list.target, from: list)
        let tabs = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTabView }.first)
        tabs.selectTabViewItem(withIdentifier: "transcript")
        app.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let scroll = try #require(tabs.selectedTabViewItem?.view?.allDescendants.compactMap { $0 as? MeetingTranscriptView }.first)
        let table = try #require(scroll.documentView as? NSTableView)
        let pane = try #require(tabs.selectedTabViewItem?.view)
        #expect(abs(pane.frame.minY - tabs.contentRect.minY) < 2,
                "tab content \(tabs.contentRect), pane \(pane.frame), transcript \(scroll.frame)")
        #expect(scroll.bounds.height >= 80, "transcript viewport: \(scroll.frame)")
        #expect(table.visibleRect.height > 20, "table: \(table.frame), visible: \(table.visibleRect)")
        #expect(table.frame.width >= scroll.contentSize.width - 2, "table must fill the reading pane")
        let first = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(first.convert(first.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds))
        for _ in 0..<3 {
            tabs.selectTabViewItem(withIdentifier: "summary")
            tabs.selectTabViewItem(withIdentifier: "transcript")
            app.panel.contentView?.layoutSubtreeIfNeeded()
        }
        #expect(table.visibleRect.height > 20)
        #expect(abs(pane.frame.minY - tabs.contentRect.minY) < 2,
                "repeated layout must not move the text pane outside its tab: \(pane.frame), \(tabs.contentRect)")
    }

    @Test(.freshHome) func wideLibraryGivesReadingPaneMostOfTheWidth() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(NSSize(width: 1600, height: 900))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let split = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.columns" } as? NSStackView)
        #expect(split.arrangedSubviews[0].frame.width >= 600, "document \(split.arrangedSubviews[0].frame)")
        #expect(split.arrangedSubviews[2].frame.width <= 290, "inspector \(split.arrangedSubviews[2].frame)")
    }
}
