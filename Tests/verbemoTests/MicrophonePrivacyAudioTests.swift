import AVFoundation
import Foundation
import Testing
@testable import verbemo

struct MicrophonePrivacyAudioTests {
    func tone() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        pcm.frameLength = 1600
        for i in 0..<1600 { pcm.floatChannelData![0][i] = 0.5 }
        return pcm
    }

    @Test func delayedMuteRemovesPrivateAudioBeforeBothFileAndLiveSink() throws {
        let gate = MicrophonePrivacyGate(), pcm = tone()
        let filter = MicrophonePrivacyFilter(gate: gate)
        gate.update(unmuted: true, validFor: 1.5, now: 10)
        #expect(filter.process(pcm, now: 10.1).isEmpty)
        gate.update(unmuted: false, validFor: 0, now: 10.6)
        gate.update(unmuted: true, validFor: 1.5, now: 12)
        let output = try #require(filter.process(pcm, now: 12.2).first)
        #expect(output.buffer.frameLength == 1600)
        #expect(AudioLevel.peak(of: output.buffer) == 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
            let writer = TrackWriter(file: file, label: "privacy-test")
            writer.write(output.buffer); writer.drain()
        }
        let file = try AVAudioFile(forReading: url)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
        try file.read(into: read)
        #expect(AudioLevel.peak(of: read) == 0)
        let relay = LiveAudioBufferRelay()
        relay.install { buffer in #expect(AudioLevel.peak(of: buffer) == 0) }
        #expect(relay.forward(output.buffer))
    }

    @Test func continuousPermissionPreservesAudioAndPauseInvalidatesPending() throws {
        let gate = MicrophonePrivacyGate(), pcm = tone()
        let filter = MicrophonePrivacyFilter(gate: gate)
        gate.update(unmuted: true, validFor: 1.5, now: 10)
        #expect(filter.process(pcm, padding: 16, now: 10.1).isEmpty)
        gate.update(unmuted: true, validFor: 1.5, now: 11)
        gate.update(unmuted: true, validFor: 1.5, now: 12)
        let result = try #require(filter.process(pcm, now: 12.2).first)
        #expect(AudioLevel.peak(of: result.buffer) == 0.5)
        #expect(result.padding == 16)
        filter.silencePending()
        gate.update(unmuted: true, validFor: 1.5, now: 13)
        gate.update(unmuted: true, validFor: 1.5, now: 14)
        #expect(try AudioLevel.peak(of: #require(filter.process(pcm, now: 14.3).first).buffer) == 0)
    }

    @Test func finishNeverFlushesUnconfirmedAudio() throws {
        let gate = MicrophonePrivacyGate(), pcm = tone()
        let filter = MicrophonePrivacyFilter(gate: gate)
        gate.update(unmuted: true, validFor: 1.5, now: 10)
        _ = filter.process(pcm, now: 10.1)
        let tail = try #require(filter.finish().first)
        #expect(tail.buffer.frameLength == 1600)
        #expect(AudioLevel.peak(of: tail.buffer) == 0)
        #expect(filter.finish().isEmpty)
    }
}
