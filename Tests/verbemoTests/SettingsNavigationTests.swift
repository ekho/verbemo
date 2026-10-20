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
    @Test(.freshHome) func everySummaryBackendHasAnHonestSelectionAndNoneCanBeEnabledAgain() throws {
        Config.update(path: ["summary", "backend"], value: "none")
        let form = SetupForm(forSettings: true)
        let page = try #require(form.settingsPages[.summary])
        let cards = page.allDescendants.compactMap { $0 as? ChoiceCard }
        #expect(cards.first { $0.id == "none" }?.isSelected == true)
        let toggle = try #require(page.allDescendants.first { $0.identifier?.rawValue == "summary.enabled" } as? NSSwitch)
        #expect(toggle.state == .off)
        toggle.state = .on
        _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        #expect(Config.summary().backend == "auto")
        #expect(PostProcessor.Policy.configured.summary)
    }
    @Test(.freshHome) func themeChangePreservesAnActiveSettingsEdit() throws {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let settings = SettingsWindow(hostWindow: host)
        host.contentView = settings.content(for: .summary)
        let field = try #require(settings.renderedControls.first { $0.identifier?.rawValue == "summary.template" } as? NSTextField)
        #expect(host.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "UNSAVED TEMPLATE"
        Config.update(path: ["interface_theme"], value: "dark")
        #expect(editor.string == "UNSAVED TEMPLATE")
        #expect(host.firstResponder === editor)
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
