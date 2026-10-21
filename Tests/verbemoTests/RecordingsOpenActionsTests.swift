import AppKit
import Foundation
import Testing

@testable import verbemo

@Suite(.serialized, .freshHome)
struct RecordingsOpenActionsTests {
    @Test("Open Transcript is available from the meeting menu for a finished transcript")
    @MainActor
    func transcriptButtonTracksReadableFile() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbemo-open-actions-\(UUID().uuidString)")
        let session = root.appendingPathComponent("2026-09-23-120000-meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: session.appendingPathComponent("meta.json"))

        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSTableView }.first)
        let menu = try #require(table.menu)
        func editorItem() throws -> NSMenuItem {
            library.menuWillOpen(menu)
            return try #require(menu.items.first { $0.representedObject as? String == MeetingActionState.Action.openTranscript.rawValue })
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(try !editorItem().isEnabled)

        let transcript = Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-09-23T12:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hello.")]
        )
        try JSONEncoder().encode(transcript)
            .write(to: session.appendingPathComponent("transcript.json"))
        library.refresh()
        await library.settled()
        #expect(try editorItem().isEnabled)
        #expect(try editorItem().target === library)
        #expect(try editorItem().action != nil)

        try FileManager.default.removeItem(at: session.appendingPathComponent("transcript.json"))
        try Data("# Meeting\n".utf8).write(to: session.appendingPathComponent("transcript.md"))
        library.refresh()
        await library.settled()
        #expect(try !editorItem().isEnabled)
        #expect(MeetingLibraryController.readableTranscript(in: session)?.lastPathComponent == "transcript.md")
    }

    @Test("The transcript uses its default app and falls back to a text editor")
    @MainActor
    func transcriptOpeningFallsBackOnlyWhenNeeded() {
        let file = URL(fileURLWithPath: "/tmp/transcript.md")
        var opened: [String] = []

        MeetingLibraryController.openTranscript(file,
            openDefault: { url in
                #expect(url == file)
                opened.append("default")
                return true
            },
            openTextEdit: { _ in opened.append("TextEdit") })
        #expect(opened == ["default"])

        opened.removeAll()
        MeetingLibraryController.openTranscript(file,
            openDefault: { _ in
                opened.append("default")
                return false
            },
            openTextEdit: { url in
                #expect(url == file)
                opened.append("TextEdit")
            })
        #expect(opened == ["default", "TextEdit"])
    }

    @Test("A canonical transcript without Markdown is made readable before opening")
    @MainActor
    func missingMarkdownIsRebuilt() throws {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbemo-rebuild-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        let transcript = Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-09-23T12:00:00Z",
            segments: [
                .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hello, team."),
            ]
        )
        try JSONEncoder().encode(transcript)
            .write(to: session.appendingPathComponent("transcript.json"))

        let file = try #require(MeetingLibraryController.readableTranscript(in: session))
        #expect(file.lastPathComponent == "transcript.md")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Hello, team."))
    }

}
