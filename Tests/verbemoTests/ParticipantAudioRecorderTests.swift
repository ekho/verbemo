import AVFoundation
import CallIntegrations
import Foundation
import Testing
@testable import verbemo

struct ParticipantAudioRecorderTests {
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
