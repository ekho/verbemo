import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct CalendarEventPickerTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z")!
    private func event(_ id: String, day: Int = 0) -> CalendarWatcher.Meeting {
        let start = now.addingTimeInterval(Double(day) * 86400)
        return .init(id: id, title: "Планирование \(id)", start: start, end: start.addingTimeInterval(3600),
            attendees: ["Анна"], link: nil, looksLikeCall: true, calendarTitle: "Тестовый календарь",
            agenda: "Только синтетические данные", participants: [.init(id: "anna", name: "Анна")],
            timeZoneIdentifier: "Europe/Moscow")
    }
    @Test func defaultDayTitleAndExplicitDateQueries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Moscow"))
        let today = CalendarEventQuery(date: now, calendar: calendar)
        #expect(today.title.isEmpty)
        #expect(today.range.duration == 86400)
        #expect(today.matches(event("сегодня")))
        #expect(!today.matches(event("завтра", day: 1)))
        let text = CalendarEventQuery(date: now, text: "планирование", calendar: calendar)
        #expect(text.matches(event("ЗАВТРА", day: 1)))
        #expect(!text.matches(event("давно", day: -800)))
        for input in ["22.10.2026", "2026-10-22", "22.10", "22.10.2026 завтра"] {
            let query = CalendarEventQuery(date: now, text: input, calendar: calendar)
            #expect(query.matches(event("завтра", day: 1)))
            #expect(!query.matches(event("сегодня")))
        }
        #expect(CalendarEventQuery(date: now, text: "31.02.2026", calendar: calendar).title == "31.02.2026")
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let dst = CalendarEventQuery(date: now, text: "01.11.2026", calendar: calendar)
        #expect(dst.range.duration == 25 * 3600)
    }

    @Test(.freshHome) func sharedPickerLoadsSearchSelectsAndClearsWithoutImplicitSelection() async throws {
        let picker = CalendarEventPicker()
        picker.date.dateValue = now
        let events = [event("сегодня"), event("завтра", day: 1)]
        var selected: CalendarWatcher.Meeting?
        var changes = 0
        picker.loadEvents = { query in events.filter(query.matches) }
        picker.onSelect = { selected = $0; changes += 1 }
        picker.reload(); await picker.settled()
        #expect(picker.meetings.map(\.id) == ["сегодня"])
        #expect(changes == 0)
        picker.search.stringValue = "планирование"
        picker.reload(); await picker.settled()
        #expect(picker.meetings.count == 2)
        picker.choose(events[1]); await picker.settled()
        #expect(selected?.id == "завтра")
        #expect(picker.selectedMeeting?.start == events[1].start)
        picker.clearSelection()
        #expect(selected == nil && picker.selectedMeeting == nil)
        #expect(changes == 2)
    }

    @Test(.freshHome) func staleSearchAndCancelledSelectionCannotChangeAnotherMeeting() async throws {
        let picker = CalendarEventPicker()
        picker.date.dateValue = now
        let old = event("old"), next = event("next", day: 1)
        var pending: CheckedContinuation<[CalendarWatcher.Meeting], Never>?
        picker.loadEvents = { query in
            if query.title.isEmpty { return await withCheckedContinuation { pending = $0 } }
            return [next]
        }
        picker.reload()
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try #require(pending)
        picker.search.stringValue = "next"
        picker.reload(); await picker.settled()
        continuation.resume(returning: [old]); await Task.yield()
        #expect(picker.meetings.map(\.id) == ["next"])
        var resolution: CheckedContinuation<CalendarWatcher.Meeting, Never>?
        picker.resolveEvent = { _ in await withCheckedContinuation { resolution = $0 } }
        var writes = 0
        picker.onSelect = { _ in writes += 1 }
        picker.choose(next)
        for _ in 0..<100 where resolution == nil { await Task.yield() }
        let resolve = try #require(resolution)
        picker.update(date: now, snapshot: nil, contextID: "another-meeting")
        resolve.resume(returning: next); await picker.settled()
        #expect(writes == 0)
    }

    @Test(.freshHome, arguments: [CalendarSelectionError.accessDenied, .missingEvent])
    func unavailableCalendarOrDeletedEventKeepsPreviousSelection(error: CalendarSelectionError) async {
        let picker = CalendarEventPicker()
        let previous = event("previous")
        picker.setSelection(previous)
        var writes = 0
        picker.onSelect = { _ in writes += 1 }
        picker.loadEvents = { _ in throw error }
        picker.reload(); await picker.settled()
        #expect(picker.meetings.isEmpty)
        #expect(picker.status.stringValue == error.localizedDescription)
        picker.resolveEvent = { _ in throw error }
        picker.choose(event("deleted")); await picker.settled()
        #expect(writes == 0)
        #expect(picker.selectedMeeting?.id == previous.id)
    }

    @Test(.freshHome, arguments: ["Планирование old", "Название вручную", nil] as [String?])
    func changingEventUpdatesOnlyAnInheritedMeetingTitle(title: String?) async throws {
        var meta = MeetingContext(meeting: event("old"), app: nil).metaFields
        meta["title"] = title
        let fixture = try SessionFixture.make(meta: meta)
        let root = fixture.appendingPathExtension("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.moveItem(at: fixture, to: dir)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        await library.settled()
        let heading = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "meeting.title" })

        for id in ["next", "last"] {
            library.calendarPicker.choose(event(id))
            await library.calendarPicker.settled()
            await library.settled()
            let expected = title == "Название вручную" ? "Название вручную" : "Планирование \(id)"
            #expect(SessionState.value(dir, "title") as? String == expected)
            #expect(MeetingCalendarMetadata.read(from: dir)?.eventID == id)
            #expect(heading.stringValue == expected)
        }
        library.calendarPicker.clearSelection()
        await library.settled()
        #expect(MeetingCalendarMetadata.read(from: dir) == nil)
        #expect(heading.stringValue == (title == "Название вручную" ? "Название вручную" : "Планирование last"))
    }

    @Test(.freshHome) func linkChangeAndClearPreserveAllResultsAndManualNames() throws {
        let dir = try SessionFixture.make(meta: ["title": "Название вручную", "custom": 42])
        defer { try? FileManager.default.removeItem(at: dir) }
        PostProcessor.rename("them A", to: "Ручное имя", in: dir)
        _ = try #require(try TranscriptVersions.archiveCurrent(dir))
        try Transcript(engine: "whisper", model: "test-current", created_at: "2026-10-21T11:00:00Z", segments: SessionFixture.meeting).write(to: dir)
        #expect(TranscriptVersions.read(dir).count == 2)
        let urls = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]))
            .compactMap { $0 as? URL }.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && $0.lastPathComponent != "meta.json" && !$0.lastPathComponent.hasPrefix(".")
            }
        let before = try Dictionary(uniqueKeysWithValues: urls.map { ($0, try Data(contentsOf: $0)) })
        for meeting in [event("first"), event("second", day: 1), nil] {
            try MeetingCalendarMetadata.associate(meeting, in: dir)
            let snapshot = MeetingCalendarMetadata.read(from: dir)
            #expect(snapshot?.eventID == meeting?.id)
            if meeting != nil {
                #expect(snapshot?.isConfirmed == true)
                #expect(snapshot?.timeZoneIdentifier == "Europe/Moscow")
                #expect(snapshot?.agenda == "Только синтетические данные")
            }
            #expect(SessionState.value(dir, "title") as? String == "Название вручную")
            #expect(SessionState.value(dir, "custom") as? Int == 42)
            for (url, data) in before { #expect(try Data(contentsOf: url) == data) }
            #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == nil)
        }
        try SessionClaim.acquire(dir, stage: .finish)
        defer { SessionClaim.release(dir) }
        #expect(throws: (any Error).self) { try MeetingCalendarMetadata.associate(event("busy"), in: dir) }
        #expect(MeetingCalendarMetadata.read(from: dir) == nil)
    }

    @Test(.freshHome) func missingEventAtRecordingStartDoesNotStartCapture() async throws {
        let event = event("removed")
        let sheet = NewRecordingSheet(calendarEnabled: true, now: now) { _ in (event, [event]) }
        defer { sheet.panel.close() }
        sheet.calendarPicker.resolveEvent = { _ in throw CalendarSelectionError.missingEvent }
        var starts = 0
        sheet.onComplete = { if case .start = $0 { starts += 1 } }
        sheet.load(); await sheet.settled()
        let button = try #require(sheet.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "recording.start" } as? NSButton)
        _ = NSApp.sendAction(try #require(button.action), to: button.target, from: button)
        await sheet.settled()
        #expect(starts == 0)
        #expect(button.isEnabled)
        sheet.calendarPicker.clearSelection()
        _ = NSApp.sendAction(try #require(button.action), to: button.target, from: button)
        #expect(starts == 1)
    }
}
