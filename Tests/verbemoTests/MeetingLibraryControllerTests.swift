import AppKit
import Foundation
import Testing

@testable import verbemo

/// The Journal library keeping up with a folder that other things write
/// into: the transcription queue, a moved recordings folder, a session that
/// is still being worked on.
@Suite(.serialized, .freshHome)
@MainActor
struct MeetingLibraryControllerTests {
    @Test("Diarization details distinguish confirmed speakers, unknown speech and retained retry audio")
    func diarizationDetails() {
        var state = DiarizationState(
            request: .init(engine: "parakeet", threshold: 0.6), status: .failed)
        state.confirmedSpeakers = 3
        state.hasUnknown = true
        state.rejectedTurnCount = 2
        state.reason = "Model unavailable"
        let line = MeetingLibraryController.diarizationLine(state)
        #expect(line.contains("failed"))
        #expect(line.contains("3 confirmed speakers"))
        #expect(line.contains("some speech has no speaker"))
        #expect(line.contains("ignored 2 invalid speaker turns"))
        #expect(line.contains("audio kept for retry"))
        #expect(line.contains("Model unavailable"))
        state.status = .completed
        #expect(!MeetingLibraryController.diarizationLine(state).contains("audio kept for retry"))
    }

    @Test("An unreadable saved speaker request shows a blocked status in English",
          .freshHome, .speaking(.english))
    func unreadableDiarizationEnglish() throws {
        try assertUnreadableDiarizationStatus(
            "Diarization: saved model request cannot be read. Processing is blocked.")
    }

    @Test("An unreadable saved speaker request shows a blocked status in Russian",
          .freshHome, .speaking(.russian))
    func unreadableDiarizationRussian() throws {
        try assertUnreadableDiarizationStatus(
            "Диаризация: не удалось прочитать сохранённый запрос модели. Обработка заблокирована.")
    }

    private func assertUnreadableDiarizationStatus(_ expected: String) throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-unknown-model", in: root)
        try SessionState.amend(dir, with: [DiarizationState.key: [
            "request": ["engine": "parakeet", "threshold": 0.6, "model": "future-model"],
            "status": "pending",
        ]])
        #expect(SessionInventory.item(for: dir)?.unreadableDiarization == true)
        let app = ApplicationWindow()
        let recordings = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { recordings }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let views = recordings.contentView.allDescendants
        let status = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "diarization.status" })
        #expect(!status.isHidden)
        #expect(status.stringValue == expected)
        #expect(status.toolTip == expected)
        for id in ["diarization.retry", "diarization.skip"] {
            let button = try #require(views.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == id })
            #expect(button.isHidden)
            #expect(!button.isEnabled)
        }
        withExtendedLifetime(recordings) {}
    }

    private static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbemo-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private static func session(_ name: String, in root: URL) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "started": "2026-09-28T09:00:00Z", "duration_seconds": 600, "title": name,
        ]).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private static func transcribe(_ dir: URL) throws {
        try JSONEncoder().encode(Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-09-28T09:11:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hello.")]
        )).write(to: dir.appendingPathComponent("transcript.json"))
    }

    private static func meetingTitles(_ library: MeetingLibraryController) throws -> [String] {
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSTableView }.first)
        return (0..<table.numberOfRows).flatMap { row in
            library.tableView(table, viewFor: table.tableColumns.first, row: row)?
                .allDescendants.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        }
    }

    @Test("Selecting another recording replaces both previews, including missing files")
    func previewsFollowSelection() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try Self.session("2026-09-28-100000-first", in: root)
        try Self.transcribe(first)
        try Data("A decision from the first meeting.".utf8)
            .write(to: first.appendingPathComponent("summary.md"))
        try Self.session("2026-09-28-090000-second", in: root)
        let app = ApplicationWindow()
        let window = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { window }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let views = window.contentView.allDescendants
        let table = try #require(window.listContentView.allDescendants.compactMap { $0 as? NSTableView }.first)
        let tabs = try #require(views.compactMap { $0 as? NSTabView }.first)
        let summary = try #require(tabs.tabViewItems.first { ($0.identifier as? String) == "summary" }?.view?
            .allDescendants.compactMap { $0 as? NSTextView }.first)
        let transcript = try #require(tabs.tabViewItems.first { ($0.identifier as? String) == "transcript" }?.view?
            .allDescendants.compactMap { $0 as? NSTextView }.first)
        let firstRow = try #require((0..<table.numberOfRows).first { row in
            window.tableView(table, viewFor: table.tableColumns.first, row: row)?
                .allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("2026-09-28-100000-first") == true
        })
        table.selectRowIndexes([firstRow], byExtendingSelection: false)
        #expect(summary.string == "A decision from the first meeting.")
        #expect(transcript.string.contains("Hello."))
        #expect(!summary.isEditable && summary.isSelectable)
        table.selectRowIndexes([table.selectedRow == 0 ? 1 : 0], byExtendingSelection: false)
        #expect(!summary.string.contains("first meeting"))
        #expect(!transcript.string.contains("Hello."))
        table.deselectAll(nil)
        #expect(summary.string.isEmpty && transcript.string.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test("Recording previews display Markdown headings, lists, emphasis and links")
    func previewsRenderMarkdown() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-meeting", in: root)
        let markdown = "# Decisions\n\nA **bold** decision.\n\n- First\n- Second\n\n1. Next\n2. Last\n\n[Reference](https://example.com)"
        for file in ["summary.md", "transcript.md"] {
            try Data(markdown.utf8).write(to: dir.appendingPathComponent(file))
        }
        let app = ApplicationWindow()
        let recordings = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { recordings }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let tabs = try #require(recordings.contentView.allDescendants.compactMap { $0 as? NSTabView }.first)
        for identifier in ["summary", "transcript"] {
            let text = try #require(tabs.tabViewItems.first { ($0.identifier as? String) == identifier }?.view?
                .allDescendants.compactMap { $0 as? NSTextView }.first)
            #expect(text.string == "Decisions\nA bold decision.\n• First\n• Second\n1. Next\n2. Last\nReference")
            let storage = try #require(text.textStorage)
            let heading = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(heading.pointSize > 13)
            let boldRange = (text.string as NSString).range(of: "bold")
            let bold = try #require(storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
            #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
            let linkRange = (text.string as NSString).range(of: "Reference")
            #expect(storage.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
                    == URL(string: "https://example.com"))
        }
        withExtendedLifetime(recordings) {}
    }

    @Test("Making the application window taller gives the space to the Journal document")
    func recordingContentFillsWindow() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let columns = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.columns" })
        app.panel.setContentSize(NSSize(width: 1340, height: 700))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let before = columns.frame.height
        app.panel.setContentSize(NSSize(width: 1340, height: 900))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(columns.frame.height >= before + 190)
        #expect(library.contentView.window === app.panel)
        #expect(!library.contentView.allDescendants.contains { $0 is NSSplitView })
    }

    @Test("Long speaker excerpts leave name fields visible in the inspector")
    func speakerFieldsStayVisible() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-meeting", in: root)
        try JSONEncoder().encode(Transcript(
            engine: "assemblyai", model: "universal", created_at: "2026-09-28T09:11:00Z",
            segments: (0..<20).map { index in
                .init(speaker: index.isMultiple(of: 2) ? "A" : "B", start_ms: index * 1000,
                      end_ms: (index + 1) * 1000, text: "We discussed the plans for our next meeting and the work ahead.")
            }
        )).write(to: dir.appendingPathComponent("transcript.json"))
        let app = ApplicationWindow()
        let recordings = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { recordings }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let view = recordings.contentView
        app.panel.setContentSize(NSSize(width: 1340, height: 820))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let inspector = try #require(view.allDescendants.first { $0.identifier?.rawValue == "meeting.inspector-content" })
        let speaker = try #require(inspector.allDescendants.compactMap { $0 as? MeetingSpeakerView }.first)
        let edit = try #require(speaker.allDescendants.compactMap { $0 as? NSButton }.first)
        #expect(edit.sendAction(edit.action, to: edit.target))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(inspector.allDescendants.compactMap { $0 as? NSScrollView }.first)
        let field = try #require(speaker.allDescendants.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let visible = field.convert(field.bounds, to: scroll.contentView)
        #expect(visible.intersects(scroll.contentView.bounds), "the excerpt must not push names out of view")
        withExtendedLifetime(recordings) {}
    }

    @Test("Long speaker excerpts do not increase the window's minimum width")
    func speakersDoNotForceWindowWider() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-meeting", in: root)
        let longText = String(repeating: "We discussed the next meeting and agreed on the plan. ", count: 30)
        try JSONEncoder().encode(Transcript(
            engine: "assemblyai", model: "universal", created_at: "2026-09-28T09:11:00Z",
            segments: [.init(speaker: "A", start_ms: 0, end_ms: 1000, text: longText)]
        )).write(to: dir.appendingPathComponent("transcript.json"))
        let app = ApplicationWindow()
        let recordings = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { recordings }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let view = recordings.contentView
        app.panel.setContentSize(NSSize(width: 760, height: 700))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        recordings.updateCompactLayout()
        let inspector = try #require(view.allDescendants.first { $0.identifier?.rawValue == "meeting.inspector-content" })
        let toggle = try #require(recordings.toolbarContent.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "meeting.inspector" })
        #expect(inspector.isHidden)
        #expect(toggle.sendAction(toggle.action, to: toggle.target))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(!inspector.isHidden)
        #expect(inspector.frame.width <= view.bounds.width + 1)
        #expect(app.panel.contentView?.bounds.width == 760)
        withExtendedLifetime(recordings) {}
    }

    @Test("Switching meetings keeps the speaker inspector anchored beside the document")
    func speakerPaneDoesNotDrift() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["2026-09-28-100000-first", "2026-09-28-090000-second"] {
            try Self.transcribe(Self.session(name, in: root))
        }
        let app = ApplicationWindow()
        let recordings = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { recordings }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let view = recordings.contentView
        let table = try #require(recordings.listContentView.allDescendants.compactMap { $0 as? NSTableView }.first)
        let inspector = try #require(view.allDescendants.first { $0.identifier?.rawValue == "meeting.inspector-content" })
        app.panel.setContentSize(NSSize(width: 1340, height: 820))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let original = inspector.frame
        for index in 0..<12 {
            table.selectRowIndexes([index % 2], byExtendingSelection: false)
            app.panel.contentView?.layoutSubtreeIfNeeded()
            #expect(inspector.frame == original)
            #expect(inspector.allDescendants.contains { $0 is MeetingSpeakerView })
        }
        withExtendedLifetime(recordings) {}
    }

    /// It read the folder when it was opened and never again, so a meeting
    /// transcribed while it was open went on showing as waiting, and Finish
    /// processing acted on what the window last saw.
    @Test("A transcript finished while the window is open shows up in it")
    func finishedWorkIsShown() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-standup", in: root)

        let app = ApplicationWindow()
        let window = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { window }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        app.show()
        defer { withExtendedLifetime(window) {} }
        let before = window.currentActions.transcriptReady

        try Self.transcribe(dir)
        window.sessionsChanged()
        await window.settled()

        #expect(!before)
        #expect(window.currentActions.transcriptReady, "the Journal still shows the transcript as owed")
        app.panel.orderOut(nil)
    }

    @Test("A closed window does not read the folder until it is opened")
    func closedWindowWaits() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = ApplicationWindow()
        let window = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { window }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        defer { withExtendedLifetime(window) {} }
        await window.settled()
        try Self.session("2026-09-28-100000-later", in: root)
        window.sessionsChanged()
        await window.settled()
        #expect(try !Self.meetingTitles(window).contains("2026-09-28-100000-later"))
    }

    @Test("Moved to another recordings folder, the window lists that folder")
    func anotherFolderIsListed() async throws {
        let first = try Self.folder()
        let second = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try Self.session("2026-09-28-090000-old-folder", in: first)
        try Self.session("2026-09-28-090000-new-folder", in: second)

        let app = ApplicationWindow()
        let window = MeetingLibraryController(root: first, hostWindow: app.panel)
        app.libraryProvider = { window }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        defer { withExtendedLifetime(window) {} }
        #expect(try Self.meetingTitles(window).contains("2026-09-28-090000-old-folder"))

        window.setRoot(second)
        await window.settled()
        #expect(try Self.meetingTitles(window).contains("2026-09-28-090000-new-folder"))
        #expect(try !Self.meetingTitles(window).contains("2026-09-28-090000-old-folder"))
    }

    /// Delete moved a folder to the Trash while the transcription queue was
    /// writing into it.
    @Test("A recording something is working on cannot be deleted, and says why")
    func heldSessionIsNotDeleted() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-busy", in: root)

        #expect(MeetingLibraryController.deleteRefusal(for: dir) == nil)

        try SessionClaim.acquire(dir, stage: .transcribe)
        let why = MeetingLibraryController.deleteRefusal(for: dir)
        SessionClaim.release(dir)

        #expect(why?.contains("working on this recording") == true)
        #expect(MeetingLibraryController.deleteRefusal(for: dir) == nil)
    }
}
