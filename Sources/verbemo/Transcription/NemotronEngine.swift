import FluidAudio
import Foundation

protocol NemotronRecognition: Sendable {
    func process(_ samples: [Float]) async throws
    func finish() async throws -> (text: String, timings: [TokenTiming])
    func cleanup() async
}
protocol NemotronRuntime: Sendable {
    func prepare(at directory: URL) async throws
    func session(language: String) async throws -> any NemotronRecognition
    func release() async
}

/// Files are shared with live transcription; every track/pass gets a fresh manager.
actor NemotronEngine: TranscriptionEngine {
    nonisolated let name = "nemotron"
    nonisolated let model: String
    nonisolated let optionsFingerprint: String
    nonisolated let input: TranscriptionInput = .perTrack
    private let store: NemotronModelStore
    private let runtime: any NemotronRuntime
    private let language: String
    private let progress: @Sendable (Double) -> Void

    init(store: NemotronModelStore = .init(), runtime: any NemotronRuntime = FluidNemotronRuntime(),
         language: String? = Config.transcriptionLanguage(),
         progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.store = store
        self.runtime = runtime
        self.language = LiveTranscriptionLanguage.prompt(for: language)
        self.progress = progress
        let variant = store.variantDirectory(language: self.language)
        model = "nemotron-3.5-asr-streaming-multilingual-0.6b/\(variant.deletingLastPathComponent().lastPathComponent)/\(variant.lastPathComponent)"
        optionsFingerprint = "language=\(self.language);token_timestamps=true"
    }

    func prepare() async throws {
        let directory = try await store.download(language: language)
        try Task.checkCancellation()
        try await runtime.prepare(at: directory)
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let reader: WhisperPCMReader
        do { reader = try WhisperPCMReader(audio: audio, maximumSamples: 16_000 * 10) }
        catch { throw WhisperEngine.EngineError.unreadableAudio(audio, error) }
        let session = try await runtime.session(language: language)
        do {
            var processed = 0
            while true {
                let samples: [Float]
                do {
                    guard let next = try reader.nextChunk() else { break }
                    samples = next
                } catch is CancellationError { throw CancellationError() }
                catch { throw WhisperEngine.EngineError.unreadableAudio(audio, error) }
                try Task.checkCancellation()
                try await session.process(samples)
                processed += samples.count
                progress(Double(processed) / Double(max(reader.estimatedSampleCount, processed)))
            }
            try Task.checkCancellation()
            let result = try await session.finish()
            try Task.checkCancellation()
            let segments = Self.segments(text: result.text, timings: result.timings,
                                         duration: Double(processed) / 16_000)
            await session.cleanup()
            progress(1)
            return segments
        } catch {
            await session.cleanup()
            throw error
        }
    }

    static func segments(text: String, timings: [TokenTiming], duration: Double) -> [TranscriptSegment] {
        let words = buildWordTimings(from: timings)
        var previous = -Double.infinity
        let valid = !words.isEmpty && words.allSatisfy { word in
            defer { previous = word.startTime }
            return word.startTime.isFinite && word.endTime.isFinite && word.startTime >= 0
                && word.startTime >= previous && word.startTime < duration && word.endTime > word.startTime
                && word.endTime <= duration + 0.08
        }
        guard valid else {
            // Invalid native times are never replaced by invented word positions;
            // the existing diarization pipeline can decode individual speaker turns.
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.init(start: 0, end: duration, text: text)]
        }
        return ParakeetEngine.segments(from: words.map {
            TranscriptWord(start: $0.startTime, end: min(duration, $0.endTime), text: $0.word)
        })
    }

    func release() async { await runtime.release() }
}

actor FluidNemotronRuntime: NemotronRuntime {
    private var shared: SharedNemotronMultilingualModels?
    func prepare(at directory: URL) async throws {
        if shared == nil {
            shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: directory)
        }
    }
    func session(language: String) async throws -> any NemotronRecognition {
        guard let shared else { throw ASRError.notInitialized }
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadFromShared(shared)
        await manager.setLanguage(language)
        return FluidNemotronRecognition(manager: manager)
    }
    func release() async { shared = nil }
}
private struct FluidNemotronRecognition: NemotronRecognition {
    let manager: StreamingNemotronMultilingualAsrManager
    func process(_ samples: [Float]) async throws { _ = try await manager.process(samples: samples) }
    func finish() async throws -> (text: String, timings: [TokenTiming]) {
        try await manager.finishWithTokenTimings()
    }
    func cleanup() async { await manager.cleanup() }
}
