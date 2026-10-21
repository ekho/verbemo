import AVFoundation
import Foundation

/// OpenAI's diarizing transcription, over the mixed-down session audio.
///
/// The model is `gpt-4o-transcribe-diarize`, and it is the only one of
/// OpenAI's transcription models verbemo can use: the others return running text
/// with no timings at all, and a transcript with no clock can be neither
/// aligned with the recording nor attributed to a speaker. This one returns
/// segments with start, end and a speaker label — the same shape AssemblyAI
/// returns, which is why both are `.mixed` engines and share everything
/// downstream.
///
/// Uploads are bounded by size and a defensive duration cap (see below),
/// with timings shifted back onto the session clock. `chunking_strategy` is
/// required for anything over 30 seconds — the API refuses outright without
/// it, so it is always sent.
///
/// Every response is cached next to the audio (see `ProviderCache`), so a
/// retry after a crash re-renders from disk instead of re-uploading and
/// paying again.
actor OpenAITranscriptionEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noAPIKey
        case empty
        case invalidAudio
        case uploadLimit

        /// Only "there was no speech in this audio" is permanent; a silent
        /// recording will still be silent tomorrow. HTTP answers are
        /// classified by `CloudHTTP`.
        var isPermanent: Bool {
            if case .empty = self { return true }
            return false
        }

        var isEnvironmental: Bool {
            if case .noAPIKey = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .noAPIKey:
                return "no OpenAI API key — put one in \(Config.openAIKeyPath.path)"
                    + " (chmod 600) or set OPENAI_API_KEY"
            case .empty:
                return "openai returned no speech"
            case .invalidAudio:
                return "openai needs readable audio with a positive finite duration and upload limits"
            case .uploadLimit:
                return "openai audio exceeds the upload limits after encoding"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// The API's own per-request ceiling. Not a guess: 25 MB is what the
    /// documentation states and what a larger file is refused with.
    static let defaultRequestLimit: Int64 = 25 * 1_048_576

    /// Defensive, not a documented API contract: amanu PR #18 reported a
    /// 1400s rejection. Cut at 1390s to leave 10s for AAC padding. Official
    /// docs checked 2026-10-22 only establish 25 MB; see docs/testing/openai-duration-cap.md.
    static let defaultDurationLimit: TimeInterval = 1390
    private static let durationSlack: TimeInterval = 10

    nonisolated let name = "openai"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .mixed

    private let apiKey: String
    /// The languages this meeting may be in. Consulted for one decision only —
    /// whether a language can be named at all — because the API has no way to
    /// narrow detection to a set the way assemblyai's `expected_languages`
    /// does. See `languageField(for:)`.
    private let expected: [String]
    /// A parameter rather than a constant so the sliced path can be exercised
    /// against real audio and the real API without a meeting long enough to
    /// pass 25 MB — an hour of it, every time anyone wanted to check.
    private let requestLimit: Int64
    private let durationLimit: TimeInterval
    private let http: CloudHTTP

    /// Throws rather than failing at transcribe time — a missing key should
    /// show up in the log the moment the engine is picked, not an upload later.
    init(
        requestLimit: Int64 = OpenAITranscriptionEngine.defaultRequestLimit,
        durationLimit: TimeInterval = OpenAITranscriptionEngine.defaultDurationLimit,
        apiKey: String? = nil,
        session: URLSession = .shared,
        retry: CloudHTTP.RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        guard let key = apiKey ?? Config.openAIKey() else { throw EngineError.noAPIKey }
        self.apiKey = key
        expected = MeetingLanguages.expected(primary: Config.transcriptionLanguage())
        model = Config.openAITranscriptionModel()
        self.requestLimit = requestLimit
        self.durationLimit = durationLimit
        http = CloudHTTP(service: .openAI, session: session, retry: retry, sleep: sleep)
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let dir = audio.deletingLastPathComponent()
        let slices = try await sliced(audio)
        if slices.count > 1 {
            note("\(slices.count) pieces — the mix is over the API's limit")
        }

        var segments: [TranscriptSegment] = []
        for (index, slice) in slices.enumerated() {
            let cache = cacheURL(in: dir, audio: audio, slice: slice, piece: index, of: slices.count)
            let response: Response
            if let cached = try? Data(contentsOf: cache),
               let decoded = try? JSONDecoder().decode(Response.self, from: cached) {
                note("reusing cached \(cache.lastPathComponent)")
                response = decoded
            } else {
                let raw = try await send(slice.url)
                response = try http.decode(Response.self, from: raw, what: "transcription")
                try? raw.write(to: cache, options: .atomic)
            }
            segments += Self.segments(
                from: response,
                offset: slice.offset,
                // Labels are per request, so the "A" of one piece is not the
                // "A" of the next. Keeping them apart lets attribution settle
                // each voice on its own evidence instead of merging two
                // strangers who happened to be first in their piece.
                labelPrefix: slices.count > 1 ? "\(index + 1)" : nil
            )
        }
        Self.discardSlices(slices, of: audio)

        guard !segments.isEmpty else { throw EngineError.empty }
        return segments
    }

    // MARK: - slicing

    private func sliced(_ audio: URL) async throws -> [AudioSlicer.Slice] {
        let attributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        let bytes = attributes[.size] as? Int64 ?? 0
        let duration = Self.duration(of: audio)
        let slices: [AudioSlicer.Slice]
        if let length = try Self.pieceLength(
            bytes: bytes, duration: duration, requestLimit: requestLimit, durationLimit: durationLimit
        ) {
            slices = try await AudioSlicer.slice(audio, every: length, into: Self.sliceDirectory(audio))
        } else {
            slices = [AudioSlicer.Slice(url: audio, offset: 0, duration: duration)]
        }
        // Average source bitrate is only an estimate; check the encoded files before any upload.
        for slice in slices {
            let size = try slice.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let encodedDuration = try await AVURLAsset(url: slice.url).load(.duration).seconds
            guard size > 0, encodedDuration.isFinite, encodedDuration > 0 else {
                throw EngineError.invalidAudio
            }
            guard size <= requestLimit, encodedDuration <= durationLimit + Self.durationSlack else {
                throw EngineError.uploadLimit
            }
        }
        return slices
    }

    /// Adapted from https://github.com/gsamat/amanu/pull/18: the tighter ceiling wins.
    static func pieceLength(
        bytes: Int64, duration: TimeInterval,
        requestLimit: Int64 = defaultRequestLimit,
        durationLimit: TimeInterval = defaultDurationLimit
    ) throws -> TimeInterval? {
        guard bytes > 0, requestLimit > 0, duration.isFinite, duration > 0,
              durationLimit.isFinite, durationLimit > 0 else { throw EngineError.invalidAudio }
        let bySize = AudioSlicer.sliceLength(bytes: bytes, duration: duration, limit: requestLimit)
        guard bySize != nil || duration > durationLimit else { return nil }
        return min(bySize ?? durationLimit, durationLimit)
    }

    private static func sliceDirectory(_ audio: URL) -> URL {
        audio.deletingLastPathComponent().appendingPathComponent("openai-slices")
    }

    /// The pieces are derived and disposable; the mix they came from is not.
    private static func discardSlices(_ slices: [AudioSlicer.Slice], of audio: URL) {
        guard slices.contains(where: { $0.url != audio }) else { return }
        try? FileManager.default.removeItem(at: sliceDirectory(audio))
    }

    private static func duration(of audio: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: audio),
              file.processingFormat.sampleRate > 0
        else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - API

    /// One transcription request, streamed from a multipart body on disk.
    private func send(_ audio: URL) async throws -> Data {
        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", "diarized_json"),
            // Required by the diarizing model for anything over 30 seconds;
            // without it the API answers 400 rather than transcribing.
            ("chunking_strategy", "auto"),
        ]
        if let language = Self.languageField(for: expected) {
            fields.append(("language", language))
        }
        // Uploading and transcribing an hour of audio outlasts the 60s default
        // several times over, and a timeout here costs the whole meeting.
        return try await http.sendMultipart(
            to: Self.endpoint, fields: fields, file: audio, key: apiKey,
            what: "transcription", timeout: 1800)
    }

    /// The `language` field for a request, or nil to let the model detect.
    /// The API has nothing beside it — no `expected_languages`, no candidate
    /// list — to express an expectation instead, so it follows the rule every
    /// such engine follows: `MeetingLanguages.pin(for:)`.
    static func languageField(for expected: [String]) -> String? {
        MeetingLanguages.pin(for: expected)
    }

    // MARK: - shaping

    /// Where one piece's response is cached: named for the model, the
    /// language sent, and actual source boundaries. A changed cut must never
    /// reuse a response just because the piece number and count still match.
    func cacheURL(in dir: URL, audio: URL, slice: AudioSlicer.Slice, piece index: Int, of count: Int) -> URL {
        ProviderCache.url(
            in: dir, provider: .openAI,
            parts: [
                audio.lastPathComponent, model, Self.languageField(for: expected) ?? "detect",
                "\(requestLimit)", "\(count)", "slices-v2", "\(slice.offset)", "\(slice.duration)",
            ],
            suffix: count > 1 ? "\(index + 1)" : nil)
    }

    /// The response as verbemo's segments: times moved onto the session clock,
    /// labels kept apart per piece. Pure, so the shifting and the labelling
    /// are testable without an API key.
    static func segments(
        from response: Response,
        offset: TimeInterval,
        labelPrefix: String?
    ) -> [TranscriptSegment] {
        if let segments = response.segments, !segments.isEmpty {
            return segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let speaker = segment.speaker.map { label in
                    labelPrefix.map { "\($0)\(label)" } ?? label
                }
                return TranscriptSegment(
                    start: segment.start + offset,
                    end: max(segment.start, segment.end) + offset,
                    text: text,
                    speaker: speaker
                )
            }
        }
        // No segments at all: a piece with speech but nothing the diarizer
        // would split. Keeping the flat text beats dropping the minutes.
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(
            start: offset,
            end: offset + (response.duration ?? 0),
            text: text
        )]
    }

    /// The slice of the API response verbemo uses. Everything else it returns —
    /// usage, logprobs, the task name — is none of our business.
    struct Response: Decodable, Sendable {
        struct Segment: Decodable, Sendable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let speaker: String?
        }

        let text: String?
        let duration: TimeInterval?
        let segments: [Segment]?
    }

    /// Progress goes to stderr; the coordinator owns transcribe.log and only
    /// hears about outcomes.
    private nonisolated func note(_ message: String) {
        FileHandle.standardError.write(Data("openai: \(message)\n".utf8))
    }
}
