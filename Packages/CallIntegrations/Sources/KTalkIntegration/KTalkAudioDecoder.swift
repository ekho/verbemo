import Foundation
import CallIntegrations

/// Validate the renderer boundary before allocating PCM or exposing it to writers.
struct KTalkAudioDecoder {
    let runID: String
    private var tracks: [String: CallAudioTrack] = [:]
    private var removed: Set<String> = []
    private var ends: [String: Int64] = [:]

    init(runID: String) { self.runID = runID }

    mutating func receive(_ text: String) throws -> CallAudioEvent? {
        guard text.utf8.count <= 65_536 else { throw CallAudioFailure.invalidData }
        let value = try JSONDecoder().decode(Message.self, from: Data(text.utf8))
        guard value.run == runID else { return nil }
        switch value.type {
        case "track":
            guard let id = value.id, validID(id), let person = value.participant,
                  validID(person.id), person.name.utf8.count <= 4096,
                  let generation = value.generation, generation > 0,
                  let rate = value.rate, validRate(rate), tracks[id] != nil || tracks.count < 256
            else { throw CallAudioFailure.invalidData }
            if let old = tracks[id] {
                guard old.participant.id == person.id, old.participant.isLocal == person.isLocal,
                      generation >= old.generation, old.sampleRate == rate
                else { throw CallAudioFailure.invalidData }
            }
            let track = CallAudioTrack(id: id, participant: person, generation: generation, sampleRate: rate)
            tracks[id] = track
            removed.remove(id)
            return .track(track)
        case "audio":
            guard let id = value.id, !removed.contains(id), let track = tracks[id], value.generation == track.generation,
                  value.rate == track.sampleRate, let frame = value.frame,
                  frame >= 0, frame >= (ends[id] ?? 0), frame <= Int64.max - 4096,
                  let encoded = value.pcm, encoded.utf8.count <= 21_848,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
                  bytes.count <= 16_384, bytes.count.isMultiple(of: 4)
            else { throw CallAudioFailure.invalidData }
            let samples = bytes.withUnsafeBytes { raw in
                stride(from: 0, to: bytes.count, by: 4).map { offset in
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                }
            }
            guard samples.allSatisfy(\.isFinite) else { throw CallAudioFailure.invalidData }
            ends[id] = frame + Int64(samples.count)
            return .audio(.init(trackID: id, generation: track.generation, frameStart: frame,
                                sampleRate: track.sampleRate, samples: samples))
        case "removed":
            guard let id = value.id, tracks[id] != nil, removed.insert(id).inserted else { throw CallAudioFailure.invalidData }
            // Retain the end position if the same connection gets a replacement later.
            return .removed(id)
        case "heartbeat":
            guard let frame = value.frame, frame >= 0, let rate = value.rate, validRate(rate)
            else { throw CallAudioFailure.invalidData }
            return .heartbeat(frame: frame, sampleRate: rate)
        case "ended": return .ended
        case "error": throw CallAudioFailure.unsupportedSchema
        default: throw CallAudioFailure.invalidData
        }
    }

    private func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 }
    private func validRate(_ value: Int) -> Bool { (8000...192000).contains(value) }

    private struct Message: Decodable {
        let run: String
        let type: String
        var id: String?
        var generation: Int?
        var participant: CallParticipant?
        var rate: Int?
        var frame: Int64?
        var pcm: String?
    }
}
