import Foundation
import Testing
@testable import verbemo

struct BackgroundSummaryLifecycleTests {
    @Test("Meeting cancellation owns summary cleanup and preserves the previous version", arguments: [false, true])
    func summaryCancellationPreservesPrevious(archived: Bool) async throws {
        let entered = Gate(), cancelled = Gate(), release = Gate(), stopped = Flag()
        let backendEntered = Flag(), cancellationReceived = Flag()
        defer { release.open() }
        let backend = LLMBackend(name: "codex-cli", model: "synthetic") { _, _ in
            await withTaskCancellationHandler {
                backendEntered.raise()
                entered.open()
                await release.pass()
                return "a replacement that must not be published"
            } onCancel: { cancellationReceived.raise(); cancelled.open() }
        }
        let home = Home.sandbox(languageModels: { _ in [backend] })
        let root = try SessionFixture.make()
        defer { for dir in [home.url, root] { try? FileManager.default.removeItem(at: dir) } }
        try home.writeConfig(["summary": ["backend": "codex-cli"], "speaker_names": ["enabled": false]])
        let previous = Data("previous complete summary".utf8)
        try previous.write(to: root.appendingPathComponent("summary.md"))
        let dir: URL
        if archived {
            dir = try #require(try TranscriptVersions.archiveCurrent(root))
            try Transcript(engine: "assemblyai", model: "new-current", created_at: "2026-10-01T10:00:00Z",
                           segments: SessionFixture.meeting).write(to: root)
        } else {
            dir = root
        }
        let transcript = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))

        try await Home.$scoped.withValue(home) {
            let request = try SummaryRequest.capture(backend: "codex-cli")
            let task = Task {
                defer { entered.open(); cancelled.open() }
                try await PostProcessor.regenerateSummary(dir, request: request)
            }
            defer { task.cancel(); release.open() }
            await entered.pass()
            guard backendEntered.isRaised else {
                try await task.value
                Issue.record("Summary completed without entering the backend")
                return
            }
            let entry = try #require(ProcessingOperations.shared.snapshot().first {
                $0.session == root.standardizedFileURL.resolvingSymlinksInPath()
            })
            #expect(entry.kind == .summary)
            #expect(SessionClaim.isHeld(root))
            let stop = Task {
                await ProcessingOperations.shared.cancelAndWait(session: root)
                stopped.raise()
                cancelled.open()
            }
            await cancelled.pass()
            guard cancellationReceived.isRaised else {
                release.open()
                await stop.value
                _ = try? await task.value
                Issue.record("Meeting cancellation returned without cancelling the summary backend")
                return
            }
            #expect(!stopped.isRaised)
            #expect(ProcessingOperations.shared.snapshot().first { $0.id == entry.id }?.state == .cancelling)
            release.open()
            await stop.value
            do { try await task.value; Issue.record("Cancelled summary reported success") }
            catch is CancellationError {}
            catch { Issue.record("Unexpected cancellation result: \(error)") }
        }

        #expect(try Data(contentsOf: dir.appendingPathComponent("summary.md")) == previous)
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == transcript)
        #expect(SessionState.value(dir, SessionState.Key.summaryDeferrals) == nil)
        #expect(!SessionClaim.isHeld(root))
        #expect(!ProcessingOperations.shared.snapshot().contains { $0.session == root.standardizedFileURL.resolvingSymlinksInPath() })
    }
}
