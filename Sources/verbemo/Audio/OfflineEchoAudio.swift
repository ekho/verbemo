import AVFoundation
import CryptoKit
import Foundation

enum OfflineEchoAudio {
    struct Source: Sendable {
        let url: URL
        var channel: Int = 0
        var offsetMs: Int = 0
    }

    struct Result: Sendable {
        let directory: URL
        let frames: Int64
        var microphone: URL { directory.appendingPathComponent("mic.caf") }
        var system: URL { directory.appendingPathComponent("system.caf") }

        func removeAudio() {
            for name in ["mic.caf", "system.caf", "multichannel.m4a", "multichannel.tmp.m4a", "mixed.m4a"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    static func prepare(
        microphone: Source,
        system: Source,
        in directory: URL,
        cancellerFactory: () throws -> EchoCanceller = { try EchoCanceller() }
    ) throws -> Result {
        let mic = try Reader(microphone), far = try Reader(system)
        // LocalVQE's delay estimator uses absolute stream time and can lock
        // after its first few seconds. Decide the truly all-silent case with
        // a separate bounded preflight so any stream that later contains a
        // reference advances the model from t=0 rather than resetting its
        // clock at the first nonzero sample.
        let hasReferenceActivity = try containsReferenceActivity(system)
        // The cache namespace is tied to the processor revision and actual
        // sources. Raw AssemblyAI/OpenAI responses must never be reused here.
        let sources = try [microphone, system].map { source -> String in
            let attrs = try FileManager.default.attributesOfItem(atPath: source.url.path)
            let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(source.url.path)|\(attrs[.size] ?? 0)|\(date)|\(source.channel)|\(source.offsetMs)"
        }.joined(separator: "\n")
        let identity = LocalVQEAssets.processorVersion + "\n"
            + LocalVQEAssets.modelSHA256 + "\n" + sources
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let work = directory.appendingPathComponent(".transcription-aec-v3-\(digest.prefix(20))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = Result(directory: work, frames: max(mic.totalFrames, far.totalFrames))
        result.removeAudio()
        var completed = false
        defer { if !completed { result.removeAudio() } }
        try write(
            microphone: mic,
            reference: far,
            hasReferenceActivity: hasReferenceActivity,
            result: result,
            cancellerFactory: cancellerFactory)
        for url in [result.microphone, result.system] {
            guard try AVAudioFile(forReading: url).length == result.frames else {
                throw ProcessingError.truncated
            }
        }
        completed = true
        return result
    }

    enum ProcessingError: Error {
        case invalidSource, conversion, truncated
    }

    private static func write(
        microphone: Reader,
        reference: Reader,
        hasReferenceActivity: Bool,
        result: Result,
        cancellerFactory: () throws -> EchoCanceller
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let settings = AudioFormats.pcmSettings(sampleRate: 16_000, channels: 1)
        let micFile = try AVAudioFile(forWriting: result.microphone, settings: settings)
        let farFile = try AVAudioFile(forWriting: result.system, settings: settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(EchoCanceller.frameSize))!
        let canceller = try hasReferenceActivity ? cancellerFactory() : nil
        var pendingFrames: Int?

        func write(_ samples: [Float], count: Int, to file: AVAudioFile) throws {
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count)
            }
            try file.write(from: buffer)
        }

        // The arrays are bounded; the LocalVQE context is deliberately not.
        // Its recurrent and adaptive state stays warm across the whole meeting.
        // The early GCC bulk-delay estimate is fixed after acquisition, so this
        // does not promise reacquisition after an arbitrary route-delay change.
        // Every non-final window must end on a model hop. Padding belongs only
        // at EOF; inserting it between windows would corrupt LocalVQE's warm
        // recurrent/adaptive state even though the output file stays the same
        // length. This is 14.992 seconds (937 complete 256-sample hops).
        let nominalWindow = 15 * 16_000
        let window = nominalWindow - nominalWindow % EchoCanceller.frameSize
        for position in stride(from: Int64(0), to: result.frames, by: window) {
            try Task.checkCancellation()
            let count = Int(min(Int64(window), result.frames - position))
            var mic: [Float] = [], far: [Float] = []
            mic.reserveCapacity(count); far.reserveCapacity(count)
            for offset in stride(from: 0, to: count, by: EchoCanceller.frameSize) {
                let frames = min(EchoCanceller.frameSize, count - offset)
                mic += try microphone.read(at: position + Int64(offset), count: frames).prefix(frames)
                far += try reference.read(at: position + Int64(offset), count: frames).prefix(frames)
            }
            for offset in stride(from: 0, to: count, by: EchoCanceller.frameSize) {
                try Task.checkCancellation()
                let frames = min(EchoCanceller.frameSize, count - offset)
                var local = [Float](repeating: 0, count: EchoCanceller.frameSize)
                var remote = local
                for i in 0..<frames {
                    local[i] = mic[offset + i]
                    remote[i] = far[offset + i]
                }
                try write(remote, count: frames, to: farFile)

                // A separate full-stream preflight proves this reference is
                // absent. Streams with later playback must still advance the
                // adaptive model through leading silence from absolute t=0.
                guard let canceller else {
                    try write(local, count: frames, to: micFile)
                    continue
                }
                if let cleaned = try canceller.process(
                    microphone: local, reference: remote) {
                    guard let previousFrames = pendingFrames else {
                        throw ProcessingError.truncated
                    }
                    try write(cleaned, count: previousFrames, to: micFile)
                }
                pendingFrames = frames
            }
        }
        if let canceller, let final = try canceller.finish() {
            guard let pendingFrames else { throw ProcessingError.truncated }
            try write(final, count: pendingFrames, to: micFile)
        }
    }

    /// A bounded first pass retains the model-free path only when the decoded
    /// reference is completely absent. It intentionally uses the same Reader
    /// and exact-zero rule as processing and preservation.
    private static func containsReferenceActivity(_ source: Source) throws -> Bool {
        let reader = try Reader(source)
        let window = 15 * 16_000
        for position in stride(from: Int64(0), to: reader.totalFrames, by: window) {
            try Task.checkCancellation()
            let count = Int(min(Int64(window), reader.totalFrames - position))
            for offset in stride(from: 0, to: count, by: EchoCanceller.frameSize) {
                let frames = min(EchoCanceller.frameSize, count - offset)
                let samples = try reader.read(
                    at: position + Int64(offset),
                    count: frames)
                if samples.contains(where: { $0 != 0 }) { return true }
            }
        }
        return false
    }

    /// Sequential bounded-memory conversion with explicit channel selection.
    /// A read/conversion failure is an error, never a silent replacement track.
    private final class Reader: @unchecked Sendable {
        let totalFrames: Int64
        private let start: Int64
        private let file: AVAudioFile
        private let converter: AVAudioConverter
        private let staging: AVAudioPCMBuffer
        private let converted: AVAudioPCMBuffer
        private var readError: Error?

        init(_ source: Source) throws {
            file = try AVAudioFile(forReading: source.url)
            guard file.length > 0, source.offsetMs >= 0, source.channel >= 0,
                  source.channel < Int(file.processingFormat.channelCount),
                  let mono = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                  let converter = AVAudioConverter(from: file.processingFormat, to: mono),
                  let staging = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
                  let converted = AVAudioPCMBuffer(
                    pcmFormat: mono,
                    frameCapacity: AVAudioFrameCount(EchoCanceller.frameSize))
            else { throw ProcessingError.invalidSource }
            self.converter = converter
            self.staging = staging
            self.converted = converted
            converter.channelMap = [NSNumber(value: source.channel)]
            start = Int64(source.offsetMs) * 16
            totalFrames = Int64((Double(file.length) * 16_000 / file.processingFormat.sampleRate).rounded()) + start
        }

        func read(at position: Int64, count: Int) throws -> [Float] {
            var samples = [Float](repeating: 0, count: count)
            let lead = Int(max(0, start - position))
            guard lead < count, position < totalFrames else { return samples }
            let wanted = Int(min(Int64(count - lead), totalFrames - max(position, start)))
            converted.frameLength = 0
            // Capacity, not frameLength, controls how much the converter reads.
            let output = wanted == EchoCanceller.frameSize ? converted : AVAudioPCMBuffer(
                pcmFormat: converted.format, frameCapacity: AVAudioFrameCount(wanted))!
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [self] _, status in
                guard file.framePosition < file.length else {
                    status.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: staging)
                    guard staging.frameLength > 0 else { throw ProcessingError.truncated }
                    status.pointee = .haveData
                    return staging
                } catch {
                    readError = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let error { throw error }
            guard status != .error, Int(output.frameLength) == wanted else {
                throw ProcessingError.truncated
            }
            for i in 0..<wanted { samples[lead + i] = output.floatChannelData![0][i] }
            return samples
        }
    }
}
