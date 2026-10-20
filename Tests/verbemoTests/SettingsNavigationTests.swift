import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct SettingsNavigationTests {
    @Test(.freshHome) func schemaHasExactlyOneEditorAndPagesAreSeparate() throws {
        let host = NSWindow()
        let settings = SettingsWindow(hostWindow: host)
        let represented = settings.representedSettingsPaths
        let schema = SettingsSchema.sections.flatMap(\.entries).map { $0.path.joined(separator: ".") }
        #expect(Set(represented) == Set(schema))
        #expect(represented.count == Set(represented).count)
        let general = settings.content(for: .general)
        let transcription = settings.content(for: .transcription)
        #expect(general !== transcription)
        #expect(general.allDescendants.contains { $0.identifier?.rawValue == "interface_theme" })
        #expect(!transcription.allDescendants.contains { $0.identifier?.rawValue == "interface_theme" })
        #expect(transcription.allDescendants.contains { $0.identifier?.rawValue == "transcription.local-diarization" })
        #expect(!general.allDescendants.contains { $0 is NSTabView })
    }
}

@Suite(.serialized) @MainActor
struct AppearanceTests {
    @Test(.freshHome) func persistedThemeDoesNotChangeSystemOrRebuildViews() {
        let window = NSWindow()
        let field = NSTextField(string: "unsaved input")
        window.contentView = field
        let controller = AppearanceController(window: window)
        #expect(controller.theme == .system)
        #expect(window.appearance == nil)
        Config.update(path: ["interface_theme"], value: "dark")
        #expect(controller.theme == .dark)
        #expect(window.appearance?.name == .darkAqua)
        #expect(window.contentView === field)
        #expect(field.stringValue == "unsaved input")
        Config.update(path: ["interface_theme"], value: "light")
        #expect(window.appearance?.name == .aqua)
        Config.update(path: ["interface_theme"], value: nil)
        #expect(window.appearance == nil)
        Config.update(path: ["interface_theme"], value: "sepia")
        #expect(Config.problems().contains { if case .unusable(key: "interface_theme", found: _, expected: _) = $0 { return true }; return false })
        withExtendedLifetime(controller) {}
    }
}
