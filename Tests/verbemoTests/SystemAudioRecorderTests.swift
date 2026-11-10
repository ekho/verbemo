import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import verbemo

@Suite(.serialized)
@MainActor
struct SystemAudioRecorderTests {
    @Test("Healthy, paused and unreadable audio does not trigger recovery probes")
    func healthyAudio() {
        var health = SystemAudioRecovery(lastSignalAt: 10)
        #expect(!health.shouldProbe(at: 12, paused: false))
        #expect(!health.shouldProbe(at: 14, paused: true))
        #expect(health.shouldProbe(at: 14, paused: false))
        health.record(peak: 0.0001, at: 14)
        #expect(!health.shouldProbe(at: 15, paused: false))
        health.record(peak: nil, at: 20)
        #expect(!health.shouldProbe(at: 21, paused: false))
    }

    @Test("Genuine silence never promotes a replacement; a live primary cancels the probe")
    func genuineSilence() {
        var health = SystemAudioRecovery(lastSignalAt: 0)
        health.beginProbe(at: 4)
        let heard1 = health.hearsReplacement(peak: 0, at: 4.1)
        #expect(!heard1)
        let heard2 = health.hearsReplacement(peak: 0, at: 4.5)
        #expect(!heard2)
        let heard3 = health.hearsReplacement(peak: 0.1, at: 5)
        #expect(!heard3)
        health.record(peak: 0.1, at: 5.1)
        let heard4 = health.hearsReplacement(peak: 0.1, at: 5.2)
        #expect(!heard4)
        #expect(health.probeFinished(at: 5.2, paused: false))
    }

    @Test("Only sustained sound on the fresh tap replaces a silent primary")
    func replacementMustProveAudio() {
        var health = SystemAudioRecovery(lastSignalAt: 0)
        health.beginProbe(at: 4)
        let heard5 = health.hearsReplacement(peak: 0.1, at: 4.1)
        #expect(!heard5)
        let heard6 = health.hearsReplacement(peak: nil, at: 4.3)
        #expect(!heard6)
        let heard7 = health.hearsReplacement(peak: .infinity, at: 4.4)
        #expect(!heard7)
        let heard8 = health.hearsReplacement(peak: 0.1, at: 4.5)
        #expect(!heard8)
        let betweenWords = health.hearsReplacement(peak: 0, at: 4.6)
        #expect(!betweenWords)
        let heard9 = health.hearsReplacement(peak: 0.1, at: 4.7)
        #expect(heard9)
    }

    @Test("Silent or failed probes are bounded and do not restart capture in a loop")
    func probeBackoff() {
        var health = SystemAudioRecovery(lastSignalAt: 0)
        health.beginProbe(at: 4)
        #expect(!health.probeFinished(at: 5, paused: false))
        #expect(health.probeFinished(at: 5, paused: true))
        #expect(health.probeFinished(at: 6, paused: false))
        health.endProbe()
        #expect(!health.shouldProbe(at: 18, paused: false))
        #expect(health.shouldProbe(at: 19, paused: false))
    }

    @Test("A silent process tap recovers real audio without replacing the recording",
          .enabled(if: ProcessInfo.processInfo.environment["VERBEMO_TEST_SYSTEM_AUDIO"] == "1"),
          arguments: [false, true])
    func silentTapRecovers(stoppedCallbacks: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = dir.appendingPathComponent("tone.caf")
        try TestAudio.writeTone(to: tone, seconds: 25, frequency: 440, amplitude: 0.04)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [tone.path]
        try player.run()
        defer { if player.isRunning { player.terminate() }; player.waitUntilExit() }
        try await Task.sleep(for: .milliseconds(500))

        let before = try tapIDs()
        let devicesBefore = try audioObjects(kAudioHardwarePropertyDevices)
        let recorder = SystemAudioRecorder()
        let output = dir.appendingPathComponent("system.caf")
        try recorder.start(writingTo: output, scope: .apps(["afplay"]))
        defer { recorder.stop() }
        let originalTap = try #require(try tapIDs().subtracting(before).first)
        try await Task.sleep(for: .seconds(1))
        let firstBuffer = try #require(recorder.firstBufferAt)
        try #require(recorder.lastSoundAt != nil, "The real output must be audible before injecting failure")

        if stoppedCallbacks {
            let aggregate = try #require(try audioObjects(kAudioHardwarePropertyDevices)
                .subtracting(devicesBefore).first)
            var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyTapList,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var empty = [] as CFArray
            let status = withUnsafeMutablePointer(to: &empty) {
                AudioObjectSetPropertyData(aggregate, &address, 0, nil,
                                           UInt32(MemoryLayout<CFArray>.size), $0)
            }
            try #require(status == noErr)
        } else {
            // Keep callbacks and file growth alive, but disconnect the native tap from its source.
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var description = CATapDescription(stereoMixdownOfProcesses: [])
            description.isPrivate = true
            description.muteBehavior = .unmuted
            let status = withUnsafeMutablePointer(to: &description) {
                AudioObjectSetPropertyData(originalTap, &address, 0, nil,
                                           UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
            try #require(status == noErr)
        }
        try await Task.sleep(for: .milliseconds(700))
        if stoppedCallbacks { #expect(recorder.audioLevel == .unavailable) }
        let failedAt = Date()
        try await Task.sleep(for: .seconds(8))
        #expect(recorder.lastSoundAt.map { $0 > failedAt.addingTimeInterval(2) } == true)
        #expect(recorder.firstBufferAt == firstBuffer)
        recorder.stop()

        let file = try AVAudioFile(forReading: output)
        let expectedDuration = Date().timeIntervalSince(firstBuffer)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - expectedDuration) < 0.3)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate)))
        file.framePosition = max(0, file.length - AVAudioFramePosition(buffer.frameCapacity))
        try file.read(into: buffer)
        #expect((AudioLevel.peak(of: buffer) ?? 0) > 0.02)
        try await expectTapsRemoved(backTo: before)
    }

    @Test("A real silent source stays silent and stopping also closes its recovery probe",
          .enabled(if: ProcessInfo.processInfo.environment["VERBEMO_TEST_SYSTEM_AUDIO"] == "1"))
    func quietSourceAndStop() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = dir.appendingPathComponent("quiet.caf")
        try TestAudio.writeTone(to: tone, seconds: 12, frequency: 440, amplitude: 0)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [tone.path]
        try player.run()
        defer { if player.isRunning { player.terminate() }; player.waitUntilExit() }
        try await Task.sleep(for: .milliseconds(500))
        let before = try tapIDs()
        let recorder = SystemAudioRecorder()
        let output = dir.appendingPathComponent("system.caf")
        try recorder.start(writingTo: output, scope: .apps(["afplay"]))
        defer { recorder.stop() }
        let original = try tapIDs().subtracting(before)
        try await Task.sleep(for: .milliseconds(4300))
        #expect(recorder.lastSoundAt == nil)
        #expect(recorder.scope == .apps(["afplay"]))
        #expect(try tapIDs().isSuperset(of: original))
        #expect(try tapIDs().count == before.count + 2)
        recorder.stop()
        try await expectTapsRemoved(backTo: before)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcribe.log").path))
        let file = try AVAudioFile(forReading: output)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        #expect(AudioLevel.peak(of: buffer) == 0)
    }

    private func tapIDs() throws -> Set<AudioObjectID> {
        try audioObjects(kAudioHardwarePropertyTapList)
    }

    private func expectTapsRemoved(backTo expected: Set<AudioObjectID>) async throws {
        // CoreAudio publishes tap-list removal after the synchronous destroy call returns.
        let deadline = Date().addingTimeInterval(2)
        var remaining = try tapIDs()
        while remaining != expected, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            remaining = try tapIDs()
        }
        #expect(remaining == expected)
    }

    private func audioObjects(_ selector: AudioObjectPropertySelector) throws -> Set<AudioObjectID> {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try #require(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size) == noErr)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if size > 0 {
            try #require(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &size, &ids) == noErr)
        }
        return Set(ids)
    }
}
