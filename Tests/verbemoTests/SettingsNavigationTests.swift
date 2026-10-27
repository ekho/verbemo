import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct SettingsNavigationTests {
    @Test(.freshHome(config: #"{"user_email":["test@example.invalid"]}"#), .speaking(.russian))
    func settingsPagesPreserveWindowWidth() throws {
        let store = CalendarFixtureStore()
        _ = store.addCalendar("Рабочие встречи")
        let app = ApplicationWindow(calendar: CalendarWatcher(store: store, authorizationStatus: { .fullAccess }))
        defer { _ = app.stopForTermination(); app.hide() }
        app.show()
        for width: CGFloat in [1340, 2000, 760, 1340] {
            app.panel.setContentSize(NSSize(width: width, height: 820))
            for destination in ApplicationNavigationState.Destination.allCases {
                app.navigate(destination)
                app.panel.contentView?.layoutSubtreeIfNeeded()
                app.panel.layoutIfNeeded()
                #expect(abs(app.panel.contentLayoutRect.width - width) < 2,
                        "\(destination.rawValue) must preserve the requested width \(width)")
                if destination == .calendar {
                    let input = try #require(app.panel.contentView?.allDescendants.first {
                        $0.identifier?.rawValue == "user_email.input"
                    })
                    #expect(input.frame.width >= 260, "The email input must remain usable after resizing")
                }
            }
        }
    }

    @Test(.freshHome, .enabled(if: Platform.supportsLocalModels))
    func switchingTabsDoesNotRepeatMachineChecksOrRebuildHiddenModels() throws {
        let app = ApplicationWindow()
        defer { app.settings.setup.stop(); app.hide() }
        app.navigate(.storage)
        app.show()
        let storage = app.settings.content(for: .storage)
        let model = try #require(storage.allDescendants.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Whisper large-v3-turbo" })
        var machineChecks = 0
        app.settings.setup.loginItemStatus = { machineChecks += 1; return .notRegistered }
        for destination in [ApplicationNavigationState.Destination.general, .recording,
                            .transcription, .summary, .calendar] {
            app.navigate(destination)
            app.panel.contentView?.layoutSubtreeIfNeeded()
        }
        #expect(machineChecks == 0)
        #expect(storage.allDescendants.contains { $0 === model })
    }

    @Test(.freshHome)
    func returningToSettingsAndReopeningTheWindowRefreshMachineState() {
        let app = ApplicationWindow()
        defer { app.settings.setup.stop(); app.hide() }
        app.navigate(.general)
        app.show()
        var machineChecks = 0
        app.settings.setup.loginItemStatus = { machineChecks += 1; return .enabled }
        app.navigate(.allMeetings)
        Config.update(path: ["summary", "ollama_model"], value: "fixture-model")
        machineChecks = 0
        app.navigate(.summary)
        #expect(machineChecks == 1)
        app.hide()
        machineChecks = 0
        app.navigate(.summary)
        #expect(machineChecks == 0)
        app.show()
        #expect(machineChecks == 1)
        machineChecks = 0
        app.show()
        #expect(machineChecks == 0)
        app.hide()
        app.show()
        #expect(machineChecks == 1)
    }

    @Test(.freshHome, .enabled(if: Platform.supportsLocalModels))
    func openingStorageOffersDownloadAfterExternalModelRemoval() throws {
        let store = NemotronModelStore()
        let variant = store.variantDirectory(language: "auto")
        try NemotronFixtures.install(at: variant)
        let app = ApplicationWindow()
        defer { app.settings.setup.stop(); app.hide() }
        app.navigate(.storage)
        app.show()
        let model = try #require(ModelStorage().all().first { $0.kind == .nemotron })
        let controls = app.settings.setup.modelFilesControl(for: model)
        #expect(controls.button.isHidden)
        app.navigate(.general)
        try FileManager.default.removeItem(at: variant)
        app.navigate(.storage)
        #expect(!controls.button.isHidden)
        #expect(controls.button.isEnabled)
        #expect(controls.button.window === app.panel)
    }

    @Test(.freshHome, arguments: ["ollama_model", "ollama_base_url"])
    func returningToSummaryRechecksChangedOllamaSettingsOnce(key: String) {
        let app = ApplicationWindow()
        defer { app.settings.setup.stop(); app.hide() }
        app.navigate(.summary)
        app.show()
        Config.update(path: ["summary", key], value: key == "ollama_model"
            ? "fixture-model" : "http://127.0.0.1:11435")
        app.navigate(.general)
        var machineChecks = 0
        app.settings.setup.loginItemStatus = { machineChecks += 1; return .enabled }
        app.navigate(.summary)
        #expect(machineChecks == 1)
        app.navigate(.general)
        machineChecks = 0
        app.navigate(.summary)
        #expect(machineChecks == 0)
        app.hide()
        Config.update(path: ["summary", key], value: nil)
        machineChecks = 0
        app.navigate(.summary)
        #expect(machineChecks == 0)
        app.show()
        #expect(machineChecks == 1)
    }

    @Test(.freshHome, .enabled(if: Platform.supportsLocalModels))
    func openingStorageDiscoversFilesAddedWhileOnAnotherTab() throws {
        let app = ApplicationWindow()
        defer { app.settings.setup.stop(); app.hide() }
        app.navigate(.storage)
        app.navigate(.general)
        let store = WhisperModelStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: store.modelURL)
        app.navigate(.storage)
        let storage = app.settings.content(for: .storage)
        let name = try #require(storage.allDescendants.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Whisper large-v3-turbo" })
        let action = try #require(name.superview?.subviews.compactMap { $0 as? NSButton }.first)
        #expect(action.title == localised("Delete", "Удалить"))
    }

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
