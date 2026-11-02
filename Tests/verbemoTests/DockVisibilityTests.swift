import AppKit
import Testing

@testable import verbemo

@Suite("Dock visibility follows the workspace", .serialized)
@MainActor
struct DockVisibilityTests {
    @Test(.freshHome, arguments: [(false, true), (true, true), (true, false)])
    func closeQuitsWithoutMenuBarAndOtherwiseHides(menuBar: Bool, dock: Bool) throws {
        try Home.current.writeConfig(["menu_bar_icon": menuBar, "dock_icon": dock])
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        let window = ApplicationWindow()
        var quitRequests = 0
        window.onQuit = { quitRequests += 1 }
        defer {
            window.hide()
            application.setActivationPolicy(previousPolicy)
        }

        window.bringToFront()
        // Simulated system-button clicks can exit SwiftPM's async test host.
        #expect(!window.windowShouldClose(window.panel))

        #expect(quitRequests == (menuBar ? 0 : 1))
        #expect(window.isVisible == !menuBar, "A cancelled quit must leave the window open")
        #expect(!window.panel.isMiniaturized)
        #expect(application.activationPolicy() == (dock || !menuBar ? .regular : .accessory))

        window.bringToFront()
        #expect(window.isVisible)
        #expect(application.activationPolicy() == .regular)

        Config.update(path: ["menu_bar_icon"], value: !menuBar)
        #expect(!window.windowShouldClose(window.panel))
        #expect(quitRequests == 1)
        #expect(window.isVisible == menuBar)
    }

    @Test(.freshHome, arguments: [(true, false), (false, true), (true, true)])
    func yellowButtonMinimizesToDockOrHidesToMenuBar(menuBar: Bool, dock: Bool) async throws {
        try Home.current.writeConfig(["menu_bar_icon": menuBar, "dock_icon": dock])
        let application = NSApplication.shared
        let previous = application.activationPolicy()
        let window = ApplicationWindow()
        defer {
            window.hide()
            application.setActivationPolicy(previous)
        }
        window.bringToFront()
        let button = try #require(window.panel.standardWindowButton(.miniaturizeButton))
        try #require(button.target === window)
        #expect(button.sendAction(button.action, to: button.target))
        for _ in 0..<100 where dock && !window.panel.isMiniaturized {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!window.isVisible)
        #expect(window.panel.isMiniaturized == dock)
        #expect(application.activationPolicy() == (dock ? .regular : .accessory))

        window.bringToFront()
        #expect(window.isVisible)
        #expect(!window.panel.isMiniaturized)
        #expect(application.activationPolicy() == .regular)
    }

    @Test(.freshHome(config: #"{"dock_icon": false}"#))
    func openingWorkspaceRestoresDockAndApplicationMenu() {
        let application = NSApplication.shared
        let previous = application.activationPolicy()
        let window = ApplicationWindow()
        defer {
            window.hide()
            application.setActivationPolicy(previous)
        }
        application.setActivationPolicy(.accessory)

        window.show()
        #expect(window.isVisible)
        #expect(application.activationPolicy() == .regular)

        window.hide()
        #expect(application.activationPolicy() == .accessory)

        window.bringToFront()
        #expect(window.isVisible)
        #expect(application.activationPolicy() == .regular)

        #expect(!window.windowShouldClose(window.panel))
        #expect(!window.isVisible)
        #expect(application.activationPolicy() == .accessory)
    }

    @Test(.freshHome, arguments: [false, true])
    func minimizingAndRestoringHonorsDockPreference(keepIcon: Bool) async throws {
        try Home.current.writeConfig(["dock_icon": keepIcon])
        let application = NSApplication.shared
        let previous = application.activationPolicy()
        let window = ApplicationWindow()
        defer {
            window.hide()
            application.setActivationPolicy(previous)
        }
        window.bringToFront()
        window.panel.miniaturize(nil)
        for _ in 0..<100 {
            if window.panel.isMiniaturized { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(window.panel.isMiniaturized)
        #expect(!window.isVisible)
        #expect(application.activationPolicy() == (keepIcon ? .regular : .accessory))

        window.panel.deminiaturize(nil)
        for _ in 0..<100 {
            if !window.panel.isMiniaturized { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.isVisible)
        #expect(application.activationPolicy() == .regular)

        window.panel.miniaturize(nil)
        for _ in 0..<100 {
            if window.panel.isMiniaturized { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(window.panel.isMiniaturized)
        window.bringToFront()
        #expect(!window.panel.isMiniaturized)
        #expect(window.isVisible)
        #expect(application.activationPolicy() == .regular)

        #expect(!window.windowShouldClose(window.panel))
        #expect(application.activationPolicy() == (keepIcon ? .regular : .accessory))
    }

    @Test(.freshHome)
    func changingPreferenceKeepsOpenWindowInDock() {
        let application = NSApplication.shared
        let previous = application.activationPolicy()
        let window = ApplicationWindow()
        defer {
            window.hide()
            application.setActivationPolicy(previous)
        }
        window.bringToFront()
        Config.update(path: ["dock_icon"], value: false)
        window.applyDockPreference()
        #expect(window.isVisible)
        #expect(application.activationPolicy() == .regular)

        window.hide()
        #expect(application.activationPolicy() == .accessory)
        Config.update(path: ["dock_icon"], value: true)
        window.applyDockPreference()
        #expect(!window.isVisible)
        #expect(application.activationPolicy() == .regular)
    }

    @Test(.freshHome, arguments: [false, true])
    func dockClickMinimizesWithDockIconAndCloseHidesToTray(keepIcon: Bool) async throws {
        try Home.current.writeConfig([
            "dock_icon": keepIcon, "menu_bar_icon": true, "auto_record": ["enabled": false],
        ])
        let application = NSApplication.shared
        let previous = application.activationPolicy()
        let existing = Set(application.windows.map(ObjectIdentifier.init))
        let controller = AppController(root: Home.current.defaultRecordings, operations: ProcessingOperations(),
            calendar: CalendarWatcher(store: CalendarFixtureStore(), authorizationStatus: { .denied }))
        defer {
            for panel in application.windows where !existing.contains(ObjectIdentifier(panel)) { panel.orderOut(nil) }
            application.setActivationPolicy(previous)
        }
        controller.toggleWindow(alreadyActive: false)
        let panel = try #require(application.windows.first { $0 is WorkspaceWindow && !existing.contains(ObjectIdentifier($0)) })
        #expect(panel.isVisible)
        controller.toggleWindow(alreadyActive: true)
        for _ in 0..<100 where keepIcon && !panel.isMiniaturized {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.isMiniaturized == keepIcon)
        #expect(application.activationPolicy() == (keepIcon ? .regular : .accessory))

        controller.toggleWindow(alreadyActive: true)
        #expect(panel.isVisible && !panel.isMiniaturized)
        controller.toggleWindow(alreadyActive: false)
        #expect(panel.isVisible && !panel.isMiniaturized, "Switching to Verbemo must keep its window open")
        #expect(panel.delegate?.windowShouldClose?(panel) == false)
        #expect(!panel.isVisible && !panel.isMiniaturized)
        controller.toggleWindow(alreadyActive: true)
        #expect(panel.isVisible && !panel.isMiniaturized)

        let finished = Gate()
        #expect(controller.prepareForTermination { finished.open() })
        await finished.pass()
    }
}
