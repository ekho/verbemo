import Foundation
import CallIntegrations

enum KTalkModel {
    static func reading(_ data: Data, targetID: String, space: URL) throws -> KTalkReading {
        let value = try JSONDecoder().decode(Model.self, from: data)
        guard value.kind == "conference" else { return .init(participation: .unknown, emptyWindow: value.kind == "no_conference") }
        guard let joined = value.joined, let room = value.room, let participants = value.participants,
              !room.key.isEmpty, room.key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
              Set(participants.map(\.id)).count == participants.count,
              participants.allSatisfy({ !$0.id.isEmpty }),
              participants.filter(\.local).count <= 1 else { throw InvalidModel() }
        let call = CallInfo(id: "\(targetID):\(room.conference_id ?? room.key)", title: room.title,
            url: space.appendingPathComponent(room.key),
            participants: participants.map { .init(id: $0.id, name: $0.name, isLocal: $0.local,
                isGuest: $0.guest, microphoneMuted: $0.microphone_muted, cameraMuted: $0.camera_muted) },
            localParticipantID: value.local_participant_id,
            microphoneMuted: value.microphone_muted, cameraMuted: value.camera_muted)
        return .init(participation: joined ? .inCall : .preparing, call: call)
    }
    static func validSpace(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host else { return false }
        return c.scheme == "https" && host.hasSuffix(".ktalk.ru") && host != ".ktalk.ru"
            && c.user == nil && c.password == nil && c.port == nil && c.query == nil && c.fragment == nil
            && (c.path.isEmpty || c.path == "/")
    }
    static func validDebugger(_ url: URL, port: Int) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "ws" && c.host == "127.0.0.1" && c.port == port
            && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
            && c.path.hasPrefix("/devtools/page/") && c.path.count > "/devtools/page/".count
    }
    struct InvalidModel: Error {}
    private struct Model: Decodable {
        let kind: String
        var joined: Bool?
        var room: Room?
        var local_participant_id: String?
        var microphone_muted: Bool?
        var camera_muted: Bool?
        var participants: [Participant]?
    }
    private struct Room: Decodable { let key: String; let title: String; var conference_id: String? }
    private struct Participant: Decodable {
        let id: String; let name: String; let local: Bool; let guest: Bool
        var microphone_muted: Bool?; var camera_muted: Bool?
    }
}
