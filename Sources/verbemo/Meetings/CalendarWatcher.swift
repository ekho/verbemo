import EventKit
import Foundation

/// Reads the local calendars for two things: a real name for the session
/// folder instead of a bare timestamp, and a second, independent trigger for
/// automatic recording.
///
/// Opt-in (`auto_record.calendar`), because it costs a permission prompt and
/// because a calendar is only a good meeting signal if yours is accurate. The
/// mic-activity trigger needs no permission and no accurate calendar, so it
/// stays the default of the two.
@MainActor
final class CalendarWatcher {
    struct Meeting {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let attendees: [String]
        /// Conference link or location, whichever the event carries — kept so
        /// the recording folder can say where the call actually happened.
        let link: String?
        /// True when the event has other people or a conference link — the
        /// difference between a meeting and "dentist, 15:00".
        let looksLikeCall: Bool
        var calendarTitle: String? = nil
        var agenda: String? = nil
        var participants: [CalendarParticipant] = []
        var hasPersistentID = true
        var timeZoneIdentifier: String? = nil
    }

    private static let matchWindow: TimeInterval = 8 * 60
    private let store: EKEventStore
    private let authorizationStatus: () -> EKAuthorizationStatus
    // EventKit can keep reporting notDetermined until relaunch after a successful prompt.
    private var accessGranted = false
    var authorized: Bool {
        let status = authorizationStatus()
        return status == .fullAccess || (status == .notDetermined && accessGranted)
    }

    init(store: EKEventStore = EKEventStore(),
         authorizationStatus: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) }) {
        self.store = store
        self.authorizationStatus = authorizationStatus
    }

    /// nil means permission is unavailable; an empty array means there are no calendars.
    func availableCalendars() -> [EKCalendar]? {
        guard authorized else { return nil }
        return store.calendars(for: .event)
    }

    func selectedCalendars() -> [EKCalendar] {
        let selected = Config.calendarIDs().map(Set.init)
        return (availableCalendars() ?? []).filter { selected?.contains($0.calendarIdentifier) ?? true }
    }

    /// Only the permission buttons in setup/settings may request access; reads never prompt.
    func requestAccess() async {
        switch authorizationStatus() {
        case .fullAccess:
            break
        case .notDetermined where accessGranted:
            break
        case .notDetermined:
            accessGranted = (try? await store.requestFullAccessToEvents()) ?? false
            if !accessGranted {
                FileHandle.standardError.write(Data(
                    "calendar access denied — auto-record falls back to mic activity only\n".utf8
                ))
            }
        default:
            accessGranted = false
            FileHandle.standardError.write(Data(
                "calendar access not granted — sessions will be named by time\n".utf8
            ))
        }
        importOwnEmailsIfNeeded()
    }

    func importOwnEmailsIfNeeded() {
        guard authorized else { return }
        CalendarEmailDiscovery.afterFirstGrant(in: store)
    }

    func ownEmailAddresses() -> [String] {
        authorized ? CalendarEmailDiscovery.addresses(in: store) : []
    }

    /// Meetings that started within the last `window` seconds (or are about to,
    /// by up to 30s — calendar clocks and wall clocks disagree slightly) and
    /// look like calls. The auto-record trigger.
    func justStarted(now: Date, window: TimeInterval) -> [Meeting] {
        meetings(around: now, slack: window).filter {
            let sinceStart = now.timeIntervalSince($0.start)
            return sinceStart >= -30 && sinceStart <= window && $0.looksLikeCall
        }
    }

    /// The event that best describes a recording started at `date` — used to
    /// name the session folder even when the recording began some other way.
    /// Prefers calls over solo blocks, then the closest start among ongoing
    /// meetings and those starting within eight minutes. Ended events cannot match.
    func bestMatch(for date: Date) -> Meeting? {
        let candidates = meetings(around: date, slack: Self.matchWindow)
        return Self.bestMatch(for: date, among: candidates)
    }

    static func bestMatch(for date: Date, among candidates: [Meeting]) -> Meeting? {
        candidates.filter {
            $0.end > date && $0.start.timeIntervalSince(date) <= matchWindow
        }.min {
            if $0.looksLikeCall != $1.looksLikeCall { return $0.looksLikeCall }
            let firstDistance = abs($0.start.timeIntervalSince(date))
            let secondDistance = abs($1.start.timeIntervalSince(date))
            if firstDistance != secondDistance { return firstDistance < secondDistance }
            return $0.start > $1.start
        }
    }

    func meetings(on date: Date) -> [Meeting] {
        guard let day = Calendar.current.dateInterval(of: .day, for: date) else { return [] }
        return meetings(from: day.start, to: day.end)
    }

    func search(_ query: CalendarEventQuery) async throws -> [Meeting] {
        guard Config.useCalendar() else { throw CalendarSelectionError.integrationDisabled }
        guard authorized else { throw CalendarSelectionError.accessDenied }
        return meetings(from: query.range.start, to: query.range.end, includeAllDay: true).filter(query.matches)
    }

    func resolve(_ selected: Meeting) async throws -> Meeting {
        let events = try await search(CalendarEventQuery(date: selected.start))
        guard selected.hasPersistentID,
              let current = events.first(where: { $0.id == selected.id && $0.start == selected.start }) else {
            throw CalendarSelectionError.missingEvent
        }
        return current
    }

    // MARK: -

    private func meetings(around date: Date, slack: TimeInterval) -> [Meeting] {
        meetings(from: date.addingTimeInterval(-slack), to: date.addingTimeInterval(slack))
    }

    private func meetings(from start: Date, to end: Date, includeAllDay: Bool = false) -> [Meeting] {
        guard authorized else { return [] }
        guard Config.useCalendar() || Config.autoRecord().calendar else { return [] }
        let calendars = selectedCalendars()
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendars
        )
        return store.events(matching: predicate)
            .filter { (includeAllDay || !$0.isAllDay) && $0.status != .canceled }
            .map(Self.convert)
            .sorted { $0.start < $1.start }
    }

    private static func convert(_ event: EKEvent) -> Meeting {
        let attendees = (event.attendees ?? []).compactMap { participant -> String? in
            participant.name
                ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        let haystack = [
            event.location ?? "",
            event.url?.absoluteString ?? "",
            event.hasNotes ? (event.notes ?? "") : "",
        ].joined(separator: " ").lowercased()

        // Notes are a local snapshot; only the existing attendee names enter model context.
        let link = [event.url?.absoluteString, event.location]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return Meeting(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "meeting",
            start: event.startDate,
            end: event.endDate,
            attendees: attendees,
            link: link,
            // Self counts as an attendee, so "other people" means more than one.
            looksLikeCall: attendees.count > 1
                || Self.conferenceMarkers.contains { haystack.contains($0) },
            calendarTitle: event.calendar.title,
            agenda: event.notes,
            participants: (event.attendees ?? []).map { participant in
                CalendarParticipant(id: participant.url.absoluteString,
                    name: participant.name ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                    email: participant.url.scheme == "mailto" ? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") : nil,
                    organizer: participant.url == event.organizer?.url)
            },
            hasPersistentID: event.eventIdentifier?.isEmpty == false,
            timeZoneIdentifier: event.timeZone?.identifier
        )
    }

    /// Substrings that mean "there's a call link in here". Kept broad rather
    /// than clever: a missed marker only costs the calendar trigger for that
    /// event, and the mic trigger still catches the meeting.
    private static let conferenceMarkers = [
        "zoom.us", "meet.google.com", "teams.microsoft", "teams.live", "whereby.com",
        "webex.com", "jitsi", "around.co", "gather.town", "huddle", "discord.gg",
        "telemost", "yandex.ru/telemost", "ktalk", "contour.ru", "salutejazz", "vkmeet",
    ]
}
