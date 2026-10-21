@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import verbemo

actor FixtureNemotronRuntime: NemotronRuntime {
    private(set) var prepared: [URL] = []
    private(set) var sessions: [FixtureNemotronRecognition] = []
    func prepare(at directory: URL) async throws { prepared.append(directory) }
    func session(language: String) async throws -> any NemotronRecognition {
        let session = FixtureNemotronRecognition()
        sessions.append(session)
        return session
    }
    func release() async {}
}
actor FixtureNemotronRecognition: NemotronRecognition {
    private(set) var counts: [Int] = []
    private(set) var finished = false
    private(set) var cleaned = false
    func process(_ samples: [Float]) async throws { counts.append(samples.count) }
    func finish() async throws -> (text: String, timings: [TokenTiming]) {
        finished = true
        let duration = Double(counts.reduce(0, +)) / 16_000
        return ("Привет мир. Конец.", [
            .init(token: "▁При", tokenId: 1, startTime: 0, endTime: 0.1, confidence: 1),
            .init(token: "вет", tokenId: 2, startTime: 0.1, endTime: 0.2, confidence: 1),
            .init(token: "▁мир.", tokenId: 3, startTime: 0.25, endTime: 0.4, confidence: 1),
            .init(token: "▁Конец.", tokenId: 4, startTime: duration - 0.2, endTime: duration + 0.02, confidence: 1),
        ])
    }
    func cleanup() async { cleaned = true }
}

struct NemotronEngineTests {
    @Test("Downloaded Nemotron recognizes a real audio fixture with native word times",
          .enabled(if: ProcessInfo.processInfo.environment["VERBEMO_RUN_NEMOTRON_TEST"] == "1"))
    func downloadedModel() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["VERBEMO_NEMOTRON_MODEL_ROOT"]))
        let audio = URL(fileURLWithPath: try #require(env["VERBEMO_NEMOTRON_TEST_AUDIO"]))
        let output = URL(fileURLWithPath: try #require(env["VERBEMO_NEMOTRON_TEST_OUTPUT"]))
        let store = NemotronModelStore(root: root) { _, _, _ in
            Issue.record("A ready live cache must not trigger a download")
            throw URLError(.notConnectedToInternet)
        }
        try #require(store.isReady(language: "ru-RU"))
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let engine = NemotronEngine(store: store, language: "ru")
        let started = Date()
        try await engine.prepare()
        let result = try await engine.transcribe(audio)
        await engine.release()
        let data = try JSONEncoder().encode(result)
        try data.write(to: output)
        let words = result.flatMap { $0.words ?? [] }
        print("Nemotron integration: duration=\(duration)s elapsed=\(Date().timeIntervalSince(started))s segments=\(result.count) words=\(words.count)")
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0.words?.isEmpty == false })
        // The converted stream length rounds to a 16 kHz sample.
        #expect(words.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 1.0 / 16_000 })
        #expect((words.last?.end ?? 0) > duration - 10, "The final partial chunk must reach the transcript")
    }

    @Test("Final recognition reads bounded chunks, flushes the tail and resets every track/pass")
    func boundedAndIndependent() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NemotronModelStore(root: root) { _, _, _ in Issue.record("Downloaded a ready live model"); throw URLError(.unknown) }
        try NemotronFixtures.install(at: store.variantDirectory(language: "ru-RU"))
        let audio = root.appendingPathComponent("test.caf")
        try TestAudio.writeTone(to: audio, seconds: 25.17, frequency: 220, sampleRate: 16_000)
        let runtime = FixtureNemotronRuntime()
        let engine = NemotronEngine(store: store, runtime: runtime, language: "ru")
        try await engine.prepare()
        let first = try await engine.transcribe(audio)
        let second = try await engine.transcribe(audio)
        let sessions = await runtime.sessions
        #expect(sessions.count == 2)
        #expect(await sessions[0].counts == [160_000, 160_000, 82_720])
        #expect(await sessions[1].counts == [160_000, 160_000, 82_720])
        #expect(await sessions[0].finished)
        #expect(await sessions[0].cleaned)
        #expect(await sessions[1].finished)
        #expect(await sessions[1].cleaned)
        #expect(first.map(\.text) == ["Привет мир.", "Конец."])
        #expect(first.first?.words?.map(\.text) == ["Привет", "мир."])
        #expect(first.last?.end == 25.17)
        #expect(first.map(\.start) == second.map(\.start))
        #expect(await runtime.prepared == [store.variantDirectory(language: "ru-RU")])
        #expect(engine.name == "nemotron")
        #expect(engine.model.hasSuffix("multilingual/1120ms"))
        #expect(engine.optionsFingerprint.contains("language=ru-RU"))
    }

    @Test("Invalid native timestamps do not become invented word positions")
    func invalidTimings() {
        let result = NemotronEngine.segments(text: "текст", timings: [
            .init(token: "▁текст", tokenId: 1, startTime: 0.1, endTime: 25, confidence: 1)
        ], duration: 1)
        #expect(result.count == 1)
        #expect(result[0].words == nil)
        #expect(result[0].text == "текст")
    }

    @Test("Nemotron is a configured local engine with a language-specific immutable identity", .freshHome)
    func engineSelection() {
        Config.update(path: ["transcription", "engine"], value: "nemotron")
        Config.update(path: ["transcription", "local_engine"], value: "nemotron")
        #expect(Config.problems().isEmpty)
        #expect(Config.transcriptionEngine() == "nemotron")
        #expect(Config.transcriptionLocalEngine() == "nemotron")
        #expect(EngineResolver.knownEngines.contains("nemotron"))
        #expect(EngineResolver.resolveEngine(configured: "nemotron", hasKey: true, localModels: true) == .local)
        #expect(EngineResolver.localEngine(named: "nemotron") is NemotronEngine)
        #expect(!Config.liveTranscriptionEnabled())
        let english = NemotronEngine(language: "en"), russian = NemotronEngine(language: "ru")
        #expect(english.model != russian.model)
        #expect(english.optionsFingerprint != russian.optionsFingerprint)
    }

    @Test("New and imported sessions retain timed diarized Nemotron results and version history",
          .freshHome(config: #"{"offline_echo_cancellation":false,"keep_audio":true,"transcription":{"engine":"nemotron","local_engine":"nemotron","local_diarization":true},"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#),
          arguments: [false, true])
    func sessionPipeline(imported: Bool) async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NemotronModelStore(root: root)
        try NemotronFixtures.install(at: store.variantDirectory(language: "auto"))
        let dir: URL
        if imported {
            let source = recordings.root.appendingPathComponent("import.wav")
            try TestAudio.writeTone(to: source, seconds: 2, frequency: 330)
            let result = await MediaImportCoordinator(root: recordings.root).importFiles([source])
            dir = try #require(result.imported.first?.session)
        } else { dir = try recordings.session("recorded", seconds: 2) }
        let runtime = FixtureNemotronRuntime()
        let engine = NemotronEngine(store: store, runtime: runtime, language: nil)
        let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil },
            diarizerFactory: { _ in FixtureNemotronDiarizer() }, modelFingerprint: { _ in "test-diarizer" })
        try await coordinator.transcribeNow(dir)
        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.engine == "nemotron")
        #expect(transcript.model == engine.model)
        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(transcript.segments.allSatisfy { $0.start_ms >= 0 && $0.end_ms <= 2001 && $0.start_ms < $0.end_ms })
        #expect(transcript.segments.contains { $0.text.contains("Конец") })
        #expect(transcript.segments.contains { $0.speaker.contains("A") || $0.speaker.contains("B") })
        let versions = TranscriptVersions.read(dir)
        #expect(!versions.isEmpty)
        #expect(versions.filter(\.isCurrent).count == 1)
        #expect(versions.first?.model == engine.model)
        #expect(await MainActor.run { MeetingLibraryController.markForRetranscription(dir, engine: "nemotron") == nil })
        try await coordinator.transcribeNow(dir)
        let retried = TranscriptVersions.read(dir)
        // Diarization also preserves the provisional ASR generation.
        #expect(retried.count > versions.count)
        #expect(retried.filter(\.isCurrent).count == 1)
        #expect(retried.allSatisfy { $0.engine == "nemotron" && $0.model == engine.model })
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
    }
}
private actor FixtureNemotronDiarizer: LocalDiarizationRuntime {
    func prepare() async throws {}
    func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
        [.init(speakerID: "A", start: 0, end: 1), .init(speakerID: "B", start: 1, end: 2)]
    }
    func release() async {}
}
