import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome) @MainActor
struct BulkRecordingSelectionTests {
    @Test func selectionSurvivesInsertionAndContextClickInsideTheSet() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        for name in ["one", "two", "three"] { try session(name, in: root) }
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        defer { _ = library.stopForTermination(); app.hide() }
        let table = try table(in: library)
        #expect(table.allowsMultipleSelection)
        #expect(table.accessibilityLabel()?.isEmpty == false)
        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        let chosen = Set(library.selectedMeetings.map(\.dir))
        table.onContext?(2)
        #expect(Set(library.selectedMeetings.map(\.dir)) == chosen)
        try session("new", in: root, started: "2026-11-14T10:00:00Z")
        library.refresh(); await library.settled()
        #expect(Set(library.selectedMeetings.map(\.dir)) == chosen)
        let outside = try #require((0..<table.numberOfRows).first { !table.selectedRowIndexes.contains($0) })
        table.onContext?(outside)
        #expect(library.selectedMeetings.count == 1)
        table.selectAll(nil)
        #expect(library.selectedMeetings.count == 4)
    }

    @Test func confirmedIdentitiesSurviveSearchAndPartialFailure() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let first = try session("one", in: root)
        let failed = try session("two", in: root)
        let excluded = try session("three", in: root)
        var recycled: [URL] = []
        let deletion = SessionDeletionController(delay: 0) { dir, completion in
            recycled.append(dir)
            if dir.lastPathComponent == failed.lastPathComponent { completion(CocoaError(.fileWriteNoPermission)) }
            else {
                do { try FileManager.default.removeItem(at: dir); completion(nil) }
                catch { completion(error) }
            }
        }
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, hostWindow: app.panel, deletion: deletion)
        app.libraryProvider = { library }
        defer { _ = library.stopForTermination(); app.hide() }
        let table = try table(in: library)
        table.selectAll(nil)
        let confirmed = library.selectedMeetings.filter { $0.dir.lastPathComponent != excluded.lastPathComponent }
        let field = try #require(library.listContentView.allDescendants.first { $0.identifier?.rawValue == "library.search" } as? NSSearchField)
        field.stringValue = "three"
        #expect(field.sendAction(field.action, to: field.target))
        await library.settled()
        #expect(library.selectedMeetings.map { $0.dir.lastPathComponent } == [excluded.lastPathComponent])
        library.deleteConfirmed(confirmed)
        for _ in 0..<100 where deletion.hasWork { try await Task.sleep(for: .milliseconds(10)) }
        await library.settled()
        #expect(Set(recycled.map(\.lastPathComponent)) == Set([first, failed].map(\.lastPathComponent)))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: failed.path))
        #expect(FileManager.default.fileExists(atPath: excluded.path))
        #expect(!SessionClaim.isHeld(failed))
        let notice = try #require(library.serviceViews.first { $0.identifier?.rawValue == "meeting.deletion-notice" })
        #expect(notice.allDescendants.compactMap { ($0 as? NSTextField)?.toolTip }.contains { $0.contains("two") })
    }

    @Test func busyRecordingsAreKeptAndUndoRestoresTheWholePendingSet() throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let active = try session("active", in: root)
        let claimed = try session("claimed", in: root)
        let queued = try session("queued", in: root)
        for name in ["one", "two"] { try session(name, in: root) }
        try Data("{}".utf8).write(to: active.appendingPathComponent(".recording.json"))
        try SessionClaim.acquire(claimed, stage: .transcribe)
        defer { SessionClaim.release(claimed) }
        let operations = ProcessingOperations()
        _ = try operations.register(session: queued, kind: .transcription)
        let deletion = SessionDeletionController(delay: 60) { _, _ in Issue.record("Undo must not touch any files") }
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, operations: operations, hostWindow: app.panel, deletion: deletion)
        app.libraryProvider = { library }
        defer { _ = library.stopForTermination(); app.hide() }
        let table = try table(in: library)
        table.selectAll(nil)
        library.deleteConfirmed(library.selectedMeetings)
        #expect(!deletion.isPending(active) && !deletion.isPending(claimed) && !deletion.isPending(queued))
        #expect(deletion.pendingCount == 2)
        let notice = try #require(library.serviceViews.first { $0.identifier?.rawValue == "meeting.deletion-notice" })
        let undo = try #require(notice.allDescendants.compactMap { $0 as? NSButton }.first)
        #expect(undo.sendAction(undo.action, to: undo.target))
        #expect(deletion.pendingCount == 0)
        #expect(!notice.isHidden, "Busy-item failures remain visible after Undo")
        for name in ["one", "two"] {
            #expect(!SessionClaim.isHeld(root.appendingPathComponent(name)))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        library.deleteConfirmed(SessionInventory.scan(root: root).filter { ["one", "two"].contains($0.name) })
        #expect(deletion.pendingCount == 2)
        #expect(undo.sendAction(undo.action, to: undo.target))
        #expect(deletion.pendingCount == 0)
        #expect(notice.isHidden, "A fully undone group leaves no empty notice")
    }

    private func table(in library: MeetingLibraryController) throws -> MeetingTableView {
        try #require(library.listContentView.allDescendants.compactMap { $0 as? MeetingTableView }.first)
    }

    @discardableResult private func session(_ name: String, in root: URL, started: String = "2026-11-13T10:00:00Z") throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["title": name, "started": started, "duration_seconds": 60])
            .write(to: dir.appendingPathComponent("meta.json"))
        return dir.standardizedFileURL.resolvingSymlinksInPath()
    }
}
