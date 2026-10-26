import AppKit
import Foundation
import Testing

@testable import verbemo

@MainActor
@Suite(.serialized, .freshHome)
struct AutoRecordStartupTests {
    @Test("Startup never requests calendar access, even with calendar features enabled", arguments: [false, true])
    func startupDoesNotRequestCalendarPermission(setupCompleted: Bool) async {
        if setupCompleted { SetupState.markCompleted() }
        Config.update(path: ["calendar"], value: true)
        Config.update(path: ["auto_record", "calendar"], value: true)
        let store = CalendarFixtureStore()
        let calendar = CalendarWatcher(store: store, authorizationStatus: { .notDetermined })
        var settings = Config.AutoRecordSettings()
        settings.enabled = false
        let watcher = AutoRecordController(settings: settings, calendar: calendar, loadSettings: { settings })
        let app = AppController(root: Home.current.defaultRecordings, autoRecord: watcher,
                                operations: ProcessingOperations(), calendar: calendar)
        defer {
            watcher.stop()
            for window in NSApp.windows { window.orderOut(nil) }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(store.accessRequests == 0)
        let finished = Gate()
        #expect(app.prepareForTermination { finished.open() })
        await finished.pass()
        #expect(store.accessRequests == 0)
    }

    @Test("Existing calendar access imports own emails only when calendar features are enabled", arguments: [false, true])
    func startupPreservesPassiveEmailDiscovery(enabled: Bool) async {
        SetupState.markCompleted()
        Config.update(path: ["calendar"], value: enabled)
        Config.update(path: ["auto_record", "calendar"], value: enabled)
        let store = CalendarFixtureStore()
        let calendar = CalendarWatcher(store: store, authorizationStatus: { .fullAccess })
        var settings = Config.AutoRecordSettings()
        settings.enabled = false
        let watcher = AutoRecordController(settings: settings, calendar: calendar, loadSettings: { settings })
        let app = AppController(root: Home.current.defaultRecordings, autoRecord: watcher,
                                operations: ProcessingOperations(), calendar: calendar)
        defer {
            watcher.stop()
            for window in NSApp.windows { window.orderOut(nil) }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(store.accessRequests == 0)
        #expect(SetupState.calendarEmailsImported() == enabled)
        let finished = Gate()
        #expect(app.prepareForTermination { finished.open() })
        await finished.pass()
    }

    @Test("An unfinished setup does not prevent the app from watching a granted microphone")
    func pendingSetupStillWatchesMeetings() async {
        #expect(SetupState.isPending)
        var settings = Config.AutoRecordSettings()
        settings.startDelay = 3600
        let watcher = AutoRecordController(
            settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { _ in Self.zoom }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let app = AppController(root: Home.current.defaultRecordings, autoRecord: watcher, operations: ProcessingOperations())
        defer {
            watcher.stop()
            for window in NSApp.windows { window.orderOut(nil) }
        }
        #expect(watcher.lastDecision == "zoom.us on the mic for 0s")
        #expect(SetupState.isPending, "watching must not silently complete the setup wizard")
        let finished = Gate()
        #expect(app.prepareForTermination { finished.open() })
        #expect(!SetupState.isPending, "quitting dismisses the first-run page")
        await finished.pass()
    }

    @Test("Both triggers wait for microphone access without requesting a recording or backing off",
          arguments: [false, true])
    func microphoneGrantUnblocksWatching(fromCalendar: Bool) {
        var settings = Config.AutoRecordSettings()
        settings.startDelay = 0
        settings.calendar = fromCalendar
        let calendar = FakeCalendar()
        calendar.meetings = [FakeCalendar.meeting(id: "sync", start: Date())]
        var granted = false
        var attempts = 0
        let watcher = AutoRecordController(
            settings: settings, calendar: calendar, loadSettings: { settings },
            canStartRecording: { granted }, checkMic: { _ in Self.zoom })
        watcher.startRecording = { _, _ in attempts += 1; return true }
        watcher.tick()
        #expect(attempts == 0)
        #expect(watcher.phase == .watching)
        #expect(watcher.lastDecision == "waiting for microphone access")
        granted = true
        watcher.tick()
        #expect(attempts == 1)
        #expect(watcher.phase == .recording)
    }

    @Test("Starting a disabled watcher reports its state immediately")
    func disabledStateIsVisibleAtStartup() {
        var settings = Config.AutoRecordSettings()
        settings.enabled = false
        let watcher = AutoRecordController(
            settings: settings, calendar: nil, loadSettings: { settings })
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.lastDecision == "auto-record off")
    }

    @Test("The real timer starts a held Zoom microphone within the three-second default delay")
    func timerUsesShortStartDelay() {
        let settings = Config.AutoRecordSettings()
        var session: FakeAutoSession?
        var started: Date?
        let watcher = AutoRecordController(
            settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { _ in Self.zoom })
        watcher.currentSession = { session }
        watcher.startRecording = { trigger, _ in
            started = Date()
            session = FakeAutoSession(startedAt: Date(), trigger: trigger)
            return true
        }
        let beganWatching = Date()
        watcher.start()
        defer { watcher.stop() }
        RunLoop.current.run(until: beganWatching.addingTimeInterval(2))
        #expect(started == nil)
        let deadline = beganWatching.addingTimeInterval(4.5)
        while started == nil, Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date(timeIntervalSinceNow: 0.02)))
        }
        #expect(started != nil, "a five-second poll misses the configured three-second delay")
    }

    private static var zoom: MicActivityMonitor.Result {
        MicActivityMonitor.Result(active: true, names: ["zoom.us"],
            families: ["us.zoom.xos"], allHolders: ["zoom.us"])
    }
}
