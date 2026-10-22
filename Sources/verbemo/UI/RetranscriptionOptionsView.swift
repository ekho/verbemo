import AppKit

/// This sheet only snapshots choices. Downloads stay on Files and Models.
@MainActor final class RetranscriptionOptionsView: NSStackView {
    let enginePicker = NSPopUpButton()
    let diarizationPicker = NSPopUpButton()
    let status = NSTextField(wrappingLabelWithString: "")
    var onValidation: ((Bool) -> Void)?
    private let session: URL
    private var validation: Task<Void, Never>?
    private(set) var request: TranscriptVersions.Request?

    init(session: URL, engine: String?) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 410, height: 178))
        orientation = .vertical
        alignment = .leading
        spacing = 8
        enginePicker.identifier = .init("retranscription.engine")
        enginePicker.addItem(withTitle: localised("Use transcription settings", "По настройкам расшифровки"))
        for choice in MeetingLibraryController.retranscriptionEngines {
            let locality = Config.localEngines.contains(choice.id)
                ? localised(" · on Mac", " · на Mac")
                : localised(" · sends audio to cloud", " · аудио отправляется в облако")
            enginePicker.addItem(withTitle: choice.title + locality)
            enginePicker.lastItem?.representedObject = choice.id
        }
        if let engine, let index = enginePicker.itemArray.firstIndex(where: { $0.representedObject as? String == engine }) {
            enginePicker.selectItem(at: index)
        }
        diarizationPicker.identifier = .init("retranscription.diarization")
        diarizationPicker.addItems(withTitles: [localised("Use diarization settings", "По настройкам диаризации"),
            localised("Off for this job", "Отключена для этого задания")] + DiarizationModel.allCases.map(\.title))
        for picker in [enginePicker, diarizationPicker] {
            picker.target = self
            picker.action = #selector(changed)
        }
        let engineLabel = localised("Transcription engine", "Способ распознавания")
        let speakersLabel = localised("Diarization for this job", "Диаризация для этого задания")
        enginePicker.setAccessibilityLabel(engineLabel)
        diarizationPicker.setAccessibilityLabel(speakersLabel)
        status.identifier = .init("retranscription.availability")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        for view in [NSTextField(labelWithString: engineLabel), enginePicker,
                     NSTextField(labelWithString: speakersLabel), diarizationPicker, status] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func selectedRequest() -> TranscriptVersions.Request {
        let engine = enginePicker.selectedItem?.representedObject as? String
            ?? EngineResolver.configuredEngine(for: session)
        let selection = diarizationPicker.indexOfSelectedItem
        if selection == 0 { return .capture(engine: engine) }
        let model = selection > 1 ? DiarizationModel.allCases[selection - 2] : nil
        return .init(engine: engine, diarization: model.map {
            .init(engine: engine, threshold: Config.diarizationThreshold(), explicit: true, model: $0)
        })
    }

    @objc func changed() {
        validation?.cancel()
        request = nil
        onValidation?(false)
        let selected = selectedRequest()
        status.stringValue = localised("Checking model…", "Проверяю модель…")
        validation = Task { [weak self] in
            let reason = await Self.refusal(for: selected)
            guard !Task.isCancelled, let self else { return }
            request = reason == nil ? selected : nil
            status.stringValue = reason ?? (selected.diarization.map {
                localised("Installed: ", "Установлена: ") + $0.model.title + ". "
                    + localised("Saved only for this job.", "Сохранится только для этого задания.")
            } ?? localised("Local diarization is off. Cloud services may include their own speaker labels.",
                           "Локальная диаризация отключена. Облачный сервис может добавлять свои метки голосов."))
            onValidation?(reason == nil)
        }
    }

    static func refusal(for request: TranscriptVersions.Request) async -> String? {
        guard let selected = request.diarization else { return nil }
        guard Platform.supportsLocalModels, Config.localEngines.contains(request.engine) else {
            return localised("Choose a local transcription engine for local diarization.",
                             "Для локальной диаризации выберите локальный способ распознавания.")
        }
        if selected.model == .nemotron3, NemotronDiarizationRunner.bundledExecutable == nil {
            return localised("The Nemotron runtime is unavailable in this build.",
                             "В этой сборке недоступен модуль Nemotron.")
        }
        guard await DiarizationModelStore.shared(for: selected.model).isReady() else {
            return localised("First download ", "Сначала скачайте ") + selected.model.title
                + localised(" in Files and Models.", " в разделе «Файлы и модели».")
        }
        return nil
    }
}
