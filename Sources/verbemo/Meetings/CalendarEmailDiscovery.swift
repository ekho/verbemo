import EventKit
import Foundation

@MainActor
enum CalendarEmailDiscovery {
    static func addresses(in store: EKEventStore, now: Date = Date()) -> [String] {
        let calendars = store.calendars(for: .event).filter { !$0.isSubscribed && $0.source?.isDelegate == false }
        guard !calendars.isEmpty else { return [] }
        // shortcut: accounts without invitations within ±1 year need manual entry or another lookup later.
        let start = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let end = Calendar.current.date(byAdding: .year, value: 1, to: now)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let found = store.events(matching: predicate).flatMap { event in
            ((event.attendees ?? []) + [event.organizer].compactMap { $0 }).compactMap {
                ownAddress(url: $0.url, isCurrentUser: $0.isCurrentUser)
            }
        }
        return EmailAddresses.normalize(found).sorted()
    }

    static func ownAddress(url: URL, isCurrentUser: Bool) -> String? {
        guard isCurrentUser, url.scheme?.lowercased() == "mailto",
              let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
              let normalized = EmailAddresses.normalize([address]).first,
              EmailAddresses.isValid(normalized) else { return nil }
        return normalized
    }

    static func afterFirstGrant(in store: EKEventStore) {
        guard !SetupState.calendarEmailsImported() else { return }
        importAfterFirstGrant(addresses(in: store))
    }

    static func importAfterFirstGrant(_ found: [String]) {
        guard !SetupState.calendarEmailsImported() else { return }
        let current = Config.userEmails()
        let merged = EmailAddresses.normalize(current + found)
        guard merged == current || Config.update(path: ["user_email"], value: merged) else { return }
        SetupState.markCalendarEmailsImported()
    }
}
