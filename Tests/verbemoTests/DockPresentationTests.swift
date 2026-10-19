import AppKit
import Testing

@testable import verbemo

@Suite("Dock recording status", .serialized)
@MainActor
struct DockPresentationTests {
    @Test("Recording uses the badge without replacing the application icon")
    func recordingKeepsApplicationIcon() {
        let application = NSApplication.shared
        let previousIcon = application.applicationIconImage
        let previousBadge = application.dockTile.badgeLabel
        defer {
            application.applicationIconImage = previousIcon
            application.dockTile.badgeLabel = previousBadge
        }

        let installedIcon = NSImage(size: NSSize(width: 64, height: 64))
        application.applicationIconImage = installedIcon
        let iconBeforeUpdate = application.applicationIconImage?.tiffRepresentation

        DockPresentation.update(
            state: .recording, elapsed: "1:23", application: application)

        #expect(application.applicationIconImage?.tiffRepresentation == iconBeforeUpdate)
        #expect(application.dockTile.badgeLabel == "1:23")
    }

    @Test("Idle clears the badge without replacing the application icon")
    func idleKeepsApplicationIcon() {
        let application = NSApplication.shared
        let previousIcon = application.applicationIconImage
        let previousBadge = application.dockTile.badgeLabel
        defer {
            application.applicationIconImage = previousIcon
            application.dockTile.badgeLabel = previousBadge
        }

        let installedIcon = NSImage(size: NSSize(width: 64, height: 64))
        application.applicationIconImage = installedIcon
        application.dockTile.badgeLabel = "9:59"
        let iconBeforeUpdate = application.applicationIconImage?.tiffRepresentation

        DockPresentation.update(
            state: .idle, elapsed: nil, application: application)

        #expect(application.applicationIconImage?.tiffRepresentation == iconBeforeUpdate)
        #expect(application.dockTile.badgeLabel == nil)
    }
}
