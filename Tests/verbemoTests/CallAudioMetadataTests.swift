import Foundation
import Testing
@testable import verbemo

struct CallAudioMetadataTests {
    @Test func decodesKnownAndOrdinaryTracksAndRejectsBrokenReferences() throws {
        let dir = try ParticipantAudioRecorderTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = ParticipantAudioRecorder(directory: dir, offsetMs: 0)
        try recorder.consume(.track(ParticipantAudioRecorderTests.descriptor()))
        recorder.close()
        let snapshot = recorder.snapshot
        let metadata = CallAudioMetadata(integrationID: "ktalk", callID: "call", periods: [], tracks: snapshot.tracks)
        var files = snapshot.files
        files["mic"] = "mic.caf"
        var json: [String: Any] = ["files": files, "start_offset_ms": snapshot.offsets, "call_audio": try metadata.jsonValue()]
        func write() throws { try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("meta.json")) }
        try write()
        let meta = try SessionMeta.read(from: dir)
        #expect(meta.tracks.count == 2)
        #expect(meta.tracks.filter { $0.participant != nil }.count == 1)
        #expect(meta.track(for: "me")?.participant == nil)
        var broken = try metadata.jsonValue()
        broken["version"] = 99
        json["call_audio"] = broken
        try write()
        #expect(throws: (any Error).self) { try SessionMeta.read(from: dir) }
        json["call_audio"] = try metadata.jsonValue()
        json["files"] = ["mic": "mic.caf"]
        try write()
        #expect(throws: (any Error).self) { try SessionMeta.read(from: dir) }
        json["files"] = files.mapValues { _ in "../outside.caf" }
        try write()
        #expect(throws: (any Error).self) { try SessionMeta.read(from: dir) }
    }
}
