import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct ActivityStatusBarTests {
    @Test("Playback and library search messages belong to the bottom row", .freshHome)
    func playbackAndSearchMessagesUseStatusRow() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        let library = MeetingLibraryController(root: Home.current.defaultRecordings, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        let bar = try #require(app.panel.contentView?.allDescendants.first { $0 is ActivityStatusBar } as? ActivityStatusBar)
        for id in ["playback.message", "library.search-status"] {
            #expect(bar.serviceRows.contains { $0.identifier?.rawValue == id })
            #expect(!library.contentView.allDescendants.contains { $0.identifier?.rawValue == id })
            #expect(!library.listContentView.allDescendants.contains { $0.identifier?.rawValue == id })
        }
    }

    @Test("Settings and import notices share the bottom row without expanding a narrow window", .freshHome)
    func simultaneousServiceNoticesFit() throws {
        try FileManager.default.createDirectory(at: Home.current.configDirectory, withIntermediateDirectories: true)
        try Data("{\"synthetic_status_fixture\":true}".utf8).write(to: Home.current.configFile)
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        app.navigate(.general)
        app.updateConfigProblem("Synthetic configuration problem\nMore detail")
        var result = MediaImportCoordinator.Result()
        result.failures = [.init(source: URL(fileURLWithPath: "/tmp/fixture.wav"),
                                 message: String(repeating: "Synthetic import failure. ", count: 20))]
        app.finishImport(result)
        let bar = try #require(app.panel.contentView?.allDescendants.first { $0 is ActivityStatusBar } as? ActivityStatusBar)
        let messagesButton = try #require(bar.allDescendants.first { $0.identifier?.rawValue == "activity.messages" } as? NSButton)
        #expect(!messagesButton.isHidden)
        let notice = try #require(bar.serviceRows.first { $0.identifier?.rawValue == "settings.notice" } as? NSTextField)
        #expect(!notice.isHidden)
        #expect(notice.toolTip?.contains("synthetic_status_fixture") == true)
        #expect(!bar.allDescendants.contains { $0 === notice })
        #expect(!app.settings.content(for: .general).allDescendants.contains { $0 === notice })
        bar.updateAttention(count: 1, detail: "Synthetic configuration problem")
        app.update(state: .recording, elapsed: "12:34")
        bar.readAudioLevels = { (.unavailable, .level(0.5)) }
        bar.refreshAudioLevels()
        let warning = try #require(bar.allDescendants.first { $0.identifier?.rawValue == "activity.warning" } as? NSButton)
        #expect(warning.title == "2", "Only configuration and meeting attention count; the mic has its own icon")
        #expect(messagesButton.title.hasPrefix("2 ·"))
        #expect(messagesButton.toolTip?.contains("Synthetic configuration problem") == false)
        let progress = try #require(bar.serviceRows.first { $0 is MediaImportStatusView } as? MediaImportStatusView)
        let work = ProcessingOperations()
        _ = try work.register(session: nil, kind: .importMedia)
        bar.updateWork(work.snapshot(), title: { $0.lastPathComponent })
        var cancellations = 0
        app.onCancelImport = { cancellations += 1 }
        app.panel.orderFront(nil)
        defer { app.panel.orderOut(nil) }
        for width in [760.0, 1340.0] {
            app.panel.setContentSize(.init(width: width, height: 600))
            app.updateImport(.init(source: URL(fileURLWithPath: "/tmp/fixture.wav"),
                                   index: 1, total: 1, stage: .normalizing, fraction: 0.5))
            app.panel.contentView?.layoutSubtreeIfNeeded()
            #expect(bar.frame.height == 36)
            #expect(abs(bar.frame.width - width) < 1)
            #expect(!bar.allDescendants.contains { !$0.isHiddenOrHasHiddenAncestor && $0.identifier?.rawValue == "activity.job" })
            #expect(messagesButton.toolTip?.contains("50%") == true)
            for view in bar.arrangedSubviews where !view.isHidden {
                let frame = view.convert(view.bounds, to: bar)
                #expect(frame.width > 0)
                #expect(frame.minX >= 0 && frame.maxX <= bar.bounds.width + 1)
            }
            if width == 760 {
                #expect(NSApp.sendAction(try #require(messagesButton.action), to: messagesButton.target, from: messagesButton))
                let popoverWindow = try #require(bar.serviceContent.window)
                popoverWindow.contentView?.layoutSubtreeIfNeeded()
                #expect(bar.serviceContent.bounds.width > 400)
                #expect(progress.frame.width > 400)
                #expect(!progress.isHiddenOrHasHiddenAncestor)
                #expect(!notice.isHiddenOrHasHiddenAncestor)
                let cancel = try #require(progress.allDescendants.first { $0.identifier?.rawValue == "media-import.cancel" } as? NSButton)
                #expect(cancel.convert(cancel.bounds, to: bar.serviceContent).maxX <= bar.serviceContent.bounds.width)
                if let output = ProcessInfo.processInfo.environment["VERBEMO_STATUS_SHOTS"] {
                    for (name, view) in [("concurrent-bar", bar as NSView), ("concurrent-messages", bar.serviceContent as NSView)] {
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: output).appendingPathComponent("macos-\(name).png"))
                    }
                }
                #expect(NSApp.sendAction(try #require(cancel.action), to: cancel.target, from: cancel))
                bar.refreshMessages()
                #expect(cancellations == 1)
                #expect(!cancel.isEnabled)
                #expect(messagesButton.toolTip?.contains("Cancelling import") == true)
                #expect(NSApp.sendAction(try #require(messagesButton.action), to: messagesButton.target, from: messagesButton))
            }
            app.finishImport(result)
            let dismiss = try #require(progress.allDescendants.first { $0.identifier?.rawValue == "media-import.dismiss" } as? NSButton)
            dismiss.performClick(nil)
            bar.refreshMessages()
            #expect(messagesButton.title.hasPrefix("1 ·"))
            app.finishImport(result)
        }
    }

    @Test("Import and configuration messages use the persistent status row", .freshHome)
    func serviceMessagesUseStatusRow() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        app.updateConfigProblem("Synthetic configuration problem")
        app.updateImport(.init(source: URL(fileURLWithPath: "/tmp/fixture.wav"),
                               index: 1, total: 1, stage: .normalizing, fraction: 0.5))
        let bar = try #require(app.panel.contentView?.allDescendants.first { $0 is ActivityStatusBar } as? ActivityStatusBar)
        let progress = try #require(bar.serviceRows.first { $0 is MediaImportStatusView })
        #expect(!bar.allDescendants.contains { $0 === progress })
        #expect(bar.serviceRows.flatMap { [$0] + $0.allDescendants }.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "Synthetic configuration problem"
        })
        app.finishImport(.init())
        app.navigate(.general)
        app.panel.setContentSize(.init(width: 760, height: 600))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(bar.frame.height == 36)
        #expect(bar.serviceRows.flatMap { [$0] + $0.allDescendants }.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Imported 0" })
        #expect(!app.isVisible, "Status updates must not reveal a hidden window")
    }

    @Test(.freshHome)
    func globalQueueAndWarningsClearUnrelatedSearch() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        let library = MeetingLibraryController(root: Home.current.defaultRecordings, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        let search = try #require(library.listContentView.allDescendants.first { $0 is NSSearchField } as? NSSearchField)
        let bar = try #require(app.panel.contentView?.allDescendants.first { $0 is ActivityStatusBar } as? ActivityStatusBar)
        bar.updateAttention(count: 1, detail: nil)
        for id in ["activity.queue", "activity.warning"] {
            search.stringValue = "unrelated meeting"
            let button = try #require(bar.allDescendants.first { $0.identifier?.rawValue == id } as? NSButton)
            #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
            #expect(search.stringValue.isEmpty)
        }
    }

    @Test(.freshHome)
    func failedAudioTestInvalidatesOlderSuccess() throws {
        SetupState.markCompleted()
        SetupState.rememberSystemAudioHeard()
        #expect(SetupState.systemAudioHeardAt() != nil)
        SetupState.rememberSystemAudioTest(.silent)
        #expect(SetupState.systemAudioHeardAt() == nil)
        #expect(!SetupState.isPending)
        SetupState.rememberSystemAudioTest(.heard)
        #expect(SetupState.systemAudioHeardAt() != nil)
        SetupState.rememberSystemAudioTest(.refused("fixture"))
        #expect(SetupState.systemAudioHeardAt() == nil)
    }

    @Test(.freshHome)
    func applicationTickerRefreshesWorkWithoutRecording() async throws {
        _ = NSApplication.shared
        Config.update(path: ["calendar"], value: false)
        Config.update(path: ["transcription", "enabled"], value: false)
        Config.update(path: ["summary", "enabled"], value: false)
        Config.update(path: ["auto_record", "enabled"], value: false)
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let operations = ProcessingOperations()
        let app = AppController(root: Home.current.defaultRecordings, operations: operations)
        let panel = try #require(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.contentView?.allDescendants.contains { $0.identifier?.rawValue == "activity-status-bar" } == true })
        let queue = try #require(panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "activity.queue" } as? NSButton)
        let ticket = try operations.register(session: Home.current.url.appendingPathComponent("waiting"), kind: .transcription)
        let deadline = Date().addingTimeInterval(3)
        while queue.title != "0 · 1", Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(queue.title == "0 · 1")
        operations.cancel(ticket.id)
        let finished = Gate()
        #expect(app.prepareForTermination { finished.open() })
        await finished.pass()
        panel.orderOut(nil)
    }

    @Test(.speaking(.russian))
    func requiredAccessDoesNotInventGrantsOrRequireAnUnusedCalendar() {
        let granted = ActivityAccess(microphone: .granted, systemAudio: .heard, calendar: nil)
        #expect(granted.ready)
        #expect(granted.automaticBlockReason == nil)
        let untested = ActivityAccess(microphone: .granted, systemAudio: nil, calendar: nil)
        #expect(!untested.ready)
        #expect(!untested.denied)
        #expect(untested.title == "Доступ: ?")
        let denied = ActivityAccess(microphone: .denied, systemAudio: .heard, calendar: nil)
        #expect(!denied.ready)
        #expect(denied.denied)
        #expect(denied.automaticBlockReason != nil)
        #expect(denied.destination == .recording)
        let calendar = ActivityAccess(microphone: .granted, systemAudio: .heard, calendar: .denied)
        #expect(!calendar.ready)
        #expect(calendar.destination == .calendar)
        #expect(!ActivityAccess(microphone: .granted, systemAudio: .silent, calendar: nil).ready)
    }

    @Test(.speaking(.russian))
    func automaticReadinessRequiresAnEnabledUsableTrigger() {
        var access = ActivityAccess(microphone: .granted, systemAudio: .heard, calendar: .denied)
        access.micActivity = false
        #expect(access.automaticBlockReason == "Включите запуск по микрофону или календарю")
        access.autoCalendar = true
        #expect(access.automaticBlockReason == "Нужен доступ к календарю")
        access.micActivity = true
        #expect(access.automaticBlockReason == nil, "Microphone triggering remains usable without calendar access")
        #expect(!access.ready, "Enabled calendar functionality still needs its permission")
    }

    @Test(.freshHome, .speaking(.russian))
    func selectedCalendarReadinessHandlesEmptyAndUnavailableSelectionsWithoutReadingEvents() {
        let store = CalendarFixtureStore()
        let work = store.addCalendar("Work")
        let watcher = CalendarWatcher(store: store, authorizationStatus: { .fullAccess })
        #expect(watcher.selectedCalendars().count == 1, "No explicit selection uses all calendars")
        for selection in [[], ["missing"], [work.calendarIdentifier]] {
            Config.update(path: ["calendar_ids"], value: selection)
            let access = ActivityAccess(microphone: .granted, systemAudio: .heard, calendar: .granted,
                micActivity: false, autoCalendar: true, hasSelectedCalendar: !watcher.selectedCalendars().isEmpty)
            #expect((access.automaticBlockReason == nil) == (selection == [work.calendarIdentifier]))
        }
        store.calendarList = []
        #expect(watcher.selectedCalendars().isEmpty, "A selected calendar can disappear after synchronization")
        #expect(store.accessRequests == 0)
        #expect(store.queryCount == 0, "Readiness depends on calendars, not whether an event is scheduled")
    }

    @Test(.freshHome, .speaking(.russian))
    func calendarOnlyReadinessRequiresASelectedCalendarAndOpensItsSettings() throws {
        var access = ActivityAccess(microphone: .granted, systemAudio: .heard, calendar: .granted,
            micActivity: false, autoCalendar: true, hasSelectedCalendar: false)
        #expect(access.ready, "Calendar selection is separate from permission")
        #expect(access.automaticBlockReason == "Выберите календарь")
        let bar = ActivityStatusBar()
        var destination: ApplicationNavigationState.Destination?
        bar.onAccess = { destination = $0 }
        bar.updateAccess(access)
        bar.updateAutomatic(true, reason: access.automaticBlockReason, blocked: access.automaticBlockReason != nil)
        let automatic = try #require(bar.allDescendants.first { $0.identifier?.rawValue == "navigation.auto-record" } as? NSButton)
        #expect(automatic.toolTip?.contains("заблокирована") == true)
        let settings = try #require(automatic.menu?.items.first)
        #expect(NSApp.sendAction(try #require(settings.action), to: settings.target, from: settings))
        #expect(destination == .calendar)
        access.hasSelectedCalendar = true
        #expect(access.automaticBlockReason == nil)
        access.hasSelectedCalendar = false
        access.micActivity = true
        #expect(access.automaticBlockReason == nil, "Microphone triggering remains usable with no selected calendars")
        bar.updateAccess(access)
        #expect(NSApp.sendAction(try #require(settings.action), to: settings.target, from: settings))
        #expect(destination == .recording)
    }

    @Test(.freshHome, .speaking(.russian))
    func countsRealWorkAndRetainsCancellationUntilCleanup() async throws {
        let operations = ProcessingOperations()
        let entered = Gate(), release = Gate()
        defer { release.open() }
        _ = try operations.register(session: nil, kind: .sweep)
        _ = try operations.register(session: nil, kind: .transcription)
        let waiting = try operations.register(session: Home.current.url.appendingPathComponent("waiting"), kind: .transcription)
        let running = try operations.register(session: Home.current.url.appendingPathComponent("running"), kind: .summary)
        let task = Task { try await running.run { entered.open(); await release.pass() } }
        await entered.pass()
        var work = ActivityWork(operations.snapshot())
        #expect(work.running == 1)
        #expect(work.waiting == 1)
        #expect(work.current?.id == running.id)
        #expect(ActivityWork.stage(try #require(work.current)) == "Создание сводки")
        operations.cancel(running.id)
        work = ActivityWork(operations.snapshot())
        #expect(work.running == 1)
        #expect(ActivityWork.stage(try #require(work.current)) == "Отмена…")
        release.open()
        try await task.value
        work = ActivityWork(operations.snapshot())
        #expect(work.running == 0)
        #expect(work.waiting == 1)
        #expect(work.current?.id == waiting.id)
        await operations.cancelAllAndWait()
        #expect(ActivityWork(operations.snapshot()).jobs.isEmpty)
    }

    @Test(.freshHome, .speaking(.russian))
    func statusActionsRecordingPauseAndSignals() throws {
        let bar = ActivityStatusBar()
        func button(_ id: String) throws -> NSButton {
            try #require(bar.allDescendants.first { $0.identifier?.rawValue == id } as? NSButton)
        }
        func click(_ id: String) throws {
            let item = try button(id)
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        var recorded = false, queued = false, attention = false
        var destination: ApplicationNavigationState.Destination?
        bar.onRecording = { recorded = true }
        bar.onQueue = { queued = true }
        bar.onAttention = { attention = true }
        bar.onAccess = { destination = $0 }
        bar.readAudioLevels = { (.level(0), .level(0)) }
        bar.updateRecording(.recording, elapsed: "12:34")
        #expect(try button("activity.recording").title == "12:34")
        #expect(try button("activity.warning").isHidden, "Silence is not a failed source")
        try click("activity.recording")
        #expect(recorded)
        bar.readAudioLevels = { (.level(0), .unavailable) }
        bar.refreshAudioLevels()
        #expect(try button("activity.warning").isHidden)
        #expect(try button("activity.system-access").toolTip == "Сигнал звука системы недоступен")
        recorded = false
        try click("activity.system-access")
        #expect(recorded)
        bar.updateRecording(.paused, elapsed: "12:34")
        #expect(try button("activity.recording").title == "12:34")
        #expect(try button("activity.warning").isHidden)
        bar.updateRecording(.idle, elapsed: nil)
        #expect(try !button("activity.recording").isEnabled)
        try click("activity.queue")
        #expect(queued)
        bar.updateAccess(.init(microphone: .granted, systemAudio: .heard, calendar: .denied))
        try click("activity.calendar-access")
        #expect(destination == .calendar)
        bar.updateAttention(count: 2, detail: nil)
        try click("activity.warning")
        #expect(attention)
        bar.updateAttention(count: 0, detail: "Configuration unreadable")
        try click("activity.warning")
        #expect(destination == .general)
    }

    @Test(.freshHome, .speaking(.russian), arguments: [760, 1340])
    func longJobsFitAndCompletionClearsTheOldJob(width: Int) async throws {
        _ = NSApplication.shared
        let app = ApplicationWindow()
        defer { app.hide() }
        let content = try #require(app.panel.contentView)
        let bar = try #require(content.allDescendants.first { $0 is ActivityStatusBar } as? ActivityStatusBar)
        let operations = ProcessingOperations(), entered = Gate(), release = Gate()
        defer { release.open() }
        let ticket = try operations.register(session: Home.current.url, kind: .diarization)
        let task = Task { try await ticket.run { entered.open(); await release.pass() } }
        await entered.pass()
        app.updateAutoRecord(enabled: true, decision: "Ожидает окончания звонка", blocked: true)
        app.update(state: .recording, elapsed: "1:23:45")
        bar.updateAttention(count: 2, detail: nil)
        let title = String(repeating: "Очень длинное название встречи ", count: 8)
        bar.updateWork(operations.snapshot()) { _ in title }
        app.panel.setContentSize(NSSize(width: width, height: 680))
        content.layoutSubtreeIfNeeded()
        let job = try #require(bar.allDescendants.first { $0.identifier?.rawValue == "activity.job" } as? NSButton)
        #expect(job.toolTip?.contains(title) == true)
        #expect(job.frame.width > 0)
        #expect(bar.frame.width <= CGFloat(width))
        for view in bar.arrangedSubviews where !view.isHidden {
            let frame = view.convert(view.bounds, to: bar)
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= bar.bounds.width + 1)
        }
        if let output = ProcessInfo.processInfo.environment["VERBEMO_STATUS_SHOTS"] {
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("macos-active-\(width).png"))
        }
        release.open()
        try await task.value
        bar.updateWork(operations.snapshot()) { _ in title }
        #expect(job.title.isEmpty)
        #expect(!job.isEnabled)
    }

    @Test(.freshHome, .speaking(.russian))
    func mainWindowKeepsStatusBarAcrossDestinations() throws {
        _ = NSApplication.shared
        let app = ApplicationWindow()
        defer { app.hide() }
        let content = try #require(app.panel.contentView)
        let bar = try #require(content.allDescendants.first { $0.identifier?.rawValue == "activity-status-bar" })
        let automatic = try #require(bar.allDescendants.first { $0.identifier?.rawValue == "navigation.auto-record" } as? NSButton)
        var toggles = 0
        app.onToggleAutoRecord = { toggles += 1 }
        #expect(NSApp.sendAction(try #require(automatic.action), to: automatic.target, from: automatic))
        #expect(toggles == 1)
        app.updateAutoRecord(enabled: true, decision: "Ожидание звонка")
        #expect(automatic.state == .on)
        #expect(content.allDescendants.filter { $0.identifier?.rawValue == "navigation.auto-record" }.count == 1)
        for destination in [ApplicationNavigationState.Destination.allMeetings, .general, .recording, .processing] {
            app.navigate(destination)
            app.panel.setContentSize(NSSize(width: 760, height: 600))
            content.layoutSubtreeIfNeeded()
            #expect(!bar.isHiddenOrHasHiddenAncestor)
            #expect(bar.frame.width <= 760)
            #expect(automatic.frame.width > 0)
        }
    }
}
