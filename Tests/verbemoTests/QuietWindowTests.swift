import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct QuietWindowTests {
    @Test func orderedWindowsKeepTheirLifecycleWithoutCoveringTheDesktop() {
        _ = NSApplication.shared
        let left = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let window = NSWindow(contentRect: NSRect(x: left - 200, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        #expect(window.isVisible)
        let visible = ProcessInfo.processInfo.environment["VERBEMO_TEST_WINDOWS"] == "1"
            || ProcessInfo.processInfo.environment["VERBEMO_CALENDAR_ACCEPTANCE"] != nil
        #expect(window.alphaValue == (visible ? 1 : 0))
        #expect(window.ignoresMouseEvents == !visible)
        window.orderOut(nil)
        #expect(!window.isVisible)
    }

    @Test(.freshHome, .enabled(if: ProcessInfo.processInfo.environment["VERBEMO_TEST_WINDOWS"] != "1"
                              && ProcessInfo.processInfo.environment["VERBEMO_CALENDAR_ACCEPTANCE"] == nil))
    func openingWorkspaceDoesNotActivateTheTestProcess() async throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination(); app.hide() }
        app.bringToFront()
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.isVisible)
        #expect(app.panel.alphaValue == 0)
        #expect(!NSRunningApplication.current.isActive)
    }
}
