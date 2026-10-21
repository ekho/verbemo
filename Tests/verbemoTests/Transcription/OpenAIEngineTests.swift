import AVFoundation
import Foundation
import Testing

@testable import verbemo

/// The parts of the OpenAI engine that don't need an API key: what comes back
/// from one request becomes segments on the session's clock, and a meeting too
/// long for one request is cut up and put back together.
struct OpenAIEngineTests {
    @Test("A small long AAC recording is sliced, and a retry reuses only completed pieces", .freshHome)
    func longAudioRetry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbemo-openai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("mixed.m4a")
        try TestAudio.write(to: audio, seconds: 1401, sampleRate: 48_000, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ]) { _, frame in Float(frame % 80) / 200 - 0.2 }
        let original = try Data(contentsOf: audio)
        #expect(original.count < 25 * 1_048_576)
        let service = StubHTTP { _, count in
            if count == 2 { return .json(500, #"{"error":{"message":"try again"}}"#) }
            return .json(200, """
            {"text":"piece\(count)","duration":1,"segments":[
              {"start":0.1,"end":0.8,"text":"piece\(count)","speaker":"A"}]}
            """)
        }
        let engine = try OpenAITranscriptionEngine(
            apiKey: "test-key", session: service.session, retry: .once)
        await #expect(throws: CloudHTTP.Failure.self) { try await engine.transcribe(audio) }
        try #require(service.requests.count == 2)
        #expect(ProviderCache.files(in: dir).count == 1)
        #expect(try Data(contentsOf: audio) == original)

        let pieces = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("openai-slices"), includingPropertiesForKeys: nil)
        #expect(pieces.count == 2)
        for piece in pieces {
            let duration = try await AVURLAsset(url: piece).load(.duration).seconds
            #expect(duration > 0 && duration < 1400)
            #expect(try Data(contentsOf: piece).count < 25 * 1_048_576)
        }

        let resumed = try OpenAITranscriptionEngine(
            apiKey: "test-key", session: service.session, retry: .once)
        let segments = try await resumed.transcribe(audio)
        #expect(service.requests.count == 3)
        #expect(segments.map(\.text) == ["piece1", "piece3"])
        #expect(segments.map(\.speaker) == ["1A", "2A"])
        #expect(segments.map(\.start) == [0.1, 1390.1])
        #expect(segments.map(\.end) == [0.8, 1390.8])
        #expect(try Data(contentsOf: audio) == original)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("openai-slices").path))
        let cached = try await resumed.transcribe(audio)
        #expect(cached.map(\.text) == segments.map(\.text))
        #expect(service.requests.count == 3)
    }

    private static func response(_ json: String) throws -> OpenAITranscriptionEngine.Response {
        try JSONDecoder().decode(
            OpenAITranscriptionEngine.Response.self, from: Data(json.utf8))
    }

    @Test("Unreadable audio is retained and rejected before any upload", .freshHome)
    func invalidAudioIsNotUploaded() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("mixed.m4a")
        let original = Data("not audio".utf8)
        try original.write(to: audio)
        let service = Self.service()
        let engine = try OpenAITranscriptionEngine(apiKey: "test-key", session: service.session)
        await #expect(throws: (any Error).self) { try await engine.transcribe(audio) }
        #expect(service.requests.isEmpty)
        #expect(try Data(contentsOf: audio) == original)
    }

    private static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbemo-openai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func service() -> StubHTTP {
        StubHTTP { _, count in
            .json(200, """
            {"text":"piece\(count)","duration":1,"segments":[
              {"start":0.1,"end":0.8,"text":"piece\(count)","speaker":"A"}]}
            """)
        }
    }

    @Test("The tighter size or duration ceiling wins")
    func pieceLength() throws {
        #expect(try OpenAITranscriptionEngine.pieceLength(bytes: 20 * 1_048_576, duration: 2530) == 1390)
        #expect(try OpenAITranscriptionEngine.pieceLength(bytes: 55 * 1_048_576, duration: 7200) == 1390)
        #expect(try OpenAITranscriptionEngine.pieceLength(bytes: 100 * 1_048_576, duration: 1500) == 318.75)
        #expect(try OpenAITranscriptionEngine.pieceLength(bytes: 100 * 1_048_576, duration: 1200) == 255)
        #expect(try OpenAITranscriptionEngine.pieceLength(bytes: 10 * 1_048_576, duration: 1200) == nil)
        #expect(try OpenAITranscriptionEngine.pieceLength(bytes: 10 * 1_048_576, duration: 1390) == nil)
        #expect(try OpenAITranscriptionEngine.pieceLength(bytes: 10 * 1_048_576, duration: 1390.01) == 1390)
    }

    @Test("Invalid duration cannot bypass slicing", arguments: [0.0, -1, .nan, .infinity, -.infinity])
    func invalidDuration(duration: Double) {
        #expect(throws: OpenAITranscriptionEngine.EngineError.self) {
            try OpenAITranscriptionEngine.pieceLength(bytes: 1_000_000, duration: duration)
        }
    }

    @Test("Changing boundaries with the same piece count does not reuse stale responses", .freshHome)
    func cacheFollowsBoundaries() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("mixed.caf")
        try TestAudio.writeTone(to: audio, seconds: 110, frequency: 440)
        let service = Self.service()
        let first = try OpenAITranscriptionEngine(
            durationLimit: 60, apiKey: "test-key", session: service.session)
        // The old key had no slice boundaries, even when the piece count matched.
        for index in 1...2 {
            let legacy = ProviderCache.url(in: dir, provider: .openAI, parts: [
                "mixed.caf", first.model,
                OpenAITranscriptionEngine.languageField(
                    for: MeetingLanguages.expected(primary: Config.transcriptionLanguage())) ?? "detect",
                "26214400", "2",
            ], suffix: "\(index)")
            try Data(#"{"text":"stale","duration":110}"#.utf8).write(to: legacy)
        }
        let original = try await first.transcribe(audio)
        #expect(original.map(\.text) == ["piece1", "piece2"])
        #expect(original.map(\.start) == [0.1, 60.1])
        let changed = try OpenAITranscriptionEngine(
            durationLimit: 65, apiKey: "test-key", session: service.session)
        let updated = try await changed.transcribe(audio)
        #expect(updated.map(\.text) == ["piece3", "piece4"])
        #expect(updated.map(\.start) == [0.1, 65.1])
        #expect(updated.map(\.speaker) == ["1A", "2A"])
        let cached = try await changed.transcribe(audio)
        #expect(cached.map(\.text) == updated.map(\.text))
        #expect(service.requests.count == 4)
    }

    @Test("Size-limited AAC parts fit after encoding", .freshHome, arguments: [1390.0, 90.0])
    func encodedSize(durationLimit: Double) async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("mixed.m4a")
        try TestAudio.write(to: audio, seconds: 180, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ]) { _, frame in Float(frame % 80) / 200 - 0.2 }
        #expect(try Data(contentsOf: audio).count > 600_000)
        let service = StubHTTP { _, _ in .json(500, "{}") }
        let engine = try OpenAITranscriptionEngine(
            requestLimit: 600_000, durationLimit: durationLimit,
            apiKey: "test-key", session: service.session, retry: .once)
        await #expect(throws: CloudHTTP.Failure.self) { try await engine.transcribe(audio) }
        let pieces = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("openai-slices"), includingPropertiesForKeys: nil)
        #expect(pieces.count >= 3)
        for piece in pieces {
            #expect(try Data(contentsOf: piece).count <= 600_000)
            let duration = try await AVURLAsset(url: piece).load(.duration).seconds
            #expect(duration > 0 && duration < durationLimit + 10)
        }
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("An encoded piece over the byte budget is never uploaded", .freshHome)
    func oversizedEncodingIsNotUploaded() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("mixed.caf")
        try TestAudio.writeTone(to: audio, seconds: 61, frequency: 440)
        let service = Self.service()
        let engine = try OpenAITranscriptionEngine(
            requestLimit: 1000, apiKey: "test-key", session: service.session)
        await #expect(throws: OpenAITranscriptionEngine.EngineError.self) { try await engine.transcribe(audio) }
        #expect(service.requests.isEmpty)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("Diarized segments keep their speakers and land on the session clock")
    func segmentsAreShifted() throws {
        let decoded = try Self.response("""
        {"task":"transcribe","duration":12.0,"text":"hello there",
         "segments":[
           {"type":"transcript.text.segment","id":"1","start":0.5,"end":2.0,
            "text":"hello","speaker":"A"},
           {"type":"transcript.text.segment","id":"2","start":3.0,"end":4.5,
            "text":"there","speaker":"B"}]}
        """)

        let segments = OpenAITranscriptionEngine.segments(
            from: decoded, offset: 600, labelPrefix: nil)

        #expect(segments.count == 2)
        #expect(segments[0].start == 600.5)
        #expect(segments[0].end == 602.0)
        #expect(segments[0].speaker == "A")
        #expect(segments[1].text == "there")
        #expect(segments[1].start == 603.0)
    }

    /// Labels are per request, so the "A" of the second piece is a different
    /// person from the "A" of the first as far as anyone knows. Prefixing
    /// keeps them apart; merging them would hand two strangers one name.
    @Test("A sliced meeting keeps each piece's speakers apart")
    func labelsArePerSlice() throws {
        let decoded = try Self.response("""
        {"segments":[{"start":1.0,"end":2.0,"text":"go on","speaker":"A"}]}
        """)

        let first = OpenAITranscriptionEngine.segments(
            from: decoded, offset: 0, labelPrefix: "1")
        let second = OpenAITranscriptionEngine.segments(
            from: decoded, offset: 2400, labelPrefix: "2")

        #expect(first[0].speaker == "1A")
        #expect(second[0].speaker == "2A")
        #expect(second[0].start == 2401.0)
    }

    /// A response with speech but nothing the diarizer would split: keeping
    /// the flat text beats dropping the minutes it covers.
    @Test("A response with no segments keeps its text")
    func flatTextSurvives() throws {
        let decoded = try Self.response("""
        {"text":"  one long take  ","duration":30.0}
        """)

        let segments = OpenAITranscriptionEngine.segments(
            from: decoded, offset: 60, labelPrefix: nil)

        #expect(segments.count == 1)
        #expect(segments[0].text == "one long take")
        #expect(segments[0].start == 60)
        #expect(segments[0].end == 90)
    }

    @Test("An empty response yields nothing rather than an empty segment")
    func emptyIsEmpty() throws {
        let decoded = try Self.response("""
        {"text":"   ","duration":0,"segments":[]}
        """)
        #expect(OpenAITranscriptionEngine.segments(
            from: decoded, offset: 0, labelPrefix: nil).isEmpty)
    }

    /// The cache is the server's own answer, and a retry after a crash has to
    /// find every piece of it — so the name says which piece it is, and the
    /// ordinary one-request case keeps the plain name.
    /// The engine used to pass the configured language straight through, which
    /// is a pin — and "meetings are mostly in Russian" is precisely the case
    /// where a pin is sometimes wrong. OpenAI has no expected_languages to
    /// narrow detection with instead, so the only safe answer is to say
    /// nothing and let the model listen.
    @Test("A language is named only when it cannot be the wrong one")
    func languageIsNamedOnlyWhenUnambiguous() {
        #expect(OpenAITranscriptionEngine.languageField(for: ["en"]) == "en")
        #expect(OpenAITranscriptionEngine.languageField(for: ["ru", "en"]) == nil)
        #expect(OpenAITranscriptionEngine.languageField(for: []) == nil)
    }

    /// The rule stated against the setting people actually change, so that a
    /// later change to what a choice expects can't quietly restore the pin.
    @Test("Choosing Russian sends no language at all")
    func russianIsNotPinned() {
        let expected = MeetingLanguages.expected(primary: "ru")
        #expect(OpenAITranscriptionEngine.languageField(for: expected) == nil)
        #expect(OpenAITranscriptionEngine.languageField(
            for: MeetingLanguages.expected(primary: "en")) == "en")
    }

    /// A response is only reused for the audio it came from: every piece of a
    /// sliced meeting has its own, and none of them is the whole meeting's —
    /// a first piece answered from the whole meeting's cache would carry an
    /// hour of text for three minutes of audio.
    @Test("Every piece of a sliced meeting has its own cached response")
    func cacheNames() async throws {
        let engine = try OpenAITranscriptionEngine(apiKey: "test-key")
        let folder = URL(fileURLWithPath: "/tmp/meeting")
        let audio = folder.appendingPathComponent("mixed.m4a")
        var pieces: [URL] = []
        for index in 0..<3 {
            pieces.append(await engine.cacheURL(
                in: folder, audio: audio,
                slice: AudioSlicer.Slice(url: audio, offset: Double(index) * 60, duration: 60),
                piece: index, of: 3))
        }
        #expect(Set(pieces).count == 3)
        #expect(!pieces.contains(await engine.cacheURL(
            in: folder, audio: audio, slice: AudioSlicer.Slice(url: audio, offset: 0, duration: 180),
            piece: 0, of: 1)))
    }

    /// 25 MB is the API's ceiling; the pieces have to come in under it with
    /// room for a bitrate that isn't perfectly constant.
    @Test("Slice length keeps every piece under the request limit")
    func sliceMath() {
        let limit = OpenAITranscriptionEngine.defaultRequestLimit

        // Under the limit: nothing to cut.
        #expect(AudioSlicer.sliceLength(
            bytes: 20 * 1_048_576, duration: 3000, limit: limit) == nil)

        // Two hours at the mix's own 64 kbit/s, which is about 55 MB.
        let bytes: Int64 = 55 * 1_048_576
        let length = try! #require(AudioSlicer.sliceLength(
            bytes: bytes, duration: 7200, limit: limit))
        let bytesPerSecond = Double(bytes) / 7200
        #expect(Double(length) * bytesPerSecond < Double(limit))
        // And not so cautious that it turns one meeting into a dozen uploads.
        #expect(length > 2000)
    }
}
