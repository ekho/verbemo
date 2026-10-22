import AppKit
import Foundation
import Testing
@testable import verbemo

@Suite(.serialized)
@MainActor
struct SummaryProviderSheetTests {
    @Test func pickerKeepsSelectionForExplicitRetry() async throws {
        let chosen = FakeModel("codex-cli") { call, _, _ in
            if call == 0 { throw LLMError.exit(1, "Not logged in") }
            return "retried"
        }
        let other = FakeModel("claude-cli", answer: "wrong provider")
        let home = Home.withModels([other, chosen])
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try home.writeConfig(["summary": ["backend": "claude-cli"]])
        try Data("old".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try await Home.$scoped.withValue(home) {
            let sheet = SummaryRegenerationSheet(run: { request in
                try await PostProcessor.regenerateSummary(dir, request: request)
            }, completion: {})
            sheet.picker.selectItem(at: 1)
            sheet.selectionChanged()
            #expect(sheet.disclosure.stringValue.contains("Codex"))
            sheet.start()
            await sheet.task?.value
            #expect(sheet.picker.indexOfSelectedItem == 1)
            #expect(sheet.create.isEnabled)
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "old")
            try home.writeConfig(["summary": ["backend": "claude-cli", "enabled": false]])
            sheet.start()
            await sheet.task?.value
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "retried\n")
            #expect(other.callCount == 0)
        }
    }

    @Test func oneRunChoiceIsAvailableWithAutomaticSummaryDisabled() {
        let state = MeetingActionState(transcriptReady: true, summaryReady: false, hasAudio: false,
            isRecording: false, isBusy: false, configReadable: true, transcriptionEnabled: false, summaryEnabled: false)
        #expect(state.reason(for: .regenerateSummary) == nil)
    }
}
