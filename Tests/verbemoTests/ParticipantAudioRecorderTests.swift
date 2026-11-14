import AVFoundation
import CallIntegrations
import Foundation
import os
import Testing
@testable import verbemo

struct ParticipantAudioRecorderTests {
    @Test func capturedListRequiresFreshPCMAndRetainsSavedTracksAfterRemoval() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = ParticipantAudioRecorder(directory: dir, offsetMs: 0)
        defer { recorder.close() }
        try recorder.consume(.track(Self.descriptor()))
        try recorder.consume(.heartbeat(frame: 0, sampleRate: 48000))
        #expect(recorder.capturedTracks(at: 10).isEmpty)
        try recorder.consume(.audio(.init(trackID: "p1", generation: 1, frameStart: 0,
            sampleRate: 48000, samples: [0, 0])), at: 10)
        #expect(recorder.capturedTracks(at: 12.9).count == 1, "Silent PCM confirms a track without live ASR")
        #expect(recorder.capturedTracks(at: 13).isEmpty, "A heartbeat must not keep a stalled track current")
        let renamed = CallAudioTrack(id: "p1", participant: .init(id: "p1", name: "Updated name", isLocal: false, isGuest: true),
            generation: 1, sampleRate: 48000)
        try recorder.consume(.track(renamed), at: 13)
        #expect(recorder.capturedTracks(at: 13).isEmpty, "Metadata does not renew PCM freshness")
        recorder.isPaused = true
        try recorder.consume(.audio(.init(trackID: "p1", generation: 1, frameStart: 2,
            sampleRate: 48000, samples: [0.5])), at: 14)
        #expect(recorder.capturedTracks(at: 14).map(\.name) == ["Updated name"])
        try recorder.consume(.track(Self.descriptor(generation: 2)), at: 14)
        #expect(recorder.capturedTracks(at: 14).isEmpty, "Replacement requires its own PCM")
        try recorder.consume(.audio(.init(trackID: "p1", generation: 2, frameStart: 3,
            sampleRate: 48000, samples: [0])), at: 15)
        #expect(recorder.capturedTracks(at: 15).map(\.generation) == [2])
        try recorder.consume(.removed("p1"))
        #expect(recorder.capturedTracks(at: 15).isEmpty)
        #expect(recorder.snapshot.tracks.count == 2)
        #expect(recorder.snapshot.files.values.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) })
        recorder.close()
        #expect(recorder.capturedTracks(at: 15).isEmpty)
    }

    @Test func delayedAudioAfterResumeRedactsPauseIntervalsInFileAndLiveSink() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = Date(timeIntervalSince1970: 0)
        let recorder = ParticipantAudioRecorder(directory: dir, offsetMs: 500, clockOrigin: origin)
        let live = OSAllocatedUnfairLock(initialState: [[Float]]())
        recorder.installLiveSink { event in
            if case .audio(_, let buffer, _) = event {
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                live.withLock { $0.append(samples) }
            }
        }
        try recorder.consume(.track(Self.descriptor()))
        recorder.setPaused(true, at: origin.addingTimeInterval(1.0 / 64))
        recorder.setPaused(false, at: origin.addingTimeInterval(2.0 / 64))
        recorder.setPaused(true, at: origin.addingTimeInterval(3.0 / 64))
        recorder.setPaused(false, at: origin.addingTimeInterval(3.5 / 64))
        // A new participant may deliver the same delayed timeline after Resume.
        try recorder.consume(.track(Self.descriptor("p2")))
        for id in ["p1", "p2"] {
            try recorder.consume(.audio(.init(trackID: id, generation: 1, frameStart: 0,
                sampleRate: 48000, samples: Array(repeating: 0.5, count: 3000))))
        }
        recorder.close()
        var expected = Array(repeating: Float(0.5), count: 3000)
        expected.replaceSubrange(750..<1500, with: repeatElement(0, count: 750))
        expected.replaceSubrange(2250..<2625, with: repeatElement(0, count: 375))
        #expect(live.withLock { $0 } == [expected, expected])
        for filename in recorder.snapshot.files.values {
            let file = try AVAudioFile(forReading: dir.appendingPathComponent(filename))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 3000))
            try file.read(into: buffer)
            #expect(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 3000)) == expected)
        }
    }

    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func descriptor(_ id: String = "p1", generation: Int = 1) -> CallAudioTrack {
        .init(id: id, participant: .init(id: id, name: "../Same name", isLocal: false, isGuest: true),
              generation: generation, sampleRate: 48000)
    }

    @Test func writesLateAudioGapsPauseAndReplacementOnTheSameClock() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = ParticipantAudioRecorder(directory: dir, offsetMs: 500)
        try recorder.consume(.track(Self.descriptor()))
        try recorder.consume(.audio(.init(trackID: "p1", generation: 1, frameStart: 96000,
                                         sampleRate: 48000, samples: [0.25, -0.25])))
        recorder.isPaused = true
        try recorder.consume(.audio(.init(trackID: "p1", generation: 1, frameStart: 96004,
                                         sampleRate: 48000, samples: [0.75, 0.75])))
        recorder.isPaused = false
        try recorder.consume(.track(Self.descriptor(generation: 2)))
        try recorder.consume(.audio(.init(trackID: "p1", generation: 2, frameStart: 192000,
                                         sampleRate: 48000, samples: [0.5])))
        try recorder.consume(.removed("p1"))
        recorder.close()
        let snapshot = recorder.snapshot
        #expect(snapshot.tracks.count == 2)
        #expect(Set(snapshot.tracks.map(\.speakerID)).count == 1)
        #expect(snapshot.offsets.values.sorted() == [2500, 4500])
        let first = try #require(snapshot.files[snapshot.tracks[0].fileKey])
        #expect(!first.contains("Same name"))
        let file = try AVAudioFile(forReading: dir.appendingPathComponent(first))
        #expect(file.length == 6)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 6))
        try file.read(into: buffer)
        #expect(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 6)) == [0.25, -0.25, 0, 0, 0, 0])
        #expect(throws: (any Error).self) { try recorder.consume(.track(Self.descriptor("late"))) }
    }

    @Test func namesDoNotJoinDifferentParticipantsAndInvalidPCMDoesNotReachDisk() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = ParticipantAudioRecorder(directory: dir, offsetMs: 0)
        defer { recorder.close() }
        try recorder.consume(.track(Self.descriptor()))
        try recorder.consume(.track(Self.descriptor("p2")))
        #expect(Set(recorder.snapshot.tracks.map(\.speakerID)).count == 2)
        for chunk in [
            CallAudioChunk(trackID: "p1", generation: 1, frameStart: -1, sampleRate: 48000, samples: [0]),
            CallAudioChunk(trackID: "p1", generation: 2, frameStart: 0, sampleRate: 48000, samples: [0]),
            CallAudioChunk(trackID: "p1", generation: 1, frameStart: 0, sampleRate: 48000, samples: [.nan]),
        ] {
            #expect(throws: (any Error).self) { try recorder.consume(.audio(chunk)) }
        }
    }
}
