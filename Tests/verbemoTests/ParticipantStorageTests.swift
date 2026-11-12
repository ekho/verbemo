import AVFoundation
import Foundation
import Testing
@testable import verbemo

@Suite(.freshHome)
struct ParticipantStorageTests {
    static func session() throws -> URL {
        let dir = try ParticipantTranscriptionTests.session(hybrid: true)
        let recorder = ParticipantAudioRecorder(directory: dir, offsetMs: 2500)
        try recorder.consume(.track(ParticipantAudioRecorderTests.descriptor("p3")))
        recorder.close()
        let snapshot = recorder.snapshot
        for file in snapshot.files.values {
            try TestAudio.writeTone(to: dir.appendingPathComponent(file), seconds: 1, frequency: 880)
        }
        var meta = try #require(SessionState.read(dir))
        var info = try #require(try SessionMeta.read(from: dir).callAudio)
        info.tracks += snapshot.tracks
        var files = meta["files"] as! [String: String]
        var offsets = meta["start_offset_ms"] as! [String: Int]
        files.merge(snapshot.files) { _, value in value }; offsets.merge(snapshot.offsets) { _, value in value }
        meta["files"] = files; meta["start_offset_ms"] = offsets; meta["call_audio"] = try info.jsonValue()
        try RecordingSession.durableWrite(try RecordingSession.json(meta), dir.appendingPathComponent("meta.json"))
        return dir
    }

    @Test @MainActor func fiveSourcesKeepIdentityOffsetsAndPlaybackAfterArchive() async throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try SessionMeta.read(from: dir)
        TrackCompressor.compress(sessionDir: dir)
        let after = try SessionMeta.read(from: dir)
        #expect(after.callAudio == before.callAudio)
        #expect(after.tracks.count == 5)
        #expect(Set(after.tracks.map(\.file)).count == 5)
        #expect(after.tracks.map(\.offsetMs) == before.tracks.map(\.offsetMs))
        for track in after.tracks {
            #expect(track.file.hasSuffix(".m4a"))
            let audio = try AVAudioFile(forReading: dir.appendingPathComponent(track.file))
            #expect(audio.length > 0 && audio.processingFormat.channelCount == 1)
        }
        #expect(before.tracks.allSatisfy { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) })
        let sources = MeetingPlaybackView.sources(in: dir)
        #expect(sources.count == 5)
        let item = try await MeetingPlaybackView.makeItem(sources)
        #expect(try await item.asset.loadTracks(withMediaType: .audio).count == 5)
        #expect(try await item.asset.load(.duration).seconds >= 8)
        TrackCompressor.compress(sessionDir: dir)
        #expect(try SessionMeta.read(from: dir).tracks == after.tracks)
    }

    @Test func failedPublicationOrUnreadableSourceNeverDeletesOriginals() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try SessionMeta.read(from: dir)
        #expect(throws: DiskFull.self) {
            try TrackCompressor.compressParticipantTracks(sessionDir: dir, publish: { _ in throw DiskFull() })
        }
        #expect(try SessionMeta.read(from: dir).tracks == before.tracks)
        #expect(before.tracks.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) })
        try Data("broken".utf8).write(to: dir.appendingPathComponent(before.tracks[0].file))
        TrackCompressor.compress(sessionDir: dir)
        #expect(try SessionMeta.read(from: dir).tracks == before.tracks)
        #expect(before.tracks.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) })
    }

    @Test @MainActor func recoveryRetainsParticipantMetadataAndOffsets() throws {
        let root = try ParticipantAudioRecorderTests.folder(), dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: dir) }
        let original = try SessionMeta.read(from: dir)
        var manifest = try #require(SessionState.read(dir))
        manifest["started"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-12))
        try RecordingSession.durableWrite(try RecordingSession.json(manifest), dir.appendingPathComponent(".recording.json"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("meta.json"))
        let moved = root.appendingPathComponent("crashed")
        try FileManager.default.moveItem(at: dir, to: moved)
        #expect(RecordingSession.recoverInterrupted(root: root).map { $0.resolvingSymlinksInPath().path } == [moved.resolvingSymlinksInPath().path])
        let recovered = try SessionMeta.read(from: moved)
        #expect(recovered.callAudio == original.callAudio)
        #expect(recovered.tracks == original.tracks)
    }

    @Test(.freshHome(config: #"{"keep_audio":false}"#))
    func discardAndRecordingOnlyRespectTheirDifferentRetentionPolicies() async throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await TranscriptionCoordinator(onStop: { nil }).archiveRecordingOnly(dir)
        #expect(try SessionMeta.read(from: dir).tracks.allSatisfy { $0.file.hasSuffix(".m4a") })
        #expect(MeetingPresentation.audioFiles(dir).count == 5)
        SessionState.update(dir, with: ["diarization": "unreadable pending stage"])
        TrackCompressor.settle(sessionDir: dir)
        #expect(MeetingPresentation.audioFiles(dir).count == 5)
        SessionState.update(dir, with: ["diarization": nil])
        TrackCompressor.settle(sessionDir: dir)
        #expect(MeetingPresentation.audioFiles(dir).isEmpty)
        #expect(SessionState.read(dir)?["audio_discarded"] as? Bool == true)
    }
}
