import Foundation

/// Participant provenance supplements the existing physical file index.
struct CallAudioMetadata: Codable, Sendable, Equatable {
    struct Period: Codable, Sendable, Equatable {
        enum Mode: String, Codable, Sendable { case direct, fallback }
        var mode: Mode
        var startMs: Int
        var endMs: Int?
        var reason: String?
    }

    struct Track: Codable, Sendable, Equatable {
        var fileKey: String
        var sourceID: String
        var speakerID: String
        var participantID: String
        var name: String
        var isLocal: Bool
        var generation: Int
        var sampleRate: Int
        var missingFrames: Int64 = 0
    }

    var version = 1
    var integrationID: String
    var callID: String
    var periods: [Period]
    var tracks: [Track]

    func jsonValue() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    }

    static func read(_ value: Any, files: [String: String], offsets: [String: Int]) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        guard result.version == 1, !result.integrationID.isEmpty, !result.callID.isEmpty,
              result.tracks.count <= 4096, Set(result.tracks.map(\.fileKey)).count == result.tracks.count,
              result.periods.allSatisfy({ $0.startMs >= 0 && ($0.endMs ?? $0.startMs) >= $0.startMs }),
              result.tracks.allSatisfy({ track in
                  guard let file = files[track.fileKey], let offset = offsets[track.fileKey] else { return false }
                  return track.fileKey.hasPrefix("call_") && track.speakerID.hasPrefix("call_")
                      && !track.sourceID.isEmpty && !track.participantID.isEmpty
                      && track.name.utf8.count <= 4096 && track.generation > 0 && track.missingFrames >= 0
                      && (8000...192000).contains(track.sampleRate) && offset >= 0
                      && [track.fileKey + ".caf", track.fileKey + ".m4a"].contains(file)
                      && file == URL(fileURLWithPath: file).lastPathComponent
                      && file != "." && file != ".." && !file.contains("\\")
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
