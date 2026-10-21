import AppKit
import AVFoundation
import Testing

@testable import verbemo

struct AudioMeterTests {
    @Test("A peak accumulated offscreen does not persist through later quiet buffers")
    func boundedHold() {
        var mic = AudioMeter(), system = AudioMeter()
        mic.record(peak: 0.9, at: 10)
        system.record(peak: 0.2, at: 10)
        mic.record(peak: 0.01, at: 10.3)
        #expect(mic.read(running: true, paused: false, now: 10.4) == .level(0.01))
        #expect(system.read(running: true, paused: false, now: 10.4) == .level(0.2))
    }

    @Test("Interleaved 16-bit stereo includes the second channel's final sample")
    func int16Stereo() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let data = try #require(buffer.int16ChannelData?[0])
        data.update(repeating: 0, count: 8)
        data[7] = -16384
        let peak = try #require(AudioLevel.peak(of: buffer))
        #expect(abs(peak - 0.5) < 0.001)
    }

    @Test("Polling retains brief peaks but expires a stopped source")
    func peaksAndFreshness() {
        var meter = AudioMeter()
        #expect(meter.read(running: true, paused: false, now: 10) == .unavailable)
        meter.record(peak: 0.5, at: 10)
        meter.record(peak: 0.1, at: 10.02)
        #expect(meter.read(running: true, paused: false, now: 10.1) == .level(0.5))
        meter.record(peak: 0, at: 10.12)
        #expect(meter.read(running: true, paused: false, now: 10.2) == .level(0))
        #expect(meter.read(running: true, paused: false, now: 11) == .unavailable)
    }

    @Test("Pause, stop and route reset cannot revive an old signal")
    func lifecycle() {
        var meter = AudioMeter()
        meter.record(peak: 0.8, at: 10)
        #expect(meter.read(running: true, paused: true, now: 10.1) == .paused)
        #expect(meter.read(running: true, paused: false, now: 10.2) == .unavailable)
        meter.record(peak: 0.4, at: 11)
        meter.reset()
        #expect(meter.read(running: true, paused: false, now: 11.1) == .unavailable)
        meter.record(peak: 0.2, at: 12)
        #expect(meter.read(running: false, paused: false, now: 12.1) == .off)
        #expect(meter.read(running: true, paused: false, now: 12.2) == .unavailable)
    }

    @Test("Unsupported and invalid measurements are unavailable, not silence")
    func invalidMeasurements() {
        for peak: Float? in [nil, .nan, .infinity, -1] {
            var meter = AudioMeter()
            meter.record(peak: 0.8, at: 10)
            meter.record(peak: peak, at: 10.02)
            #expect(meter.read(running: true, paused: false, now: 10.1) == .unavailable)
        }
    }

    @Test("Real stereo peaks include the last sample of either channel", arguments: [false, true])
    func stereo(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            let samples = try #require(audio.mData?.assumingMemoryBound(to: Float.self))
            samples.update(repeating: 0.125, count: Int(audio.mDataByteSize) / 4)
        }
        let data = try #require(buffer.floatChannelData)
        data[interleaved ? 0 : 1][interleaved ? 7 : 3] = -0.75
        #expect(AudioLevel.peak(of: buffer) == 0.75)
        let silent = try #require(AudioLevel.silence(like: buffer))
        for audio in UnsafeMutableAudioBufferListPointer(silent.mutableAudioBufferList) {
            let samples = try #require(audio.mData?.assumingMemoryBound(to: Float.self))
            #expect((0..<Int(audio.mDataByteSize) / 4).allSatisfy { samples[$0] == 0 })
        }
        #expect(AudioLevel.peak(of: buffer) == 0.75, "Pause must not overwrite capture memory")
    }
}

@Suite(.serialized)
@MainActor
struct AudioMeterViewTests {
    @Test("Journal exposes independent source names, levels and pause states", .freshHome, .speaking(.english))
    func journalMeters() throws {
        _ = NSApplication.shared
        let app = ApplicationWindow()
        defer { app.hide() }
        var readings: (mic: AudioMeter.Reading, system: AudioMeter.Reading) = (.level(0.1), .level(0))
        app.readAudioLevels = { readings }
        app.update(state: .recording, elapsed: "00:01")
        app.showActiveRecording()
        let view = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? LiveTranscriptView }.first)
        view.refreshAudioLevels()
        let meters = view.allDescendants.compactMap { $0 as? NSLevelIndicator }
        #expect(meters.count == 2)
        let mic = try #require(meters.first { $0.identifier?.rawValue == "audio-level.mic" })
        let system = try #require(meters.first { $0.identifier?.rawValue == "audio-level.system" })
        #expect(mic.accessibilityLabel() == "Microphone")
        #expect(mic.accessibilityValueDescription()?.contains("−20 dBFS") == true)
        #expect(abs(mic.doubleValue - 2.0 / 3.0) < 0.001)
        #expect(system.doubleValue == 0)
        #expect(system.accessibilityValueDescription() == "Silence")
        readings = (.paused, .unavailable)
        view.refreshAudioLevels()
        #expect(mic.doubleValue == 0)
        #expect(mic.accessibilityValueDescription() == "Paused")
        #expect(system.accessibilityValueDescription() == "Unavailable")
        readings = (.off, .level(1))
        view.refreshAudioLevels()
        #expect(mic.accessibilityValueDescription() == "Off")
        #expect(system.doubleValue == 1)
        app.panel.setContentSize(NSSize(width: 760, height: 600))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(mic.frame.width > 100 && system.frame.width > 100)
    }

    @Test("Meter states have Russian accessible descriptions", .freshHome, .speaking(.russian))
    func russianStates() {
        let view = AudioLevelView(title: "Микрофон", source: "mic")
        for (reading, expected): (AudioMeter.Reading, String) in [
            (.off, "Отключён"), (.paused, "На паузе"), (.unavailable, "Недоступен"), (.level(0), "Тишина")
        ] {
            view.update(reading)
            #expect(view.meter.accessibilityValueDescription() == expected)
        }
    }
}
