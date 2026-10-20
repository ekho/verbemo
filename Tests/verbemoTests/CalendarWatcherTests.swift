import Foundation
import Testing

@testable import verbemo

@MainActor
struct CalendarWatcherTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(
        _ id: String, start: TimeInterval, end: TimeInterval, call: Bool = true
    ) -> CalendarWatcher.Meeting {
        CalendarWatcher.Meeting(
            id: id, title: id,
            start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
            attendees: [], link: nil, looksLikeCall: call)
    }

    @Test("An early join uses the upcoming meeting instead of the previous one",
          arguments: [-60.0, 0.0, 120.0])
    func earlyJoin(previousEnd: TimeInterval) {
        let candidates = [
            meeting("Previous", start: -30 * 60, end: previousEnd),
            meeting("Upcoming", start: 2 * 60, end: 32 * 60),
        ]
        let selected = CalendarWatcher.bestMatch(for: now, among: candidates)
        #expect(selected?.id == "Upcoming")
        #expect(MeetingContext(meeting: selected, app: "zoom.us").folderSuffix
            == "Upcoming (zoom.us)")
    }

    @Test("An event that has ended cannot name a new recording", arguments: [-1.0, 0.0])
    func endedEvent(end: TimeInterval) {
        #expect(CalendarWatcher.bestMatch(for: now, among: [
            meeting("Ended", start: -30 * 60, end: end),
        ]) == nil)
    }

    @Test("An ongoing call remains eligible even when it started more than eight minutes ago")
    func ongoingCall() {
        #expect(CalendarWatcher.bestMatch(for: now, among: [
            meeting("Ongoing", start: -30 * 60, end: 30 * 60),
        ])?.id == "Ongoing")
    }

    @Test("The closest start wins regardless of the input order")
    func closestStart() {
        let earlier = meeting("Earlier", start: -20 * 60, end: 20 * 60)
        let closest = meeting("Closest", start: -60, end: 29 * 60)
        let upcoming = meeting("Upcoming", start: 5 * 60, end: 35 * 60)
        for candidates in [[earlier, closest, upcoming], [upcoming, closest, earlier]] {
            #expect(CalendarWatcher.bestMatch(for: now, among: candidates)?.id == "Closest")
        }
    }

    @Test("Equally close starts favor the upcoming meeting")
    func equallyCloseStarts() {
        #expect(CalendarWatcher.bestMatch(for: now, among: [
            meeting("Previous", start: -2 * 60, end: 2 * 60),
            meeting("Upcoming", start: 2 * 60, end: 32 * 60),
        ])?.id == "Upcoming")
    }

    @Test("Early joins stay within the eight-minute window")
    func earlyJoinWindow() {
        let upcoming = meeting("Upcoming", start: 8 * 60, end: 38 * 60)
        #expect(CalendarWatcher.bestMatch(for: now, among: [upcoming])?.id == "Upcoming")
        #expect(CalendarWatcher.bestMatch(for: now, among: [
            meeting("Too far away", start: 8 * 60 + 1, end: 38 * 60),
        ]) == nil)
    }

    @Test("Calls still take priority over solo blocks")
    func callPreference() {
        #expect(CalendarWatcher.bestMatch(for: now, among: [
            meeting("Solo", start: 0, end: 30 * 60, call: false),
            meeting("Call", start: 2 * 60, end: 32 * 60),
        ])?.id == "Call")
    }

    @Test("A solo block can name a recording when there are no calls")
    func soloFallback() {
        #expect(CalendarWatcher.bestMatch(for: now, among: [
            meeting("Solo", start: 0, end: 30 * 60, call: false),
        ])?.id == "Solo")
        #expect(CalendarWatcher.bestMatch(for: now, among: []) == nil)
    }
}
