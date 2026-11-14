import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome) @MainActor
struct RecordingSelectionTests {
    @Test(.speaking(.english), arguments: [false, true], [false, true])
    func stoppingPreservesTheMeetingBeingRead(navigatedAway: Bool, saveFails: Bool) async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = root.appendingPathComponent("2026-01-01")
        try FileManager.default.moveItem(at: SessionFixture.make(meta: ["title": "Previous meeting"]), to: saved)
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.show()
        #expect(await library.reveal(saved))
        let session = try RecordingSession(root: root, context: MeetingContext(title: "New recording"),
            mic: FakeMicRecorder(), system: FakeSystemRecorder(), writeFile: { data, url in
                if saveFails && url.lastPathComponent == "meta.json" { throw DiskFull() }
                try RecordingSession.durableWrite(data, url)
            })
        try session.start()
        app.recordingTitle = "New recording"
        app.update(state: .recording, elapsed: "00:01")
        library.setActiveRecording(.init(dir: session.dir, title: "New recording", started: session.startedAt,
            paused: false, liveStatus: .idle))
        app.showActiveRecording()
        if navigatedAway { #expect(await library.reveal(saved)) }
        let title = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "meeting.title" })
        let expected = navigatedAway ? "Previous meeting" : "New recording"
        #expect(title.stringValue == expected)
        #expect(session.stop(reason: "manual") == !saveFails)
        // Match AppController.present: window state first, library publication second.
        app.update(state: .idle, elapsed: nil)
        library.setActiveRecording(nil)
        #expect(title.stringValue == expected, "Publishing idle must not briefly select an unrelated meeting")
        await session.finishCapture()
        library.refresh()
        await library.settled()
        #expect(title.stringValue == expected, "The next inventory scan must preserve the same meeting")
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? MeetingTableView }.first)
        let row = try #require(table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true))
        #expect(row.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == expected })
        #expect(!app.recordingBarIsVisible)
        #expect(library.activeRecordingView?.isHiddenOrHasHiddenAncestor == true)
        if saveFails {
            #expect(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent(".recording.json").path))
            let error = try #require(library.serviceViews.compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "meeting.operation-error" })
            #expect(!error.isHidden && error.stringValue.contains("metadata could not be saved"))
            #expect(!library.attentionMeetings.contains { $0.problems.contains { $0.contains("Transcription failed") } })
        }
        let field = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSSearchField }.first)
        field.stringValue = expected
        #expect(field.sendAction(field.action, to: field.target))
        await library.settled()
        #expect(title.stringValue == expected)
        #expect(table.numberOfRows == 1)

        // Recovery or processing replaces the temporary row with disk state, once.
        if saveFails {
            try JSONSerialization.data(withJSONObject: ["title": "New recording"])
                .write(to: session.dir.appendingPathComponent("meta.json"))
        }
        let entered = Gate(), release = Gate()
        defer { release.open() }
        let ticket = try ProcessingOperations.shared.register(session: session.dir, kind: .transcription)
        let processing = Task { try await ticket.run { entered.open(); await release.pass() } }
        await entered.pass()
        app.activityBar.updateWork(ProcessingOperations.shared.snapshot()) { library.activityTitle(for: $0) }
        library.refresh()
        await library.settled()
        #expect(title.stringValue == expected, "Starting processing must preserve the reading context")
        release.open()
        try await processing.value
        try Transcript(engine: "test", model: "test", created_at: "2026-11-14T10:00:00Z", segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Completed recording")
        ]).write(to: session.dir)
        library.sessionsChanged()
        await library.settled()
        #expect(title.stringValue == expected)
        #expect(table.numberOfRows == 1)
        field.stringValue = ""
        #expect(field.sendAction(field.action, to: field.target))
        await library.settled()
        #expect(table.numberOfRows == 2, "The recovered row must not duplicate its temporary snapshot")
        #expect(title.stringValue == expected)
    }
}
