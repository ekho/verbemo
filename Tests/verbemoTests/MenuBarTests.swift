import AppKit
import Testing
@testable import verbemo

@MainActor
struct MenuBarTests {
    @Test(.speaking(.russian)) func idleMenuOffersOnlyUsefulActionsInApprovedOrder() {
        let tray = MenuBarController(visible: false)
        tray.setupAvailable(false)
        #expect(tray.offeredItemTitles == [
            "Начать запись", "Импортировать запись…", "Автозапись встреч", "",
            "Настройки…", "Открыть Verbemo", "", "Выйти из Verbemo",
        ])
        var pauses = 0
        tray.onTogglePause = { pauses += 1 }
        #expect(!tray.performOfferedItem(titled: "Пауза"))
        #expect(pauses == 0)
    }

    @Test(.speaking(.english)) func recordingControlsFollowStateWithoutLosingActions() {
        let tray = MenuBarController(visible: false)
        var toggles = 0, pauses = 0
        tray.onToggle = { toggles += 1 }
        tray.onTogglePause = { pauses += 1 }
        #expect(tray.performOfferedItem(titled: "Start recording"))
        tray.update(state: .recording, elapsed: "12:34")
        #expect(!tray.performOfferedItem(titled: "Start recording"))
        #expect(tray.performOfferedItem(titled: "Pause"))
        tray.update(state: .paused, elapsed: "12:35")
        #expect(!tray.performOfferedItem(titled: "Pause"))
        #expect(tray.performOfferedItem(titled: "Resume"))
        #expect(tray.performOfferedItem(titled: "Finish recording"))
        #expect(toggles == 2)
        #expect(pauses == 2)
        tray.update(state: .idle, elapsed: nil)
        #expect(!tray.performOfferedItem(titled: "Finish recording"))
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
        #expect(controls.map(\.title) == ["Resume", "Finish recording"])
        #expect(controls.allSatisfy { $0.view == nil && $0.isEnabled })
        let finish = try #require(controls.last)
        #expect(NSApp.sendAction(try #require(finish.action), to: finish.target, from: finish))
        #expect(toggles == 3)
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

    @Test(.freshHome, .speaking(.english)) func processingLinkRevealsItsMeetingDespiteAnActiveFilter() async throws {
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
        let tray = MenuBarController(visible: false)
        let status = TranscriptionCoordinator.Status.failed(session: target)
        tray.updateTranscription(AppController.transcriptionLine(for: status))
        var opened: Task<Bool, Never>?
        tray.onShowTranscription = { opened = Task { await library.reveal(target) } }
        #expect(tray.performOfferedItem(titled: "Could not transcribe: a-target…"))
        #expect(await opened?.value == true)
        #expect(library.contentView.allDescendants.compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "a-target" })
        #expect(!(await library.reveal(root.appendingPathComponent("missing"))))
    }
}
