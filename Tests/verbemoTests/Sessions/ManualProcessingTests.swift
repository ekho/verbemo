import AppKit
import ArgumentParser
import Foundation
import Testing

@testable import verbemo

@Suite(.serialized)
struct ManualProcessingTests {
    private func withSession(_ model: FakeModel, isolation: isolated (any Actor)? = #isolation, _ body: (URL, Home) async throws -> Void) async throws {
        let home = Home.withModels([model])
        let dir = try SessionFixture.make()
        defer {
            try? FileManager.default.removeItem(at: home.url)
            try? FileManager.default.removeItem(at: dir)
        }
        try home.writeConfig(["summary": ["backend": "auto"], "user_name": "Test owner"])
        try await Home.$scoped.withValue(home) { try await body(dir, home) }
    }

    @Test("The actual process command retries legacy and unchanged-fingerprint failures", arguments: [false, true])
    @MainActor func cliRetries(legacy: Bool) async throws {
        let model = FakeModel.working("claude-cli")
        try await withSession(model) { dir, _ in
            SessionState.update(dir, with: [
                SessionState.Key.summaryStatus: "failed", SessionState.Key.speakersStatus: "failed",
                SessionState.Key.summaryFailedFor: legacy ? nil : MeetingEgress.fingerprint(for: .summary),
                SessionState.Key.speakersFailedFor: legacy ? nil : MeetingEgress.fingerprint(for: .speakerNames),
            ])
            let original = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
            #expect(await PostProcessor.finish(dir).isEmpty)
            let command = try ProcessSession.parse([dir.path])
            try command.run()
            #expect(PostProcessor.hasCurrentSummary(dir))
            #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.name == "Фёдор")
            #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == original)
            let calls = model.callCount
            try command.run()
            #expect(model.callCount == calls, "successful stages must not run again")
        }
    }

    @Test("The selected archive respects the root claim and preserves current results")
    func archivedVersionUsesRootClaim() async throws {
        let model = FakeModel.working("claude-cli")
        try await withSession(model) { dir, _ in
            let archive = try #require(try TranscriptVersions.archiveCurrent(dir))
            let newer = Transcript(engine: "assemblyai", model: "new", created_at: "2026-10-01T10:00:00Z", segments: SessionFixture.meeting)
            try newer.write(to: dir)
            try Data("current summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
            let current = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
            try SessionClaim.acquire(dir, stage: .transcribe)
            #expect(await PostProcessor.finish(archive, retryFailed: true).isEmpty)
            #expect(model.callCount == 0)
            SessionClaim.release(dir)
            #expect(!(await PostProcessor.finish(archive, retryFailed: true)).isEmpty)
            #expect(PostProcessor.hasCurrentSummary(archive))
            #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == current)
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "current summary")
        }
    }

    @Test("Signed-out CLIs log the login remedy and fall through for names and summary")
    func signedOutFallsThrough() async throws {
        let failed = FakeModel("claude-cli", failing: LLMError.exit(1, "API Error: 401 Invalid API key · Please run /login"))
        let next = FakeModel.working("codex-cli")
        let home = Home.withModels([failed, next])
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["summary": ["backend": "auto"], "user_name": "Test owner"])
        await Home.$scoped.withValue(home) { await PostProcessor.finish(dir) }
        let log = try String(contentsOf: dir.appendingPathComponent("transcribe.log"), encoding: .utf8)
        #expect(log.contains("sign in again"))
        #expect(log.contains("claude /login"))
        #expect(PostProcessor.hasCurrentSummary(dir))
        #expect(SpeakerNames.read(from: dir)?.backend == "codex-cli")
        #expect(failed.callCount == 2 && next.callCount == 2)
    }


    @Test("A repeated failure settles and the background sweep does not force it", arguments: ["failed", "deferred"])
    @MainActor func retryFailureAndSweep(outcome: String) async throws {
        let model = FakeModel("claude-cli", failing: outcome == "failed" ? LLMError.exit(1, "Not logged in") : URLError(.notConnectedToInternet))
        try await withSession(model) { dir, _ in
            let root = dir.deletingLastPathComponent().appendingPathComponent("sweep-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let session = root.appendingPathComponent("meeting")
            try FileManager.default.moveItem(at: dir, to: session)
            defer { try? FileManager.default.removeItem(at: root) }
            SessionState.update(session, with: [SessionState.Key.summaryStatus: "failed", SessionState.Key.speakersStatus: "failed"])
            let command = try ProcessSession.parse([session.path])
            #expect(throws: ExitCode.self) { try command.run() }
            #expect(SessionState.value(session, SessionState.Key.summaryStatus) as? String == outcome)
            #expect(SessionState.value(session, SessionState.Key.speakersStatus) as? String == outcome)
            let calls = model.callCount
            for _ in 0..<3 { await PostProcessor.sweep(root: root) }
            #expect(outcome == "failed" ? model.callCount == calls : model.callCount > calls)
        }
    }

    @Test("Explicit retry refuses unreadable config and claim, and unfinished diarization")
    func retryGuards() async throws {
        let model = FakeModel.working("claude-cli")
        try await withSession(model) { dir, home in
            let original = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
            try home.writeConfig(text: "{")
            #expect(!(await PostProcessor.finishManually(dir)).succeeded)
            try home.writeConfig(["summary": ["backend": "auto"]])
            try Data("{".utf8).write(to: dir.appendingPathComponent(SessionClaim.file))
            #expect(!(await PostProcessor.finishManually(dir)).succeeded)
            try FileManager.default.removeItem(at: dir.appendingPathComponent(SessionClaim.file))
            try DiarizationState(request: .init(engine: "parakeet", threshold: 0.6), status: .pending).write(to: dir)
            #expect(!(await PostProcessor.finishManually(dir)).succeeded)
            #expect(model.callCount == 0)
            #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == original)
        }
    }


    @Test("A recordings folder called transcripts does not redirect the session claim")
    func recordingsNamedTranscripts() async throws {
        let model = FakeModel.working("claude-cli")
        try await withSession(model) { dir, home in
            let root = home.url.appendingPathComponent("transcripts")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let session = root.appendingPathComponent("meeting")
            try FileManager.default.moveItem(at: dir, to: session)
            try SessionClaim.acquire(session, stage: .transcribe)
            defer { SessionClaim.release(session) }
            #expect(await PostProcessor.finish(session, retryFailed: true).isEmpty)
            #expect(model.callCount == 0)
        }
    }

    @Test("A config broken during naming is reported as paused, not as the old summary failure")
    func configBreaksDuringRetry() async throws {
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let model = FakeModel("claude-cli") { _, _, _ in
            try home.writeConfig(text: "{")
            return SessionFixture.namesThemA
        }
        let scoped = Home(url: home.url, environment: [:], discoversTools: false, languageModels: { _ in [model.backend] })
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try home.writeConfig(["summary": ["backend": "auto"]])
        SessionState.update(dir, with: [SessionState.Key.summaryStatus: "failed"])
        await Home.$scoped.withValue(scoped) {
            let result = await PostProcessor.finishManually(dir)
            #expect(!result.succeeded)
            #expect(result.description.contains("config.json"))
            #expect(!result.description.contains("failed again"))
        }
        #expect(model.callCount == 1)
        #expect(SpeakerNames.read(from: dir) != nil)
        #expect(!PostProcessor.hasCurrentSummary(dir))
    }


    @Test("Completed artifacts win over a config change during the last call")
    func configBreaksAfterLastCall() async throws {
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let model = FakeModel("claude-cli") { _, _, _ in
            try home.writeConfig(text: "{")
            return "## Summary"
        }
        let scoped = Home(url: home.url, environment: [:], discoversTools: false, languageModels: { _ in [model.backend] })
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try home.writeConfig(["summary": ["backend": "auto"], "speaker_names": ["enabled": false]])
        await Home.$scoped.withValue(scoped) {
            #expect((await PostProcessor.finishManually(dir)).succeeded)
        }
        #expect(PostProcessor.hasCurrentSummary(dir))
    }

    @Test("Finish processing reports the actual result in the window", arguments: ["completed", "failed", "deferred"])
    @MainActor func uiReportsOutcome(outcome: String) async throws {
        let model: FakeModel = outcome == "completed" ? .working("claude-cli") : FakeModel("claude-cli", failing:
            outcome == "failed" ? LLMError.exit(1, "Not logged in") : URLError(.notConnectedToInternet))
        try await withSession(model) { dir, _ in
            SessionState.update(dir, with: [SessionState.Key.summaryStatus: "failed", SessionState.Key.speakersStatus: "failed"])
            let root = dir.deletingLastPathComponent().appendingPathComponent("ui-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let session = root.appendingPathComponent("meeting")
            try FileManager.default.moveItem(at: dir, to: session)
            defer { try? FileManager.default.removeItem(at: root) }
            let app = ApplicationWindow()
            let library = MeetingLibraryController(root: root, hostWindow: app.panel)
            app.libraryProvider = { library }
            app.navigate(.allMeetings)
            app.show()
            defer {
                if let sheet = app.panel.attachedSheet { app.panel.endSheet(sheet) }
                app.panel.orderOut(nil)
                withExtendedLifetime(library) {}
            }
            await library.settled()
            let button = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("finishClicked") })
            #expect(button.isEnabled)
            #expect(button.sendAction(button.action, to: button.target))
            for _ in 0..<200 where library.isProcessing || app.panel.attachedSheet == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            let sheet = try #require(app.panel.attachedSheet)
            let text = sheet.contentView?.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ") ?? ""
            #expect(text.lowercased().contains(outcome))
            if outcome == "completed" {
                #expect(PostProcessor.hasCurrentSummary(session))
                #expect(SpeakerNames.read(from: session)?.speakers["them A"]?.name == "Фёдор")
            } else {
                #expect(text.contains("transcribe.log"))
            }
        }
    }
}
