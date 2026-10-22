import Foundation
import Testing
@testable import verbemo

@Suite(.freshHome(config: #"{"offline_echo_cancellation":false,"transcription":{"local_diarization":false},"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct ProcessingCancellationTests {
    private actor HeldEngine: TranscriptionEngine {
        nonisolated let name = "parakeet", model = "held", input = TranscriptionInput.perTrack
        nonisolated let entered = Gate(), finishInference = Gate(), cleanup = Gate(), released = Gate()
        nonisolated let thirdEntered = Gate(), finishThird = Gate()
        private var first = true
        func prepare() async throws {}
        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            if first { first = false; entered.open(); await finishInference.pass() }
            if audio.deletingLastPathComponent().lastPathComponent == "third" {
                thirdEntered.open(); await finishThird.pass()
            }
            return [TranscriptSegment(start: 0, end: 1, text: "synthetic speech")]
        }
        func release() async { released.open(); await cleanup.pass() }
    }

    @Test("Cancellation after non-cooperative inference preserves sources and waits for engine release")
    func cancelInference() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("held")
        let engine = HeldEngine()
        defer { engine.finishInference.open(); engine.cleanup.open() }
        let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })
        let task = Task { try await coordinator.transcribeNow(dir) }
        await engine.entered.pass()
        task.cancel(); engine.finishInference.open()
        await engine.released.pass()
        #expect(!SessionClaim.isHeld(dir))
        #expect(PostProcessor.readTranscript(dir) == nil)
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        engine.cleanup.open()
        do { try await task.value; Issue.record("cancelled inference published success") }
        catch is CancellationError {} catch { Issue.record("unexpected \(error)") }
    }
    @Test("A cancelled direct operation leaves the barrier without waiting for another meeting")
    func waitingDirectCancellation() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let a = try recordings.session("active"), b = try recordings.session("waiting")
        let operations = ProcessingOperations(), engine = HeldEngine()
        defer { engine.finishInference.open(); engine.cleanup.open() }
        let coordinator = TranscriptionCoordinator(engine: engine, operations: operations, onStop: { nil })
        let first = Task { try await coordinator.transcribeNow(a) }
        await engine.entered.pass()
        let second = Task { try await coordinator.transcribeNow(b) }
        for _ in 0..<1000 {
            if operations.snapshot().contains(where: { $0.session == b.resolvingSymlinksInPath() && $0.state == .waiting }) { break }
            await Task.yield()
        }
        let waiting = try #require(operations.snapshot().first { $0.session == b.resolvingSymlinksInPath() })
        await operations.cancelAndWait(waiting.id)
        #expect(operations.snapshot().allSatisfy { $0.session != b.resolvingSymlinksInPath() })
        #expect(PostProcessor.readTranscript(b) == nil)
        engine.finishInference.open(); engine.cleanup.open()
        try await first.value
        do { try await second.value; Issue.record("cancelled waiting work ran") } catch is CancellationError {}
        #expect(!SessionClaim.isHeld(a) && !SessionClaim.isHeld(b))
    }

    @Test("Cancelling a queued reservation keeps other meetings and permits explicit retry")
    func queuedCancellation() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let a = try recordings.session("first"), b = try recordings.session("second")
        let operations = ProcessingOperations(), engine = HeldEngine()
        defer { engine.finishInference.open(); engine.cleanup.open() }
        let coordinator = TranscriptionCoordinator(engine: engine, operations: operations, onStop: { nil })
        await coordinator.enqueue(a)
        await engine.entered.pass()
        await coordinator.enqueue(b)
        let pending = try #require(operations.snapshot().first { $0.session == b.resolvingSymlinksInPath() })
        #expect(pending.state == .waiting)
        await operations.cancelAndWait(pending.id)
        await coordinator.resumePending(root: recordings.root)
        engine.finishInference.open(); engine.cleanup.open()
        await coordinator.waitUntilIdle()
        #expect(PostProcessor.readTranscript(a) != nil)
        #expect(PostProcessor.readTranscript(b) == nil)
        #expect(SessionState.value(b, SessionState.Key.transcriptionAttempts) == nil)
        #expect(operations.snapshot().isEmpty)
        await coordinator.enqueue(b)
        await coordinator.waitUntilIdle()
        #expect(PostProcessor.readTranscript(b) != nil)
        #expect(operations.snapshot().isEmpty)
    }

    @Test("Closed admission rejects recording handoff and direct work")
    func closedHandoff() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("stopped-recording")
        let operations = ProcessingOperations()
        let engine = FakeEngine("parakeet")
        let coordinator = TranscriptionCoordinator(engine: engine, operations: operations, onStop: { nil })
        await operations.cancelAllAndWait()
        await coordinator.enqueue(dir)
        await coordinator.resumePending(root: recordings.root)
        do { try await coordinator.transcribeNow(dir); Issue.record("accepted direct work") } catch is CancellationError {}
        await coordinator.waitUntilIdle()
        #expect(engine.counts.prepared == 0)
        #expect(PostProcessor.readTranscript(dir) == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }

    @MainActor
    @Test("Cancelling a waiting sweep does not wait for unrelated inference")
    func waitingSweepCancellation() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("active")
        let operations = ProcessingOperations(), engine = HeldEngine(), swept = Flag()
        defer { engine.finishInference.open(); engine.cleanup.open() }
        let coordinator = TranscriptionCoordinator(engine: engine, operations: operations, onStop: { nil })
        await coordinator.enqueue(dir); await engine.entered.pass()
        let scheduler = SweepScheduler(waitForQueue: { await coordinator.waitUntilIdle() },
                                       sweep: { swept.raise() }, operations: operations)
        scheduler.request()
        let pending = try #require(operations.snapshot().first { $0.kind == .sweep })
        await operations.cancelAndWait(pending.id)
        #expect(!swept.isRaised)
        #expect(operations.snapshot().contains { $0.session == dir.resolvingSymlinksInPath() })
        engine.finishInference.open(); engine.cleanup.open()
        await coordinator.waitUntilIdle()
    }

    @Test("A skipped cancelled reservation stays suppressed until a later recovery cycle")
    func skippedReservationRecovery() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let a = try recordings.session("first"), b = try recordings.session("second"), c = try recordings.session("third")
        let operations = ProcessingOperations(), engine = HeldEngine()
        defer { engine.finishInference.open(); engine.finishThird.open(); engine.cleanup.open() }
        let coordinator = TranscriptionCoordinator(engine: engine, operations: operations, onStop: { nil })
        await coordinator.enqueue(a); await engine.entered.pass()
        await coordinator.enqueue(b); await coordinator.enqueue(c)
        await operations.cancelAndWait(session: b)
        engine.finishInference.open(); engine.cleanup.open()
        await engine.thirdEntered.pass()
        await coordinator.resumePending(root: recordings.root)
        engine.finishThird.open()
        await coordinator.waitUntilIdle()
        #expect(PostProcessor.readTranscript(b) == nil)
        await coordinator.resumePending(root: recordings.root)
        await coordinator.waitUntilIdle()
        #expect(PostProcessor.readTranscript(b) != nil)
    }

}
