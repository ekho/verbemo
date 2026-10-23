import AppKit
import Foundation
import Testing
@testable import verbemo

@MainActor
@Suite(.serialized, .freshHome)
struct ShutdownServicesTests {
    @Test("A key check returning after shutdown cannot save or change settings")
    func lateKeyCheck() async throws {
        let form = SetupForm(mode: .settings)
        let field = try #require(form.settingsPages[.transcription]?.allDescendants.first {
            $0.identifier?.rawValue == "transcription.key.assemblyai"
        } as? NSSecureTextField)
        field.stringValue = "synthetic-shutdown-key"
        let entered = Gate(), release = Gate()
        form.checkKey = { _ in entered.open(); await release.pass(); return .works }
        let check = Task { await form.saveCloudKey(for: "assemblyai") }
        await entered.pass()
        let tasks = form.stopForTermination()
        release.open()
        await check.value
        for task in tasks { await task.value }
        #expect(Config.assemblyAIKey() == nil)
    }

    @Test("Stopping status remains visible after stale navigation or recording callbacks")
    func stoppingPage() {
        let window = ApplicationWindow()
        _ = window.stopForTermination()
        window.showStopping("Останавливаю…")
        window.navigate(.transcription)
        window.newRecording()
        window.update(state: .recording, elapsed: "0:00")
        #expect(window.recordingSheet == nil)
        #expect(window.panel.contentView?.allDescendants.contains {
            ($0 as? NSTextField)?.stringValue == "Останавливаю…"
        } == true)
    }
    @Test("An unanswered OS permission prompt does not hold up exit", arguments: [false, true])
    func permissionIsNotAResourceBarrier(calendar: Bool) async throws {
        let form = SetupForm(mode: .settings)
        let entered = Gate(), answer = Gate(), returned = Flag()
        let request: @MainActor () async -> SetupPermissions.State = {
            entered.open(); await answer.pass(); return .denied
        }
        var openedSettings = false
        form.requestMicrophone = request
        form.requestCalendar = request
        form.openPermissionSettings = { _ in openedSettings = true }
        let page = try #require(form.settingsPages[calendar ? .calendar : .recording])
        let row = try #require(page.allDescendants.first {
            $0.identifier?.rawValue == (calendar ? "access.calendar" : "access.microphone")
        } as? AccessRow)
        row.onAct?()
        await entered.pass()
        let tasks = form.stopForTermination()
        let finish = Task { for task in tasks { await task.value }; returned.raise() }
        for _ in 0..<20 { await Task.yield() }
        #expect(returned.isRaised)
        answer.open()
        await finish.value
        for _ in 0..<20 { await Task.yield() }
        #expect(!openedSettings)
    }

}
