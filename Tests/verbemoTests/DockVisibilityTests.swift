import AppKit
import Testing

@testable import verbemo

@Suite("Dock visibility follows the workspace", .serialized)
@MainActor
struct DockVisibilityTests {
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

        window.panel.performClose(nil)
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

        window.panel.performClose(nil)
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
}
