import AppKit
import Foundation
import Testing
@testable import verbemo

@Suite(.serialized)
@MainActor
struct RecordingWorkspaceTests {
    @Test(.freshHome, .speaking(.english))
    func liveModelProgressPreservesTheSavedMeetingBeingRead() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let saved = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try Data(#"{"title":"Saved meeting"}"#.utf8).write(to: saved.appendingPathComponent("meta.json"))
        let words = (0..<300).map { "Paragraph \($0): a long summary to keep reading during capture." }.joined(separator: "\n\n")
        try Data(words.utf8).write(to: saved.appendingPathComponent("summary.md"))
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(NSSize(width: 1340, height: 820))
        let active = MeetingPresentation.ActiveRecording(dir: root.appendingPathComponent("active"), title: "Recording",
            started: Date(), paused: false, liveStatus: .downloading(0.1))
        library.setActiveRecording(active)
        app.show()
        #expect(await library.reveal(saved))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let text = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTextView }.first { $0.string.contains("Paragraph 299") })
        text.layoutManager?.ensureLayout(for: try #require(text.textContainer))
        text.scrollToEndOfDocument(nil)
        let clip = try #require(text.enclosingScrollView?.contentView)
        let offset = clip.bounds.origin
        try #require(offset.y > 0)
        for status in [LiveTranscriptionCoordinator.Status.downloading(0.2), .downloading(0.3), .loading, .live] {
            var update = active
            update.liveStatus = status
            library.setActiveRecording(update)
            app.panel.contentView?.layoutSubtreeIfNeeded()
            #expect(clip.bounds.origin == offset, "An active recording update must not move the saved summary")
        }
    }

    @Test(.freshHome, .speaking(.english), arguments: [760, 1340])
    func currentRecordingKeepsItsInspectorAndLiveText(width: Int) throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let session = try RecordingSession(root: root, context: MeetingContext(title: "Current meeting"),
            mic: FakeMicRecorder(), system: FakeSystemRecorder())
        try session.start()
        defer { session.stop(reason: "manual") }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        library.setActiveRecording(.init(dir: session.dir, title: "Current meeting", started: session.startedAt,
            paused: false, liveStatus: .live))
        app.update(state: .recording, elapsed: "03:06")
        app.recordingTitle = "Current meeting"
        app.panel.setContentSize(NSSize(width: width, height: 820))
        let search = try #require(library.listContentView.allDescendants.first { $0 is NSSearchField } as? NSSearchField)
        search.stringValue = "no match"
        library.applyFilter(.attention)
        app.navigate(.general)
        app.showActiveRecording()
        app.updateLive(.init(isRecording: true, isEnabled: true,
            entries: [.speech(.init(speaker: .you, text: "Visible during the meeting", startMilliseconds: 0, isProvisional: true))],
            status: .live))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let inspector = try #require(app.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "meeting.inspector-content" })
        let button = try #require(app.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "meeting.inspector" } as? NSButton)
        if width == 760 {
            #expect(inspector.isHidden)
            #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        }
        #expect(!inspector.isHiddenOrHasHiddenAncestor)
        #expect(inspector.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Transcribing live" })
        if width == 760 { _ = NSApp.sendAction(try #require(button.action), to: button.target, from: button) }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let text = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSTextView }
            .first { $0.string.contains("Visible during the meeting") })
        #expect(!text.isHiddenOrHasHiddenAncestor)
        #expect(text.visibleRect.height > 0)
        #expect(search.stringValue.isEmpty)
        #expect(library.currentFilter == .allMeetings)
        #expect(app.panel.contentLayoutRect.width <= CGFloat(width + 2))
        app.show()
        library.beginRenamingMeeting()
        let name = try #require(app.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "recording-title" } as? NSTextField)
        #expect(name.currentEditor() != nil, "The shared Rename action must edit the visible live title")
        app.panel.makeFirstResponder(nil)
        app.update(state: .paused, elapsed: "03:06")
        app.showActiveRecording()
        #expect(text.window === app.panel)
    }

    @Test(.freshHome) func recordingControlsFollowRuntimeAcrossDestinations() {
        let app = ApplicationWindow()
        var starts = 0
        var pauses = 0
        app.onToggle = { starts += 1; app.update(state: .recording, elapsed: "00:01") }
        app.onTogglePause = { pauses += 1; app.update(state: .paused, elapsed: "00:01") }
        app.startRecording()
        app.startRecording()
        #expect(starts == 1)
        #expect(app.recordingBarIsVisible)
        app.navigate(.general)
        #expect(app.recordingBarIsVisible)
        app.pauseRecording()
        #expect(pauses == 1)
        app.showActiveRecording()
        #expect(app.navigation.destination == .allMeetings)
        app.hide()
        #expect(starts == 1)
        #expect(app.recordingBarIsVisible)
    }
    @Test(.freshHome) func failedStartDoesNotPresentLiveAsRecording() {
        let app = ApplicationWindow()
        var attempts = 0
        app.onToggle = { attempts += 1 }
        app.startRecording()
        #expect(attempts == 1)
        #expect(!app.recordingBarIsVisible)
        #expect(!app.navigation.showsDetail)
    }
    @Test(.freshHome) func liveTitleRenamesOnlyTheSessionAndPersistsRecoveryManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root, context: MeetingContext(title: "Calendar title"),
            mic: FakeMicRecorder(), system: FakeSystemRecorder())
        try session.start()
        try session.rename(to: "  Новое название  ")
        #expect(session.title == "Новое название")
        #expect(session.context.title == "Calendar title")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: session.dir.appendingPathComponent(".recording.json"))) as! [String: Any]
        #expect(manifest["title"] as? String == "Новое название")
        #expect(throws: (any Error).self) { try session.rename(to: "  ") }
        session.stop(reason: "manual")
        #expect(SessionState.read(session.dir)?["title"] as? String == "Новое название")
    }
}
