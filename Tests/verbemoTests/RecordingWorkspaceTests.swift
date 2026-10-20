import AppKit
import Foundation
import Testing
@testable import verbemo

@Suite(.serialized)
@MainActor
struct RecordingWorkspaceTests {
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
