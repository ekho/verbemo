import AppKit
import Foundation
import Testing
import os

@testable import verbemo

/// What the setup form does when it is used, rather than how it is laid out:
/// clicks that have to write something, work that has to survive the window
/// closing, and things it must refuse to do in the middle of a meeting.
@Suite(.serialized)
@MainActor
struct SetupFormBehaviourTests {
    @Test(.freshHome(config: #"{"transcription":{"engine":"parakeet"}}"#), .enabled(if: Platform.supportsLocalModels))
    func nemotronModesShareOneDownloadWithoutEnablingEachOther() async throws {
        let store = NemotronModelStore()
        let started = Gate(), finish = Gate(), installed = Gate()
        defer { finish.open() }
        let downloads = OSAllocatedUnfairLock(initialState: 0)
        let form = SetupForm(mode: .settings)
        defer { form.stop() }
        form.liveModelStore = NemotronModelStore(root: store.root) { language, root, progress in
            downloads.withLock { $0 += 1 }
            started.open(); progress(0.4); await finish.pass(); try Task.checkCancellation()
            let variant = NemotronModelStore(root: root).variantDirectory(language: language)
            defer { installed.open() }
            try NemotronFixtures.install(at: variant); return variant
        }
        let card = try #require(Self.view("choice.nemotron", in: form) as? ChoiceCard)
        card.onSelect?("nemotron")
        await started.pass()
        #expect(Config.transcriptionEngine() == "nemotron")
        #expect(!Config.liveTranscriptionEnabled())
        let live = try #require(Self.view("transcription.live", in: form) as? NSSwitch)
        live.state = .on
        _ = NSApp.sendAction(try #require(live.action), to: live.target, from: live)
        try await Task.sleep(for: .milliseconds(50))
        form.refresh()
        #expect(downloads.withLock { $0 } == 1)
        #expect(Config.transcriptionEngine() == "nemotron")
        #expect(form.hasModelDownloads)
        live.state = .off
        _ = NSApp.sendAction(try #require(live.action), to: live.target, from: live)
        finish.open()
        await installed.pass()
        for _ in 0..<100 where form.hasModelDownloads { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.isReady(language: "auto"))
        #expect(!Config.liveTranscriptionEnabled())
        #expect(Config.transcriptionEngine() == "nemotron")
        #expect(downloads.withLock { $0 } == 1)
        #expect(ModelStorage().all().filter { $0.kind == .nemotron }.count == 1)
        #expect(card.status.contains("downloaded") || card.status.contains("скачана"))
        // A later live enable consumes the same ready files without another request.
        live.state = .on
        _ = NSApp.sendAction(try #require(live.action), to: live.target, from: live)
        #expect(downloads.withLock { $0 } == 1)
        Config.update(path: ["live_transcription", "enabled"], value: false)
        Config.update(path: ["transcription", "enabled"], value: false)
        try await store.delete()
        form.refresh()
        #expect(!store.isReady(language: "auto"))
        #expect(!card.status.contains("downloaded") && !card.status.contains("скачана"))
    }

    @Test(.freshHome(config: #"{"transcription":{"engine":"parakeet","model":"v2","cloud":"openai"}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func transcriptionModesAreExclusiveAndRememberTheirSelections() throws {
        try Credentials.writeSecret("test-openai-key", to: Config.openAIKeyPath)
        let form = SetupForm(mode: .settings)
        defer { form.stop() }
        form.parakeetIsHere = { true }
        form.refresh()
        let cloud = try #require(Self.view("transcription.cloud", in: form) as? NSSwitch)
        let local = try #require(Self.view("transcription.local", in: form) as? NSSwitch)
        #expect(local.state == .on && cloud.state == .off)
        cloud.state = .on
        _ = NSApp.sendAction(try #require(cloud.action), to: cloud.target, from: cloud)
        #expect(cloud.state == .on && local.state == .off)
        #expect(Config.transcriptionEngine() == "openai")
        local.state = .on
        _ = NSApp.sendAction(try #require(local.action), to: local.target, from: local)
        #expect(local.state == .on && cloud.state == .off)
        #expect(Config.transcriptionEngine() == "parakeet")
        #expect(Config.transcriptionModel() == "v2")
        form.refresh()
        #expect(local.state == .on && cloud.state == .off)
        cloud.state = .on
        _ = NSApp.sendAction(try #require(cloud.action), to: cloud.target, from: cloud)
        #expect(cloud.state == .on && local.state == .off)
        #expect(Config.transcriptionEngine() == "openai")
        #expect(Config.openAIKey() == "test-openai-key")
        cloud.state = .off
        _ = NSApp.sendAction(try #require(cloud.action), to: cloud.target, from: cloud)
        #expect(cloud.state == .off && local.state == .off)
        #expect(!Config.transcriptionEnabled())
    }

    @Test(.freshHome(config: #"{"transcription":{"engine":"parakeet","cloud":"openai"}}"#),
          .enabled(if: Platform.supportsLocalModels), arguments: [false, true])
    func cloudKeyValidationCannotEnableBothModesOrUndoLocalSelection(selectLocal: Bool) async throws {
        let form = SetupForm(mode: .settings)
        defer { form.stop() }
        form.parakeetIsHere = { true }
        let cloud = try #require(Self.view("transcription.cloud", in: form) as? NSSwitch)
        let local = try #require(Self.view("transcription.local", in: form) as? NSSwitch)
        cloud.state = .on
        _ = NSApp.sendAction(try #require(cloud.action), to: cloud.target, from: cloud)
        #expect(cloud.state == .on && local.state == .off)
        #expect(!Config.transcriptionEnabled(), "Cloud processing waits for a validated key")
        let field = try #require(Self.view("transcription.key.openai", in: form) as? NSSecureTextField)
        field.stringValue = "test-openai-key"
        let started = Gate(), release = Gate()
        form.checkKey = { _ in started.open(); await release.pass(); return .works }
        let check = Task { await form.saveCloudKey(for: "openai") }
        await started.pass()
        if selectLocal {
            local.state = .on
            _ = NSApp.sendAction(try #require(local.action), to: local.target, from: local)
        }
        release.open()
        await check.value
        #expect(Config.transcriptionEnabled())
        #expect(Config.transcriptionEngine() == (selectLocal ? "parakeet" : "openai"))
        #expect(local.state == (selectLocal ? .on : .off))
        #expect(cloud.state == (selectLocal ? .off : .on))
        #expect(Config.openAIKey() == "test-openai-key")
    }

    @Test(.freshHome, .enabled(if: Platform.supportsLocalModels), arguments: [false, true])
    func legacyAutoDisplaysOnePrimaryModeWithoutRewritingSettings(hasKey: Bool) throws {
        if hasKey { try Credentials.writeSecret("test-key", to: Config.assemblyAIKeyPath) }
        let before = Home.current.configText
        let form = SetupForm(mode: .settings)
        defer { form.stop() }
        let cloud = try #require(Self.view("transcription.cloud", in: form) as? NSSwitch)
        let local = try #require(Self.view("transcription.local", in: form) as? NSSwitch)
        #expect(cloud.state == (hasKey ? .on : .off))
        #expect(local.state == (hasKey ? .off : .on))
        #expect(Home.current.configText == before)
    }

    @Test(.freshHome, .speaking(.russian))
    func loginCanBeDisabledAndEnabledWithoutOpeningSystemSettings() throws {
        let form = SetupForm(mode: .settings)
        defer { form.stop() }
        var state = LoginItem.State.enabled
        var changes: [Bool] = []
        var settingsOpened = 0
        form.loginItemStatus = { state }
        form.setLoginItemEnabled = { enabled in
            changes.append(enabled)
            state = enabled ? .enabled : .notRegistered
            return state
        }
        form.openLoginItemSettings = { settingsOpened += 1 }
        form.refresh()
        let toggle = try #require(Self.view("access.login.toggle", in: form) as? NSSwitch)
        #expect(toggle.accessibilityLabel() == "Запуск при входе")
        #expect(toggle.state == .on)
        toggle.state = .off
        _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        #expect(changes == [false])
        #expect(state == .notRegistered)
        #expect(toggle.state == .off)
        toggle.state = .on
        _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        #expect(changes == [false, true])
        #expect(toggle.state == .on)
        #expect(settingsOpened == 0)
    }

    @Test(.freshHome, .speaking(.russian))
    func loginFailureKeepsTheActualStateAndAllowsRetry() throws {
        let form = SetupForm(mode: .settings)
        defer { form.stop() }
        var state = LoginItem.State.enabled
        var attempts = 0
        form.loginItemStatus = { state }
        form.setLoginItemEnabled = { enabled in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteNoPermission) }
            state = enabled ? .enabled : .notRegistered
            return state
        }
        form.refresh()
        let toggle = try #require(Self.view("access.login.toggle", in: form) as? NSSwitch)
        toggle.state = .off
        _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        form.refresh()
        let row = try #require(Self.view("access.login", in: form))
        #expect(Self.labels(in: row).contains { $0.contains("не удалось отключить запуск при входе") })
        #expect(toggle.accessibilityHelp()?.contains("не удалось отключить запуск при входе") == true)
        #expect(toggle.state == .on)
        #expect(toggle.isEnabled)
        #expect(form.loginItemStatus() == .enabled)
        toggle.state = .off
        _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        #expect(attempts == 2)
        #expect(toggle.state == .off)
        #expect(!Self.labels(in: row).contains { $0.contains("не удалось") })
    }

    @Test(.freshHome)
    func loginChangesRespectRecordingGuardAndSystemApproval() throws {
        let form = SetupForm(mode: .settings)
        defer { form.stop() }
        var recording = true
        var changes = 0
        var settingsOpened = 0
        var state = LoginItem.State.notRegistered
        form.isRecording = { recording }
        form.loginItemStatus = { state }
        form.setLoginItemEnabled = { _ in changes += 1; state = .needsApproval; return state }
        form.openLoginItemSettings = { settingsOpened += 1 }
        form.refresh()
        let toggle = try #require(Self.view("access.login.toggle", in: form) as? NSSwitch)
        toggle.state = .on
        _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        #expect(changes == 0)
        #expect(toggle.state == .off)
        recording = false
        toggle.state = .on
        _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        #expect(changes == 1)
        #expect(settingsOpened == 1)
        #expect(toggle.state == .off)
        toggle.state = .on
        _ = NSApplication.shared.sendAction(try #require(toggle.action), to: toggle.target, from: toggle)
        #expect(changes == 1)
        #expect(settingsOpened == 2)
        #expect(toggle.state == .off)
        state = .enabled
        form.refresh()
        #expect(toggle.state == .on)
    }

    @Test(.freshHome)
    func loginSwitchIsDisabledWithoutAPersistentApplication() throws {
        let form = SetupForm(mode: .settings)
        defer { form.stop() }
        form.loginItemStatus = { .unavailable }
        form.refresh()
        let toggle = try #require(Self.view("access.login.toggle", in: form) as? NSSwitch)
        #expect(toggle.state == .off)
        #expect(!toggle.isEnabled)
        #expect(toggle.accessibilityHelp()?.contains("Only Verbemo.app") == true)
    }

    @Test("Speaker model cards require local transcription and the feature switch",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet"}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func diarizationSwitchDoesNotDownload() throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        form.fetchDiarization = { _, _ in }
        defer { form.stop(); withExtendedLifetime(application) {} }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let names = ["nemotron-3", "ls-eend-ami", "community-1"]
        let cards = try names.map { try #require(Self.view("choice.diarization.\($0)", in: form) as? ChoiceCard) }
        let downloads = try names.map { try #require(Self.button("transcription.diarization.download.\($0)", in: form)) }
        #expect(toggle.state == .off)
        #expect(cards.map(\.isSelected) == [true, false, false])
        #expect(cards.allSatisfy { !$0.isEnabled })
        #expect(downloads.allSatisfy { !$0.isEnabled })
        toggle.performClick(nil)
        #expect(Config.localDiarizationEnabled())
        #expect(cards.allSatisfy { $0.isEnabled })
        #expect(downloads.allSatisfy { $0.isEnabled }, "enabling the feature started a hidden download")
        #expect(cards[1].accessibilityPerformPress())
        #expect(cards.map(\.isSelected) == [false, true, false])
        #expect(Config.diarizationModel() == .lsEendAMI)
        #expect(Self.labels(in: cards[0]).joined(separator: " ").contains("107 MB"))
        #expect(Self.labels(in: cards[1]).joined(separator: " ").contains("45 MB"))
        #expect(Self.labels(in: cards[2]).joined(separator: " ").contains("22 MB"))
        toggle.performClick(nil)
        #expect(cards.allSatisfy { !$0.isEnabled })
        #expect(Config.diarizationModel() == .lsEendAMI, "turning the feature off lost the selected model")
    }

    @Test("Returning to Nemotron saves an explicit speaker-model preference",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet","local_diarization":true}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func diarizationDefaultPickIsPersisted() throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        form.fetchDiarization = { _, _ in }
        defer { form.stop(); withExtendedLifetime(application) {} }
        let ami = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let nemo = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        #expect(ami.accessibilityPerformPress())
        #expect(nemo.accessibilityPerformPress())
        #expect(Config.diarizationModel() == .nemotron3)
        let saved = try String(contentsOf: Config.path, encoding: .utf8)
        let config = try #require(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        let transcription = try #require(config["transcription"] as? [String: Any])
        #expect(transcription["diarization_model"] as? String == "nemotron-3",
                "an explicit selection must survive a future default change")
    }

    @Test("Cloud-only mode cannot enable speaker separation",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"openai","local_diarization":true}}"#),
          .speaking(.english), .enabled(if: Platform.supportsLocalModels))
    func diarizationRequiresLocalMode() throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        defer { form.stop(); withExtendedLifetime(application) {} }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let card = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.diarization.download.nemotron-3", in: form))
        #expect(!toggle.isEnabled)
        #expect(!card.isEnabled)
        #expect(!download.isEnabled)
        #expect(!card.accessibilityPerformPress())
        #expect(Self.labels(in: application.panel.contentView).contains("Available with On this Mac enabled."))
    }

    @Test("A broken config leaves the speaker choices unavailable",
          .freshHome(config: "{broken"), .enabled(if: Platform.supportsLocalModels))
    func diarizationCannotBypassBadConfig() throws {
        let application = Self.localApplication()
        let form = application.settings.setup
        defer { form.stop(); withExtendedLifetime(application) {} }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let card = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        #expect(!toggle.isEnabled)
        #expect(!card.isEnabled)
        #expect(!card.accessibilityPerformPress())
    }

    @Test("Speaker radio cards explain their capacity in English", .freshHome,
          .speaking(.english))
    func diarizationEnglishDescriptions() throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        defer { form.stop(); withExtendedLifetime(application) {} }
        let nemo = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let ami = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let community = try #require(Self.view("choice.diarization.community-1", in: form) as? ChoiceCard)
        #expect(nemo.accessibilityHelp()?.contains("Meetings up to 8 speakers") == true)
        #expect(ami.accessibilityHelp()?.contains("Meetings up to 4 speakers") == true)
        #expect(community.accessibilityHelp()?.contains("Compact alternative") == true)
    }

    @Test("Speaker radio cards explain their capacity in Russian", .freshHome,
          .speaking(.russian))
    func diarizationRussianDescriptions() throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        defer { form.stop(); withExtendedLifetime(application) {} }
        let nemo = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let ami = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let community = try #require(Self.view("choice.diarization.community-1", in: form) as? ChoiceCard)
        #expect(nemo.accessibilityHelp()?.contains("Встречи до 8 говорящих") == true)
        #expect(ami.accessibilityHelp()?.contains("Встречи до 4 говорящих") == true)
        #expect(community.accessibilityHelp()?.contains("Компактная альтернатива") == true)
    }

    @Test("Cloud-only speaker hint names the local switch in Russian",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"openai","local_diarization":true}}"#),
          .speaking(.russian), .enabled(if: Platform.supportsLocalModels))
    func diarizationRussianCloudOnlyHint() {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        defer { form.stop(); withExtendedLifetime(application) {} }
        #expect(Self.labels(in: application.panel.contentView).contains("Доступно при включённом «На этом Mac»."))
    }

    @Test("Selecting speaker models starts each missing download once",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet"}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func diarizationSelectionDownloadsMissingModelsIndependently() async throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        defer { form.stop(); withExtendedLifetime(application) {} }
        let gate = Gate()
        var fetched: [DiarizationModel] = []
        form.fetchDiarization = { model, _ in
            fetched.append(model)
            await gate.pass()
        }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let ami = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let nemo = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.diarization.download.ls-eend-ami", in: form))
        toggle.performClick(nil)
        #expect(ami.accessibilityPerformPress())
        for _ in 0..<10 where fetched.isEmpty { await Task.yield() }
        #expect(fetched == [.lsEendAMI])
        #expect(!download.isEnabled)
        #expect(ami.accessibilityPerformPress())
        for _ in 0..<10 { await Task.yield() }
        #expect(fetched == [.lsEendAMI], "reselecting a model duplicated its active download")
        #expect(nemo.accessibilityPerformPress())
        #expect(Config.diarizationModel() == .nemotron3)
        for _ in 0..<100 where fetched.count < 2 { await Task.yield() }
        #expect(fetched == [.lsEendAMI, .nemotron3])
        gate.open()
        for _ in 0..<100 where form.hasModelDownloads { await Task.yield() }
        #expect(download.isEnabled)
        #expect(!form.hasModelDownloads)
    }

    @Test("Reopening settings or choosing a ready speaker model does not download",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet","local_diarization":true}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func readyDiarizationSelectionDoesNotDownload() async throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        defer { form.stop(); withExtendedLifetime(application) {} }
        var fetched = 0
        form.diarizationIsHere = { $0 == .nemotron3 }
        form.fetchDiarization = { _, _ in fetched += 1 }
        form.reload()
        let card = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        #expect(card.accessibilityPerformPress())
        for _ in 0..<10 { await Task.yield() }
        #expect(fetched == 0)
        #expect(!form.hasModelDownloads)
        #expect(Config.diarizationModel() == .nemotron3)
    }

    @Test("Every model card owns a hidden progress bar and named cancel control",
          .freshHome, .speaking(.english), .enabled(if: Platform.supportsLocalModels))
    func modelProgressBelongsToItsCard() throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        defer { form.stop(); withExtendedLifetime(application) {} }
        for (id, name) in [
            ("parakeet", "Parakeet"),
            ("whisper", "Whisper large-v3-turbo"),
            ("gigaam", "GigaAM v3"),
            ("diarization.nemotron-3", "Nemotron 3"),
            ("diarization.ls-eend-ami", "LS-EEND AMI"),
            ("diarization.community-1", "Community-1"),
        ] {
            let card = try #require(Self.view("choice.\(id)", in: form) as? ChoiceCard)
            let bars = card.allDescendants.compactMap { $0 as? NSProgressIndicator }
            let cancel = try #require(card.allDescendants
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel()?.contains(name) == true
                    && $0.accessibilityLabel()?.contains("Cancel") == true })
            #expect(bars.count == 1, "\(name) has no progress bar inside its card")
            #expect(cancel.isHiddenOrHasHiddenAncestor)
        }
    }

    @Test("Cancel stops Parakeet without losing the selected engine or showing an error",
          .freshHome, .speaking(.english), .enabled(if: Platform.supportsLocalModels))
    func parakeetCancelRestoresDownload() async throws {
        let application = Self.localApplication()
        let form = application.settings.setup
        defer { form.stop(); withExtendedLifetime(application) {} }
        let gate = Gate()
        form.parakeetIsHere = { false }
        form.fetchParakeet = {
            await gate.pass()
            try Task.checkCancellation()
        }
        form.refresh()

        let card = try #require(Self.view("choice.parakeet", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.download.parakeet", in: form))
        download.performClick(nil)
        let bar = try #require(card.allDescendants.compactMap { $0 as? NSProgressIndicator }.first)
        let cancel = try #require(card.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel()?.contains("Cancel") == true })
        #expect(form.isDownloading)
        #expect(!bar.isHiddenOrHasHiddenAncestor)
        #expect(!cancel.isHiddenOrHasHiddenAncestor && cancel.isEnabled)

        cancel.performClick(nil)
        gate.open()
        for _ in 0..<100 where form.isDownloading { await Task.yield() }
        #expect(!form.isDownloading)
        #expect(card.isSelected)
        #expect(!download.isHidden && download.isEnabled)
        #expect(!card.status.localizedLowercase.contains("failed"))
    }

    @Test("Speaker progress stays in its card and ignores a cancelled attempt's late callback",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet"}}"#),
          .speaking(.russian), .enabled(if: Platform.supportsLocalModels))
    func diarizationCancelAndRetryIgnoreStaleProgress() async throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        defer { form.stop(); withExtendedLifetime(application) {} }
        let gates = [Gate(), Gate()]
        var callbacks: [@Sendable (Double) -> Void] = []
        form.fetchDiarization = { _, progress in
            let attempt = callbacks.count
            callbacks.append(progress)
            await gates[attempt].pass()
            try Task.checkCancellation()
        }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let card = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let other = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.diarization.download.nemotron-3", in: form))
        toggle.performClick(nil)
        download.performClick(nil)
        for _ in 0..<100 where callbacks.isEmpty { await Task.yield() }
        let first = try #require(callbacks.first)
        first(0.37)
        for _ in 0..<100 where !Self.labels(in: card).contains("Загрузка · 37%") {
            await Task.yield()
        }
        let bar = try #require(card.allDescendants.compactMap { $0 as? NSProgressIndicator }.first)
        let cancel = try #require(card.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel()?.contains("Nemotron 3") == true
                && $0.accessibilityLabel()?.contains("Отменить") == true })
        #expect(Self.labels(in: card).contains("Загрузка · 37%"))
        #expect(!bar.isHiddenOrHasHiddenAncestor)
        #expect(abs(bar.doubleValue / bar.maxValue - 0.37) < 0.01)
        #expect(other.allDescendants.compactMap { $0 as? NSProgressIndicator }
            .allSatisfy { $0.isHiddenOrHasHiddenAncestor })

        toggle.performClick(nil)
        #expect(!card.isEnabled)
        #expect(cancel.isEnabled && !cancel.isHiddenOrHasHiddenAncestor,
                "turning off the feature must not trap an active download")
        cancel.performClick(nil)
        gates[0].open()
        for _ in 0..<100 where download.isHidden { await Task.yield() }
        toggle.performClick(nil)
        for _ in 0..<100 where !download.isEnabled { await Task.yield() }
        #expect(!download.isHidden && download.isEnabled)
        #expect(!card.status.contains("ошибка"))

        download.performClick(nil)
        for _ in 0..<100 where callbacks.count < 2 { await Task.yield() }
        let second = try #require(callbacks.last)
        first(0.95)
        second(0.42)
        for _ in 0..<100 where !Self.labels(in: card).contains("Загрузка · 42%") {
            await Task.yield()
        }
        #expect(Self.labels(in: card).contains("Загрузка · 42%"))
        #expect(abs(bar.doubleValue / bar.maxValue - 0.42) < 0.01)
        gates[1].open()
        for _ in 0..<100 where download.isHidden { await Task.yield() }
        #expect(!download.isHidden, "the test left a fetch active after opening its gate")
    }

    @Test("A failed speaker fetch explains the HTTP failure and offers retry",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet"}}"#),
          .speaking(.english), .enabled(if: Platform.supportsLocalModels))
    func diarizationDownloadShowsHTTPFailure() async throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        defer { form.stop(); withExtendedLifetime(application) {} }
        form.fetchDiarization = { _, _ in
            throw VerifiedModelStore.Error.badHTTPStatus(404)
        }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let card = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.diarization.download.nemotron-3", in: form))
        let progress = try #require(card.allDescendants
            .compactMap { $0 as? ModelDownloadProgress }.first)
        toggle.performClick(nil)
        #expect(card.accessibilityPerformPress())
        for _ in 0..<100 where progress.isHidden == false { await Task.yield() }

        #expect(card.status.contains("HTTP 404"), "the error hid the actionable HTTP status")
        #expect(download.title == "Retry…" && download.isEnabled && !download.isHidden)
        #expect(progress.isHidden)
    }

    /// A form whose transcription settings live in memory and say "parakeet,
    /// on this Mac", so the local model is the thing it is waiting for.
    private static func localApplication() -> ApplicationWindow {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.transcription)
        form.storedTranscription = {
            TranscriptionChoice.read(
                engine: "parakeet", cloudProvider: "assemblyai", enabled: true,
                localModels: Platform.supportsLocalModels, localEngine: "parakeet")
        }
        form.write = { _, _ in }
        form.refresh()
        return application
    }

    /// Closing the window stopped the bar's timer and, with it, the form's
    /// only record that a download was running — so opening it again offered
    /// the download a second time, into the same cache, beside the first.
    @Test(
        "A parakeet download outlives the window closing, and reopening does not start another",
        .enabled(if: Platform.supportsLocalModels))
    func parakeetDownloadSurvivesClosing() async throws {
        let application = Self.localApplication()
        let form = application.settings.setup
        let gate = Gate()
        var fetches = 0
        form.parakeetIsHere = { false }
        form.fetchParakeet = {
            fetches += 1
            await gate.pass()
        }
        form.refresh()

        // The card's own button rather than the wizard's: on a Mac where the
        // test runner has never been asked for the microphone, the wizard's
        // next step is that prompt, not the download.
        let download = try #require(Self.button("transcription.download.parakeet", in: form))
        download.performClick(nil)
        #expect(form.isDownloading)
        await Task.yield()
        #expect(fetches == 1)

        form.stop()
        #expect(form.isDownloading, "putting the window away forgot the download")
        form.reload()
        #expect(form.progress.machine.localModelDownloading)
        #expect(download.isHidden, "the download was offered again while it was running")
        download.performClick(nil)
        await Task.yield()
        #expect(fetches == 1, "a second fetch started beside the first")

        gate.open()
        for _ in 0..<50 where form.isDownloading { await Task.yield() }
        #expect(!form.isDownloading)
        #expect(fetches == 1)
        form.stop()
    }

    /// The rule was written down on `isRecording` and kept only by the login
    /// item: the system-audio test opened a second tap during a meeting and
    /// played a tone the far end could hear.
    @Test("The system-audio test is refused during a recording, and says why",
          .freshHome)
    func noToneDuringARecording() async throws {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.recording)
        defer { form.stop(); withExtendedLifetime(application) {} }
        var tones = 0
        form.playTestTone = { tones += 1; return .heard }
        var recording = true
        form.isRecording = { recording }
        let row = try #require(Self.view("access.system-audio", in: form) as? AccessRow)

        row.onAct?()
        for _ in 0..<5 { await Task.yield() }
        #expect(tones == 0, "a tone was played into a meeting")
        let words = Self.labels(in: row).joined(separator: " ")
        #expect(words.contains("not while a recording is running"))

        recording = false
        row.onAct?()
        for _ in 0..<5 where tones == 0 { await Task.yield() }
        #expect(tones == 1)
    }

    /// Grants are given in System Settings, and the person comes back to
    /// verbemo from there. Nothing redrew the rows when they did, so the
    /// microphone row went on saying denied beside a grant that existed.
    @Test("Coming back to verbemo redraws a form that is on screen, and only one that is")
    func activationRedraws() {
        let application = ApplicationWindow()
        let form = application.settings.setup
        application.navigate(.recording)
        defer { form.stop(); withExtendedLifetime(application) {} }
        var redraws = 0
        form.onStateChange = { redraws += 1 }

        // Counted across each post rather than from zero: a parallel test's
        // config write redraws every form, but only between these lines —
        // nothing else runs on the main thread inside them.
        var before = redraws
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(redraws == before, "a form nobody can see asked macOS for its grants")

        application.panel.orderFront(nil)
        defer { application.panel.orderOut(nil) }

        before = redraws
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(redraws == before + 1)
    }
}

extension SetupFormBehaviourTests {
    fileprivate static func button(_ id: String, in form: SetupForm) -> NSButton? {
        view(id, in: form) as? NSButton
    }

    fileprivate static func view(_ id: String, in form: SetupForm) -> NSView? {
        var pending = Array(form.settingsPages.values) as [NSView]
        while let view = pending.popLast() {
            if view.identifier?.rawValue == id { return view }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The words on screen under a view, hidden ones left out.
    fileprivate static func labels(in root: NSView?) -> [String] {
        var found: [String] = []
        var pending = root.map { [$0] } ?? []
        while let view = pending.popLast() {
            if let label = view as? NSTextField, !label.isHidden { found.append(label.stringValue) }
            pending.append(contentsOf: view.subviews)
        }
        return found
    }
}
