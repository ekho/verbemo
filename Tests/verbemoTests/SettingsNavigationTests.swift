import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct SettingsNavigationTests {
    @Test(.freshHome, .speaking(.russian))
    func settingsSelectorNavigatesAtBothWindowWidths() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        app.navigate(.general)
        app.panel.setContentSize(NSSize(width: 1340, height: 820))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let views = try #require(app.panel.contentView).allDescendants
        let tabs = try #require(views.first { $0.identifier?.rawValue == "settings.tabs" } as? NSStackView)
        let compact = try #require(views.first { $0.identifier?.rawValue == "settings.sections" } as? NSPopUpButton)
        #expect(!tabs.isHiddenOrHasHiddenAncestor)
        #expect(compact.isHiddenOrHasHiddenAncestor)
        let tabButtons = tabs.arrangedSubviews.compactMap { $0 as? NSButton }
        #expect(tabButtons.count == 6)
        #expect(tabButtons.allSatisfy { $0.image != nil && !$0.isBordered })
        #expect(tabButtons[0].state == .on)
        let transcription = tabButtons[2]
        _ = NSApplication.shared.sendAction(try #require(transcription.action), to: transcription.target, from: transcription)
        #expect(app.navigation.destination == .transcription)
        #expect(compact.indexOfSelectedItem == 2)

        app.panel.setContentSize(NSSize(width: 760, height: 680))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(app.panel.contentLayoutRect.width <= 762)
        #expect(tabs.isHiddenOrHasHiddenAncestor)
        #expect(!compact.isHiddenOrHasHiddenAncestor)
        compact.selectItem(at: 4)
        _ = NSApplication.shared.sendAction(try #require(compact.action), to: compact.target, from: compact)
        #expect(app.navigation.destination == .calendar)
        #expect(tabButtons[4].state == .on)
        #expect(tabButtons.filter { $0.state == .on }.count == 1)
        app.navigate(.general)
        let general = try #require(app.panel.contentView).allDescendants
        for path in ["interface_theme", "interface_language", "window"] {
            let control = try #require(general.first { $0.identifier?.rawValue == path })
            var parent = control.superview
            while parent != nil && !(parent is Box) { parent = parent?.superview }
            #expect(parent is Box)
        }
        let buttons = general.compactMap { ($0 as? NSButton)?.title }
        #expect(!buttons.contains("← К встречам"))
        #expect(!buttons.contains("Показать файл настроек"))
    }

    @Test(.freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet"}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func cloudConfigurationCanBeExpandedAndDismissedWithoutAKey() throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        defer { form.stop(); withExtendedLifetime(application) {} }
        application.navigate(.transcription)
        let page = try #require(application.panel.contentView)
        let cloud = try #require(page.allDescendants.first { $0.identifier?.rawValue == "transcription.cloud" } as? NSSwitch)
        let local = try #require(page.allDescendants.first { $0.identifier?.rawValue == "transcription.local" } as? NSSwitch)
        let provider = try #require(page.allDescendants.first { $0.identifier?.rawValue == "choice.assemblyai" })
        #expect(provider.isHiddenOrHasHiddenAncestor)
        cloud.state = .on
        _ = NSApplication.shared.sendAction(try #require(cloud.action), to: cloud.target, from: cloud)
        #expect(cloud.state == .on)
        #expect(!provider.isHiddenOrHasHiddenAncestor)
        #expect(Config.transcriptionEngine() == "parakeet", "opening the key editor must not enable cloud processing")
        local.state = .off
        _ = NSApplication.shared.sendAction(try #require(local.action), to: local.target, from: local)
        #expect(!Config.transcriptionEnabled(), "editing local mode while a key is pending must not enable cloud processing")
        cloud.state = .off
        _ = NSApplication.shared.sendAction(try #require(cloud.action), to: cloud.target, from: cloud)
        #expect(provider.isHiddenOrHasHiddenAncestor)
        #expect(cloud.state == .off)
    }

    @Test(.freshHome, .speaking(.russian), .enabled(if: Platform.supportsLocalModels))
    func transcriptionLanguageAndMoreOptionsHaveOneEditorAndDisclosure() throws {
        let application = ApplicationWindow()
        let settings = application.settings
        defer { withExtendedLifetime(application) {} }
        application.navigate(.transcription)
        let page = try #require(application.panel.contentView)
        let language = try #require(page.allDescendants.first { $0.identifier?.rawValue == "transcription.language" } as? NSPopUpButton)
        #expect(language.itemArray.contains { $0.representedObject as? String == "ru" })
        let options = try #require(page.allDescendants.first { $0.identifier?.rawValue == "options.transcription" } as? NSButton)
        let rare = try #require(page.allDescendants.first { $0.identifier?.rawValue == "transcription.diarization_threshold" })
        #expect(rare.isHiddenOrHasHiddenAncestor)
        let before = try? Data(contentsOf: Config.path)
        options.state = .on
        _ = NSApplication.shared.sendAction(try #require(options.action), to: options.target, from: options)
        #expect(!rare.isHiddenOrHasHiddenAncestor)
        options.state = .off
        _ = NSApplication.shared.sendAction(try #require(options.action), to: options.target, from: options)
        #expect(rare.isHiddenOrHasHiddenAncestor)
        #expect((try? Data(contentsOf: Config.path)) == before)
    }

    @Test(.freshHome) func schemaHasExactlyOneEditorAndPagesAreSeparate() throws {
        let application = ApplicationWindow()
        let settings = application.settings
        defer { withExtendedLifetime(application) {} }
        let represented = settings.representedSettingsPaths
        let schema = SettingsSchema.sections.flatMap(\.entries).map { $0.path.joined(separator: ".") }
        #expect(Set(represented) == Set(schema))
        #expect(represented.count == Set(represented).count)
        application.navigate(.general)
        let general = settings.content(for: .general)
        application.navigate(.transcription)
        let transcription = settings.content(for: .transcription)
        #expect(general !== transcription)
        #expect(general.allDescendants.contains { $0.identifier?.rawValue == "interface_theme" })
        #expect(!transcription.allDescendants.contains { $0.identifier?.rawValue == "interface_theme" })
        #expect(transcription.allDescendants.contains { $0.identifier?.rawValue == "transcription.local-diarization" })
        #expect(!general.allDescendants.contains { $0 is NSTabView })
    }
    @Test(.freshHome) func summaryOffUsesOnlyTheSwitchAndLegacyNoneCanBeEnabledAgain() throws {
        Config.update(path: ["summary", "backend"], value: "none")
        let application = ApplicationWindow()
        let form = application.settings.setup
        defer { form.stop(); withExtendedLifetime(application) {} }
        application.navigate(.summary)
        let page = try #require(application.panel.contentView)
        let cards = page.allDescendants.compactMap { $0 as? ChoiceCard }
        #expect(Set(cards.map(\.id)) == ["auto", "claude-cli", "codex-cli", "api-key", "ollama"])
        let toggle = try #require(page.allDescendants.first { $0.identifier?.rawValue == "summary.enabled" } as? NSSwitch)
        #expect(toggle.state == .off)
        toggle.state = .on
        _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        #expect(Config.summary().backend == "auto")
        #expect(PostProcessor.Policy.configured.summary)
        #expect(cards.first { $0.id == "auto" }?.isSelected == true)
        #expect(cards.allSatisfy { $0.isEnabled })
    }
    @Test(.freshHome) func themeChangePreservesAnActiveSettingsEdit() throws {
        let application = ApplicationWindow()
        let settings = application.settings
        let host = application.panel
        application.navigate(.summary)
        defer { withExtendedLifetime(application) {} }
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
