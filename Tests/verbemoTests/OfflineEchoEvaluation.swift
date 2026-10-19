import AVFoundation
import CryptoKit
import Foundation
import Testing

@testable import verbemo

/// Opt-in native parity harness for private recordings. It exercises the same
/// AVFoundation decoder, LocalVQE stream and AAC encoder as production without
/// reading or changing session metadata and without invoking an ASR provider.
///
/// VERBEMO_ECHO_EVAL_INPUT=/absolute/stereo.m4a \
/// VERBEMO_ECHO_EVAL_OUTPUT=/absolute/repository/.build/evaluation \
/// swift test --skip-build --filter OfflineEchoEvaluation
@Suite(
    .serialized,
    .enabled(if:
        ProcessInfo.processInfo.environment["VERBEMO_ECHO_EVAL_INPUT"] != nil
        && ProcessInfo.processInfo.environment["VERBEMO_ECHO_EVAL_OUTPUT"] != nil)
)
struct OfflineEchoEvaluation {
    @Test("Private stereo input completes the production decoder, AEC and AAC path")
    func processStereoArchive() throws {
        let environment = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(environment["VERBEMO_ECHO_EVAL_INPUT"]))
            .standardizedFileURL
        let requestedOutput = URL(
            fileURLWithPath: try #require(environment["VERBEMO_ECHO_EVAL_OUTPUT"]),
            isDirectory: true).standardizedFileURL
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // verbemoTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
        let build = repository.appendingPathComponent(".build", isDirectory: true)
            .standardizedFileURL.path + "/"
        guard requestedOutput.path.hasPrefix(build) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "VERBEMO_ECHO_EVAL_OUTPUT must be inside this checkout's .build directory"
            ])
        }

        let source = try AVAudioFile(forReading: input)
        #expect(source.processingFormat.channelCount >= 2)
        let sourceHash = try sha256(input)
        let run = requestedOutput.appendingPathComponent(
            "run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Reproduce the old per-track Parakeet path, which extracted each
        // channel from the shared archive to temporary mono AAC before ASR.
        let rawMic = run.appendingPathComponent("raw-mic.m4a")
        let rawSystem = run.appendingPathComponent("raw-system.m4a")
        try AudioChannelExtractor.extract(channel: 0, from: input, to: rawMic)
        try AudioChannelExtractor.extract(channel: 1, from: input, to: rawSystem)

        let result = try OfflineEchoAudio.prepare(
            microphone: .init(url: input, channel: 0),
            system: .init(url: input, channel: 1),
            in: run)
        defer { result.removeAudio() }
        let mic = run.appendingPathComponent("mic.localvqe.caf")
        let system = run.appendingPathComponent("system.caf")
        let archive = run.appendingPathComponent("processed.m4a")
        try FileManager.default.copyItem(at: result.microphone, to: mic)
        try FileManager.default.copyItem(at: result.system, to: system)
        _ = try TrackCompressor.encodeStereo(
            mic: .init(url: mic, offsetMs: 0),
            system: .init(url: system, offsetMs: 0),
            to: archive)

        let encoded = try AVAudioFile(forReading: archive)
        let rawMicFile = try AVAudioFile(forReading: rawMic)
        let rawSystemFile = try AVAudioFile(forReading: rawSystem)
        #expect(encoded.processingFormat.channelCount == 2)
        #expect(rawMicFile.processingFormat.channelCount == 1)
        #expect(rawSystemFile.processingFormat.channelCount == 1)
        #expect(Double(rawMicFile.length) >= Double(source.length) * 0.99)
        #expect(Double(rawSystemFile.length) >= Double(source.length) * 0.99)
        #expect(Double(encoded.length) >= Double(result.frames) * 0.99)
        #expect(try sha256(input) == sourceHash)

        let manifest: [String: Any] = [
            "source": input.path,
            "source_sha256": sourceHash,
            "source_channels": source.processingFormat.channelCount,
            "source_frames": source.length,
            "source_sample_rate": source.processingFormat.sampleRate,
            "processed_frames_16khz": result.frames,
            "raw_mic_archive": rawMic.lastPathComponent,
            "raw_mic_archive_frames": rawMicFile.length,
            "raw_system_archive": rawSystem.lastPathComponent,
            "raw_system_archive_frames": rawSystemFile.length,
            "archive": archive.lastPathComponent,
            "archive_channels": encoded.processingFormat.channelCount,
            "archive_frames": encoded.length,
            "processor": LocalVQEAssets.processorVersion,
            "model_sha256": LocalVQEAssets.modelSHA256,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: run.appendingPathComponent("verification.json"), options: .atomic)
        print("Offline echo evaluation → \(run.path)")
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
