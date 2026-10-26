import AppKit
import EventKit
import Foundation
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct CalendarSettingsTests {
    @Test(.freshHome)
    func calendarPageOffersAllCalendarsByDefault() throws {
        let app = ApplicationWindow()
        defer { app.settings.setup.stop(); app.hide() }
        let page = app.settings.content(for: .calendar)
        let all = try #require(page.allDescendants.first {
            $0.identifier?.rawValue == "calendar_ids.all"
        } as? NSButton)
        #expect(all.state == .on)
        #expect(!all.isHiddenOrHasHiddenAncestor)
    }

    private func button(_ id: String, in view: NSView) throws -> NSButton {
        try #require(view.allDescendants.first { $0.identifier?.rawValue == "calendar_ids.\(id)" } as? NSButton)
    }

    private func set(_ button: NSButton, _ state: NSControl.StateValue) throws {
        button.state = state
        _ = NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button)
    }

    @Test(.freshHome)
    func selectionPersistsAndNewCalendarsStayExcluded() throws {
        let store = CalendarFixtureStore()
        let first = store.addCalendar("Same name")
        let second = store.addCalendar("Same name")
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .fullAccess })
        let view = CalendarSettingsView(calendar: watcher)
        let firstButton = try button(first.calendarIdentifier, in: view)
        try set(firstButton, .off)
        #expect(Config.calendarIDs() == [second.calendarIdentifier])
        #expect(try button(first.calendarIdentifier, in: view) === firstButton)
        first.title = "Renamed"
        let third = store.addCalendar("New calendar")
        view.refresh()
        #expect(try button(first.calendarIdentifier, in: view).state == .off)
        #expect(try button(third.calendarIdentifier, in: view).state == .off)
        let reopened = CalendarSettingsView(calendar: watcher)
        #expect(try button(second.calendarIdentifier, in: reopened).state == .on)
        try set(button(second.calendarIdentifier, in: reopened), .off)
        #expect(Config.calendarIDs() == [])
        #expect(try button("all", in: view).state == .off)
        try set(button("all", in: reopened), .on)
        #expect(Config.calendarIDs() == nil)
        #expect(try button(third.calendarIdentifier, in: view).state == .on)
        try set(button("all", in: reopened), .off)
        #expect(Set(Config.calendarIDs() ?? []) == Set([first, second, third].map(\.calendarIdentifier)))
    }

    @Test(.freshHome)
    func missingCalendarsAreRetainedAndPermissionAndEmptyStatesAreDistinct() throws {
        let store = CalendarFixtureStore()
        let first = store.addCalendar("Work")
        var permission = EKAuthorizationStatus.denied
        let view = CalendarSettingsView(calendar: CalendarWatcher(store: store, authorizationStatus: { permission }))
        let status = try #require(view.allDescendants.first { $0.identifier?.rawValue == "calendar_ids.status" } as? NSTextField)
        #expect(!status.isHidden)
        #expect(try !button("all", in: view).isEnabled)
        let deniedMessage = status.stringValue
        permission = .fullAccess
        view.refresh()
        #expect(status.isHidden)
        Config.update(path: ["calendar_ids"], value: ["missing", first.calendarIdentifier])
        #expect(!status.isHidden)
        try set(button(first.calendarIdentifier, in: view), .off)
        #expect(Config.calendarIDs() == ["missing"])
        store.calendarList = []
        view.refresh()
        #expect(!status.isHidden)
        #expect(status.stringValue != deniedMessage)
        #expect(Config.calendarIDs() == ["missing"])
        #expect(view.allDescendants.allSatisfy { $0.identifier?.rawValue != "calendar_ids.\(first.calendarIdentifier)" })
    }

    @Test(.freshHome)
    func failedWriteRestoresSavedSelectionAndReportsError() throws {
        let store = CalendarFixtureStore()
        let first = store.addCalendar("Work")
        Config.update(path: ["calendar_ids"], value: [first.calendarIdentifier])
        let view = CalendarSettingsView(calendar: CalendarWatcher(store: store, authorizationStatus: { .fullAccess }))
        try Data("broken json".utf8).write(to: Config.path)
        try set(button(first.calendarIdentifier, in: view), .off)
        #expect(try button(first.calendarIdentifier, in: view).state == .on)
        let error = try #require(view.allDescendants.first { $0.identifier?.rawValue == "calendar_ids.error" } as? NSTextField)
        #expect(!error.isHidden)
        #expect(try String(contentsOf: Config.path, encoding: .utf8) == "broken json")
    }

    @Test(.freshHome)
    func newlyGrantedAccessOpensListEvenWhileSystemStatusIsStale() async throws {
        let store = CalendarFixtureStore()
        let work = store.addCalendar("Work")
        let now = Date()
        store.addEvent("Work meeting", calendar: work, now: now)
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .notDetermined })
        let app = ApplicationWindow(calendar: watcher)
        let settings = app.settings
        defer { _ = settings.stopForTermination(); app.hide() }
        let page = settings.content(for: .calendar)
        #expect(try !button("all", in: page).isEnabled)
        #expect(store.accessRequests == 0, "Constructing settings must not ask for permission")
        let refreshed = Gate()
        let onStateChange = settings.setup.onStateChange
        settings.setup.onStateChange = { onStateChange?(); refreshed.open() }
        let row = try #require(page.allDescendants.first { $0.identifier?.rawValue == "access.calendar" } as? AccessRow)
        row.onAct?()
        await refreshed.pass()
        _ = settings.content(for: .calendar)
        #expect(store.accessRequests == 1)
        #expect(SetupState.calendarEmailsImported())
        #expect(try button("all", in: page).isEnabled)
        #expect(try button(work.calendarIdentifier, in: page).state == .on)
        #expect(watcher.bestMatch(for: now)?.title == "Work meeting")
        #expect(try await watcher.search(CalendarEventQuery(date: now)).count == 1)
        #expect(store.accessRequests == 1, "Reads after the explicit grant must not request again")
    }

    @Test(.freshHome)
    func initialSetupGrantsAccessAndSharesCalendarSelectionWithSettings() async throws {
        let store = CalendarFixtureStore()
        let work = store.addCalendar("Work")
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .notDetermined })
        let app = ApplicationWindow(calendar: watcher)
        let setup = SetupPage(calendar: watcher)
        defer { _ = setup.stopForTermination(); _ = app.stopForTermination(); app.hide() }
        app.presentSetup(setup)
        let page = setup.contentView
        #expect(store.accessRequests == 0)
        #expect(try !button("all", in: page).isEnabled)
        let permission = try #require(page.allDescendants.first { $0.identifier?.rawValue == "access.calendar" } as? AccessRow)
        permission.onAct?()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.accessRequests == 1)
        #expect(try button(work.calendarIdentifier, in: page).state == .on)
        try set(button(work.calendarIdentifier, in: page), .off)
        #expect(Config.calendarIDs() == [])
        app.navigate(.calendar)
        let settings = app.settings.content(for: .calendar)
        #expect(try button(work.calendarIdentifier, in: settings).state == .off)
        try set(button(work.calendarIdentifier, in: settings), .on)
        #expect(Config.calendarIDs() == [work.calendarIdentifier])
        #expect(try button(work.calendarIdentifier, in: page).state == .on)
        #expect(store.accessRequests == 1)
    }

    @Test(.freshHome)
    func readingEventsNeverRequestsPermission() async throws {
        let store = CalendarFixtureStore()
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .notDetermined })
        let now = Date()
        #expect(watcher.availableCalendars() == nil)
        #expect(watcher.meetings(on: now).isEmpty)
        #expect(watcher.bestMatch(for: now) == nil)
        #expect(watcher.justStarted(now: now, window: 120).isEmpty)
        await #expect(throws: CalendarSelectionError.accessDenied) {
            try await watcher.search(CalendarEventQuery(date: now))
        }
        #expect(store.accessRequests == 0)
        watcher.importOwnEmailsIfNeeded()
        #expect(!SetupState.calendarEmailsImported())
    }

    @Test(.freshHome)
    func emailLookupUsesSharedAccessWithoutRequestingPermission() async throws {
        let store = CalendarFixtureStore()
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .notDetermined })
        let app = ApplicationWindow(calendar: watcher)
        defer { _ = app.stopForTermination(); app.hide() }
        let page = app.settings.content(for: .calendar)
        let editor = try #require(page.allDescendants.compactMap { $0 as? EmailAddressesEditor }.first)
        editor.onLookup?()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.accessRequests == 0)
        #expect(store.calendarReads == 0)
        let permission = try #require(page.allDescendants.first { $0.identifier?.rawValue == "access.calendar" } as? AccessRow)
        permission.onAct?()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.accessRequests == 1)
        let reads = store.calendarReads
        editor.onLookup?()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.calendarReads > reads)
        #expect(store.accessRequests == 1)
    }

    @Test(.freshHome)
    func manualEmailLookupCompletesFirstImportWithoutPrompting() async throws {
        let store = CalendarFixtureStore()
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .fullAccess })
        let app = ApplicationWindow(calendar: watcher)
        defer { _ = app.stopForTermination(); app.hide() }
        let page = app.settings.content(for: .calendar)
        let editor = try #require(page.allDescendants.compactMap { $0 as? EmailAddressesEditor }.first)
        #expect(!SetupState.calendarEmailsImported())
        editor.onLookup?()
        for _ in 0..<20 { await Task.yield() }
        #expect(SetupState.calendarEmailsImported())
        #expect(store.accessRequests == 0)
        let reads = store.calendarReads
        watcher.importOwnEmailsIfNeeded()
        #expect(store.calendarReads == reads, "Startup must not import again after a manual lookup")
    }

    @Test(.freshHome)
    func existingPermissionWorksWithoutAnExplicitRequest() {
        let store = CalendarFixtureStore()
        let work = store.addCalendar("Work")
        let now = Date()
        store.addEvent("Work meeting", calendar: work, now: now)
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .fullAccess })
        #expect(watcher.bestMatch(for: now)?.title == "Work meeting")
        #expect(watcher.justStarted(now: now, window: 120).count == 1)
        #expect(store.accessRequests == 0)
    }

    @Test(.freshHome)
    func disablingBothCalendarFeaturesPreventsEventReadsWithExistingPermission() {
        Config.update(path: ["calendar"], value: false)
        Config.update(path: ["auto_record", "calendar"], value: false)
        let store = CalendarFixtureStore()
        let work = store.addCalendar("Work")
        let now = Date()
        store.addEvent("Work meeting", calendar: work, now: now)
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .fullAccess })
        #expect(watcher.bestMatch(for: now) == nil)
        #expect(watcher.justStarted(now: now, window: 120).isEmpty)
        #expect(store.queryCount == 0)
    }

    @Test(.freshHome)
    func everyEventConsumerUsesTheSelectionImmediately() async throws {
        let store = CalendarFixtureStore()
        let work = store.addCalendar("Work")
        let personal = store.addCalendar("Personal")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.addEvent("Work meeting", calendar: work, now: now)
        store.addEvent("Personal meeting", calendar: personal, now: now)
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .fullAccess })
        await watcher.requestAccess()
        #expect(watcher.meetings(on: now).count == 2)
        Config.update(path: ["calendar_ids"], value: [work.calendarIdentifier])
        #expect(watcher.bestMatch(for: now)?.title == "Work meeting")
        #expect(watcher.justStarted(now: now, window: 120).map(\.title) == ["Work meeting"])
        #expect(watcher.meetings(on: now).map(\.title) == ["Work meeting"])
        #expect(try await watcher.search(CalendarEventQuery(date: now)).map(\.title) == ["Work meeting"])
        #expect(store.requestedIDs == [work.calendarIdentifier])
        Config.update(path: ["calendar_ids"], value: [personal.calendarIdentifier])
        #expect(watcher.bestMatch(for: now)?.title == "Personal meeting")
        for ids in [[], ["no-longer-available"]] {
            Config.update(path: ["calendar_ids"], value: ids)
            let requests = store.queryCount
            #expect(watcher.bestMatch(for: now) == nil)
            #expect(watcher.justStarted(now: now, window: 120).isEmpty)
            #expect(try await watcher.search(CalendarEventQuery(date: now)).isEmpty)
            #expect(store.queryCount == requests, "An empty filter must never become an all-calendar EventKit query")
        }
    }

    @Test(.freshHome, arguments: ["invalid", "", "   "])
    func malformedSelectionDoesNotEnableAllCalendars(value: String) {
        Config.update(path: ["calendar_ids"], value: value)
        #expect(Config.calendarIDs() == [])
        #expect(Config.problems().contains { $0.explanation.contains("calendar_ids") })
    }

    @Test(.freshHome(config: #"{"calendar_ids":[]}"#))
    func unreadableConfigurationRetainsSelectionAndRevokedAccessReturnsNoEvents() async throws {
        let store = CalendarFixtureStore()
        let work = store.addCalendar("Work")
        let now = Date()
        store.addEvent("Work meeting", calendar: work, now: now)
        var permission = EKAuthorizationStatus.fullAccess
        let watcher = CalendarWatcher(store: store, authorizationStatus: { permission })
        await watcher.requestAccess()
        #expect(watcher.meetings(on: now).isEmpty)
        try Data("invalid json".utf8).write(to: Config.path)
        #expect(watcher.meetings(on: now).isEmpty)
        try Data("{}".utf8).write(to: Config.path)
        #expect(watcher.meetings(on: now).count == 1)
        permission = .denied
        #expect(watcher.meetings(on: now).isEmpty)
    }
}

/// Only EventKit IO is faked; the watcher, UI actions and config persistence are real.
final class CalendarFixtureStore: EKEventStore {
    var calendarList: [EKCalendar] = []
    var eventList: [EKEvent] = []
    var requestedIDs: [String] = []
    var queryCount = 0
    var accessRequests = 0
    var calendarReads = 0

    override func requestFullAccessToEvents(completion: @escaping EKEventStoreRequestAccessCompletionHandler) {
        accessRequests += 1
        completion(true, nil)
    }

    func addCalendar(_ title: String) -> EKCalendar {
        let calendar = EKCalendar(for: .event, eventStore: self)
        calendar.title = title
        calendarList.append(calendar)
        return calendar
    }

    func addEvent(_ title: String, calendar: EKCalendar, now: Date) {
        let event = EKEvent(eventStore: self)
        event.calendar = calendar
        event.title = title
        event.startDate = now.addingTimeInterval(-60)
        event.endDate = now.addingTimeInterval(600)
        event.url = URL(string: "https://meet.google.com/test")
        eventList.append(event)
    }

    override func calendars(for entityType: EKEntityType) -> [EKCalendar] {
        calendarReads += 1
        return calendarList
    }
    override func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate {
        queryCount += 1
        requestedIDs = (calendars ?? calendarList).map(\.calendarIdentifier)
        return NSPredicate(value: true)
    }
    override func events(matching predicate: NSPredicate) -> [EKEvent] {
        eventList.filter { requestedIDs.contains($0.calendar.calendarIdentifier) }
    }
}
