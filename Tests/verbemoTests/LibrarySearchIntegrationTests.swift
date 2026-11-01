import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome) @MainActor
struct LibrarySearchIntegrationTests {
    @Test func libraryFindsContentAndRefreshesChangedArtifacts() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let dir = try session(root, name: "one", text: "Кварцевый компас", summary: "Сапфировый маяк")
        _ = try session(root, name: "two", text: "Другая реплика", summary: "Другая сводка")
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        for query in ["КВАРЦЕВЫЙ компас", "сапфировый маяк"] {
            try await search(query, in: library)
            #expect(table.numberOfRows == 1)
            let row = try #require(library.tableView(table, viewFor: nil, row: 0))
            #expect(row.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Meeting one" })
        }
        try Data("Новая сводка".utf8).write(to: dir.appendingPathComponent("summary.md"))
        library.refresh()
        await library.settled()
        #expect(table.numberOfRows == 0)
        try await search("Новая сводка", in: library)
        #expect(table.numberOfRows == 1)
    }

    @Test func laterQueryAndNewRootCannotShowOldResults() async throws {
        let root = Home.current.url.appendingPathComponent("first")
        _ = try session(root, name: "old", text: "Only old-root phrase", summary: "")
        let next = Home.current.url.appendingPathComponent("next")
        _ = try session(next, name: "new", text: "Only new-root phrase", summary: "")
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let field = try #require(library.listContentView.allDescendants.first { $0.identifier?.rawValue == "library.search" } as? NSSearchField)
        field.stringValue = "old-root"
        #expect(field.sendAction(field.action, to: field.target))
        field.stringValue = "new-root"
        #expect(field.sendAction(field.action, to: field.target))
        library.setRoot(next)
        await library.settled()
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        #expect(table.numberOfRows == 1)
        let row = try #require(library.tableView(table, viewFor: nil, row: 0))
        #expect(row.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Meeting new" })
        #expect(field.stringValue == "new-root")
    }

    @Test func filteredEmptyResultDoesNotPretendTheLibraryIsEmpty() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        _ = try session(root, name: "one", text: "Actual text", summary: "")
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        try await search("no matching phrase", in: library)
        let title = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.title" } as? NSTextField)
        #expect(title.stringValue == "No matching meetings")
        try await search("", in: library)
        library.applyFilter(.processing)
        #expect(title.stringValue != "No recordings yet")
    }

    @Test func contentResultOpensCurrentVersionAndCorrectTab() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let dir = try session(root, name: "one", text: "Old archived words", summary: "Old summary")
        try TranscriptVersions.archiveCurrent(dir)
        try Transcript(engine: "whisper", model: "test", created_at: "2026-11-01T10:00:00Z", segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "😀 Кварцевый компас"),
        ]).write(to: dir)
        try Data("# Сапфи**ровый** маяк".utf8).write(to: dir.appendingPathComponent("summary.md"))
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        let versions = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "transcript-versions" } as? NSPopUpButton)
        let tabs = try #require(library.contentView.allDescendants.first { $0 is NSTabView } as? NSTabView)
        for (query, tab) in [("Кварцевый компас", "transcript"), ("Сапфировый маяк", "summary")] {
            try await search(query, in: library)
            versions.selectItem(at: 0)
            #expect(versions.sendAction(versions.action, to: versions.target))
            #expect(table.sendAction(table.action, to: table.target))
            #expect(versions.indexOfSelectedItem == 1)
            #expect(tabs.selectedTabViewItem?.identifier as? String == tab)
            #expect(library.meetingSearchQuery == query)
            let index = try #require(library.meetingSearchIndex)
            #expect(library.meetingSearchHits[index].tab == tab)
            if tab == "transcript" { #expect(library.meetingSearchHits[index].segment == 0) }
        }
    }

    @Test func snippetsFitResizedLibraryAndKeyboardSelectionNavigates() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        for name in ["one", "two"] {
            _ = try session(root, name: name, text: String(repeating: "Контекст ", count: 5) + "Кварцевый компас " + String(repeating: "продолжение ", count: 20), summary: "")
        }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(.init(width: 1340, height: 600))
        app.show()
        try await search("Кварцевый компас", in: library)
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        let split = try #require(app.panel.contentView?.allDescendants.first { $0 is WorkspaceSplitView } as? NSSplitView)
        for width in [220.0, 400] {
            split.setPosition(width, ofDividerAt: 0)
            app.panel.contentView?.layoutSubtreeIfNeeded()
            let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            row.layoutSubtreeIfNeeded()
            let snippet = try #require(row.allDescendants.first { $0.identifier?.rawValue == "meeting.list-snippet" } as? NSTextField)
            #expect(snippet.stringValue.contains("Transcript"))
            #expect(snippet.stringValue.contains("Кварцевый компас"))
            #expect(snippet.maximumNumberOfLines == 2)
            let frame = snippet.convert(snippet.bounds, to: row)
            let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: try #require(snippet.font)))
            #expect(frame.height <= 2 * lineHeight + 1, "The rendered snippet must fit two actual native text lines")
            let match = (snippet.stringValue as NSString).range(of: "Кварцевый компас")
            let leadingText = snippet.attributedStringValue.attributedSubstring(from: .init(location: 0, length: NSMaxRange(match)))
            #expect(leadingText.boundingRect(with: .init(width: frame.width, height: 1000), options: [.usesLineFragmentOrigin]).height <= 2 * lineHeight + 1,
                    "The matching phrase must be visible within the two lines")
            #expect(frame.maxY <= row.bounds.height - 8)
            #expect(frame.width >= 150)
        }
        table.selectRowIndexes([1], byExtendingSelection: false)
        #expect(library.meetingSearchQuery == "Кварцевый компас")
        #expect(library.meetingSearchIndex != nil)
    }

    @Test func changedContentResultRefreshesInsteadOfOpeningStaleHit() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let dir = try session(root, name: "one", text: "Old compass", summary: "")
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        try await search("compass", in: library)
        try Transcript(engine: "whisper", model: "test", created_at: "2026-11-01T10:00:00Z", segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Changed text"),
        ]).write(to: dir)
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        #expect(table.sendAction(table.action, to: table.target))
        #expect(library.meetingSearchIndex == nil)
        await library.settled()
        #expect(table.numberOfRows == 0)
    }

    @Test func incompleteSearchAndResetKeepAbsenceHonest() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let dir = try session(root, name: "one", text: "Actual text", summary: "")
        try Data("{ broken".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        library.applyFilter(.attention)
        try await search("absent", in: library)
        let title = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.title" } as? NSTextField)
        #expect(title.stringValue == "Search incomplete")
        let status = try #require(library.listContentView.allDescendants.first { $0.identifier?.rawValue == "library.search-status" } as? NSTextField)
        #expect(!status.isHidden)
        #expect(status.stringValue.contains("could not be searched"))
        let reset = try #require(library.listContentView.allDescendants.first { $0.identifier?.rawValue == "library.reset" } as? NSButton)
        #expect(reset.sendAction(reset.action, to: reset.target))
        #expect(library.currentFilter == .allMeetings)
        #expect(status.isHidden)
        #expect(title.stringValue == "Meeting one")
    }

    @Test func legacyResultCannotSilentlyNavigateIntoAnArchive() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let dir = try session(root, name: "one", text: "Archived compass", summary: "")
        try TranscriptVersions.archiveCurrent(dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.json"))
        try Data("Current compass".utf8).write(to: dir.appendingPathComponent("transcript.md"))
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        try await search("compass", in: library)
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        #expect(table.sendAction(table.action, to: table.target))
        await library.settled()
        #expect(library.meetingSearchIndex == nil)
        let status = try #require(library.listContentView.allDescendants.first { $0.identifier?.rawValue == "library.search-status" } as? NSTextField)
        #expect(status.stringValue.contains("could not be opened"))
    }

    @Test func shutdownAwaitsCancelledQueriesWithoutApplyingTheirResults() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        _ = try session(root, name: "one", text: "compass", summary: "")
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        let field = try #require(library.listContentView.allDescendants.first { $0.identifier?.rawValue == "library.search" } as? NSSearchField)
        field.stringValue = "compass"
        #expect(field.sendAction(field.action, to: field.target))
        let cleanup = library.stopForTermination()
        for task in cleanup { await task.value }
        await library.settled()
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        #expect(table.numberOfRows == 0)
    }

    @Test func refreshPreservesContentSelectionVersionAndLocalSearch() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        for name in ["one", "two"] {
            let dir = try session(root, name: name, text: "Archived beacon", summary: "")
            try Transcript(engine: "whisper", model: "old", created_at: "2026-10-31T10:00:00Z", segments: (0..<80).map {
                .init(speaker: "me", start_ms: $0 * 1000, end_ms: ($0 + 1) * 1000, text: "Archived beacon \($0)")
            }).write(to: dir)
            try TranscriptVersions.archiveCurrent(dir)
            try Transcript(engine: "whisper", model: "test", created_at: "2026-11-01T10:00:00Z", segments: [
                .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Current compass"),
            ]).write(to: dir)
        }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.show()
        app.panel.contentView?.layoutSubtreeIfNeeded()
        try await search("compass", in: library)
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        table.selectRowIndexes([1], byExtendingSelection: false)
        let versions = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "transcript-versions" } as? NSPopUpButton)
        versions.selectItem(at: 0)
        #expect(versions.sendAction(versions.action, to: versions.target))
        library.setMeetingSearchQuery("beacon")
        for _ in 0..<26 { library.moveMeetingSearch(forward: true) }
        let transcript = try #require(library.contentView.allDescendants.first { $0 is MeetingTranscriptView } as? MeetingTranscriptView)
        let reading = try #require(transcript.readingPosition())
        let title = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.title" } as? NSTextField)
        let before = title.stringValue
        library.refresh()
        await library.settled()
        #expect(title.stringValue == before)
        #expect(table.selectedRow == 1)
        #expect(versions.indexOfSelectedItem == 0)
        #expect(library.meetingSearchQuery == "beacon")
        #expect(library.meetingSearchIndex == 25)
        #expect(transcript.readingPosition()?.segment == reading.segment)
        #expect(abs((transcript.readingPosition()?.offset ?? -1000) - reading.offset) < 1)
        try await search("compass", in: library)
        #expect(title.stringValue == before)
        #expect(versions.indexOfSelectedItem == 0)
        #expect(library.meetingSearchQuery == "beacon")
    }

    @Test func newlyCommittedTranscriptInvalidatesAnEarlierSummaryHit() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let dir = try session(root, name: "one", text: "Original", summary: "Old beacon")
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        try await search("beacon", in: library)
        try TranscriptVersions.commit(.init(engine: "whisper", model: "test", created_at: "2026-11-01T10:00:00Z", segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Replacement"),
        ]), to: dir)
        #expect(!PostProcessor.hasCurrentSummary(dir))
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        #expect(table.sendAction(table.action, to: table.target))
        await library.settled()
        #expect(table.numberOfRows == 0)
        #expect(library.meetingSearchIndex == nil)
    }

    private func search(_ query: String, in library: MeetingLibraryController) async throws {
        let field = try #require(library.listContentView.allDescendants.first { $0.identifier?.rawValue == "library.search" } as? NSSearchField)
        field.stringValue = query
        #expect(field.sendAction(field.action, to: field.target))
        await library.settled()
    }
    private func session(_ root: URL, name: String, text: String, summary: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent(name)
        try FileManager.default.moveItem(at: SessionFixture.make(segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: text),
        ], meta: ["title": "Meeting \(name)"]), to: dir)
        try Data(summary.utf8).write(to: dir.appendingPathComponent("summary.md"))
        return dir
    }
}
