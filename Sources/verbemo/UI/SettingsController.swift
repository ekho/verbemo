import AppKit

/// Settings pages hosted by the application's Journal window.
@MainActor
final class SettingsController: NSObject, NSTextFieldDelegate {
    var isRecording: (() -> Bool)? {
        didSet { setup.isRecording = isRecording }
    }
    var isProcessing: (() -> Bool)?
    private let panel: NSWindow
    private let calendar: CalendarWatcher
    private let calendarSelection: CalendarSettingsView
    let setup: SetupForm
    private var deletionTask: Task<Void, Never>?
    private var emailLookupTask: Task<Void, Never>?
    private var pages: [ApplicationNavigationState.Destination: NSView] = [:]
    private var pageNotices: [NSTextField] = []
    private var providerRows: [(SettingsSchema.Entry, NSView)] = []
    private var configWatch: ConfigWatch.Token?
    private var rows: [Row] = []
    private let modelStorage = ModelStorage()
    private let modelsBox = NSStackView()
    private let modelsTotal = NSTextField(labelWithString: "")
    private var shownModels: [ModelStorage.Model] = []
    private var restartNotice = ""
    private var summaryConnection = [Config.summary().ollamaBaseURL, Config.summary().ollamaModel]

    private struct Row {
        let entry: SettingsSchema.Entry
        let control: NSControl
    }

    init(hostWindow: NSWindow, calendar: CalendarWatcher = CalendarWatcher()) {
        panel = hostWindow
        self.calendar = calendar
        setup = SetupForm(mode: .settings, calendar: calendar)
        calendarSelection = CalendarSettingsView(calendar: calendar)
        super.init()
        buildPages()
        configWatch = ConfigWatch.observe { [weak self] in self?.refresh() }
        setup.onStateChange = { [weak self] in
            self?.refreshModels()
            self?.calendarSelection.refresh()
        }
        refresh()
    }

    var representedSettingsPaths: [String] {
        rows.map { $0.entry.path.joined(separator: ".") }
            + [Config.Key.calendarIDs.rawValue]
            + Array(SetupForm.settingsCoveredPaths.intersection(Set(SettingsSchema.sections.flatMap(\.entries).map { $0.path.joined(separator: ".") })))
    }
    var renderedControls: [NSControl] { rows.map(\.control) }

    var modelLines: [String] {
        var found = [modelsTotal.stringValue]
        var pending = modelsBox.subviews
        while let next = pending.popLast() {
            pending.append(contentsOf: next.subviews)
            switch next {
            case let field as NSTextField: found.append(field.stringValue)
            case let button as NSButton: found.append(button.title)
            default: break
            }
        }
        return found
    }

    func stopForTermination() -> [Task<Void, Never>] {
        configWatch = nil
        deletionTask?.cancel()
        emailLookupTask?.cancel()
        return setup.stopForTermination() + [deletionTask, emailLookupTask].compactMap { $0 }
    }

    func reload() {
        let summary = Config.summary()
        summaryConnection = [summary.ollamaBaseURL, summary.ollamaModel]
        setup.reload()
        calendarSelection.refresh()
    }

    func content(for destination: ApplicationNavigationState.Destination) -> NSView {
        guard let page = pages[destination] else { preconditionFailure("Not a settings destination") }
        // Config/download observers keep pages current without a full refresh on every tab.
        if destination == .storage { refreshModels() }
        if destination == .calendar { calendarSelection.refresh() }
        if destination == .summary && panel.isVisible {
            let summary = Config.summary()
            if [summary.ollamaBaseURL, summary.ollamaModel] != summaryConnection { reload() }
        }
        return page
    }

    private func buildPages() {
        for destination in ApplicationNavigationState.Destination.allCases where !destination.isMeetings && destination != .about {
            let form = setup.settingsPages[destination] ?? FlippedStackView()
            let heading = NSTextField(labelWithString: destination.title)
            heading.font = JournalStyle.titleFont(30)
            heading.textColor = JournalStyle.ink
            form.insertArrangedSubview(heading, at: 0)
            heading.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -48).isActive = true
            let notice = NSTextField(wrappingLabelWithString: "")
            notice.textColor = .systemOrange
            notice.font = .systemFont(ofSize: 12)
            notice.isHidden = true
            notice.identifier = .init("settings.notice")
            pageNotices.append(notice)
            form.insertArrangedSubview(notice, at: 0)
            notice.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -48).isActive = true
            let entries = SettingsSchema.sections.flatMap(\.entries).filter {
                SettingsPage.destination(for: $0.path) == destination
                    && $0.path != Config.Key.calendarIDs.path
                    && !SetupForm.settingsCoveredPaths.contains($0.path.joined(separator: "."))
            }
            let common: Set<String> = ["interface_theme", "interface_language", "window", "calendar", "system_audio", "transcription.language", "transcription.model", "summary.language", "summary.template", "user_name", "user_email", "speaker_names.enabled"]
            let rare = NSStackView()
            rare.orientation = .vertical
            rare.alignment = .leading
            rare.spacing = 16
            for entry in entries {
                let content = makeRow(for: entry)
                let row = destination == .general ? SetupLayout.box([SetupLayout.row(title: content)]) : content
                if destination == .general { content.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -38).isActive = true }
                providerRows.append((entry, row))
                let container = common.contains(entry.path.joined(separator: ".")) ? form : rare
                container.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: container.widthAnchor, constant: container === form ? -48 : 0).isActive = true
                if entry.path == Config.Key.calendar.path {
                    let box = SetupLayout.box([SetupLayout.row(title: calendarSelection)])
                    calendarSelection.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -38).isActive = true
                    let section = SetupLayout.section(localised("Calendars for events", "Календари для событий"), content: box)
                    form.addArrangedSubview(section)
                    section.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -48).isActive = true
                }
            }
            if !rare.arrangedSubviews.isEmpty {
                let disclosure = NSButton(title: localised("More options", "Дополнительные параметры"), target: self, action: #selector(toggleOptions(_:)))
                disclosure.setButtonType(.onOff)
                disclosure.isBordered = false
                disclosure.font = SetupLayout.titleFont
                disclosure.alignment = .left
                disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
                disclosure.imagePosition = .imageLeading
                disclosure.contentTintColor = JournalStyle.ink
                disclosure.identifier = .init("options.\(destination.rawValue)")
                disclosure.state = .off
                disclosure.setAccessibilityRole(.disclosureTriangle)
                disclosure.setAccessibilityLabel(localised("Show more options", "Показать дополнительные параметры"))
                disclosure.tag = optionGroups.count
                optionGroups.append(rare)
                rare.isHidden = true
                let content = SetupLayout.group([disclosure, rare], spacing: 16)
                let box = SetupLayout.box([SetupLayout.row(title: content)])
                form.addArrangedSubview(box)
                box.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -48).isActive = true
                // Include the row's gap before its trailing spacer.
                content.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -38).isActive = true
            }
            if destination == .storage && Platform.supportsLocalModels {
                for view in modelsSection() {
                    form.addArrangedSubview(view)
                    view.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -48).isActive = true
                }
            }
            pages[destination] = SetupLayout.scroller(around: form)
        }
    }
    private var optionGroups: [NSView] = []
    @objc private func toggleOptions(_ sender: NSButton) {
        optionGroups[sender.tag].isHidden = sender.state != .on
        sender.image = NSImage(systemSymbolName: sender.state == .on ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        sender.setAccessibilityLabel(sender.state == .on
            ? localised("Hide more options", "Скрыть дополнительные параметры")
            : localised("Show more options", "Показать дополнительные параметры"))
    }

    /// Storage operations stay beside the downloaded model inventory.
    private func modelsSection() -> [NSView] {
        modelsBox.orientation = .vertical
        modelsBox.alignment = .leading
        modelsBox.spacing = 10

        modelsTotal.font = .systemFont(ofSize: 11)
        modelsTotal.textColor = .secondaryLabelColor
        modelsTotal.lineBreakMode = .byTruncatingMiddle

        return [
            sectionHeader(localised("Model files", "Файлы моделей")),
            modelsTotal,
            modelsBox,
        ]
    }

    /// Rebuild the rows rather than update them. Which models are worth
    /// listing is itself an answer that changes — a parakeet version left
    /// behind by a change on this very tab appears, and goes when it is
    /// deleted — and a list that only ever grew would keep offering to
    /// delete a directory that isn't there any more.
    private func refreshModels() {
        guard Platform.supportsLocalModels else { return }
        for view in modelsBox.arrangedSubviews {
            modelsBox.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        shownModels = modelStorage.all()
        let total = modelStorage.total(shownModels)
        let hasIncompleteModel = shownModels.contains {
            !modelStorage.isReady($0)
                && FileManager.default.fileExists(atPath: $0.directory.path)
        }
        modelsTotal.stringValue = total == 0 && hasIncompleteModel
            ? localised("An incomplete model cache is present.",
                        "Найдена неполная папка модели.")
            : total == 0
            ? localised(
                "No models installed. Download one from the list below.",
                "Модели пока не установлены. Их можно скачать из списка ниже.")
            : localised("\(ModelStorage.describe(bytes: total)) in total · ",
                        "всего \(ModelStorage.describe(bytes: total)) · ")
                + friendlyPath(shownModels[0].directory.deletingLastPathComponent())

        for diarization in [false, true] {
            modelsBox.addArrangedSubview(sectionHeader(diarization
                ? localised("Diarization", "Диаризация")
                : localised("Transcription", "Расшифровка")))
            for (index, model) in shownModels.enumerated() where (model.kind == .diarization) == diarization {
                let row = modelRow(model, tag: index)
                modelsBox.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: modelsBox.widthAnchor).isActive = true
            }
        }
    }

    private func modelRow(_ model: ModelStorage.Model, tag: Int) -> NSView {
        let name = NSTextField(wrappingLabelWithString: model.name)
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let ready = modelStorage.isReady(model)
        let size = ready ? ModelStorage.describe(bytes: model.bytes)
            : localised("about ", "около ") + ModelStorage.describe(bytes: model.advertisedBytes)
        let controls = setup.modelFilesControl(for: model)
        let action: NSButton
        if ready {
            action = NSButton(title: localised("Delete", "Удалить"), target: self,
                              action: #selector(deleteModelClicked(_:)))
            action.bezelStyle = .rounded
            action.controlSize = .small
            action.tag = tag
            let deletionReason = modelDeletionReason(model)
            action.isEnabled = deletionReason == nil
            action.toolTip = deletionReason
        } else {
            action = controls.button
        }
        action.setContentHuggingPriority(.required, for: .horizontal)
        action.setContentCompressionResistancePriority(.required, for: .horizontal)

        let line = NSStackView(views: [name, action])
        line.orientation = .horizontal
        line.distribution = .fill
        line.alignment = .firstBaseline
        line.spacing = 10

        let help = NSTextField(wrappingLabelWithString: Self.purpose(of: model) + " • " + size)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [line, help, controls.status])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        for view in row.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        return row
    }

    /// What the model is for, in the words the setup form uses for the switch
    /// that asks for it — so somebody who deletes the wrong one has to have
    /// misread the same sentence twice.
    private static func purpose(of model: ModelStorage.Model) -> String {
        switch model.kind {
        case .parakeet:
            return localised(
                "Transcribes on this Mac, after the meeting.",
                "Расшифровывает на этом маке, после встречи.")
        case .whisper:
            return localised(
                "Local multilingual transcription with whisper.cpp.",
                "Локальная многоязычная расшифровка через whisper.cpp.")
        case .gigaAM:
            return localised(
                "Local Russian transcription with transcribe.cpp.",
                "Локальная русская расшифровка через transcribe.cpp.")
        case .nemotron:
            return localised(
                "Shared files for live and final transcription. Downloaded once.",
                "Общие файлы для живой и итоговой расшифровки. Скачиваются один раз.")
        case .diarization:
            let chosen = model.diarizationModel ?? .community1
            let license = switch chosen {
            case .nemotron3: "OpenMDW 1.1"
            case .lsEendAMI: "MIT"
            case .community1: "CC BY 4.0"
            }
            return localised(chosen.detailEnglish, chosen.detailRussian) + " · " + license
        }
    }

    /// A path as a person would write it, which is also how the setup form
    /// shows the recordings folder.
    private func friendlyPath(_ url: URL) -> String {
        Home.current.abbreviating(url.path)
    }

    /// Ask, then delete, then bring down the switch that wanted it.
    ///
    /// The asking is not ceremony: the download is hundreds of megabytes over
    /// whatever connection the person is on next time, and the alert is the
    /// only place that says the switch is going off with it.
    func modelDeletionReason(_ model: ModelStorage.Model) -> String? {
        if isProcessing?() == true || isRecording?() == true || setup.hasModelDownloads {
            return localised("Wait for recording and processing to finish.", "Дождитесь окончания записи и обработки.")
        }
        let choice = TranscriptionChoice.read(engine: Config.transcriptionEngine(), cloudProvider: Config.transcriptionCloudProvider(), enabled: Config.transcriptionEnabled(), localModels: Platform.supportsLocalModels, localEngine: Config.transcriptionLocalEngine())
        let selected: Bool = switch model.kind {
        case .parakeet: choice.local && choice.localEngine == "parakeet" && model.directory == ParakeetEngine.cacheDirectory(for: ParakeetEngine.configuredVersion())
        case .whisper: choice.local && choice.localEngine == "whisper"
        case .gigaAM: choice.local && choice.localEngine == "gigaam"
        case .nemotron: Config.liveTranscriptionEnabled() || (choice.local && choice.localEngine == "nemotron")
        case .diarization: Config.localDiarizationEnabled() && model.diarizationModel == Config.diarizationModel()
        }
        return selected ? localised("Choose another model or turn this feature off before deleting it.", "Перед удалением выберите другую модель или выключите эту функцию.") : nil
    }

    @objc private func deleteModelClicked(_ sender: NSButton) {
        guard shownModels.indices.contains(sender.tag), panel.attachedSheet == nil else { return }
        let model = shownModels[sender.tag]
        if let reason = modelDeletionReason(model) {
            let alert = NSAlert()
            alert.messageText = reason
            alert.beginJournalSheetModal(for: panel)
            return
        }
        let previewChoice = TranscriptionChoice.read(
            engine: Config.transcriptionEngine(), cloudProvider: Config.transcriptionCloudProvider(),
            enabled: Config.transcriptionEnabled(), localModels: Platform.supportsLocalModels,
            localEngine: Config.transcriptionLocalEngine())
        let previewUpdates = ModelStorage.updatesAfterDeleting(
            model.kind, choice: previewChoice, liveEnabled: Config.liveTranscriptionEnabled(),
            diarizationEnabled: Config.localDiarizationEnabled(),
            deletedDiarizationModel: model.diarizationModel ?? .community1,
            selectedDiarizationModel: Config.diarizationModel())
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localised("Delete \(model.name)?", "Удалить \(model.name)?")
        alert.informativeText = Self.consequence(of: model, choice: previewChoice, switchesOff: !previewUpdates.isEmpty)
        alert.addButton(withTitle: localised("Delete", "Удалить"))
        alert.addButton(withTitle: localised("Cancel", "Отмена")).keyEquivalent = "\u{1b}"
        alert.buttons.first?.hasDestructiveAction = true
        deletionTask = Task { @MainActor [self] in
            defer { deletionTask = nil }
            guard panel.attachedSheet == nil,
                  await alert.beginJournalSheetModal(for: panel) == .alertFirstButtonReturn else { return }
            if let reason = modelDeletionReason(model) {
                let failure = NSAlert()
                failure.messageText = reason
                failure.beginJournalSheetModal(for: panel, completionHandler: nil)
                return
            }
            do {
                if model.kind == .diarization {
                    try await DiarizationModelStore.shared(for: model.diarizationModel ?? .community1).delete()
                } else if model.kind == .nemotron {
                    try await NemotronModelStore().delete()
                } else {
                    try modelStorage.delete(model)
                }
                // Re-read after confirmation/deletion: configuration can change while a sheet is open.
                let choice = TranscriptionChoice.read(
                    engine: Config.transcriptionEngine(), cloudProvider: Config.transcriptionCloudProvider(),
                    enabled: Config.transcriptionEnabled(), localModels: Platform.supportsLocalModels,
                    localEngine: Config.transcriptionLocalEngine())
                let updates = ModelStorage.updatesAfterDeleting(
                    model.kind, choice: choice, liveEnabled: Config.liveTranscriptionEnabled(),
                    diarizationEnabled: Config.localDiarizationEnabled(),
                    deletedDiarizationModel: model.diarizationModel ?? .community1,
                    selectedDiarizationModel: Config.diarizationModel())
                for update in updates { Config.update(path: update.path, value: update.value) }
            } catch {
                let failed = NSAlert(error: error)
                failed.messageText = localised("Couldn't delete \(model.name)", "Не удалось удалить \(model.name)")
                failed.beginJournalSheetModal(for: panel, completionHandler: nil)
            }
            refreshModels()
            setup.refresh()
        }
    }

    /// What the person is about to lose, and what will change because of it.
    private static func consequence(
        of model: ModelStorage.Model,
        choice: TranscriptionChoice,
        switchesOff: Bool
    ) -> String {
        let freed = localised(
            "\(ModelStorage.describe(bytes: model.bytes)) comes back. ",
            "Освободится \(ModelStorage.describe(bytes: model.bytes)). ")
        if model.kind == .diarization {
            return freed + (switchesOff
                ? localised("Diarization turns off. Download the model explicitly to use it later.",
                            "Диаризация отключится. Чтобы включить её снова, скачайте модель отдельно.")
                : localised("Download the model explicitly to use diarization later.",
                            "Чтобы включить диаризацию позже, скачайте модель отдельно."))
        }
        guard switchesOff else {
            return freed + localised(
                "It downloads again if you switch it back on.",
                "Скачается снова, если её опять включить.")
        }
        switch model.kind {
        case .diarization:
            preconditionFailure("handled above")
        case .parakeet, .whisper, .gigaAM:
            if choice.cloud {
                return freed + localised(
                    "Transcribing on this Mac goes off with it, so meetings go to "
                        + "\(TranscriptionChoice.displayName(choice.provider)) instead.",
                    "Расшифровка на этом маке выключится, и встречи пойдут "
                        + "в \(TranscriptionChoice.displayName(choice.provider)).")
            }
            return freed + localised(
                "Nothing else is set up to transcribe, so transcription goes off "
                    + "entirely — otherwise the model comes back at the next meeting.",
                "Расшифровывать больше нечем, поэтому расшифровка выключится совсем — "
                    + "иначе модель вернётся на ближайшей встрече.")
        case .nemotron:
            return freed + localised(
                "Live transcription and final processing with Nemotron will be turned off.",
                "Живая расшифровка и итоговая обработка с Nemotron будут выключены.")
        }
    }

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func makeRow(for entry: SettingsSchema.Entry) -> NSView {
        let control = makeControl(for: entry)
        // The label beside it is a separate text field, which a screen reader
        // does not connect to the control: every switch on this tab used to
        // be announced as "switch" and nothing else.
        control.setAccessibilityLabel(entry.label)
        control.identifier = NSUserInterfaceItemIdentifier(entry.path.joined(separator: "."))
        control.tag = rows.count

        let label = NSTextField(labelWithString: entry.label)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [label, control])
        line.orientation = .vertical
        line.alignment = .leading
        line.spacing = 10

        // A toggle is a small thing on the right of a wide label; a text field
        // wants room. Both keep the same column so the window reads as a form.
        let controlWidth: CGFloat
        switch entry.kind {
        case .toggle: controlWidth = 40
        case .number: controlWidth = 110
        // Wide enough for the longest default to be read rather than
        // truncated: the placeholder is the only place some of them appear.
        default: controlWidth = 260
        }
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            entry.path == ["user_email"]
                ? control.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
                : control.widthAnchor.constraint(equalToConstant: controlWidth),
        ])
        if entry.path == ["user_email"] {
            let width = control.widthAnchor.constraint(equalTo: line.widthAnchor)
            width.priority = .defaultHigh
            width.isActive = true
        }

        var helpText = entry.help
        if entry.path == ["interface_language"] {
            helpText = localised("System follows macOS. Meeting and summary languages are configured separately.", "Системный язык следует настройке macOS. Язык встреч и сводки настраивается отдельно.")
        } else if entry.path == ["system_audio"] {
            helpText = localised("Choose only call audio, or all audio including music and notifications.", "Можно записывать только звук звонка или весь звук Mac, включая музыку и уведомления.")
        }
        if entry.needsRestart {
            helpText += localised(
                " Takes effect at the next launch.", " Подействует при следующем запуске.")
        }
        let help = NSTextField(labelWithString: helpText)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 0
        help.preferredMaxLayoutWidth = 460
        rows.append(Row(entry: entry, control: control))

        let row = NSStackView(views: [line, help])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        line.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        help.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        help.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makeControl(for entry: SettingsSchema.Entry) -> NSControl {
        if entry.path == ["user_email"] {
            let editor = EmailAddressesEditor()
            editor.onChange = { Config.update(path: entry.path, value: $0.isEmpty ? nil : $0) }
            editor.onLookup = { [weak self, weak editor] in
                guard let self, let editor, self.emailLookupTask == nil else { return }
                editor.setSearching(true)
                self.emailLookupTask = Task { [weak self, weak editor] in
                    defer { self?.emailLookupTask = nil; editor?.setSearching(false) }
                    guard !Task.isCancelled, let watcher = self?.calendar else { return }
                    guard watcher.authorized else {
                        editor?.report(CalendarSelectionError.accessDenied.localizedDescription, error: true)
                        return
                    }
                    let found = watcher.ownEmailAddresses()
                    let current = Config.userEmails()
                    let merged = EmailAddresses.normalize(current + found)
                    guard merged == current || Config.update(path: entry.path, value: merged) else {
                        editor?.report(localised("Could not save the addresses.", "Не удалось сохранить адреса."), error: true)
                        return
                    }
                    SetupState.markCalendarEmailsImported()
                    editor?.show(merged)
                    editor?.report(found.isEmpty
                        ? localised("No addresses found. You can add them manually.", "Адреса не найдены. Их можно добавить вручную.")
                        : localised("Found \(found.count) addresses. The list has been updated.", "Найдено адресов: \(found.count). Список обновлён."))
                }
            }
            return editor
        }
        switch entry.kind {
        case .toggle:
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(controlChanged(_:))
            return toggle

        case .choice(let options):
            let popup = NSPopUpButton()
            popup.addItems(withTitles: options)
            for item in popup.itemArray {
                let raw = item.title
                item.representedObject = raw
                switch entry.path {
                case ["interface_theme"]:
                    item.title = raw == "system" ? localised("System", "Системная") : raw == "light" ? localised("Light", "Светлая") : localised("Dark", "Тёмная")
                case ["interface_language"]:
                    item.title = raw == "auto" ? localised("System", "Как в системе") : raw == "ru" ? "Русский" : "English"
                case ["system_audio"]:
                    item.title = raw == "app" ? localised("Call application", "Приложение звонка") : localised("All Mac audio", "Весь звук Mac")
                default: break
                }
            }
            popup.target = self
            popup.action = #selector(controlChanged(_:))
            return popup

        case .number, .text, .list:
            let field = NSTextField()
            // The grey text in an empty field is the default itself: where
            // it is a real value it can be read and copied, and where it is a
            // sentence ("the language of the meeting") that sentence is the
            // honest answer to what happens if you leave the field alone.
            field.placeholderString = SettingsSchema.describeDefault(entry)
            field.delegate = self
            field.target = self
            field.action = #selector(controlChanged(_:))
            return field

        case .multilineText:
            let field = NSTextField()
            field.usesSingleLineMode = false
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 14
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.delegate = self
            field.target = self
            field.action = #selector(controlChanged(_:))
            field.heightAnchor.constraint(equalToConstant: 210).isActive = true
            return field
        }
    }

    // MARK: - reading and writing

    /// Redraw every control from the config file.
    private func refresh() {
        let config = Config.raw()
        for row in rows {
            if let editor = row.control as? EmailAddressesEditor {
                editor.show(Config.userEmails())
                continue
            }
            if (row.control as? NSTextField)?.currentEditor() != nil { continue }
            let stored = value(at: row.entry.path, in: config)
            switch row.entry.kind {
            case .toggle:
                let on = stored as? Bool ?? row.entry.defaultValue as? Bool ?? false
                (row.control as? NSSwitch)?.state = on ? .on : .off
            case .choice:
                let selected = stored as? String ?? row.entry.defaultValue as? String
                if let selected, let popup = row.control as? NSPopUpButton {
                    if let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) { popup.selectItem(at: index) }
                    else { popup.selectItem(withTitle: selected) }
                }
            case .list:
                let items = stored as? [String] ?? []
                row.control.stringValue = items.joined(separator: ", ")
            case .number, .text:
                row.control.stringValue = stored.map { "\($0)" } ?? ""
            case .multilineText:
                row.control.stringValue = stored as? String
                    ?? row.entry.defaultValue as? String ?? ""
            }
        }
        let stray = SettingsSchema.strayKeys(in: config)
        let strayNotice = stray.isEmpty ? ""
            : localised("Not read by this version: ", "Эта версия не читает: ") + stray.joined(separator: ", ")
        let notices = (Config.problems().map(\.explanation) + [restartNotice, strayNotice])
            .filter { !$0.isEmpty }.joined(separator: "\n")
        refreshModels()
        for notice in pageNotices {
            notice.stringValue = notices
            notice.isHidden = notices.isEmpty
        }
        for (entry, view) in providerRows { view.isHidden = !providerIsSelected(entry.path) }
    }

    private func providerIsSelected(_ path: [String]) -> Bool {
        if path.first == "transcription", path.count > 2 {
            return Config.transcriptionEnabled() && path[1] == Config.transcriptionCloudProvider()
        }
        guard path.first == "summary", let leaf = path.last else { return true }
        if !Config.summary().enabled || Config.summary().backend == "none" { return false }
        let backend = Config.summary().backend
        if leaf.hasPrefix("ollama_") { return backend == "ollama" || backend == "auto" }
        if leaf.hasPrefix("openai_") { return backend == "openai-api" || backend == "auto" }
        if leaf == "api_key_path" { return backend == "anthropic-api" || backend == "auto" }
        return true
    }

    private func value(at path: [String], in config: [String: Any]) -> Any? {
        var node: Any? = config
        for key in path {
            guard let object = node as? [String: Any] else { return nil }
            node = object[key]
        }
        return node
    }

    @objc private func controlChanged(_ sender: NSControl) {
        commit(rows[sender.tag])
    }

    /// Enter isn't the only way to leave a text field, and a setting that took
    /// effect only when you remembered to press it would be a bug people
    /// blamed on the recorder.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSControl else { return }
        commit(rows[field.tag])
    }

    /// `NSTextField` normally treats Return as "finish editing", even when
    /// it wraps. The summary prompt is prose, so Return has to remain a real
    /// newline while leaving the field still commits in the usual way.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard rows.indices.contains(control.tag),
              rows[control.tag].entry.kind.isMultiline,
              commandSelector == #selector(NSResponder.insertNewline(_:))
        else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    private func commit(_ row: Row) {
        let entry = row.entry
        let input: SettingsSchema.Input
        switch entry.kind {
        case .toggle:
            input = .flag((row.control as? NSSwitch)?.state == .on)
        case .choice:
            input = .choice((row.control as? NSPopUpButton)?.selectedItem?.representedObject as? String ?? (row.control as? NSPopUpButton)?.titleOfSelectedItem ?? "")
        case .number, .text, .multilineText, .list:
            input = .text(row.control.stringValue)
        }

        let resolution = SettingsSchema.resolve(input, for: entry)
        if case .invalid = resolution {
            // Letters in a number field: put back what is actually stored
            // rather than writing a guess or leaving the field lying.
            refresh()
            return
        }
        // Leaving a field is not deciding anything. This is reached whenever
        // editing ends — a tab switch, another window, the window closing —
        // and a row still showing what the file already says has nothing to
        // commit.
        guard SettingsSchema.changes(
            resolution, from: value(at: entry.path, in: Config.raw()))
        else { return }

        switch resolution {
        case .set(let value): Config.update(path: entry.path, value: value)
        case .clear: Config.update(path: entry.path, value: nil)
        case .invalid: return
        }

        if entry.needsRestart {
            restartNotice = localised(
                "“\(entry.label)” applies the next time verbemo starts.",
                "«\(entry.label)» подействует при следующем запуске verbemo.")
        }
        // Clearing can change what a field should show — an emptied field goes
        // back to displaying its default as a placeholder — and a nested
        // object may have just disappeared from the file entirely. The write
        // above has already redrawn every other surface, this one included;
        // an invalid entry never reaches it, which is why the guard clause
        // redraws by hand.
        refresh()
    }

}
