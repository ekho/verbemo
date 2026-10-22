import Foundation
import Testing
@testable import verbemo

struct SummaryRequestTests {
    @Test func selectedProviderIsFrozenAndDoesNotChangeOtherMeetings() async throws {
        let chosen = FakeModel("codex-cli") { _, system, prompt in
            #expect(system.contains("English"))
            #expect(prompt.contains("Original template"))
            return "chosen"
        }
        let configured = FakeModel("claude-cli", answer: "configured")
        let home = Home.withModels([configured, chosen])
        let first = try SessionFixture.make()
        let second = try SessionFixture.make()
        defer { for url in [home.url, first, second] { try? FileManager.default.removeItem(at: url) } }
        try home.writeConfig(["summary": ["backend": "claude-cli", "language": "English", "template": "Original template"]])
        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: "codex-cli")
            let before = try Data(contentsOf: Config.path)
            try await PostProcessor.regenerateSummary(first, request: request)
            #expect(try Data(contentsOf: Config.path) == before)
            try await PostProcessor.regenerateSummary(second)
            #expect(try String(contentsOf: first.appendingPathComponent("summary.md"), encoding: .utf8) == "chosen\n")
            #expect(try String(contentsOf: second.appendingPathComponent("summary.md"), encoding: .utf8) == "configured\n")
            try home.writeConfig(["summary": ["enabled": false, "backend": "none", "language": "Russian"]])
            try await PostProcessor.regenerateSummary(first, request: request)
            #expect(chosen.callCount == 2 && configured.callCount == 1)
            #expect(request.settings.language == "English")
        }
    }

    @Test(arguments: [true, false]) func selectedFailureCannotFallBackOrBecomeBackgroundWork(explicit: Bool) async throws {
        let chosen = FakeModel("codex-cli", failing: LLMError.exit(1, "Not logged in"))
        let other = FakeModel("claude-cli", answer: "must not receive transcript")
        let home = Home.withModels([other, chosen])
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try home.writeConfig(["summary": ["backend": "codex-cli"], "speaker_names": ["enabled": false]])
        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: explicit ? "codex-cli" : nil)
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(dir, request: request) }
            try home.writeConfig(["summary": ["backend": "claude-cli"], "speaker_names": ["enabled": false]])
            for _ in 0..<8 { #expect(await PostProcessor.finish(dir).isEmpty) }
            #expect(chosen.callCount == 1 && other.callCount == 0)
            #expect(SessionState.value(dir, SessionState.Key.summaryFailedFor) as? String == request.fingerprint)
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(dir, request: request) }
            #expect(chosen.callCount == 2 && other.callCount == 0)
        }
    }

    @Test func accessFailureNeverSendsTranscriptOrChangesOldSummary() async throws {
        let backend = LLMBackend(name: "codex-cli", model: nil, checkAccess: { throw LLMError.exit(1, "Not logged in") }) { _, _ in
            Issue.record("Unavailable backend received the transcript")
            return "wrong"
        }
        let home = Home.sandbox(languageModels: { _ in [backend] })
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try Data("old".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: "codex-cli")
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(dir, request: request) }
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "old")
            #expect(!SessionClaim.isHeld(dir))
        }
    }

    @Test func cancelledReplacementKeepsOldSummary() async throws {
        let model = FakeModel("codex-cli", failing: CancellationError())
        let home = Home.withModels([model])
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try Data("old".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: "codex-cli")
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(dir, request: request) }
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "old")
            #expect(!SessionClaim.isHeld(dir))
        }
    }
    @Test func unwritableMetadataStopsBeforeSendingText() async throws {
        let model = FakeModel("codex-cli", answer: "must not send")
        let home = Home.withModels([model])
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        let meta = dir.appendingPathComponent("meta.json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: meta.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: meta.path) }
        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: "codex-cli")
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(dir, request: request) }
            #expect(model.callCount == 0)
        }
    }

    @Test func selectedArchiveUsesRootClaimAndDoesNotReplaceCurrentSummary() async throws {
        let model = FakeModel("codex-cli", answer: "archive replacement")
        let home = Home.withModels([model])
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try Data("old archive".utf8).write(to: dir.appendingPathComponent("summary.md"))
        let archive = try #require(try TranscriptVersions.archiveCurrent(dir))
        try Transcript(engine: "assemblyai", model: "newer", created_at: "2026-10-22T11:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "New transcript only")]).write(to: dir)
        try Data("current summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: "codex-cli")
            try SessionClaim.acquire(dir, stage: .transcribe)
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(archive, request: request) }
            SessionClaim.release(dir)
            #expect(model.callCount == 0)
            try await PostProcessor.regenerateSummary(archive, request: request)
            #expect(try String(contentsOf: archive.appendingPathComponent("summary.md"), encoding: .utf8) == "archive replacement\n")
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "current summary")
            #expect(SessionState.value(dir, SessionState.Key.summaryManual) == nil)
            #expect(model.prompts.first?.contains("Фёдор") == true)
            #expect(model.prompts.first?.contains("New transcript only") == false)
        }
    }

    @Test func cancellationInFlightCannotPublishEvenIfBackendIgnoresIt() async throws {
        let gate = Gate()
        let entered = Gate()
        let backend = LLMBackend(name: "codex-cli", model: nil) { _, _ in
            entered.open()
            await gate.pass()
            return "late replacement"
        }
        let home = Home.sandbox(languageModels: { _ in [backend] })
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try Data("old".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: "codex-cli")
            let task = Task { try await PostProcessor.regenerateSummary(dir, request: request) }
            await entered.pass()
            task.cancel()
            gate.open()
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "old")
            #expect(!SessionClaim.isHeld(dir))
        }
    }

    @Test func parallelRequestsKeepIndependentRoutesAndPrompts() async throws {
        let entered = Gate(), release = Gate()
        let codex = LLMBackend(name: "codex-cli", model: nil) { system, _ in
            entered.open()
            await release.pass()
            #expect(system.contains("English"))
            return "first"
        }
        let ollama = LLMBackend(name: "ollama", model: "local") { system, _ in
            #expect(system.contains("Russian"))
            return "second"
        }
        let home = Home.sandbox(languageModels: { LLMBackend.chain(preference: $0, from: [codex, ollama]) })
        let first = try SessionFixture.make(), second = try SessionFixture.make()
        defer { for url in [home.url, first, second] { try? FileManager.default.removeItem(at: url) } }
        try home.writeConfig(["summary": ["language": "English"]])
        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: "codex-cli")
            let task = Task { try await PostProcessor.regenerateSummary(first, request: request) }
            await entered.pass()
            try home.writeConfig(["summary": ["language": "Russian", "backend": "ollama"]])
            let next = try SummaryRequest.capture(backend: "ollama")
            do { try await PostProcessor.regenerateSummary(second, request: next) }
            catch { release.open(); throw error }
            release.open()
            try await task.value
            #expect(try String(contentsOf: first.appendingPathComponent("summary.md"), encoding: .utf8) == "first\n")
            #expect(try String(contentsOf: second.appendingPathComponent("summary.md"), encoding: .utf8) == "second\n")
        }
    }

    @Test func keyResolutionUsesTheSameConfigurationSnapshotAsEndpoint() throws {
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try Home.$scoped.withValue(home) {
            let old = home.url.appendingPathComponent("old-key")
            let new = home.url.appendingPathComponent("new-key")
            try Data("old synthetic key".utf8).write(to: old)
            try Data("new synthetic key".utf8).write(to: new)
            let snapshot: [String: Any] = ["transcription": ["openai": ["api_key_path": old.path]]]
            try home.writeConfig(["transcription": ["openai": ["api_key_path": new.path]]])
            #expect(Credentials.summaryOpenAIKey(in: snapshot) == "old synthetic key")
        }
    }

}
