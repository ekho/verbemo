import AppKit
import Foundation
import Testing
import os
@testable import verbemo

@Suite(.freshHome(config: #"{"offline_echo_cancellation":false,"keep_audio":true,"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct RetranscriptionDiarizationTests {
    private actor Runtime: LocalDiarizationRuntime {
        func prepare() async throws {}
        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            [SpeakerTurn(speakerID: "new-voice", start: 0, end: 1)]
        }
        func release() async {}
    }

    private func oldResult(_ dir: URL) throws {
        try Transcript(engine: "parakeet", model: "old", created_at: "2026-10-01T00:00:00Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "Old words.")]).write(to: dir)
        try SpeakerNames(speakers: ["them": .init(name: "Alice", source: .manual)]).write(to: dir)
        try Data("Old summary.".utf8).write(to: dir.appendingPathComponent("summary.md"))
    }

    private func engine() -> FakeEngine {
        FakeEngine("parakeet", answer: { audio, _ in
            let text = audio.lastPathComponent.contains("mic") ? "Local." : "Remote."
            return [.init(start: 0, end: 1, text: text,
                          words: [.init(start: 0, end: 1, text: text)])]
        })
    }

    private func request(_ model: DiarizationModel?, threshold: Double = 0.8) -> TranscriptVersions.Request {
        .init(engine: "parakeet", diarization: model.map {
            .init(engine: "parakeet", threshold: threshold, explicit: true, model: $0)
        })
    }

    @Test("A persisted job retains model and threshold after config changes and a new coordinator", arguments: DiarizationModel.allCases)
    func persistedChoice(model: DiarizationModel) async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("persisted")
        try oldResult(dir)
        let choice = request(model)
        #expect(PostProcessor.markForRetranscription(dir, request: choice))
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["engine": "whisper", "local_diarization": false,
                              "diarization_model": "community-1", "diarization_threshold": 0.3],
            "speaker_names": ["enabled": false], "summary": ["enabled": false]])
        #expect(try TranscriptVersions.readRequest(dir) == choice)
        #expect(EngineResolver.configuredEngine(for: dir) == "parakeet")
        let used = OSAllocatedUnfairLock(initialState: [DiarizationSettings]())
        let coordinator = TranscriptionCoordinator(engine: engine(),
            diarizerFactory: { settings in used.withLock { $0.append(settings) }; return Runtime() },
            modelFingerprint: { $0.rawValue })
        try await coordinator.transcribeNow(dir)
        #expect(used.withLock { $0.map(\.model) } == [model])
        #expect(used.withLock { $0.first?.threshold } == 0.8)
        #expect(DiarizationState.read(dir)?.request == choice.diarization)
        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(!TranscriptVersions.isRequested(dir))
        let saved = try #require(SessionState.value(dir, TranscriptVersions.requestKey) as? [String: Any])
        #expect(try JSONDecoder().decode(TranscriptVersions.Request.self,
            from: JSONSerialization.data(withJSONObject: saved)) == choice)
        #expect(SpeakerNames.read(from: dir)?.name(for: "them") == nil)
        let previous = try #require(TranscriptVersions.read(dir).first { !$0.isCurrent && !$0.isRequest })
        #expect(SpeakerNames.read(from: previous.dir)?.name(for: "them") == "Alice")
        #expect(try String(contentsOf: previous.dir.appendingPathComponent("summary.md"), encoding: .utf8) == "Old summary.")
    }

    @Test("Two waiting jobs keep different speaker models in one queue")
    func independentJobs() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let a = try recordings.session("a"), b = try recordings.session("b")
        #expect(PostProcessor.markForRetranscription(a, request: request(.lsEendAMI)))
        #expect(PostProcessor.markForRetranscription(b, request: request(.nemotron3)))
        let used = OSAllocatedUnfairLock(initialState: [DiarizationModel]())
        let coordinator = TranscriptionCoordinator(engine: engine(),
            diarizerFactory: { settings in used.withLock { $0.append(settings.model) }; return Runtime() },
            modelFingerprint: { $0.rawValue })
        await coordinator.drainPending(in: recordings.root)
        #expect(used.withLock { $0 } == [.lsEendAMI, .nemotron3])
        #expect(DiarizationState.read(a)?.request.model == .lsEendAMI)
        #expect(DiarizationState.read(b)?.request.model == .nemotron3)
    }

    @Test("An explicit opt-out survives global enablement and clears old sidecars and remote names")
    func disabledJob() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("off")
        try oldResult(dir)
        try DiarizationState(request: .init(engine: "parakeet", threshold: 0.6), status: .completed).write(to: dir)
        try Data("old cache".utf8).write(to: dir.appendingPathComponent("diarization.json"))
        #expect(PostProcessor.markForRetranscription(dir, request: request(nil)))
        try Home.current.writeConfig(["offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["local_diarization": true],
            "speaker_names": ["enabled": false], "summary": ["enabled": false]])
        let coordinator = TranscriptionCoordinator(engine: engine(), modelFingerprint: { _ in
            Issue.record("Disabled job consulted a speaker model")
            throw CancellationError()
        })
        try await coordinator.transcribeNow(dir)
        #expect(DiarizationState.read(dir) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("diarization.json").path))
        #expect(SpeakerNames.read(from: dir)?.name(for: "them") == nil)
        #expect(TranscriptVersions.read(dir).last?.title.contains(localised("Diarization off", "Без диаризации")) == true)
        #expect(Config.localDiarizationEnabled())
    }

    @Test("Missing models and cancellation preserve the old result and the same waiting request", arguments: [false, true])
    func unavailableOrCancelled(cancelled: Bool) async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("blocked")
        try oldResult(dir)
        let selected = request(.community1)
        #expect(PostProcessor.markForRetranscription(dir, request: selected))
        let asr = engine()
        let coordinator = TranscriptionCoordinator(engine: asr, modelFingerprint: { _ in
            if cancelled { throw CancellationError() }
            throw CocoaError(.fileReadNoSuchFile)
        })
        await #expect(throws: (any Error).self) { try await coordinator.transcribeNow(dir) }
        #expect(asr.counts.prepared == 0)
        #expect(try TranscriptVersions.readRequest(dir) == selected)
        #expect(PostProcessor.readTranscript(dir)?.segments.first?.text == "Old words.")
        #expect(SpeakerNames.read(from: dir)?.name(for: "them") == "Alice")
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "Old summary.")
        let retry = TranscriptionCoordinator(engine: engine(), diarizerFactory: { _ in Runtime() },
            modelFingerprint: { $0.rawValue })
        try await retry.transcribeNow(dir)
        #expect(DiarizationState.read(dir)?.request.model == .community1)
    }

    @Test("Text requests remain readable and unknown JSON choices fail closed")
    func legacyAndMalformed() throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("old")
        let file = dir.appendingPathComponent(TranscriptVersions.requestFile)
        try Data("whisper\n".utf8).write(to: file)
        #expect(try TranscriptVersions.readRequest(dir)?.engine == "whisper")
        #expect(TranscriptVersions.read(dir).last?.engine == "whisper")
        for invalid in [#"{"engine":"parakeet","diarization":{"engine":"parakeet","threshold":0.6,"model":"unknown"}}"#,
                        #"{"engine":"parakeet","diarization":{"engine":"whisper","threshold":0.6}}"#,
                        #"{"engine":"parakeet","diarization":{"engine":"parakeet","threshold":9}}"#] {
            try Data(invalid.utf8).write(to: file)
            #expect(throws: (any Error).self) { try TranscriptVersions.readRequest(dir) }
        }
    }

    @Test("A changed model cannot reuse the previous speaker timeline")
    func cacheIsBoundToModel() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("cache")
        let used = OSAllocatedUnfairLock(initialState: [DiarizationModel]())
        let coordinator = TranscriptionCoordinator(engine: engine(),
            diarizerFactory: { settings in used.withLock { $0.append(settings.model) }; return Runtime() },
            modelFingerprint: { $0.rawValue })
        #expect(PostProcessor.markForRetranscription(dir, request: request(.community1)))
        try await coordinator.transcribeNow(dir)
        let old = try Data(contentsOf: dir.appendingPathComponent("diarization.json"))
        #expect(PostProcessor.markForRetranscription(dir, request: request(.lsEendAMI)))
        try await coordinator.transcribeNow(dir)
        #expect(used.withLock { $0 } == [.community1, .lsEendAMI])
        #expect(try Data(contentsOf: dir.appendingPathComponent("diarization.json")) != old)
        #expect(TranscriptVersions.read(dir).contains { !$0.isCurrent && DiarizationState.read($0.dir)?.request.model == .community1 })
    }

    @Test("The sheet exposes all existing models, opt-out and accessible controls")
    @MainActor func options() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("sheet")
        let view = RetranscriptionOptionsView(session: dir, engine: "parakeet")
        #expect(view.diarizationPicker.numberOfItems == 5)
        #expect(view.enginePicker.accessibilityLabel() != nil)
        #expect(view.diarizationPicker.accessibilityLabel() != nil)
        for (index, model) in DiarizationModel.allCases.enumerated() {
            view.diarizationPicker.selectItem(at: index + 2)
            let selected = view.selectedRequest()
            #expect(selected.diarization?.model == model)
            #expect(await RetranscriptionOptionsView.refusal(for: selected) != nil)
        }
        view.diarizationPicker.selectItem(at: 1)
        #expect(view.selectedRequest().diarization == nil)
        #expect(await RetranscriptionOptionsView.refusal(for: view.selectedRequest()) == nil)
        let incompatible = TranscriptVersions.Request(engine: "openai", diarization:
            .init(engine: "openai", threshold: 0.6, explicit: true, model: .lsEendAMI))
        #expect(await RetranscriptionOptionsView.refusal(for: incompatible)?.contains(localised("local", "локальн")) == true)
    }
    private actor InterruptedRuntime: LocalDiarizationRuntime {
        let cancelled: Bool
        init(cancelled: Bool) { self.cancelled = cancelled }
        func prepare() async throws {}
        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            if cancelled { throw CancellationError() }
            throw CocoaError(.fileReadUnknown)
        }
        func release() async {}
    }

    @Test("A speaker failure or cancellation resumes the explicit job after restart with global diarization off", arguments: [false, true])
    func resumeAfterSpeakerInterruption(cancelled: Bool) async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("restart")
        try oldResult(dir)
        #expect(PostProcessor.markForRetranscription(dir, request: request(.lsEendAMI)))
        let first = TranscriptionCoordinator(engine: engine(),
            diarizerFactory: { _ in InterruptedRuntime(cancelled: cancelled) }, modelFingerprint: { $0.rawValue })
        if cancelled {
            await #expect(throws: CancellationError.self) { try await first.transcribeNow(dir) }
        } else {
            try await first.transcribeNow(dir)
        }
        #expect(!Config.localDiarizationEnabled())
        #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root).contains { $0.resolvingSymlinksInPath() == dir.resolvingSymlinksInPath() })
        let second = TranscriptionCoordinator(engine: engine(),
            diarizerFactory: { _ in Runtime() }, modelFingerprint: { $0.rawValue })
        await second.drainPending(in: recordings.root)
        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(DiarizationState.read(dir)?.request.model == .lsEendAMI)
        #expect(TranscriptVersions.read(dir).contains { !$0.isCurrent && SpeakerNames.read(from: $0.dir)?.name(for: "them") == "Alice" })
    }

    @Test("Legacy cloud requests remain provider-owned with local diarization enabled", arguments: ["assemblyai", "auto"])
    func legacyCloud(configured: String) async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("cloud")
        try Home.current.writeConfig(["offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["local_diarization": true],
            "speaker_names": ["enabled": false], "summary": ["enabled": false]])
        #expect(TranscriptVersions.Request.capture(engine: "assemblyai").diarization == nil)
        try Data(configured.utf8).write(to: dir.appendingPathComponent(TranscriptVersions.requestFile))
        let asr = FakeEngine("assemblyai", input: .multichannel, answer: FakeEngine.bothSides)
        try await TranscriptionCoordinator(engine: asr).transcribeNow(dir)
        #expect(PostProcessor.readTranscript(dir)?.engine == "assemblyai")
    }

    @Test("An unavailable model never retires a waiting job")
    func modelAbsenceDoesNotRetire() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("removed")
        try oldResult(dir)
        #expect(PostProcessor.markForRetranscription(dir, request: request(.community1)))
        for _ in 0..<4 {
            let coordinator = TranscriptionCoordinator(engine: engine(), modelFingerprint: { _ in
                throw DiarizationModelStore.StoreError.missingOrCorrupt("synthetic missing model")
            })
            await #expect(throws: (any Error).self) { try await coordinator.transcribeNow(dir) }
        }
        #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
        #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root).contains { $0.resolvingSymlinksInPath() == dir.resolvingSymlinksInPath() })
    }

    @Test("Manual speaker retry keeps the job model and threshold")
    func manualRetryKeepsChoice() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("manual-retry")
        #expect(PostProcessor.markForRetranscription(dir, request: request(.lsEendAMI, threshold: 0.9)))
        let first = TranscriptionCoordinator(engine: engine(),
            diarizerFactory: { _ in InterruptedRuntime(cancelled: false) }, modelFingerprint: { $0.rawValue })
        try await first.transcribeNow(dir)
        try Home.current.writeConfig(["offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["diarization_model": "community-1", "diarization_threshold": 0.4],
            "speaker_names": ["enabled": false], "summary": ["enabled": false]])
        let used = OSAllocatedUnfairLock(initialState: [DiarizationSettings]())
        let second = TranscriptionCoordinator(engine: engine(),
            diarizerFactory: { settings in used.withLock { $0.append(settings) }; return Runtime() },
            modelFingerprint: { $0.rawValue })
        try await second.diarizeNow(dir)
        #expect(used.withLock { $0.first?.model } == .lsEendAMI)
        #expect(used.withLock { $0.first?.threshold } == 0.9)
    }

    @Test("A speaker retry cannot consume a waiting replacement by processing its old version")
    func speakerRetryWhileReplacementWaits() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("queued-replacement")
        let coordinator = TranscriptionCoordinator(engine: engine(),
            diarizerFactory: { _ in Runtime() }, modelFingerprint: { $0.rawValue })
        #expect(PostProcessor.markForRetranscription(dir, request: request(.community1)))
        try await coordinator.transcribeNow(dir)
        #expect(PostProcessor.markForRetranscription(dir, request: request(.lsEendAMI)))
        try await coordinator.diarizeNow(dir)
        #expect(!TranscriptVersions.isRequested(dir))
        #expect(DiarizationState.read(dir)?.request.model == .lsEendAMI)
    }

    @Test("Skipping an old speaker stage cannot discard audio needed by a queued replacement")
    func skipCannotDiscardQueuedAudio() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("skip-old")
        try oldResult(dir)
        try DiarizationState(request: .init(engine: "parakeet", threshold: 0.6), status: .pending).write(to: dir)
        #expect(PostProcessor.markForRetranscription(dir, request: request(.lsEendAMI)))
        await #expect(throws: (any Error).self) { try await TranscriptionCoordinator().skipDiarization(dir) }
        #expect(TranscriptVersions.isRequested(dir))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
    }

}
