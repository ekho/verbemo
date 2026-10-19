import Foundation
import Testing
import os

@testable import verbemo

struct WakefulnessTests {
    @Test("Waiting allows idle sleep while preserving App Nap and termination protection")
    func lifetimeOptions() {
        #expect(ProcessInfo.ActivityOptions.userInitiated.contains(.idleSystemSleepDisabled))
        #expect(!Wakefulness.lifetime.contains(.idleSystemSleepDisabled))
        #expect(Wakefulness.lifetime.contains(.userInitiatedAllowingIdleSystemSleep))
        #expect(Wakefulness.lifetime.contains(.suddenTerminationDisabled))
        #expect(Wakefulness.lifetime.contains(.automaticTerminationDisabled))
        #expect(Wakefulness.recording.contains(.idleSystemSleepDisabled))
        #expect(Wakefulness.transcribing.contains(.idleSystemSleepDisabled))
    }
}

@Suite(.freshHome(config: #"{"offline_echo_cancellation":false,"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct DrainWakefulnessTests {
    @Test("Foundation exposes recording and queue assertions for this process, then releases them")
    func realPowerAssertions() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("power-manager")
        let queueReason = "verbemo issue 5 transcribing \(UUID().uuidString)"
        let lifetime = ProcessInfo.processInfo.beginActivity(
            options: Wakefulness.lifetime, reason: "verbemo issue 5 waiting")
        defer { ProcessInfo.processInfo.endActivity(lifetime) }
        #expect(try !ownSleepAssertions().contains("verbemo issue 5 waiting"))

        do {
            let recording = ProcessInfo.processInfo.beginActivity(
                options: Wakefulness.recording, reason: "verbemo issue 5 recording")
            defer { ProcessInfo.processInfo.endActivity(recording) }
            #expect(try ownSleepAssertions().contains("verbemo issue 5 recording"))
        }
        #expect(try !ownSleepAssertions().contains("verbemo issue 5 recording"))

        let engine = FakeEngine("parakeet", answer: { audio, call in
            #expect(try ownSleepAssertions().contains(queueReason))
            return try FakeEngine.speech(audio, call)
        })
        let coordinator = TranscriptionCoordinator(
            engine: engine, onStop: { nil }, keepAwake: { _ in Wakefulness.holdAwake(queueReason) })
        await coordinator.enqueue(dir)
        await coordinator.waitUntilIdle()
        #expect(!engine.counts.heard.isEmpty)
        #expect(try !ownSleepAssertions().contains(queueReason))
    }

    @Test("A drain releases its hold after success, failure or cancellation", arguments: Outcome.allCases)
    func drainLifetime(outcome: Outcome) async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("first")
        let holds = HoldCounter()
        let engine = FakeEngine("parakeet", answer: { audio, call in
            #expect(holds.held == 1)
            try outcome.check()
            return try FakeEngine.speech(audio, call)
        })
        let coordinator = TranscriptionCoordinator(
            engine: engine, onStop: { nil }, keepAwake: holds.begin)

        await coordinator.enqueue(dir)
        await coordinator.waitUntilIdle()

        #expect(!engine.counts.heard.isEmpty)
        #expect(engine.counts.released == 1)
        #expect(holds.begun == 1)
        #expect(holds.held == 0)
        #expect(!SessionClaim.isHeld(dir))
        #expect((PostProcessor.readTranscript(dir) != nil) == (outcome == .success))
        if outcome == .cancelled {
            #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
            #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root).contains {
                $0.resolvingSymlinksInPath() == dir.resolvingSymlinksInPath()
            })
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        }
    }

    @Test("Enqueue during engine release starts a new drain with its own hold")
    func restartDuringRelease() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let first = try recordings.session("first")
        let second = try recordings.session("second")
        let holds = HoldCounter()
        let engine = ReleasingEngine { #expect(holds.held == 1) }
        defer { engine.finishRelease.open() }
        let coordinator = TranscriptionCoordinator(
            engine: engine, onStop: { nil }, keepAwake: holds.begin)

        await coordinator.enqueue(first)
        await engine.releasing.pass()
        #expect(holds.held == 1, "The hold must survive asynchronous engine cleanup")
        await coordinator.enqueue(second)
        engine.finishRelease.open()
        await coordinator.waitUntilIdle()

        #expect(PostProcessor.readTranscript(first) != nil)
        #expect(PostProcessor.readTranscript(second) != nil)
        #expect(engine.wrapped.counts.released == 2)
        #expect(holds.begun == 2)
        #expect(holds.remainingAfterRelease == [1, 0], "A restarted drain must overlap the old hold")
        #expect(holds.held == 0)
        await coordinator.resumePending(root: recordings.root)
        await coordinator.waitUntilIdle()
        #expect(holds.begun == 2, "An empty queue must not acquire another hold")
    }

    @Test("A queued drain holds sleep off while waiting for a direct processing turn")
    func waitingForProcessingTurn() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let first = try recordings.session("direct")
        let second = try recordings.session("queued")
        let holds = HoldCounter()
        let engine = ReleasingEngine {}
        defer { engine.finishRelease.open() }
        let coordinator = TranscriptionCoordinator(
            engine: engine, onStop: { nil }, keepAwake: holds.begin)
        let direct = Task { try await coordinator.transcribeNow(first) }
        await engine.releasing.pass()
        #expect(holds.begun == 0)

        await coordinator.enqueue(second)
        await holds.started.pass()
        #expect(holds.held == 1)
        #expect(PostProcessor.readTranscript(second) == nil)
        engine.finishRelease.open()
        try await direct.value
        await coordinator.waitUntilIdle()
        #expect(PostProcessor.readTranscript(second) != nil)
        #expect(holds.begun == 1)
        #expect(holds.held == 0)
    }

    @Test("A direct CLI transcription does not acquire a queue hold")
    func directProcessingAllowsSleep() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("direct")
        let holds = HoldCounter()
        let coordinator = TranscriptionCoordinator(
            engine: FakeEngine("parakeet"), onStop: { nil }, keepAwake: holds.begin)
        try await coordinator.transcribeNow(dir)
        #expect(PostProcessor.readTranscript(dir) != nil)
        #expect(holds.begun == 0)
    }

    @Test("Post-processing keeps the drain's hold until the summary is saved")
    func postProcessingLifetime() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("summary", state: [
            SessionState.Key.summaryStatus: SessionState.deferred,
        ])
        let holds = HoldCounter()
        let model = FakeModel("claude") { _, _, _ in
            #expect(holds.held == 1)
            return "## Summary\nSynthetic meeting."
        }
        let home = Home.withModels([model])
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig([
            "offline_echo_cancellation": false,
            "speaker_names": ["enabled": false],
            "summary": ["enabled": true],
        ])
        await Home.$scoped.withValue(home) {
            let coordinator = TranscriptionCoordinator(
                engine: FakeEngine("parakeet"), onStop: { nil }, keepAwake: holds.begin)
            await coordinator.enqueue(dir)
            await coordinator.waitUntilIdle()
        }
        #expect(model.callCount == 1)
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
            == "## Summary\nSynthetic meeting.\n")
        #expect(holds.begun == 1)
        #expect(holds.held == 0)
    }
}

@Suite(.freshHome(config: #"{"offline_echo_cancellation":false,"transcription":{"local_diarization":true},"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct DiarizationWakefulnessTests {
    @Test("The queue holds through diarization and releases on every outcome", arguments: Outcome.allCases)
    func diarizationLifetime(outcome: Outcome) async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("speakers")
        let holds = HoldCounter()
        let runtime = ObservedDiarizer(holds: holds, outcome: outcome)
        let engine = FakeEngine("parakeet", answer: { audio, _ in
            #expect(holds.held == 1)
            let text = audio.lastPathComponent == "mic.caf" ? "local" : "remote"
            return [TranscriptSegment(start: 0, end: 1, text: text,
                words: [TranscriptWord(start: 0, end: 1, text: text)])]
        })
        let coordinator = TranscriptionCoordinator(
            engine: engine, onStop: { nil }, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "fixture-model" }, keepAwake: holds.begin)

        await coordinator.enqueue(dir)
        await coordinator.waitUntilIdle()

        #expect(await runtime.calls == 1)
        #expect(await runtime.releases == 1)
        #expect(holds.begun == 1)
        #expect(holds.held == 0)
        #expect(!SessionClaim.isHeld(dir))
        #expect(PostProcessor.readTranscript(dir) != nil)
        #expect(DiarizationState.read(dir)?.status == (outcome == .success ? .completed : .pending))
        if outcome != .success {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
            #expect(DiarizationState.read(dir)?.attempts == (outcome == .cancelled ? 0 : 1))
        }
    }
}

enum Outcome: CaseIterable, Sendable {
    case success, failure, cancelled
    struct Failed: Error {}
    func check() throws {
        switch self {
        case .success: break
        case .failure: throw Failed()
        case .cancelled: throw CancellationError()
        }
    }
}

private final class HoldCounter: Sendable {
    private struct State {
        var held = 0
        var begun = 0
        var remainingAfterRelease: [Int] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let started = Gate()
    var held: Int { state.withLock { $0.held } }
    var begun: Int { state.withLock { $0.begun } }
    var remainingAfterRelease: [Int] { state.withLock { $0.remainingAfterRelease } }

    func begin(_ reason: String) -> () -> Void {
        #expect(reason == "verbemo is transcribing a meeting")
        state.withLock { $0.held += 1; $0.begun += 1 }
        started.open()
        return {
            self.state.withLock {
                $0.held -= 1
                $0.remainingAfterRelease.append($0.held)
            }
        }
    }
}

private final class ReleasingEngine: TranscriptionEngine {
    let wrapped = FakeEngine("parakeet")
    let observe: @Sendable () -> Void
    let releasing = Gate()
    let finishRelease = Gate()
    init(observe: @escaping @Sendable () -> Void) { self.observe = observe }
    var name: String { wrapped.name }
    var model: String { wrapped.model }
    var input: TranscriptionInput { wrapped.input }
    func prepare() async throws {
        observe()
        try await wrapped.prepare()
    }
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        observe()
        return try await wrapped.transcribe(audio)
    }
    func release() async {
        observe()
        releasing.open()
        await finishRelease.pass()
        observe()
        await wrapped.release()
    }
}

private actor ObservedDiarizer: LocalDiarizationRuntime {
    let holds: HoldCounter
    let outcome: Outcome
    private(set) var calls = 0
    private(set) var releases = 0
    init(holds: HoldCounter, outcome: Outcome) { self.holds = holds; self.outcome = outcome }
    func prepare() async throws { #expect(holds.held == 1) }
    func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
        #expect(holds.held == 1)
        calls += 1
        try outcome.check()
        return [SpeakerTurn(speakerID: "voice", start: 0, end: 1)]
    }
    func release() async {
        #expect(holds.held == 1)
        releases += 1
    }
}

private func ownSleepAssertions() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g", "assertions"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let pid = ProcessInfo.processInfo.processIdentifier
    return String(decoding: data, as: UTF8.self).split(separator: "\n")
        .filter { $0.contains("pid \(pid)(") && $0.contains("PreventUserIdleSystemSleep") }
        .joined(separator: "\n")
}
