import Foundation
import CallIntegrations
import Testing
@testable import verbemo

@Suite(.freshHome(config: #"{"offline_echo_cancellation":false,"transcription":{"local_diarization":true},"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct ParticipantTranscriptionTests {
    private actor Runtime: LocalDiarizationRuntime {
        private var files: [String] = []
        func prepare() async throws {}
        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            files.append(audio.lastPathComponent)
            return [.init(speakerID: "remote", start: 6, end: 7)]
        }
        func release() async {}
        func heard() -> [String] { files }
    }
    static func session(hybrid: Bool = false) throws -> URL {
        let dir = try TestAudio.rawSession()
        let recorder = ParticipantAudioRecorder(directory: dir, offsetMs: 500)
        for (index, id) in ["p1", "p2"].enumerated() {
            try recorder.consume(.track(ParticipantAudioRecorderTests.descriptor(id)))
            try recorder.consume(.audio(.init(trackID: id, generation: 1, frameStart: Int64(index * 48000),
                                             sampleRate: 48000, samples: [0.5])))
        }
        recorder.close()
        let snapshot = recorder.snapshot
        for file in snapshot.files.values {
            try TestAudio.writeTone(to: dir.appendingPathComponent(file), seconds: 1, frequency: 440)
        }
        let info = CallAudioMetadata(integrationID: "ktalk", callID: "test", periods: [], tracks: snapshot.tracks)
        var files = snapshot.files
        var offsets = snapshot.offsets
        if hybrid {
            files.merge(["mic": "mic.caf", "system": "system.caf"]) { _, new in new }
            offsets.merge(["mic": 6000, "system": 6000]) { _, new in new }
        }
        SessionState.update(dir, with: ["files": files, "start_offset_ms": offsets,
            "duration_seconds": 10, "call_audio": try info.jsonValue()])
        return dir
    }

    @Test func independentCloudInputsIgnoreRecognizerLabelsAndKeepOffsets() async throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try SessionMeta.read(from: dir)
        let engine = FakeEngine("assemblyai", input: .multichannel, answer: { _, _ in
            [.init(start: 0.1, end: 0.8, text: "spoken", speaker: "wrong voice")]
        })
        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(engine.counts.heard.count == 2)
        #expect(Set(transcript.segments.map(\.speaker)) == Set(original.tracks.map(\.speaker)))
        #expect(transcript.segments.map(\.start_ms) == [600, 1600])
        let names = try #require(SpeakerNames.read(from: dir))
        #expect(names.speakers.count == 2)
        #expect(Set(names.speakers.values.compactMap(\.name)) == ["../Same name"])
        #expect(names.speakers.values.allSatisfy { $0.source.rawValue == "integration" })
        #expect(try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8).contains("../Same name"))
    }

    @Test func directOnlyDoesNotPrepareDiarizationAndManualNamesSurviveCommit() async throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = try SessionMeta.read(from: dir)
        let speaker = meta.tracks[0].speaker
        try SpeakerNames(speakers: [speaker: .init(name: "Corrected", source: .manual)]).write(to: dir)
        let engine = FakeEngine("whisper")
        let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil },
            diarizerFactory: { settings in
                Issue.record("Known tracks must not load a diarizer")
                return DiarizationEngine(settings: settings)
            }, modelFingerprint: { _ in
                Issue.record("Known tracks must not prepare a diarization model")
                throw CocoaError(.fileNoSuchFile)
            })
        try await coordinator.transcribeNow(dir)
        #expect(DiarizationState.read(dir)?.retainsAudio != true)
        #expect(SpeakerNames.read(from: dir)?.name(for: speaker) == "Corrected")
        let transcript = try #require(PostProcessor.readTranscript(dir))
        try TranscriptVersions.commit(transcript, to: dir, metadata: ["retry_test": true], preserveRemoteNames: false)
        #expect(SpeakerNames.read(from: dir)?.name(for: speaker) == "Corrected")
    }

    @Test func hybridPreservesKnownTracksAlongsideOrdinaryMultichannelInput() async throws {
        let dir = try Self.session(hybrid: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let known = Set(try SessionMeta.read(from: dir).tracks.filter { $0.participant != nil }.map(\.speaker))
        let engine = FakeEngine("assemblyai", input: .multichannel, answer: { file, _ in
            file.lastPathComponent.hasPrefix("call_")
                ? [.init(start: 0, end: 1, text: "participant", speaker: "garbage")]
                : [.init(start: 6, end: 7, text: "fallback local", speaker: "1A"),
                   .init(start: 7, end: 8, text: "fallback remote", speaker: "2A")]
        })
        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(engine.counts.heard.count == 3)
        #expect(Set(transcript.segments.map(\.speaker)) == known.union(["me", "them"]))
        #expect(transcript.segments.map(\.start_ms) == [500, 1500, 6000, 7000])
    }

    @Test func providerRequestsAndCachesDistinguishKnownSpeakers() async throws {
        let body = AssemblyAIEngine.requestBody(audioURL: "fixture", expectedLanguages: [], speechModel: nil,
                                                multichannel: false, knownSpeaker: true)
        #expect(body["speaker_labels"] as? Bool == false)
        #expect(Dictionary(uniqueKeysWithValues: ElevenLabsEngine.requestFields(knownSpeaker: true))["diarize"] == "false")
        let url = URL(fileURLWithPath: "/tmp/participant.caf")
        let assembly = try AssemblyAIEngine(apiKey: "test")
        #expect(await assembly.cacheURL(for: url, multichannel: false) != assembly.cacheURL(for: url, multichannel: false, knownSpeaker: true))
        let eleven = try ElevenLabsEngine(apiKey: "test")
        #expect(await eleven.cacheURL(for: url, channel: nil) != eleven.cacheURL(for: url, channel: nil, knownSpeaker: true))
    }

    @Test func hybridLocalDiarizationOnlyReceivesTheOrdinaryRemoteTrack() async throws {
        let dir = try Self.session(hybrid: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let known = Set(try SessionMeta.read(from: dir).tracks.filter { $0.participant != nil }.map(\.speaker))
        let runtime = Runtime()
        let engine = FakeEngine("whisper", answer: { _, _ in
            [.init(start: 0, end: 1, text: "words", words: [.init(start: 0, end: 1, text: "words")])]
        })
        try await TranscriptionCoordinator(engine: engine, onStop: { nil },
            diarizerFactory: { _ in runtime }, modelFingerprint: { _ in "fixture" }).transcribeNow(dir)
        let state = DiarizationState.read(dir)
        #expect(await runtime.heard().count == 1, "Diarization: \(String(describing: state))")
        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(known.isSubset(of: Set(transcript.segments.map(\.speaker))))
        #expect(transcript.segments.filter { known.contains($0.speaker) }.map(\.start_ms) == [500, 1500])
    }

    @Test func silentKnownTrackDoesNotBlockTheOtherParticipant() async throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = try SessionMeta.read(from: dir)
        try TestAudio.write(to: dir.appendingPathComponent(meta.tracks[0].file), seconds: 1) { _, _ in 0 }
        let engine = FakeEngine("whisper")
        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        #expect(engine.counts.heard.count == 1)
        #expect(PostProcessor.readTranscript(dir)?.segments.map(\.speaker) == [meta.tracks[1].speaker])
    }
}
