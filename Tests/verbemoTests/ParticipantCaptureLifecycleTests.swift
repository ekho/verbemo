import CallIntegrations
import Foundation
import Testing
@testable import verbemo

actor FakeCallAudioCapture: CallAudioCapture {
    nonisolated let events: AsyncThrowingStream<CallAudioEvent, Error>
    nonisolated let continuation: AsyncThrowingStream<CallAudioEvent, Error>.Continuation
    let error: CallAudioFailure?
    let stopGate: Gate?
    private(set) var starts = 0
    private(set) var stops = 0
    init(error: CallAudioFailure? = nil, stopGate: Gate? = nil) {
        let pair = AsyncThrowingStream<CallAudioEvent, Error>.makeStream()
        events = pair.stream; continuation = pair.continuation
        self.error = error; self.stopGate = stopGate
    }
    func start() async throws { starts += 1; if let error { throw error } }
    func stop() async {
        guard stops == 0 else { return }
        stops += 1
        await stopGate?.pass()
        continuation.finish()
    }
}

@MainActor
struct ParticipantCaptureLifecycleTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Capture transition did not complete")
    }

    @Test func directCaptureNeedsNoDevicePermissionAndMuteDoesNotFallback() async throws {
        let root = try ParticipantAudioRecorderTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder(), capture = FakeCallAudioCapture()
        let session = try RecordingSession(root: root, mic: mic, system: system)
        try session.start(callAudio: { capture }, fallbackPermission: { false })
        try await wait { session.captureSource == .direct }
        capture.continuation.yield(.track(ParticipantAudioRecorderTests.descriptor()))
        capture.continuation.yield(.audio(.init(trackID: "p1", generation: 1, frameStart: 0, sampleRate: 48000, samples: [0, 0])))
        capture.continuation.yield(.heartbeat(frame: 48000, sampleRate: 48000))
        try await wait { session.participantSnapshot?.tracks.count == 1 }
        #expect(!mic.started && !system.started)
        #expect(session.captureSource == .direct)
        session.stop()
        await session.finishCapture()
        let meta = try SessionMeta.read(from: session.dir)
        #expect(meta.tracks.count == 1)
        #expect(meta.tracks.allSatisfy { $0.participant != nil })
        #expect(await capture.stops == 1)
    }

    @Test func failedSetupFallsBackAndIgnoresKTalkMute() async throws {
        let root = try ParticipantAudioRecorderTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder(), capture = FakeCallAudioCapture(error: .unavailable)
        let observation = CallIntegrationRecordingTests().observation(muted: true)
        var context = MeetingContext(); context.applyCall(observation)
        let session = try RecordingSession(root: root, context: context, mic: mic, system: system)
        try session.start(callAudio: { capture }, fallbackPermission: { true })
        try await wait { session.captureSource == .fallback }
        #expect(mic.started && system.started)
        #expect(mic.startCount == 1 && system.startCount == 1)
        #expect(mic.privacyGate == nil)
        session.updateCallObservation([observation])
        session.pause(); session.resume()
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.stop(); await session.finishCapture()
        #expect(try SessionMeta.read(from: session.dir).callAudio?.periods.last?.mode == .fallback)
    }

    @Test func lossPreservesDirectTracksAndPauseThroughFallback() async throws {
        let root = try ParticipantAudioRecorderTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder(), capture = FakeCallAudioCapture()
        let session = try RecordingSession(root: root, mic: mic, system: system)
        try session.start(callAudio: { capture }, fallbackPermission: { true })
        try await wait { session.captureSource == .direct }
        capture.continuation.yield(.track(ParticipantAudioRecorderTests.descriptor()))
        capture.continuation.yield(.audio(.init(trackID: "p1", generation: 1, frameStart: 0, sampleRate: 48000, samples: [0.5])))
        try await wait { session.participantSnapshot?.tracks.count == 1 }
        session.pause()
        capture.continuation.finish(throwing: CallAudioFailure.timedOut)
        try await wait { session.captureSource == .fallback }
        #expect(mic.isMuted && system.isMuted)
        #expect(mic.privacyGate == nil)
        session.stop(); await session.finishCapture()
        let meta = try SessionMeta.read(from: session.dir)
        #expect(meta.tracks.count == 3)
        #expect(meta.callAudio?.periods.map(\.mode) == [.direct, .fallback])
        #expect(await capture.starts == 1)
    }

    @Test func stopWhilePreparingOrClosingDoesNotStartFallback() async throws {
        let root = try ParticipantAudioRecorderTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = Gate(), release = Gate(), capture = FakeCallAudioCapture()
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        let session = try RecordingSession(root: root, mic: mic, system: system)
        try session.start(callAudio: { entered.open(); await release.pass(); return capture }, fallbackPermission: { true })
        await entered.pass()
        session.stop()
        release.open()
        await session.finishCapture()
        #expect(await capture.starts == 0)
        #expect(await capture.stops == 1)
        #expect(!mic.started && !system.started)

        let stopGate = Gate(), nextCapture = FakeCallAudioCapture(stopGate: stopGate)
        let next = try RecordingSession(root: root, mic: mic, system: system)
        try next.start(callAudio: { nextCapture }, fallbackPermission: { true })
        try await wait { next.captureSource == .direct }
        nextCapture.continuation.finish(throwing: CallAudioFailure.unavailable)
        for _ in 0..<200 where await nextCapture.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
        next.stop()
        stopGate.open()
        await next.finishCapture()
        #expect(!mic.started && !system.started)
    }

    @Test func callExitDoesNotFallbackAndDeniedFallbackKeepsPartialAudio() async throws {
        let root = try ParticipantAudioRecorderTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for ended in [true, false] {
            let capture = FakeCallAudioCapture(), mic = FakeMicRecorder(), system = FakeSystemRecorder()
            let session = try RecordingSession(root: root, mic: mic, system: system)
            try session.start(callAudio: { capture }, fallbackPermission: { false })
            try await wait { session.captureSource == .direct }
            capture.continuation.yield(.track(ParticipantAudioRecorderTests.descriptor()))
            try await wait { session.participantSnapshot?.tracks.count == 1 }
            if ended { capture.continuation.yield(.ended); capture.continuation.finish() }
            else { capture.continuation.finish(throwing: CallAudioFailure.unavailable) }
            try await wait { session.captureSource == (ended ? .ended : .failed) }
            #expect(!mic.started && !system.started)
            session.stop(); await session.finishCapture()
            #expect(try SessionMeta.read(from: session.dir).tracks.count == 1)
        }
    }
    @Test func fallbackDeviceFailurePreservesParticipantFilesAndStopsBothDevices() async throws {
        let root = try ParticipantAudioRecorderTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = FakeCallAudioCapture(), mic = FakeMicRecorder(), system = FakeSystemRecorder()
        mic.startError = RefusedToStart()
        let session = try RecordingSession(root: root, mic: mic, system: system)
        try session.start(callAudio: { capture }, fallbackPermission: { true })
        try await wait { session.captureSource == .direct }
        capture.continuation.yield(.track(ParticipantAudioRecorderTests.descriptor()))
        capture.continuation.yield(.audio(.init(trackID: "p1", generation: 1, frameStart: 4800, sampleRate: 48000, samples: [0.5])))
        try await wait { session.participantSnapshot?.offsets.values.first.map { $0 >= 100 } == true }
        capture.continuation.finish(throwing: CallAudioFailure.timedOut)
        try await wait { session.captureSource == .failed }
        #expect(system.stopped)
        session.stop(); await session.finishCapture()
        let meta = try SessionMeta.read(from: session.dir)
        let saved = try #require(meta.tracks.first(where: { $0.participant != nil }))
        #expect(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent(saved.file).path))
        let json = try #require(SessionState.read(session.dir))
        #expect(json["capture_failure"] as? String != nil)
        #expect(mic.startCount == 1 && system.startCount == 1)
    }

    @Test func onlyAFreshUniqueApplicationCallCanBypassDevicePermissions() {
        let observed = CallIntegrationRecordingTests().observation()
        #expect(CallIntegrationMonitor.directCandidate(in: [observed]) == observed)
        #expect(CallIntegrationMonitor.directCandidate(in: [observed, observed]) == nil)
        #expect(CallIntegrationMonitor.directCandidate(in: [observed], now: observed.observedAt.addingTimeInterval(6)) == nil)
        var accessibility = observed; accessibility.source = .accessibility
        #expect(CallIntegrationMonitor.directCandidate(in: [accessibility]) == nil)
        var access = ActivityAccess(microphone: .denied, systemAudio: nil, calendar: nil, directCallReady: true)
        #expect(access.ready && access.automaticBlockReason == nil)
        access.directCallReady = false
        #expect(!access.ready && access.automaticBlockReason != nil)
    }

}
