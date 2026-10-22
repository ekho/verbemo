import Foundation
import Testing
@testable import verbemo

@Suite(.freshHome(config: #"{"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct BackgroundProcessingLifecycleTests {
    @Test("Cancelling the import task cancels normalization and waits for its cleanup")
    func parentCancellationReachesNormalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav")
        let bytes = Data("synthetic media".utf8)
        try bytes.write(to: source)
        let normalizer = HeldNormalizer()
        let coordinator = MediaImportCoordinator(root: root, normalizer: normalizer)
        let returned = Flag()
        let task = Task {
            let result = await coordinator.importFiles([source])
            returned.raise()
            return result
        }
        await normalizer.started.pass()

        task.cancel()
        #expect(normalizer.cancelled.isRaised, "cancellation must reach the existing child task")
        #expect(!returned.isRaised, "the importer must wait until normalization releases its resources")
        normalizer.cleanup.open()
        let result = await task.value

        #expect(result.cancelled)
        #expect(result.imported.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(try Data(contentsOf: source) == bytes)
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(contents == ["synthetic.wav"], "unpublished staging must be removed before returning")
    }

    @Test("Cancelled manual post-processing cannot report success")
    func cancelledManualDoesNotReportSuccess() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Gate()
        let task = Task {
            await start.pass()
            return await PostProcessor.finishManually(dir, policy: .init(names: false, summary: false))
        }
        task.cancel()
        start.open()
        let result = await task.value
        #expect(!result.succeeded)
        #expect(!SessionClaim.isHeld(dir))
    }

    @Test("Cancelled speaker naming does not spend attempts or try another provider")
    func namingCancellationDoesNotSpendAttempt() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cancelled = FakeModel("claude-cli", failing: CancellationError())
        let fallback = FakeModel("codex-cli", answer: SessionFixture.namesThemA)
        let home = Home.withModels([cancelled, fallback])
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["summary": ["backend": "auto"], "speaker_names": ["enabled": true]])
        let originalMarkdown = try Data(contentsOf: dir.appendingPathComponent("transcript.md"))

        let names = await Home.$scoped.withValue(home) {
            await SpeakerNamer.name(transcript: SessionFixture.transcript, title: nil,
                                    attendees: [], app: nil, into: dir)
        }

        #expect(names == nil)
        #expect(fallback.callCount == 0)
        #expect(SessionState.value(dir, SessionState.Key.speakersDeferrals) == nil)
        #expect(SessionState.value(dir, SessionState.Key.speakersStatus) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(SpeakerNames.file).path))
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.md")) == originalMarkdown)
    }

    private struct HeldNormalizer: MediaNormalizing {
        let started = Gate()
        let cancelled = Flag()
        let cleanup = Gate()

        func probe(_ source: URL) async throws -> MediaNormalizer.Probe {
            .init(duration: 1, sourceBytes: Int64(try Data(contentsOf: source).count))
        }

        func normalize(_ source: URL, to destination: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
            try await withTaskCancellationHandler {
                started.open()
                await cleanup.pass()
                try Task.checkCancellation()
                try Data("normalized".utf8).write(to: destination)
            } onCancel: {
                cancelled.raise()
            }
        }
    }
}
