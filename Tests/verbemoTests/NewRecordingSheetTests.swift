import AppKit
import Foundation
import Testing
@testable import verbemo

@Suite(.serialized)
@MainActor
struct NewRecordingSheetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func meeting(_ id: String, start: TimeInterval = 0) -> CalendarWatcher.Meeting {
        .init(id: id, title: "Встреча \(id)", start: now.addingTimeInterval(start),
            end: now.addingTimeInterval(start + 3600), attendees: ["Анна"], link: "https://call.example.test",
            looksLikeCall: true, calendarTitle: "Работа", agenda: "Повестка", participants: [.init(id: "anna", name: "Анна")],
            timeZoneIdentifier: "Europe/Moscow")
    }
    private func button(_ id: String, in sheet: NewRecordingSheet) throws -> NSButton {
        try #require(sheet.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == id } as? NSButton)
    }
    private func act(_ control: NSControl) throws {
        _ = NSApp.sendAction(try #require(control.action), to: control.target, from: control)
    }

    @Test(.freshHome, .speaking(.russian))
    func disabledCalendarUsesTimestampWithoutReadingCalendar() async throws {
        var reads = 0
        let sheet = NewRecordingSheet(calendarEnabled: false, now: now) { _ in reads += 1; return nil }
        defer { sheet.panel.close() }
        sheet.load()
        await sheet.settled()
        #expect(reads == 0)
        #expect(sheet.name.stringValue == "Запись " + MeetingPresentation.date(now))
        #expect(sheet.calendarPicker.superview == nil)
        var submitted: (String, CalendarWatcher.Meeting?)?
        sheet.onComplete = { if case .start(let title, let meeting) = $0 { submitted = (title, meeting) } }
        sheet.name.stringValue = "  "
        try act(button("recording.start", in: sheet))
        #expect(submitted?.0 == "Запись " + MeetingPresentation.date(now))
        #expect(submitted?.1 == nil)
    }

    @Test(.freshHome, .speaking(.russian))
    func automaticMatchAndEventChangesUpdateOnlySuggestedTitle() async throws {
        let first = meeting("first", start: -60), second = meeting("second", start: 300)
        let sheet = NewRecordingSheet(calendarEnabled: true, now: now) { _ in
            (CalendarWatcher.bestMatch(for: now, among: [first, second]), [first, second])
        }
        defer { sheet.panel.close() }
        sheet.load()
        #expect(try !button("recording.start", in: sheet).isEnabled)
        await sheet.settled()
        #expect(sheet.selectedMeeting?.id == first.id)
        #expect(sheet.name.stringValue == first.title)
        sheet.calendarPicker.choose(second)
        await sheet.calendarPicker.settled()
        #expect(sheet.name.stringValue == second.title)
        sheet.name.stringValue = "Моё название"
        sheet.calendarPicker.choose(first)
        await sheet.calendarPicker.settled()
        #expect(sheet.name.stringValue == "Моё название")
        var submitted: (String, CalendarWatcher.Meeting?)?
        sheet.onComplete = { if case .start(let title, let event) = $0 { submitted = (title, event) } }
        try act(button("recording.start", in: sheet))
        #expect(submitted?.0 == "Моё название")
        #expect(submitted?.1?.id == first.id)
        #expect(submitted?.1?.participants.first?.id == "anna")
        #expect(submitted?.1?.agenda == "Повестка")
    }

    @Test(.freshHome)
    func explicitNoEventClearsAssociationAndRestoresDefaultTitle() async throws {
        let event = meeting("event")
        let sheet = NewRecordingSheet(calendarEnabled: true, now: now) { _ in (event, [event]) }
        defer { sheet.panel.close() }
        sheet.load()
        await sheet.settled()
        sheet.calendarPicker.clearSelection()
        #expect(sheet.selectedMeeting == nil)
        #expect(sheet.name.stringValue.contains(MeetingPresentation.date(now)))
    }

    @Test(.freshHome, arguments: [false, true])
    func unavailableOrEmptyCalendarDoesNotBlockRecording(authorized: Bool) async throws {
        let sheet = NewRecordingSheet(calendarEnabled: true, now: now) { _ in authorized ? (nil, []) : nil }
        defer { sheet.panel.close() }
        sheet.load()
        await sheet.settled()
        #expect(try button("recording.start", in: sheet).isEnabled)
        #expect(sheet.calendarPicker.button.isEnabled)
        #expect(sheet.selectedMeeting == nil)
        #expect(sheet.name.stringValue.contains(MeetingPresentation.date(now)))
        let note = try #require(sheet.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "recording.calendar-status" } as? NSTextField)
        #expect(!note.isHidden)
        #expect(!note.stringValue.isEmpty)
    }

    @Test(.freshHome)
    func earlyJoinAcrossMidnightLoadsTheSuggestedDay() async throws {
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let beforeMidnight = midnight.addingTimeInterval(-120)
        var event = meeting("tomorrow")
        event = .init(id: event.id, title: event.title, start: midnight.addingTimeInterval(120), end: midnight.addingTimeInterval(3600), attendees: [], link: nil, looksLikeCall: true)
        var dates: [Date] = []
        let sheet = NewRecordingSheet(calendarEnabled: true, now: beforeMidnight) { date in
            dates.append(date)
            return (event, Calendar.current.isDate(date, inSameDayAs: event.start) ? [event] : [])
        }
        defer { sheet.panel.close() }
        sheet.load()
        await sheet.settled()
        #expect(dates.count == 2)
        #expect(Calendar.current.isDate(sheet.date.dateValue, inSameDayAs: event.start))
        #expect(sheet.selectedMeeting?.id == event.id)
        #expect(sheet.name.stringValue == event.title)
    }

    @Test(.freshHome)
    func lateInitialResponseCannotReplaceAnEditedTitle() async throws {
        let event = meeting("event")
        var pending: CheckedContinuation<NewRecordingSheet.CalendarOptions?, Never>?
        let sheet = NewRecordingSheet(calendarEnabled: true, now: now) { _ in
            await withCheckedContinuation { pending = $0 }
        }
        defer { sheet.panel.close() }
        sheet.load()
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try #require(pending)
        sheet.name.stringValue = "Название пользователя"
        continuation.resume(returning: (event, [event]))
        await sheet.settled()
        #expect(sheet.selectedMeeting?.id == event.id)
        #expect(sheet.name.stringValue == "Название пользователя")
    }

    @Test(.freshHome, .speaking(.russian), arguments: [false, true])
    func fullWidthTitleAndHorizontalActions(calendarEnabled: Bool) throws {
        let sheet = NewRecordingSheet(calendarEnabled: calendarEnabled, now: now, loadCalendar: nil)
        defer { sheet.panel.close() }
        sheet.panel.contentView?.layoutSubtreeIfNeeded()
        let surface = try #require(sheet.panel.contentView)
        let titleFrame = sheet.name.convert(sheet.name.bounds, to: surface)
        #expect(abs(titleFrame.minX - 24) < 1)
        #expect(abs(surface.bounds.width - titleFrame.maxX - 24) < 1)
        let start = try button("recording.start", in: sheet)
        let cancel = try button("recording.cancel", in: sheet)
        let settings = try button("recording.settings", in: sheet)
        let frames = [start, cancel, settings].map { $0.convert($0.bounds, to: surface) }
        #expect(start.title == "Начать")
        #expect(cancel.title == "Отмена")
        #expect(settings.title.isEmpty)
        #expect([start, cancel, settings].allSatisfy { $0.image != nil })
        #expect(frames[0].maxX < frames[1].minX && frames[1].maxX < frames[2].minX)
        #expect(abs(frames[0].midY - frames[1].midY) < 1 && abs(frames[1].midY - frames[2].midY) < 1)
        #expect(frames[2].width <= 34)
        #expect(start.keyEquivalent == "\r" && cancel.keyEquivalent == "\u{1b}")
        #expect(settings.accessibilityLabel() == "Настройки записи")
    }

    @Test(.freshHome, arguments: [false, true])
    func escapeCancelsWhileEditingTheTitle(calendarEnabled: Bool) async throws {
        let sheet = NewRecordingSheet(calendarEnabled: calendarEnabled, now: now) { _ in (nil, []) }
        defer { sheet.panel.close() }
        sheet.load()
        await sheet.settled()
        var cancellations = 0
        var starts = 0
        sheet.onComplete = { result in
            if case .cancel = result { cancellations += 1 }
            if case .start = result { starts += 1 }
        }
        sheet.panel.makeKeyAndOrderFront(nil)
        sheet.name.selectText(nil)
        let editor = try #require(sheet.name.currentEditor() as? NSTextView)
        editor.insertText("Edited meeting", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(cancellations == 1)
        try act(button("recording.start", in: sheet))
        #expect(starts == 0)
        #expect(cancellations == 1)
    }

    @Test(.freshHome, arguments: ["recording.cancel", "recording.settings"])
    func nonRecordingActionsFinishOnlyOnce(id: String) throws {
        let sheet = NewRecordingSheet(calendarEnabled: false, now: now, loadCalendar: nil)
        defer { sheet.panel.close() }
        var results: [NewRecordingSheet.Result] = []
        sheet.onComplete = { results.append($0) }
        try act(button(id, in: sheet))
        try act(button("recording.start", in: sheet))
        #expect(results.count == 1)
        switch try #require(results.first) {
        case .cancel: #expect(id == "recording.cancel")
        case .settings: #expect(id == "recording.settings")
        case .start: Issue.record("Cancel/settings must not start a recording")
        }
    }

    @Test(.freshHome)
    func workspacePassesTheChosenEventAndTitleBeforeShowingLiveRecording() async throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        let event = meeting("linked")
        app.recordingCalendar = { _ in (event, [event]) }
        var started: (String, CalendarWatcher.Meeting?)?
        app.onStartRecording = { title, event in
            started = (title, event)
            app.update(state: .recording, elapsed: "00:00")
        }
        app.show()
        app.newRecording()
        let sheet = try #require(app.recordingSheet)
        await sheet.settled()
        sheet.name.stringValue = "Другая тема"
        try act(button("recording.start", in: sheet))
        #expect(started?.0 == "Другая тема")
        #expect(started?.1?.id == event.id)
        #expect(app.recordingSheet == nil)
        #expect(app.recordingBarIsVisible)
        #expect(app.navigation.resultTab == "transcript")
    }

    @Test(.freshHome)
    func aConcurrentRecordingClosesTheDraftInsteadOfStartingOrRenamingAnother() async throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        var starts = 0
        app.onStartRecording = { _, _ in starts += 1 }
        app.recordingCalendar = { _ in (nil, []) }
        app.show()
        app.newRecording()
        let sheet = try #require(app.recordingSheet)
        await sheet.settled()
        app.update(state: .recording, elapsed: "00:01")
        #expect(app.recordingSheet == nil)
        try act(button("recording.start", in: sheet))
        #expect(starts == 0)
        app.newRecording()
        #expect(app.recordingSheet == nil)
    }

    @Test(.freshHome)
    func settingsFromTheSheetNavigateInTheSameWorkspaceWithoutRecording() async throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        var starts = 0
        app.onStartRecording = { _, _ in starts += 1 }
        app.recordingCalendar = { _ in (nil, []) }
        app.show()
        app.newRecording()
        let sheet = try #require(app.recordingSheet)
        await sheet.settled()
        try act(button("recording.settings", in: sheet))
        #expect(app.navigation.destination == .recording)
        #expect(app.recordingSheet == nil)
        #expect(starts == 0)
    }

    @Test(.freshHome)
    func selectedEventAndCustomTitleSurviveRecordingAndRecoveryMetadata() throws {
        let context = MeetingContext(meeting: meeting("event"), app: "Call app", appFamilies: ["call.app"], confirmed: true)
        let session = try RecordingSession(root: Home.current.url, context: context, title: "  Своя запись  ",
            mic: FakeMicRecorder(), system: FakeSystemRecorder())
        try session.start()
        #expect(session.title == "Своя запись")
        #expect(session.context.appFamilies == ["call.app"])
        #expect(session.dir.lastPathComponent.contains("Своя запись"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: session.dir.appendingPathComponent(".recording.json"))) as? [String: Any])
        #expect(manifest["title"] as? String == "Своя запись")
        let active = try #require(MeetingCalendarMetadata.read(from: session.dir))
        #expect(active.isConfirmed && active.eventID == "event")
        #expect(active.title == "Встреча event")
        #expect(active.agenda == "Повестка" && active.participants.first?.id == "anna")
        session.stop(reason: "manual")
        #expect(SessionState.read(session.dir)?["title"] as? String == "Своя запись")
        #expect(MeetingCalendarMetadata.read(from: session.dir)?.isConfirmed == true)
        #expect(throws: (any Error).self) {
            try RecordingSession(root: Home.current.url, title: " ", mic: FakeMicRecorder(), system: FakeSystemRecorder())
        }
    }
}
