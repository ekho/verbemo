import AppKit
import ArgumentParser
import Foundation
import Testing
@testable import verbemo

@Suite(.serialized)
struct SummaryIntegrationTests {
    @Test @MainActor func manualFinishCannotRerouteAOneRunFailure() async throws {
        let failed = FakeModel("codex-cli", failing: LLMError.exit(1, "Not logged in"))
        let other = FakeModel("claude-cli", answer: "must not run")
        let home = Home.withModels([other, failed])
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try home.writeConfig(["summary": ["backend": "claude-cli"], "speaker_names": ["enabled": false]])
        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: "codex-cli")
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(dir, request: request) }
            let result = await PostProcessor.finishManually(dir)
            #expect(!result.succeeded)
            #expect(result.description.contains("Create a new summary"))
            let command = try ProcessSession.parse([dir.path])
            #expect(throws: ExitCode.self) { try command.run() }
            let item = try #require(SessionInventory.item(for: dir))
            if case .refuse = MeetingLibraryController.decision(for: item) {} else { Issue.record("Must explain how to retry") }
            #expect(other.callCount == 0 && failed.callCount == 1)
            let log = try String(contentsOf: dir.appendingPathComponent("transcribe.log"), encoding: .utf8)
            #expect(log.contains("codex login"))
            #expect(!log.contains("trying the next backend"))
        }
    }

    @Test func singleNamingProviderDoesNotPromiseFallback() async throws {
        let failed = FakeModel("codex-cli", failing: LLMError.exit(1, "Not logged in"))
        let home = Home.withModels([failed])
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try home.writeConfig(["summary": ["backend": "codex-cli"], "speaker_names": ["enabled": true]])
        await Home.$scoped.withValue(home) {
            await SpeakerNamer.name(transcript: SessionFixture.transcript, title: nil, attendees: [], app: nil, into: dir)
        }
        let log = try String(contentsOf: dir.appendingPathComponent("transcribe.log"), encoding: .utf8)
        #expect(log.contains("codex login"))
        #expect(!log.contains("trying the next backend"))
    }

    @Test @MainActor func preflightLoginErrorKeepsChoiceAndGivesAction() async throws {
        let backend = LLMBackend(name: "codex-cli", model: nil, checkAccess: {
            throw LLMError.exit(1, "Not logged in\nPlease run codex login\ntoken=synthetic-secret")
        }) { _, _ in Issue.record("Must not send text"); return "wrong" }
        let home = Home.sandbox(languageModels: { _ in [backend] })
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        await Home.$scoped.withValue(home) {
            let sheet = SummaryRegenerationSheet(run: { request in
                try await PostProcessor.regenerateSummary(dir, request: request)
            }, completion: {})
            sheet.picker.selectItem(at: 1); sheet.selectionChanged()
            sheet.start(); await sheet.task?.value
            #expect(sheet.status.stringValue.contains("codex login"))
            #expect(!sheet.status.stringValue.contains("synthetic-secret"))
            #expect(!sheet.status.stringValue.contains("LLMError"))
            #expect(sheet.picker.indexOfSelectedItem == 1 && sheet.create.isEnabled)
        }
    }
}
