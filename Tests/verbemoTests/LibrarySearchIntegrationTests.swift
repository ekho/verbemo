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
