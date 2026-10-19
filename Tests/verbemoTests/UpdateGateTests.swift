import AVFoundation
import Foundation
import Testing
@testable import verbemo

@MainActor
@Suite("Updates wait for all recording work")
struct UpdateGateTests {
    @Test func recordingProcessingAndNewRecordingKeepInstallPending() {
        var recording = true
        var processing = false
        var importing = false
        let gate = UpdateGate(isBusy: { recording || processing || importing })
        var installs = 0
        #expect(gate.postponeInstallIfBusy { installs += 1 })
        #expect(!gate.mayCheck(.background))
        #expect(gate.mayCheck(.userInitiated))
        #expect(gate.mayCheck(.informationOnly))
        processing = true
        recording = false
        gate.activityDidChange()
        #expect(installs == 0)
        recording = true
        processing = false
        gate.activityDidChange()
        #expect(installs == 0)
        importing = true
        recording = false
        gate.activityDidChange()
        #expect(installs == 0)
        importing = false
        gate.activityDidChange()
        gate.activityDidChange()
        #expect(installs == 1)
        #expect(!gate.hasPostponedInstall)
    }

    @Test func failedUpdaterDropsHandlerAndPreservesRecording() throws {
        var recording = true
        let gate = UpdateGate(isBusy: { recording })
        var installs = 0
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("mic.caf")
        let bytes = Data("recording still in progress".utf8)
        try bytes.write(to: audio)
        #expect(gate.postponeInstallIfBusy { installs += 1 })
        gate.updaterDidAbort()
        #expect(recording)
        #expect(try Data(contentsOf: audio) == bytes)
        recording = false
        gate.activityDidChange()
        #expect(installs == 0)
        #expect(!gate.hasPostponedInstall)
    }

    @Test func idleDoesNotRetainHandlerAndClearsBeforeInvoking() {
        var busy = false
        let gate = UpdateGate(isBusy: { busy })
        #expect(!gate.postponeInstallIfBusy { Issue.record("not retained") })
        busy = true
        var installs = 0
        #expect(gate.postponeInstallIfBusy {
            installs += 1
            gate.activityDidChange()
        })
        gate.activityDidChange()
        #expect(installs == 0)
        busy = false
        gate.activityDidChange()
        #expect(installs == 1)
    }

    @Test("Recording-only save finishes before idle releases an update", .freshHome)
    func recordingOnlySaveIsIncludedInIdle() async throws {
        try Home.current.writeConfig(["transcription": ["enabled": false]])
        let dir = Home.current.defaultRecordings.appendingPathComponent("save-before-update")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TestAudio.write(to: dir.appendingPathComponent("mic.caf"), seconds: 2,
                            sampleRate: 16_000, channels: 1) { _, frame in
            0.2 * Float(sin(2 * .pi * 440 * Double(frame) / 16_000))
        }
        try JSONSerialization.data(withJSONObject: ["files": ["mic": "mic.caf"]])
            .write(to: dir.appendingPathComponent("meta.json"))
        let coordinator = TranscriptionCoordinator(onStop: { nil })
        var processing = true
        var installed = false
        let gate = UpdateGate(isBusy: { processing })
        #expect(gate.postponeInstallIfBusy { installed = true })
        await coordinator.enqueue(dir)
        await coordinator.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.m4a").path))
        #expect(!SessionClaim.isHeld(dir))
        processing = false
        gate.activityDidChange()
        #expect(installed)
    }

    @Test func updaterNeedsOwnFeedAndValidKey() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(!AppUpdates.isConfigured(info: [:]))
        #expect(!AppUpdates.isConfigured(info: ["SUFeedURL": AppUpdates.feedURL]))
        #expect(!AppUpdates.isConfigured(info: ["SUFeedURL": "https://example.invalid/feed", "SUPublicEDKey": key]))
        #expect(!AppUpdates.isConfigured(info: ["SUFeedURL": AppUpdates.feedURL, "SUPublicEDKey": "broken"]))
        #expect(AppUpdates.isConfigured(info: ["SUFeedURL": AppUpdates.feedURL, "SUPublicEDKey": key]))
    }
}
