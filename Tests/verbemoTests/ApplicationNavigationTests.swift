import Foundation
import AppKit
import Testing
@testable import verbemo

struct ApplicationNavigationTests {
    @Test func settingsPreserveMeetingContextAndExplicitAllClearsSearch() {
        var state = ApplicationNavigationState()
        state.selectedSession = URL(fileURLWithPath: "/fixture/meeting")
        state.versionKey = "v1"
        state.resultTab = "transcript"
        state.query = "Анна"
        state.navigate(.transcription)
        state.navigate(.allMeetings)
        #expect(state.selectedSession != nil)
        #expect(state.versionKey == "v1")
        #expect(state.resultTab == "transcript")
        #expect(state.query == "Анна")
        state.showAllMeetings()
        #expect(state.query.isEmpty)
        #expect(!state.showsDetail)
    }
}

@Suite(.serialized)
@MainActor
struct ApplicationWindowTests {
    @Test(.freshHome(config: #"{"calendar":false}"#), .speaking(.russian), arguments: [760, 1340])
    func primaryActionsStayAboveBothPanesWithLibraryShownOrHidden(width: Int) async throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: Home.current.url.appendingPathComponent("meetings"), hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(.init(width: width, height: 600))
        app.show()
        let root = try #require(app.panel.contentView)
        let split = try #require(root.allDescendants.first { $0.identifier?.rawValue == "workspace.library-split" } as? NSSplitView)
        let toggle = try #require(root.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "workspace.toggle-library" })
        for destination in [ApplicationNavigationState.Destination.allMeetings, .general, .mcp, .about] {
            app.navigate(destination)
            for collapsed in [false, true, false] {
                if split.arrangedSubviews[0].isHidden != collapsed {
                    #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
                }
                for _ in 0..<4 { root.layoutSubtreeIfNeeded(); await Task.yield() }
                let splitRect = split.convert(split.bounds, to: root)
                for id in ["journal.new-recording", "journal.import", "journal.settings"] {
                    let buttons = root.allDescendants.compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == id && !$0.isHiddenOrHasHiddenAncestor }
                    #expect(buttons.count == 1, "One visible command: \(id), \(destination), collapsed \(collapsed)")
                    let button = try #require(buttons.first)
                    let rect = button.convert(button.bounds, to: root)
                    #expect(rect.minY >= splitRect.maxY - 1, "\(id) belongs to the common header above both panes")
                    #expect(rect.minX >= 0 && rect.maxX <= root.bounds.maxX + 1)
                    #expect(button.bounds.width >= button.fittingSize.width - 1, "The action label must remain readable at width \(width)")
                }
            }
        }
    }

    @Test(.freshHome(config: #"{"calendar":false}"#))
    func headerCommandsKeepTheirActionsAndRecordingGuard() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        func command(_ id: String) throws -> NSButton {
            try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id && !$0.isHiddenOrHasHiddenAncestor })
        }
        func act(_ button: NSButton) throws {
            #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        }
        var imports = 0, recordings = 0
        app.onChooseImport = { imports += 1 }
        app.onStartRecording = { _, _ in recordings += 1 }
        try act(command("journal.import"))
        #expect(imports == 1)
        try act(command("journal.settings"))
        #expect(app.navigation.destination == .general)
        try act(command("journal.new-recording"))
        let sheet = try #require(app.recordingSheet)
        #expect(sheet.panel.sheetParent === app.panel)
        sheet.cancel()
        #expect(app.recordingSheet == nil && recordings == 0)
        app.update(state: .recording, elapsed: "00:01")
        #expect(try !command("journal.new-recording").isEnabled)
        app.update(state: .paused, elapsed: "00:01")
        #expect(try !command("journal.new-recording").isEnabled)
        app.update(state: .idle, elapsed: nil)
        #expect(try command("journal.new-recording").isEnabled)
    }

    @Test(.freshHome, .speaking(.russian)) func changingPagesKeepsNarrowWindowSize() async {
        let app = ApplicationWindow()
        defer { app.hide() }
        app.panel.setContentSize(NSSize(width: 760, height: 680))
        app.show()
        for page in [ApplicationNavigationState.Destination.general, .recording, .transcription, .summary, .calendar, .storage, .mcp, .about] {
            app.navigate(page)
            app.panel.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
            #expect(app.panel.contentLayoutRect.width <= 762, "\(page)")
        }
    }
    @Test(.freshHome) func workspaceFillsAvailableWidthAfterLayout() throws {
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let available = try #require(app.panel.contentView).bounds.width - JournalStyle.sidebarWidth
        #expect(library.contentView.bounds.width >= available - 2, "content=\(library.contentView.bounds.width), available=\(available)")
        let split = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.columns" })
        #expect(split.bounds.width >= available - 32)
        let heading = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "journal.breadcrumb" && !$0.isHiddenOrHasHiddenAncestor })
        #expect(heading.bounds.width >= heading.fittingSize.width)
    }
    @Test(.freshHome) func reopeningRefreshesMeetingsChangedWhileHidden() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSTableView }.first)
        app.hide()
        let meeting = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try Data("{\"title\":\"New meeting\"}".utf8).write(to: meeting.appendingPathComponent("meta.json"))
        library.sessionsChanged()
        app.show()
        await library.settled()
        #expect(table.numberOfRows == 1)
        app.hide()
        try FileManager.default.removeItem(at: meeting)
        library.sessionsChanged()
        app.bringToFront()
        await library.settled()
        #expect(table.numberOfRows == 0)
        app.hide()
    }
    @Test(.freshHome) func importProgressDoesNotChangePageOrRevealHiddenWindow() {
        let app = ApplicationWindow()
        app.navigate(.general)
        app.hide()
        app.updateImport(.init(source: URL(fileURLWithPath: "/fixture.wav"), index: 1, total: 1, stage: .normalizing, fraction: 0.5))
        #expect(app.navigation.destination == .general)
        #expect(!app.panel.isVisible)
    }
    @Test(.freshHome) func currentRecordingCanReturnThroughTheMainHeading() throws {
        let app = ApplicationWindow()
        app.update(state: .recording, elapsed: "01:00")
        app.showActiveRecording()
        let heading = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "journal.breadcrumb" })
        #expect(heading.isEnabled)
    }
    @Test(.freshHome, .speaking(.russian)) func trayDestinationsReuseTheMainWindow() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: Home.current.url, hostWindow: app.panel)
        app.libraryProvider = { library }
        let menu = MenuBarController(visible: false)
        menu.setupAvailable(false)
        menu.onShowMeetings = { app.navigate(.allMeetings); app.bringToFront() }
        menu.onShowSettings = { app.navigate(.general); app.bringToFront() }
        let before = Set(NSApp.windows.filter { $0.styleMask.contains(.titled) }.map(ObjectIdentifier.init))
        let commands: [(String, ApplicationNavigationState.Destination)] = [
            ("Открыть Verbemo", .allMeetings), ("Настройки…", .general),
        ]
        for (title, destination) in commands {
            app.hide()
            #expect(menu.performOfferedItem(titled: title))
            #expect(app.navigation.destination == destination)
            #expect(app.panel.isVisible)
            #expect(Set(NSApp.windows.filter { $0.styleMask.contains(.titled) }.map(ObjectIdentifier.init)) == before)
        }
        let setup = SetupPage()
        app.presentSetup(setup)
        #expect(setup.contentView.window === app.panel)
        #expect(Set(NSApp.windows.filter { $0.styleMask.contains(.titled) }.map(ObjectIdentifier.init)) == before)
        #expect(menu.offeredItemTitles.filter { $0 == "Открыть Verbemo" }.count == 1)
        #expect(!menu.offeredItemTitles.contains("Управление записями…"))
        #expect(!menu.offeredItemTitles.contains("Показать окно verbemo"))
        for title in ["Начать запись", "Импортировать запись…", "Автозапись встреч"] {
            #expect(menu.offeredItemTitles.contains(title))
        }
    }

    @Test(.freshHome) func destinationsShareOneWindowAndKeepGlobalActions() {
        let app = ApplicationWindow()
        let panel = app.panel
        for destination in ApplicationNavigationState.Destination.allCases {
            app.navigate(destination)
            #expect(app.panel === panel)
            #expect(!app.toolbarIsHidden)
            #expect(app.primaryActionsAreVisible)
        }
        app.update(state: .recording, elapsed: "04:32")
        app.navigate(.general)
        #expect(app.recordingBarIsVisible)
        app.update(state: .idle, elapsed: nil)
        #expect(!app.recordingBarIsVisible)
    }
}
