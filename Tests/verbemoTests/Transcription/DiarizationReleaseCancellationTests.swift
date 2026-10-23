import Foundation
import Testing
@testable import verbemo

@Suite(.freshHome(config: #"{"offline_echo_cancellation":false,"transcription":{"local_diarization":true},"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct DiarizationReleaseCancellationTests {
    private actor HeldReleaseRuntime: LocalDiarizationRuntime {
        nonisolated let releasing = Gate(), cleanup = Gate(), cancelled = Gate()
        func prepare() async throws {}
        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            [SpeakerTurn(speakerID: "voice", start: 0, end: 1)]
        }
        func release() async {
            await withTaskCancellationHandler {
                releasing.open()
                await cleanup.pass()
            } onCancel: { cancelled.open() }
        }
    }

    @Test("Cancellation during diarizer release preserves the unpublished generation", arguments: ["parakeet", "gigaam"])
    func cancellationDuringRelease(engineName: String) async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("release-" + engineName)
        let sources = ["mic.caf", "system.caf"].map { dir.appendingPathComponent($0) }
        let originalAudio = try sources.map { try Data(contentsOf: $0) }
        let operations = ProcessingOperations()
        let runtime = HeldReleaseRuntime()
        defer { runtime.cleanup.open() }
        let engine = FakeEngine(engineName, answer: { _, _ in
            [TranscriptSegment(start: 0, end: 1, text: "synthetic speech",
                words: [TranscriptWord(start: 0, end: 1, text: "synthetic speech")])]
        })
        let coordinator = TranscriptionCoordinator(
            engine: engine, operations: operations, onStop: { nil },
            diarizerFactory: { _ in runtime }, modelFingerprint: { _ in "test-model" })
        let work = Task { try await coordinator.transcribeNow(dir) }
        await runtime.releasing.pass()
        let transcriptURL = dir.appendingPathComponent("transcript.json")
        let previousTranscript = try? Data(contentsOf: transcriptURL)
        let previousVersions = TranscriptVersions.read(dir).map(\.dir)
        let operation = try #require(operations.snapshot().first { $0.session == dir.resolvingSymlinksInPath() })
        let stopped = Flag()
        let stop = Task { await operations.cancelAndWait(operation.id); stopped.raise() }
        await runtime.cancelled.pass()

        #expect(!stopped.isRaised)
        #expect(operations.snapshot().first?.state == .cancelling)
        #expect(SessionClaim.isHeld(dir))
        runtime.cleanup.open()
        await stop.value
        do { try await work.value; Issue.record("cancelled speaker generation was published") }
        catch is CancellationError {}

        #expect((try? Data(contentsOf: transcriptURL)) == previousTranscript)
        #expect(TranscriptVersions.read(dir).map(\.dir) == previousVersions)
        #expect(try sources.map { try Data(contentsOf: $0) } == originalAudio)
        #expect(DiarizationState.read(dir)?.status == .pending)
        #expect(DiarizationState.read(dir)?.attempts == 0)
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
        #expect(!SessionClaim.isHeld(dir))
        #expect(engine.counts.released == 1)
        #expect(operations.snapshot().isEmpty)
    }
}
