import Foundation

struct CalendarParticipant: Codable, Equatable, Sendable {
    let id: String
    let name: String
    var email: String? = nil
    var organizer: Bool? = nil
}

/// A local snapshot remains readable when an invitation changes or disappears.
struct MeetingCalendarMetadata {
    let eventID: String?
    let association: String?
    let title: String
    let calendarTitle: String?
    let eventURL: URL?
    let agenda: String?
    let participants: [CalendarParticipant]
    let start: String?
    let end: String?
    let timeZoneIdentifier: String?
    var isConfirmed: Bool { association == "confirmed" && eventID?.isEmpty == false }

    init?(_ json: [String: Any]) {
        guard !json.isEmpty else { return nil }
        eventID = json["event_id"] as? String
        association = json["association"] as? String
        title = json["title"] as? String ?? localised("Calendar event", "Событие календаря")
        calendarTitle = json["calendar_title"] as? String
        let url = (json["event_url"] as? String).flatMap(URL.init(string:))
        eventURL = ["https", "http", "x-apple-calevent"].contains(url?.scheme?.lowercased() ?? "") ? url : nil
        let notes = (json["agenda"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        agenda = notes?.isEmpty == false ? notes : nil
        start = json["scheduled_start"] as? String
        end = json["scheduled_end"] as? String
        timeZoneIdentifier = json["time_zone"] as? String
        if let values = json["participants"] as? [[String: Any]], let data = try? JSONSerialization.data(withJSONObject: values),
           let decoded = try? JSONDecoder().decode([CalendarParticipant].self, from: data) {
            var ids: Set<String> = []
            participants = decoded.filter { !$0.id.isEmpty && ids.insert($0.id).inserted }
        } else {
            participants = (json["attendees"] as? [String] ?? []).enumerated().map {
                CalendarParticipant(id: "legacy-\($0.offset)", name: $0.element)
            }
        }
    }
    static func read(from dir: URL) -> Self? {
        let json = SessionState.read(dir) ?? (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(".recording.json")))) as? [String: Any]
        return (json?["calendar"] as? [String: Any]).flatMap(Self.init)
    }
    static func modelAttendees(_ json: [String: Any]?) -> [String] {
        guard json?["association"] as? String != "candidate" else { return [] }
        // New notes and email fields are deliberately absent from model context.
        return json?["attendees"] as? [String] ?? []
    }
    static func associate(_ meeting: CalendarWatcher.Meeting?, in dir: URL) throws {
        if let meeting, !meeting.hasPersistentID || meeting.id.isEmpty { throw CalendarSelectionError.missingEvent }
        try SessionClaim.acquire(dir, stage: .finish)
        defer { SessionClaim.release(dir) }
        // Only the meeting snapshot changes; names and transcript versions are independent files.
        let snapshot = meeting.flatMap { MeetingContext(meeting: $0, app: nil, confirmed: true).metaFields["calendar"] }
        try SessionState.amend(dir, with: ["calendar": snapshot])
    }

}
