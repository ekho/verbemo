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
        app.update(state: .recording, elapsed: "00:01")
        app.show()
        #expect(await library.reveal(saved))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let text = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTextView }.first { $0.string.contains("Paragraph 299") })
        text.layoutManager?.ensureLayout(for: try #require(text.textContainer))
        text.scrollToEndOfDocument(nil)
        let clip = try #require(text.enclosingScrollView?.contentView)
        let offset = clip.bounds.origin
        try #require(offset.y > 0)
        #expect(library.activeRecordingView?.isHiddenOrHasHiddenAncestor == true)
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
        let height = width == 760 ? 600 : 820
        app.panel.setContentSize(NSSize(width: width, height: height))
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
        let liveView = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? LiveTranscriptView }.first)
        #expect(library.toolbarContent.isDescendant(of: liveView), "Current-meeting commands stay inside the live meeting")
        let button = try #require(app.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "meeting.inspector" } as? NSButton)
        if width == 760 {
            #expect(inspector.isHidden)
            #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        }
        #expect(!inspector.isHiddenOrHasHiddenAncestor)
        #expect(inspector.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Transcription waits for the recording to finish" })
        #expect(library.calendarPicker.button.isEnabled)
        let bar = try #require(liveView.allDescendants.first { $0.identifier?.rawValue == "recording-bar" })
        let title = try #require(liveView.allDescendants.first { $0.identifier?.rawValue == "recording-title" })
        #expect(liveView.convert(bar.bounds, from: bar).maxY <= liveView.convert(title.bounds, from: title).minY)
        for id in ["meeting.processing-transcript", "meeting.processing-summary"] {
            let row = try #require(inspector.allDescendants.first { $0.identifier?.rawValue == id })
            let visibleButtons = row.allDescendants.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            #expect(visibleButtons.isEmpty)
        }
        if width == 760 { _ = NSApp.sendAction(try #require(button.action), to: button.target, from: button) }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(!bar.isHiddenOrHasHiddenAncestor)
        let text = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSTextView }
            .first { $0.string.contains("Visible during the meeting") })
        #expect(!text.isHiddenOrHasHiddenAncestor)
        #expect(text.visibleRect.height > 0)
        #expect(search.stringValue.isEmpty)
        #expect(library.currentFilter == .allMeetings)
        #expect(app.panel.contentLayoutRect.width <= CGFloat(width + 2))
        #expect(app.panel.contentLayoutRect.height <= CGFloat(height + 2))
        app.show()
        library.beginRenamingMeeting()
        let name = try #require(app.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "recording-title" } as? NSTextField)
        #expect(name.currentEditor() != nil, "The shared Rename action must edit the visible live title")
        app.panel.makeFirstResponder(nil)
        app.update(state: .paused, elapsed: "03:06")
        app.showActiveRecording()
        #expect(text.window === app.panel)
    }

    @Test(.freshHome) func recordingControlsFollowRuntimeAcrossDestinations() throws {
        let app = ApplicationWindow()
        var starts = 0
        var pauses = 0
        app.onToggle = {
            starts += 1
            app.update(state: starts == 1 ? .recording : .idle, elapsed: "00:01")
        }
        app.onTogglePause = { pauses += 1; app.update(state: .paused, elapsed: "00:01") }
        app.startRecording()
        app.startRecording()
        #expect(starts == 1)
        #expect(app.recordingBarIsVisible)
        app.navigate(.general)
        #expect(app.recordingBarIsVisible)
        #expect(app.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "recording-bar" } == nil)
        app.pauseRecording()
        #expect(pauses == 1)
        app.showActiveRecording()
        #expect(app.navigation.destination == .allMeetings)
        #expect(app.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "recording-bar" }?.isHiddenOrHasHiddenAncestor == false)
        app.hide()
        #expect(starts == 1)
        #expect(app.recordingBarIsVisible)
        app.show()
        let toggle = try #require(app.panel.contentView?.allDescendants.first {
            $0.identifier?.rawValue == "workspace.toggle-library"
        } as? NSButton)
        #expect(toggle.sendAction(toggle.action, to: toggle.target))
        app.navigate(.calendar)
        #expect(app.recordingBarIsVisible)
        app.stopRecording()
        app.stopRecording()
        #expect(starts == 2, "Repeated Stop must not start or stop a second session")
        #expect(!app.recordingBarIsVisible)
        app.hide()
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

    @Test(.freshHome, arguments: [false, true])
    func calendarSelectionDuringCaptureSurvivesStopAndPreservesManualTitle(manualTitle: Bool) async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        let now = Date()
        let first = CalendarWatcher.Meeting(id: "first", title: "First event", start: now,
            end: now.addingTimeInterval(1800), attendees: ["Anna"], link: nil, looksLikeCall: true)
        let next = CalendarWatcher.Meeting(id: "next", title: "Next event", start: now,
            end: now.addingTimeInterval(3600), attendees: ["Boris"], link: nil, looksLikeCall: true)
        let session = try RecordingSession(root: root, context: MeetingContext(meeting: first, app: "Call app"),
            mic: FakeMicRecorder(), system: FakeSystemRecorder())
        try session.start()
        defer { session.stop(reason: "manual") }
        if manualTitle { try session.rename(to: "My title") }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        func refresh() {
            library.setActiveRecording(.init(dir: session.dir, title: session.title ?? "", started: now,
                paused: session.isPaused, liveStatus: .paused))
        }
        library.onAssociateActiveRecording = { dir, meeting in
            try #require(dir == session.dir)
            try session.associateCalendar(meeting)
            refresh()
        }
        refresh()
        app.update(state: .recording, elapsed: "00:01")
        app.showActiveRecording()
        #expect(library.calendarPicker.button.isEnabled)
        library.calendarPicker.choose(next)
        await library.calendarPicker.settled()
        await library.settled()
        #expect(MeetingCalendarMetadata.read(from: session.dir)?.eventID == "next")
        #expect(session.title == (manualTitle ? "My title" : "Next event"))
        #expect(!FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("meta.json").path))
        session.pause()
        refresh()
        library.calendarPicker.clearSelection()
        await library.settled()
        #expect(MeetingCalendarMetadata.read(from: session.dir) == nil)
        #expect(session.title == (manualTitle ? "My title" : "Next event"))
        library.calendarPicker.choose(next)
        await library.calendarPicker.settled()
        session.stop(reason: "manual")
        #expect(MeetingCalendarMetadata.read(from: session.dir)?.eventID == "next")
        #expect(SessionState.read(session.dir)?["app"] as? String == "Call app")
        #expect(SessionState.read(session.dir)?["title"] as? String == (manualTitle ? "My title" : "Next event"))
    }

    @Test(.freshHome)
    func calendarWriteFailureKeepsTheCurrentRecordingContext() throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        var failWrite = false
        let session = try RecordingSession(root: root, context: MeetingContext(title: "Original"),
            mic: FakeMicRecorder(), system: FakeSystemRecorder(), writeFile: { data, url in
                if failWrite { throw DiskFull() }
                try data.write(to: url, options: .atomic)
            })
        try session.start()
        defer { session.stop(reason: "manual") }
        let meeting = CalendarWatcher.Meeting(id: "new", title: "New event", start: Date(),
            end: Date().addingTimeInterval(1800), attendees: [], link: nil, looksLikeCall: true)
        failWrite = true
        #expect(throws: DiskFull.self) { try session.associateCalendar(meeting) }
        failWrite = false
        #expect(session.title == "Original")
        #expect(MeetingCalendarMetadata.read(from: session.dir)?.eventID == nil)
        var invalid = meeting
        invalid.hasPersistentID = false
        #expect(throws: CalendarSelectionError.self) { try session.associateCalendar(invalid) }
    }
}
