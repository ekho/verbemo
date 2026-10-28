import AppKit
import Testing
@testable import verbemo

@MainActor
struct MenuBarTests {
    @Test(.speaking(.english), arguments: [false, true])
    func backgroundIconFollowsWorkAndPreservesRecordingPriority(cancel: Bool) async throws {
        let tray = MenuBarController()
        defer { tray.setVisible(false) }
        let operations = ProcessingOperations()
        let entered = Gate(), release = Gate()
        defer { release.open() }
        func expectIcon(_ color: NSColor?, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let image = try #require(tray.statusItemImage, sourceLocation: sourceLocation)
            #expect(image.isTemplate == (color == nil), sourceLocation: sourceLocation)
            #expect(image.tiffRepresentation == WaveIcon.image(size: 16, color: color)?.tiffRepresentation,
                sourceLocation: sourceLocation)
        }
        try expectIcon(nil)
        let ticket = try operations.register(session: URL(fileURLWithPath: "/synthetic/meeting"), kind: .transcription)
        tray.updateActivity(operations.snapshot())
        try expectIcon(nil)
        let task = Task { try await ticket.run { entered.open(); await release.pass() } }
        await entered.pass()
        tray.updateActivity(operations.snapshot())
        try expectIcon(.systemBlue)
        #expect(tray.statusItemTitle.isEmpty)
        #expect(tray.offeredItemTitles.contains("Start recording"))

        for (state, color) in [(MenuBarController.State.recording, NSColor.systemRed), (.paused, .systemOrange)] {
            tray.update(state: state, elapsed: "1:23")
            tray.updateActivity(operations.snapshot())
            try expectIcon(color)
            #expect(tray.statusItemTitle.contains("1:23"))
            tray.updateActivity([])
            try expectIcon(color)
        }
        tray.updateActivity(operations.snapshot())
        tray.update(state: .idle, elapsed: nil)
        try expectIcon(.systemBlue)
        tray.setVisible(false)
        tray.updateActivity(operations.snapshot())
        tray.setVisible(true)
        try expectIcon(.systemBlue)

        if cancel {
            operations.cancel(ticket.id)
            tray.updateActivity(operations.snapshot())
            try expectIcon(.systemBlue)
        }
        release.open()
        try await task.value
        tray.updateActivity(operations.snapshot())
        try expectIcon(nil)
        #expect(tray.statusItemTitle.isEmpty)
    }

    @Test(.speaking(.russian)) func idleMenuOffersOnlyUsefulActionsInApprovedOrder() throws {
        let tray = MenuBarController(visible: false)
        tray.setupAvailable(false)
        #expect(tray.offeredItemTitles == [
            "Открыть Verbemo", "", "Автозапись встреч", "Начать запись", "Импортировать запись…", "",
            "Настройки…", "", "Выйти",
        ])
        var pauses = 0
        tray.onTogglePause = { pauses += 1 }
        #expect(!tray.performOfferedItem(titled: "Пауза"))
        #expect(pauses == 0)
        #expect(try #require(tray.menu.items.first { $0.title == "Начать запись" }).view != nil)
    }

    @Test(.speaking(.english)) func recordingControlsFollowStateWithoutLosingActions() throws {
        let tray = MenuBarController(visible: false)
        var toggles = 0, pauses = 0
        tray.onToggle = { toggles += 1 }
        tray.onTogglePause = { pauses += 1 }
        #expect(try pressInline("start", in: tray))
        tray.update(state: .recording, elapsed: "12:34")
        #expect(!(try pressInline("start", in: tray)))
        #expect(try pressInline("pause", in: tray))
        tray.update(state: .paused, elapsed: "12:35")
        #expect(!tray.performOfferedItem(titled: "Pause"))
        #expect(try pressInline("pause", in: tray))
        #expect(try pressInline("stop", in: tray))
        #expect(toggles == 2)
        #expect(pauses == 2)
        tray.update(state: .idle, elapsed: nil)
        #expect(!(try pressInline("stop", in: tray)))
    }

    @Test(.speaking(.english)) func shortcutsStayAvailableInsideTheRecordingBlock() throws {
        let tray = MenuBarController(visible: false)
        var toggles = 0, pauses = 0
        tray.onToggle = { toggles += 1 }
        tray.onTogglePause = { pauses += 1 }
        func press(_ key: String) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            return tray.menu.performKeyEquivalent(with: event)
        }
        #expect(try press("r"))
        #expect(!(try press("p")))
        tray.update(state: .recording, elapsed: "1:23")
        #expect(try press("p"))
        #expect(try press("r"))
        tray.update(state: .paused, elapsed: "1:24")
        #expect(try press("p"))
        #expect(toggles == 2)
        #expect(pauses == 2)
        let controls = tray.menu.items.filter { !$0.isHidden && ["Resume", "Finish recording"].contains($0.title) }
        #expect(controls.isEmpty)
        #expect(try pressInline("stop", in: tray))
        #expect(toggles == 3)
    }

    private func pressInline(_ action: String, in tray: MenuBarController) throws -> Bool {
        let row = try #require(tray.menu.items.compactMap(\.view).first)
        let button = try #require(row.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "tray.recording.\(action)" })
        guard !button.isHiddenOrHasHiddenAncestor, button.isEnabled else { return false }
        return NSApp.sendAction(try #require(button.action), to: button.target, from: button)
    }

    @Test(.speaking(.english)) func recordingRowChangesStateAndOpensTheRecordingWithoutTogglingIt() throws {
        let tray = MenuBarController(visible: false)
        let item = try #require(tray.menu.items.first { $0.view != nil })
        let row = try #require(item.view)
        var opened = 0, toggles = 0
        tray.onShowRecording = { opened += 1 }
        tray.onToggle = { toggles += 1 }
        for (state, title, pauseLabel) in [
            (MenuBarController.State.recording, "● Recording · 12:34", "Pause recording"),
            (.paused, "Ⅱ Recording paused · 12:34", "Resume recording"),
        ] {
            tray.update(state: state, elapsed: "12:34")
            #expect(item.view === row && item.isEnabled)
            #expect(item.title == title)
            let pause = try #require(row.allDescendants.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "tray.recording.pause" })
            #expect(pause.accessibilityLabel() == pauseLabel)
            #expect(try pressInline("open", in: tray))
            #expect(tray.performOfferedItem(titled: title))
            #expect(!tray.offeredItemTitles.contains("Finish recording"))
        }
        #expect(opened == 4)
        #expect(toggles == 0)
        tray.update(state: .recording, elapsed: "12:35")
        #expect(item.title == "● Recording · 12:35")
        #expect(item.view === row)
        tray.update(state: .idle, elapsed: nil)
        #expect(try pressInline("open", in: tray))
        #expect(opened == 4 && toggles == 1)
    }

    @Test(.freshHome) func recordingRowReturnsFromSettingsToTheCurrentRecording() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        app.update(state: .paused, elapsed: "12:34")
        app.recordingTitle = "Current recording"
        app.navigate(.summary)
        app.hide()
        let tray = MenuBarController(visible: false)
        tray.update(state: .paused, elapsed: "12:34")
        tray.onShowRecording = { app.showActiveRecording(); app.bringToFront() }
        #expect(try pressInline("open", in: tray))
        #expect(app.navigation.destination == .allMeetings)
        #expect(app.navigation.resultTab == "transcript")
        #expect(app.recordingTitle == "Current recording")
        #expect(app.recordingBarIsVisible && app.isVisible)
    }

    @Test func recordingControlsStayAtTheRightEdge() throws {
        let tray = MenuBarController(visible: false)
        tray.update(state: .recording, elapsed: "12:34")
        let row = try #require(tray.menu.items.compactMap(\.view).first)
        row.layoutSubtreeIfNeeded()
        let stop = try #require(row.allDescendants.first { $0.identifier?.rawValue == "tray.recording.stop" })
        let frame = row.convert(stop.bounds, from: stop)
        #expect(abs(row.bounds.maxX - frame.maxX - 12) < 1)
    }

    @Test(.speaking(.russian)) func onlyActionableNoticesCanOpenPermissions() {
        let tray = MenuBarController(visible: false)
        var opens = 0
        tray.onShowSetup = { opens += 1 }
        tray.updateAutoRecord(enabled: true, notice: .microphoneAccess)
        #expect(tray.performOfferedItem(titled: "Нужен доступ к микрофону…"))
        tray.updateAutoRecord(enabled: true, notice: .manualStop)
        #expect(!tray.performOfferedItem(titled: "Автозапись ждёт окончания текущего звонка"))
        tray.updateAutoRecord(enabled: false, notice: .microphoneAccess)
        #expect(!tray.performOfferedItem(titled: "Нужен доступ к микрофону…"))
        tray.updateAutoRecord(enabled: true, notice: nil)
        #expect(!tray.offeredItemTitles.contains("готов"))
        #expect(opens == 1)
    }

    @Test(.freshHome) func autoRecordNoticesClearAfterRetryManualStopAndDisabling() {
        let h = AutoRecordHarness { $0.startDelay = 0; $0.calendar = false }
        h.controller.tick()
        #expect(h.controller.notice == nil)
        h.micActive = true
        h.refuseStarts = true
        h.controller.tick()
        #expect(h.controller.notice == .retry(30))
        h.now.addTimeInterval(5)
        h.controller.tick()
        #expect(h.controller.notice == .retry(25))
        h.refuseStarts = false
        h.now.addTimeInterval(25)
        h.controller.tick()
        #expect(h.session != nil)
        #expect(h.controller.notice == nil)
        h.session = nil
        h.controller.noteManualStop()
        h.controller.tick()
        #expect(h.controller.notice == .manualStop)
        h.micActive = false
        h.run(for: h.settings.stopDelay + 10)
        #expect(h.controller.notice == nil)
        h.controller.noteManualStop()
        h.controller.setEnabled(false)
        #expect(h.controller.notice == nil)
    }

    @Test(.freshHome) func missingMicrophoneAccessProducesAnActionableNotice() {
        let controller = AutoRecordController(settings: .init(), calendar: nil,
            loadSettings: { .init() }, canStartRecording: { false })
        controller.tick()
        #expect(controller.notice == .microphoneAccess)
    }

    @Test(.freshHome, .speaking(.english)) func relocatedActionsRemainAvailableInTheMainWindow() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        var folders = 0, updates = 0
        app.onOpenFolder = { folders += 1 }
        app.onCheckForUpdates = { updates += 1 }
        app.navigate(.storage)
        let folder = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.title == "Open folder" })
        #expect(NSApp.sendAction(try #require(folder.action), to: folder.target, from: folder))
        #expect(folders == 1)
        app.navigate(.about)
        let check = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "about.checkUpdates" })
        #expect(check.isHidden)
        app.updatesAvailable = true
        #expect(!check.isHidden)
        #expect(NSApp.sendAction(try #require(check.action), to: check.target, from: check))
        #expect(updates == 1)
    }

    @Test(.freshHome, .speaking(.english)) func revealingAMeetingStillClearsAnActiveFilter() async throws {
        let root = Home.current.url.appendingPathComponent("recordings")
        let target = root.appendingPathComponent("a-target")
        let other = root.appendingPathComponent("z-other")
        for dir in [target, other] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{\"title\":\"\(dir.lastPathComponent)\"}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.attention)
        #expect(await library.reveal(target))
        #expect(library.contentView.allDescendants.compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "a-target" })
        #expect(!(await library.reveal(root.appendingPathComponent("missing"))))
    }
}
