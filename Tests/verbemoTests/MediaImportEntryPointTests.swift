import AppKit
import Testing
import UniformTypeIdentifiers
@testable import verbemo

@Suite("Media import entry points")
@MainActor
struct MediaImportEntryPointTests {
    @Test("The application File menu imports several audio or video files with Command-I")
    func applicationMenuOffersImport() throws {
        let delegate = AppDelegate()
        var calls = 0
        delegate.onImport = { calls += 1 }

        let main = Run.mainMenu(settingsTarget: delegate)
        let file = try #require(main.items.compactMap(\.submenu).first { $0.title == "File" })
        let item = try #require(file.items.first { $0.title == "Import…" })

        #expect(item.keyEquivalent == "i")
        #expect(item.keyEquivalentModifierMask.contains(.command))
        let action = try #require(item.action)
        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
        #expect(calls == 1)
        withExtendedLifetime(delegate) {}
    }

    @Test("The menu-bar menu routes Import through its callback")
    func menuBarOffersImport() {
        let menuBar = MenuBarController(visible: false)
        var calls = 0
        menuBar.onImport = { calls += 1 }

        #expect(menuBar.offeredItemTitles.contains("Import…"))
        #expect(menuBar.performOfferedItem(titled: "Import…"))
        #expect(calls == 1)
        withExtendedLifetime(menuBar) {}
    }

    @Test("The import picker accepts multiple audio and video files, but not folders")
    func pickerConfiguration() {
        let panel = NSOpenPanel()
        MediaImportPicker.configure(panel)

        #expect(panel.allowsMultipleSelection)
        #expect(panel.canChooseFiles)
        #expect(!panel.canChooseDirectories)
        #expect(panel.allowedContentTypes.contains(.audio))
        #expect(panel.allowedContentTypes.contains(.movie))
    }
}
