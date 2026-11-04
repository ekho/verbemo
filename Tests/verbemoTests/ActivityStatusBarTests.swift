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
        bar.updateAttention([.init(dir: Home.current.url, title: "Test meeting", problems: ["Test failure"])],
                            detail: "Synthetic configuration problem")
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
            #expect(!bar.allDescendants.contains {
                !$0.isHiddenOrHasHiddenAncestor && $0.identifier?.rawValue == "activity.job"
            }, "The import result owns the status until the outstanding import leaves the queue")
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

    @Test(.freshHome, .speaking(.english))
    func queueOpensWithoutNavigationAndItsFooterClearsSearch() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination(); app.hide() }
        let library = MeetingLibraryController(root: Home.current.defaultRecordings, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        app.show()
        let search = try #require(library.listContentView.allDescendants.first { $0 is NSSearchField } as? NSSearchField)
        let bar = app.activityBar
        let queue = try Self.click("activity.queue", in: bar)
        #expect(app.navigation.destination == .allMeetings)
        let content = bar.queuePopover.view
        #expect(content.window?.isVisible == true)
        #expect(content.allDescendants.contains { ($0 as? NSTextField)?.stringValue == "The queue is empty." })
        let popoverWindow = try #require(content.window)
        let anchor = app.panel.convertToScreen(queue.convert(queue.bounds, to: nil))
        #expect(popoverWindow.frame.minY >= anchor.midY, "The queue opens above the activity counter")
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: popoverWindow.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(content.performKeyEquivalent(with: escape))
        #expect(app.panel.firstResponder === queue)
        try Self.click("activity.queue", in: bar)
        search.stringValue = "unrelated meeting"
        try Self.click("activity.queue-processing", in: content)
        #expect(app.navigation.destination == .processing)
        #expect(search.stringValue.isEmpty)
    }

    @Test(.freshHome, .speaking(.russian))
    func attentionListsProblemsAndOpensTheChosenMeeting() async throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination(); app.hide() }
        let root = Home.current.defaultRecordings
        let otherFailures = (10..<19).map { ("\($0)", "Встреча \($0)", Optional("Сбой расшифровки")) }
        for (name, title, failure) in [("01", "Первая", "Нет звука"), ("02", "Вторая", "Сбой модели"), ("03", "Без ошибок", nil)] + otherFailures {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var meta = ["title": title]
            meta[SessionState.Key.transcriptionFailed] = failure
            try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(.init(width: 760, height: 600))
        app.show()
        await library.settled()
        app.updateActivity([], access: .init(microphone: .granted, systemAudio: .heard, calendar: nil))
        app.navigate(.calendar)

        let warning = try Self.click("activity.warning", in: app.activityBar)
        #expect(warning.title == "11")
        #expect(app.navigation.destination == .calendar)
        let popup = try #require(NSApp.windows.compactMap(\.contentView).flatMap { [$0] + $0.allDescendants }
            .first { $0.identifier?.rawValue == "activity.attention-popover" })
        popup.layoutSubtreeIfNeeded()
        let scroll = try #require(popup.allDescendants.first { $0 is NSScrollView } as? NSScrollView)
        #expect(scroll.hasVerticalScroller)
        #expect(try #require(scroll.documentView).bounds.height > scroll.contentView.bounds.height)
        let rows = popup.allDescendants.compactMap { $0 as? NSButton }
        #expect(rows.contains { $0.attributedTitle.string.contains("Вторая")
            && $0.attributedTitle.string.contains("Сбой модели") })
        let first = try #require(rows.first { $0.accessibilityLabel()?.contains("Первая") == true
            && $0.accessibilityLabel()?.contains("Нет звука") == true })
        #expect(!rows.contains { $0.accessibilityLabel()?.contains("Без ошибок") == true })
        #expect(first.sendAction(first.action, to: first.target))
        #expect(app.navigation.destination == .allMeetings)
        let title = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.title" } as? NSTextField)
        for _ in 0..<50 where title.stringValue != "Первая" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(title.stringValue == "Первая")

        app.activityBar.updateAttention(library.attentionMeetings, detail: "Ошибка настроек")
        try Self.click("activity.warning", in: app.activityBar)
        try Self.click("activity.attention-settings", in: popup)
        #expect(app.navigation.destination == .general)
    }

    @Test("The queue removes a waiting run and cancels only the confirmed running job", .freshHome, .speaking(.russian))
    func queueActionsAreScopedToTheRun() async throws {
        let operations = ProcessingOperations()
        let app = ApplicationWindow(operations: operations)
        let a = try operations.register(session: URL(fileURLWithPath: "/test/Обзор"), kind: .summary)
        let b = try operations.register(session: URL(fileURLWithPath: "/test/Интервью"), kind: .diarization)
        let c = try operations.register(session: URL(fileURLWithPath: "/test/Релиз"), kind: .transcription)
        let enteredA = Gate(), enteredB = Gate(), releaseA = Gate(), releaseB = Gate()
        let cancelledA = Flag(), cancelledB = Flag()
        let taskA = Task { try await a.run {
            await withTaskCancellationHandler { enteredA.open(); await releaseA.pass() } onCancel: { cancelledA.raise() }
            try Task.checkCancellation()
        } }
        let taskB = Task { try await b.run {
            await withTaskCancellationHandler { enteredB.open(); await releaseB.pass() } onCancel: { cancelledB.raise() }
        } }
        defer { releaseA.open(); releaseB.open(); _ = app.stopForTermination(); app.hide() }
        await enteredA.pass(); await enteredB.pass()
        app.show()
        app.panel.setContentSize(.init(width: 760, height: 600))
        app.activityBar.updateWork(operations.snapshot(), title: { $0.lastPathComponent })
        try Self.click("activity.queue", in: app.activityBar)
        let content = app.activityBar.queuePopover.view
        try Self.click("activity.queue-remove.\(c.id)", in: content)
        for _ in 0..<100 where operations.snapshot().contains(where: { $0.id == c.id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!operations.snapshot().contains { $0.id == c.id })
        try Self.click("activity.queue-cancel.\(a.id)", in: content)
        let keep = try #require(content.allDescendants.first { $0.identifier?.rawValue == "activity.queue-keep.\(a.id)" } as? NSButton)
        let new = try operations.register(session: URL(fileURLWithPath: "/test/Другая"), kind: .transcription)
        app.activityBar.updateWork(operations.snapshot(), title: { $0.lastPathComponent })
        #expect(content.allDescendants.contains { $0 === keep })
        #expect(content.window?.firstResponder === keep)
        #expect(!cancelledA.isRaised)
        try Self.click("activity.queue-confirm.\(a.id)", in: content)
        for _ in 0..<100 where !cancelledA.isRaised { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelledA.isRaised)
        #expect(operations.snapshot().first { $0.id == a.id }?.state == .cancelling)
        #expect(!cancelledB.isRaised)
        #expect(operations.snapshot().contains { $0.id == new.id && $0.state == .waiting })
        releaseA.open()
        _ = try? await taskA.value
        try Self.click("activity.queue-cancel.\(b.id)", in: content)
        try Self.click("activity.queue-confirm.\(b.id)", in: content)
        for _ in 0..<100 where !cancelledB.isRaised { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelledB.isRaised)
        releaseB.open()
        try await taskB.value
        let notices = app.activityBar.serviceRows.flatMap { [$0] + $0.allDescendants }.compactMap { $0 as? NSTextField }
        for _ in 0..<100 where !notices.contains(where: { $0.stringValue.contains("успело завершиться") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(notices.contains { $0.stringValue.contains("Интервью") && $0.stringValue.contains("успело завершиться") })
        #expect(notices.contains { $0.stringValue.contains("Обзор") && $0.stringValue.contains("Задание отменено") })
        #expect(notices.contains { $0.stringValue.contains("Релиз") && $0.stringValue.contains("Автообработка может добавить") })
    }

    @Test("A long task list scrolls inside the queue with the Processing link still visible",
          .freshHome, arguments: [false, true])
    func queueListScrolls(dark: Bool) throws {
        let operations = ProcessingOperations()
        for index in 0..<20 {
            _ = try operations.register(session: URL(fileURLWithPath: "/test/\(index)"), kind: .transcription)
        }
        let app = ApplicationWindow(operations: operations)
        defer { _ = app.stopForTermination(); app.hide() }
        app.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        app.panel.setContentSize(.init(width: 760, height: 600))
        app.show()
        let long = String(repeating: "Очень длинное название встречи ", count: 8)
        app.activityBar.updateWork(operations.snapshot(), title: { _ in long })
        try Self.click("activity.queue", in: app.activityBar)
        let content = app.activityBar.queuePopover.view
        let scroll = try #require(content.allDescendants.first { $0.identifier?.rawValue == "activity.queue-list" } as? NSScrollView)
        let document = try #require(scroll.documentView)
        let footer = try #require(content.allDescendants.first { $0.identifier?.rawValue == "activity.queue-processing" } as? NSButton)
        #expect(scroll.hasVerticalScroller)
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        #expect(content.bounds.width >= 400)
        #expect(!footer.isDescendant(of: scroll))
        #expect(content.bounds.contains(footer.convert(footer.bounds, to: content)))
        #expect(document.allDescendants.contains { ($0 as? NSTextField)?.toolTip == long })
    }

    @discardableResult
    private static func click(_ id: String, in view: NSView) throws -> NSButton {
        let button = try #require(view.allDescendants.first { $0.identifier?.rawValue == id } as? NSButton)
        #expect(button.isEnabled)
        #expect(button.sendAction(button.action, to: button.target))
        return button
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

    @Test(.freshHome, .speaking(.russian), arguments: [SetupPermissions.State.denied, .notAsked])
    func microphonePermissionBlockOpensRecordingSettings(permission: SetupPermissions.State) throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        var toggles = 0
        app.onToggleAutoRecord = { toggles += 1 }
        let access = ActivityAccess(microphone: permission, systemAudio: .heard, calendar: nil)
        app.updateActivity([], access: access)
        app.updateAutoRecord(enabled: true, decision: access.automaticBlockReason, blocked: true)
        let mic = try #require(app.activityBar.allDescendants.first { $0.identifier?.rawValue == "activity.microphone-access" } as? NSButton)
        #expect(mic.contentTintColor == .systemOrange)
        #expect(mic.toolTip == (permission == .denied ? "Доступ к микрофону запрещён" : "Нужен доступ к микрофону"))
        let button = try #require(app.activityBar.allDescendants.first { $0.identifier?.rawValue == "navigation.auto-record" } as? NSButton)
        button.performClick(nil)
        #expect(app.navigation.destination == .recording)
        #expect(button.state == .on)
        #expect(toggles == 0)

        app.updateActivity([], access: .init(microphone: .granted, systemAudio: .heard, calendar: nil))
        #expect(mic.contentTintColor != .systemOrange)
        try Self.click("navigation.auto-record", in: app.activityBar)
        #expect(toggles == 1)
    }

    @Test(.freshHome, .speaking(.russian))
    func calendarWarnsUntilAccessIsGranted() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination() }
        app.updateActivity([], access: .init(microphone: .granted, systemAudio: .heard, calendar: .notAsked))
        let calendar = try Self.click("activity.calendar-access", in: app.activityBar)
        #expect(calendar.contentTintColor == .systemOrange)
        #expect(app.navigation.destination == .calendar)
        app.updateActivity([], access: .init(microphone: .granted, systemAudio: .heard, calendar: .granted))
        #expect(calendar.contentTintColor != .systemOrange)
        app.updateActivity([], access: .init(microphone: .granted, systemAudio: .heard, calendar: nil))
        #expect(calendar.isHidden)
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
        var recorded = false
        var destination: ApplicationNavigationState.Destination?
        bar.onRecording = { recorded = true }
        bar.onAccess = { destination = $0 }
        let system = try button("activity.system-access")
        #expect(system.contentTintColor == .systemOrange)
        #expect(system.toolTip?.contains("нужно проверить") == true)
        try click("activity.system-access")
        #expect(destination == .recording)
        bar.updateAccess(.init(microphone: .granted, systemAudio: .heard, calendar: nil))
        #expect(system.contentTintColor != .systemOrange)
        bar.readAudioLevels = { (.level(0), .level(0)) }
        bar.updateRecording(.recording, elapsed: "12:34")
        #expect(try button("activity.recording").title == "12:34")
        #expect(try button("activity.warning").isHidden, "Silence is not a failed source")
        try click("activity.recording")
        #expect(recorded)
        bar.readAudioLevels = { (.level(0), .unavailable) }
        bar.refreshAudioLevels()
        #expect(try button("activity.warning").isHidden)
        #expect(system.contentTintColor == .systemOrange)
        #expect(system.toolTip == "Сигнал звука системы недоступен")
        recorded = false
        try click("activity.system-access")
        #expect(recorded)
        bar.updateRecording(.paused, elapsed: "12:34")
        #expect(try button("activity.recording").title == "12:34")
        #expect(try button("activity.warning").isHidden)
        bar.updateRecording(.idle, elapsed: nil)
        #expect(try !button("activity.recording").isEnabled)
        bar.updateAccess(.init(microphone: .granted, systemAudio: .heard, calendar: .denied))
        try click("activity.calendar-access")
        #expect(destination == .calendar)
        bar.updateAttention([], detail: "Configuration unreadable")
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
        bar.updateAttention([.init(dir: Home.current.url, title: "Встреча", problems: ["Сбой расшифровки"])], detail: nil)
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
