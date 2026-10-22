import AppKit
import FluidAudio
import Foundation

/// Permission onboarding and Journal settings share their actions and model state.
/// macOS grants must be requested by the process that will record the meeting.
@MainActor
final class SetupForm: NSObject, NSTextFieldDelegate {
    /// Whether a recording is in progress. Registering at login and testing
    /// system audio both disturb a running recording, and nothing in this
    /// form is worth losing a meeting for.
    var isRecording: (() -> Bool)?
    /// Called whenever anything a host displays *about* the form may have
    /// changed — what is still outstanding, what the next action is. The
    /// setup page's footer and the settings model inventory follow it.
    var onStateChange: (() -> Void)?
    var onOpenFolder: (() -> Void)?

    /// What the config says about transcription, and how to change it.
    ///
    /// The pair is one seam rather than two because the transcription
    /// switches only work as a loop: a click writes the choice and then
    /// redraws the switches from what it wrote. Replacing only the writing
    /// would leave a test watching the form redraw from the config file of
    /// whoever is running the suite — which is also the reason the bug this
    /// pair exists to keep out shipped in the first place.
    var storedTranscription: @MainActor () -> TranscriptionChoice = {
        TranscriptionChoice.read(
            engine: Config.transcriptionEngine(),
            cloudProvider: Config.transcriptionCloudProvider(),
            enabled: Config.transcriptionEnabled(),
            localModels: Platform.supportsLocalModels,
            localEngine: Config.transcriptionLocalEngine())
    }
    var write: @MainActor ([String], Any?) -> Void = { Config.update(path: $0, value: $1) }

    /// Whether the local model is on this Mac, and how to put it there. Also
    /// a seam, for the same reason and one more: the click that has to be
    /// got right is the one made with no model on the disk, and it starts a
    /// download — which a test has to be able to answer without pulling 460
    /// megabytes over the network.
    var parakeetIsHere: @MainActor () -> Bool = {
        let version = ParakeetEngine.configuredVersion()
        return AsrModels.modelsExist(
            at: ParakeetEngine.cacheDirectory(for: version), version: version)
    }
    var fetchParakeet: @MainActor () async throws -> Void = {
        _ = try await AsrModels.downloadAndLoad(to: ParakeetEngine.cacheDirectory(for: ParakeetEngine.configuredVersion()), version: ParakeetEngine.configuredVersion())
    }

    /// How a pasted key is put to the service it is for. A seam because the
    /// answer decides what is written where, and a test has to be able to
    /// say "that key works" without a network or a real key — which is the
    /// only way to check that a key for one purpose lands in that purpose's
    /// file and no other.
    var checkKey: @MainActor (Credentials.Check) async -> Credentials.Verdict = { check in
        await check.ask()
    }

    /// The system-audio test: a tone out of the speakers and a tap listening
    /// for it. A seam so a test can prove when it is *not* played without
    /// playing it.
    var playTestTone: @MainActor () async -> SetupPermissions.SystemAudioResult = {
        await SetupPermissions.testSystemAudio()
    }
    var loginItemStatus: () -> LoginItem.State = { LoginItem.status() }
    var setLoginItemEnabled: (Bool) throws -> LoginItem.State = {
        try $0 ? LoginItem.register() : LoginItem.unregister()
    }
    var openLoginItemSettings: () -> Void = { LoginItem.openSettings() }
    private var loginItemError: String?

    /// The form itself, for a host to put in a scroll view.
    let view = FlippedStackView()

    /// Active downloads also protect the model inventory from deletion.
    var hasModelDownloads: Bool { parakeetDownload != nil || whisperDownloadTask != nil || gigaAMDownloadTask != nil || liveDownloading || !diarizationDownloads.isEmpty }
    private var formWindow: NSWindow? { view.window ?? settingsPages.values.compactMap(\.window).first }
    private var storageControls: [String: (view: NSView, button: NSButton, note: NSTextField, model: ModelStorage.Model)] = [:]
    private lazy var liveDownloadProgress = ModelDownloadProgress(model: "Nemotron 3.5 ASR", identifier: "live.cancel", target: self, action: #selector(cancelLiveDownload))
    private var configWatch: ConfigWatch.Token?
    /// Redraws this copy when verbemo comes back to the front. Every grant the
    /// Access rows ask for is given somewhere else — System Settings, a
    /// Login Items switch — and the person comes back from there to a window
    /// that went on saying the microphone was denied until something else
    /// happened to redraw it. Coming back is the moment to look again.
    private var activation: ConfigWatch.Token?

    private let launchSwitch = NSSwitch()
    private let launchDetail = SetupLayout.detail("", lines: 3, width: 520)
    private let micRow = AccessRow(
        title: localised("Microphone", "Микрофон"),
        detail: localised("Your side of the call.", "Ваша сторона разговора."),
        action: localised("Allow", "Разрешить"),
        grantedNote: localised("allowed", "разрешено"))
    private let audioRow = AccessRow(
        title: localised("System audio", "Звук системы"),
        detail: "",
        action: localised("Allow and test", "Разрешить и проверить"),
        grantedNote: localised("heard the tone", "тон услышан"))
    private let calendarRow = AccessRow(
        title: localised("Calendar", "Календарь"),
        detail: localised(
            "Names the folder and the speakers from the invitees.",
            "По участникам события называет папку и говорящих."),
        action: localised("Allow", "Разрешить"),
        grantedNote: localised("allowed", "разрешено"),
        optional: true)

    private let cloudSwitch = NSSwitch()
    private let cloudStatus = NSTextField(labelWithString: "")
    private let providerCards = ChoiceGroup()
    private var cloudKeys: [String: NSSecureTextField] = [:]
    private var cloudKeyStatuses: [String: NSTextField] = [:]
    private var cloudKeyChecks: [String: (operation: UUID, key: String, slot: Credentials.Slot)] = [:]
    /// The provider waiting for a key. Set when a card or the switch is
    /// clicked for a service with no key yet. Cloud processing waits for a
    /// validated key; switching from local mode first disables that mode.
    private var pendingProvider: String?
    /// The provider in force, read back from the config on every refresh.
    private var provider = "assemblyai"
    private let localSwitch = NSSwitch()
    private let localEngineCards = ChoiceGroup()
    private var localDownloadButtons: [String: NSButton] = [:]
    private var localDownloadProgress: [String: ModelDownloadProgress] = [:]
    private var localDownloadOperations: [String: UUID] = [:]
    private var localDownloadErrors: [String: String] = [:]

    private let language = NSPopUpButton()
    private let languageNote = NSTextField(labelWithString: "")
    private let keepAudio = NSSwitch()
    private let liveTranscription = NSSwitch()
    private let liveStatus = NSTextField(labelWithString: "")
    private let diarizationSwitch = NSSwitch()
    private let diarizationDetail = SetupLayout.detail("", lines: 2, width: 440)
    private let diarizationCards = ChoiceGroup()
    private var diarizationDownloadButtons: [DiarizationModel: NSButton] = [:]
    private var diarizationDownloadProgress: [DiarizationModel: ModelDownloadProgress] = [:]
    private var diarizationDownloads: [DiarizationModel: Task<Void, Never>] = [:]
    private var diarizationOperations: [DiarizationModel: UUID] = [:]
    private var diarizationErrors: [DiarizationModel: String] = [:]
    var diarizationIsHere: @MainActor (DiarizationModel) -> Bool = { model in
        DiarizationModelStore.isReady(at: DiarizationModelStore.shared(for: model).directory, model: model)
    }
    var fetchDiarization: @MainActor (DiarizationModel, @escaping @Sendable (Double) -> Void) async throws -> Void = {
        model, progress in
        try await DiarizationModelStore.shared(for: model).download(progress: progress)
    }
    var liveModelStore = NemotronModelStore()
    /// What the models on this Mac weigh, for the two rows that say so. The
    /// figure in each row's prose is what a download will cost; this is what
    /// it did cost, and only this one can be trusted once the files exist.
    private let modelStorage = ModelStorage()
    private let whisperModelStore = WhisperModelStore()
    private let gigaAMModelStore = GigaAMModelStore()
    private var whisperDownloadTask: Task<Void, Never>?
    private var gigaAMDownloadTask: Task<Void, Never>?
    private var nemotronDownloads: [String: Task<Void, Never>] = [:]
    private var nemotronOperations: [String: UUID] = [:]
    private var nemotronObserver: ConfigWatch.Token?
    private var liveDownloading: Bool { !nemotronDownloads.isEmpty || liveModelStore.isDownloading }
    private lazy var nemotronFilesProgress = ModelDownloadProgress(model: "Nemotron 3.5 ASR", identifier: "nemotron.files.cancel", target: self, action: #selector(cancelNemotronFiles))
    /// What parakeet weighs on disk once it is there — measured, not quoted:
    /// 461 MB for v3, and v2 is the same 0.6B model. The bar is the cache
    /// directory growing towards this number, so a figure taken from
    /// somewhere else is a bar that stops three quarters of the way and a
    /// count that never reaches what it promised.
    private static let parakeetMegabytes = 460

    /// The bar's clock, which is only worth running while somebody can see
    /// the bar.
    private var parakeetProgress: Timer?
    /// The download itself, which is not the same thing as its bar. It used
    /// not to be kept at all: closing the window stopped the timer, the form
    /// took that to mean nothing was downloading, and opening it again
    /// offered a second fetch of the same 460 megabytes into the same cache
    /// while the first was still running.
    private var parakeetDownload: Task<Void, Never>?

    private let summariesOn = NSSwitch()
    private let summaryCards = ChoiceGroup()
    private let keyProvider = NSSegmentedControl(
        labels: ["OpenAI", "Anthropic", "OpenAI-compatible"],
        trackingMode: .selectOne, target: nil, action: nil)
    private let summaryKey = NSSecureTextField()
    private let summaryKeyStatus = NSTextField(labelWithString: "")
    private let summaryOpenAIBaseURL = NSTextField()
    private let summaryOpenAIModel = NSTextField()
    private let summaryOpenAIOptions = NSStackView()
    private var summaryOpenAIBaseURLRow: NSView?
    private let summaryOllamaBaseURL = NSTextField()
    private let summaryOllamaModel = NSTextField()
    private lazy var summaryKeyLink = link(
        localised("Get a key", "Получить ключ"),
        "https://console.anthropic.com/settings/keys")

    private let recordingsPath = NSTextField(labelWithString: "")
    private let menuBarIcon = NSSwitch()
    private let dockIcon = NSSwitch()
    /// Says what is left when both icons are off. Present only then: it is a
    /// consequence, not a warning, and a line explaining how to get back to a
    /// window you are looking at is noise until it is the only way.
    private let noIconsNote: NSTextField = {
        let label = SetupLayout.status()
        label.lineBreakMode = .byWordWrapping
        // Keep the way back into the app readable on narrow settings pages.
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 520
        return label
    }()
    private let autoRecord = NSSwitch()

    /// What is wrong with the config file, above everything else in the form:
    /// while it stands, the switches below show defaults rather than the
    /// file, and none of them can be saved. See `Config.Problem`.
    private let configProblems: NSTextField = {
        let label = SetupLayout.status()
        label.textColor = .systemOrange
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 520
        label.isHidden = true
        return label
    }()

    /// What the last look for `claude`, `codex` and ollama found, by card.
    /// Empty until that look finishes, and a missing answer is not "absent":
    /// the window says nothing about a tool it has not been to see yet.
    private var summaryToolRuns: [String: Bool] = [:]


    enum Mode { case settings, permissions }
    private let mode: Mode
    private let parakeetVersion = NSPopUpButton()
    private var cloudOptions: NSView?
    private var localOptionsView: NSView?
    private var diarizationOptions: NSView?
    private var summaryOptions: NSView?
    private var summaryKeyFields: NSView?
    private var summaryOllamaFields: NSView?
    private(set) var settingsPages: [ApplicationNavigationState.Destination: FlippedStackView] = [:]
    static var settingsCoveredPaths: Set<String> {
        var paths: Set<String> = ["auto_record.enabled", "recordings_dir", "keep_audio", "menu_bar_icon", "dock_icon",
            "transcription.enabled", "transcription.engine", "transcription.cloud", "transcription.language", "summary.enabled", "summary.backend",
            "summary.openai_base_url", "summary.openai_model", "summary.openai_compatible", "summary.ollama_base_url", "summary.ollama_model"]
        if Platform.supportsLocalModels {
            paths.formUnion(["transcription.local_engine", "transcription.model", "transcription.local_diarization", "transcription.diarization_model", "live_transcription.enabled"])
        }
        return paths
    }
    init(mode: Mode) {
        self.mode = mode
        super.init()

        let form = view
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = SetupLayout.sectionGap
        form.edgeInsets = NSEdgeInsets(
            top: 22, left: SetupLayout.gutter, bottom: 22, right: SetupLayout.gutter)

        micRow.identifier = NSUserInterfaceItemIdentifier("access.microphone")
        audioRow.identifier = NSUserInterfaceItemIdentifier("access.system-audio")
        calendarRow.identifier = NSUserInterfaceItemIdentifier("access.calendar")
        if mode == .permissions {
            let title = NSTextField(wrappingLabelWithString: localised("Hear the conversation.\nKeep what matters.", "Слышать разговор.\nНе упускать главное."))
            title.font = JournalStyle.titleFont(32)
            title.textColor = JournalStyle.ink
            let intro = SetupLayout.detail(localised(
                "Allow the microphone and test call audio before your first recording. Models and optional Calendar access are available in Settings.",
                "Перед первой записью разрешите микрофон и проверьте звук звонка. Модели и необязательный доступ к календарю доступны в настройках."), lines: 4)
            for child in [title, intro, configProblems, SetupLayout.box([micRow, audioRow])] {
                form.addArrangedSubview(child)
                child.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -48).isActive = true
            }
        } else {
            func page(_ destination: ApplicationNavigationState.Destination, _ content: [NSView]) {
                let page = FlippedStackView(views: content)
                page.orientation = .vertical
                page.alignment = .leading
                page.spacing = SetupLayout.sectionGap
                page.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
                for child in content { child.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -48).isActive = true }
                settingsPages[destination] = page
            }
            page(.general, [SetupLayout.box([startAtLoginRow(), menuBarIconRow(), dockIconRow()]), noIconsNote])
            page(.recording, [SetupLayout.box([micRow, audioRow]), SetupLayout.box([autoRecordRow()])])
            page(.calendar, [SetupLayout.box([calendarRow])])
            var transcription = [SetupLayout.section(localised("Transcription models", "Модели расшифровки"), content: transcriptionRows())]
            if Platform.supportsLocalModels {
                transcription.append(SetupLayout.section(localised("Diarization", "Диаризация"), content: SetupLayout.box([diarizationRow()])))
                transcription.append(SetupLayout.section(localised("During the meeting", "Во время встречи"), content: SetupLayout.box([liveTranscriptionRow()])))
            }
            transcription.append(SetupLayout.box([languageRow()]))
            page(.transcription, transcription)
            page(.summary, [SetupLayout.section(localised("Summary", "Сводка"), leading: summariesOn, content: summaryChoices())])
            page(.storage, [SetupLayout.box([folderRow(), keepAudioRow()])])
        }

        // Names for the switches that do not depend on the words beside
        // them, so a test can find a switch without walking up from its
        // label through however many stacks the layout has this week.
        for (toggle, name) in [
            (launchSwitch, "access.login.toggle"),
            (cloudSwitch, "transcription.cloud"), (localSwitch, "transcription.local"),
            (liveTranscription, "transcription.live"),
            (diarizationSwitch, "transcription.local-diarization"),
            (keepAudio, "files.keep-audio"),
            (summariesOn, "summary.enabled"), (menuBarIcon, "icons.menu-bar"),
            (dockIcon, "icons.dock"), (autoRecord, "auto-record"),
        ] {
            toggle.identifier = NSUserInterfaceItemIdentifier(name)
        }
        wireActions()
        refresh()
        let home = Home.current
        nemotronObserver = ConfigWatch.Token(NotificationCenter.default.addObserver(
            forName: NemotronModelStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { Home.$scoped.withValue(home) { self?.refresh() } }
        })
        configWatch = ConfigWatch.observe { [weak self] in self?.refresh() }
        // A token of the same kind as the config watch's: it ends the
        // observation when the form goes.
        activation = ConfigWatch.Token(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
    }

    /// Only a form somebody can see: asking whether a login item is
    /// registered is a round trip to another daemon, and a window that is
    /// closed will be redrawn by `reload` when it opens anyway.
    func cameBack() {
        guard formWindow?.isVisible == true else { return }
        refresh()
    }

    /// Re-read the machine and the config file. A host calls this when the
    /// form comes back on screen: the menu and the status window both write
    /// `auto_record.enabled`, and a form showing yesterday's answer is worse
    /// than no form at all.
    func reload() {
        if parakeetDownload?.isCancelled == false, parakeetProgress == nil {
            watchParakeetSize()
        }
        refresh()
        if mode == .permissions { return }
        // Detection runs off the main thread: finding `claude` can mean
        // starting the login shell, and a form that freezes while it asks
        // would be a worse first impression than one that fills in.
        Task { await detectTools() }
    }

    /// Pause polling when the host puts the form away.
    ///
    /// The Parakeet download itself is left running; `reload` restores its
    /// progress poll. The other local downloads pause when setup closes.
    func stop() {
        parakeetProgress?.invalidate()
        parakeetProgress = nil
        whisperDownloadTask?.cancel()
        localDownloadProgress["whisper"]?.cancelling()
        gigaAMDownloadTask?.cancel()
        localDownloadProgress["gigaam"]?.cancelling()
    }
    private func choiceCards(_ cards: [NSView]) -> NSView {
        SetupLayout.group(cards, spacing: SetupLayout.cardGap)
    }

    // MARK: - building

    /// The two questions this section actually asks: may audio leave this
    /// Mac, and should the local model be kept ready. Both are switches, and
    /// neither is a fallback setting — "the cloud when it answers, this Mac
    /// when it doesn't" is what having both on *means*, not a third option to
    /// pick.
    ///
    /// Each switch and its options share one block; settings collapse inactive options.
    private func transcriptionRows() -> NSView {
        cloudSwitch.target = self
        cloudSwitch.action = #selector(cloudToggled)
        cloudStatus.font = SetupLayout.statusFont
        cloudStatus.textColor = .secondaryLabelColor
        cloudStatus.lineBreakMode = .byTruncatingTail

        let cloudRow = SetupLayout.row(
            leading: cloudSwitch,
            title: SetupLayout.title(localised("In the cloud", "В облаке")),
            detail: SetupLayout.detail(
                localised(
                    "Audio is sent to the selected provider for transcription and diarization.",
                    "Звук отправляется выбранному провайдеру для расшифровки и диаризации."),
                lines: 2, width: 440),
            trailing: [cloudStatus])

        localSwitch.target = self
        localSwitch.action = #selector(localToggled)
        let localChoices = [
            ("parakeet", "Parakeet", localised("Local speech recognition", "Локальное распознавание речи")),
            ("whisper", "Whisper large-v3-turbo", localised(
                "Multilingual recognition · about \(ModelStorage.describe(bytes: modelStorage.whisperModel().advertisedBytes))",
                "Многоязычное распознавание · около \(ModelStorage.describe(bytes: modelStorage.whisperModel().advertisedBytes))")),
            ("gigaam", "GigaAM v3", localised(
                "Alternative for Russian · about \(ModelStorage.describe(bytes: modelStorage.gigaAMModel().advertisedBytes))",
                "Альтернатива для русского · около \(ModelStorage.describe(bytes: modelStorage.gigaAMModel().advertisedBytes))")),
            ("nemotron", NemotronModelStore.title, localised(
                "Shares the downloaded model with live transcription",
                "Общая модель с живой расшифровкой")),
        ]
        let localCards = localChoices.map { id, title, detail in
            let download = SetupLayout.actionButton(
                localised("Download…", "Скачать…"),
                target: self,
                action: #selector(downloadLocalClicked(_:)))
            download.identifier = NSUserInterfaceItemIdentifier("transcription.download.\(id)")
            localDownloadButtons[id] = download
            let progress = ModelDownloadProgress(
                model: title, identifier: "transcription.cancel.\(id)",
                target: self, action: #selector(cancelLocalClicked(_:)))
            localDownloadProgress[id] = progress
            var accessories: [NSView] = [download, progress]
            if id == "parakeet" {
                parakeetVersion.addItems(withTitles: ["v3", "v2"])
                parakeetVersion.identifier = .init("transcription.model")
                parakeetVersion.setAccessibilityLabel(localised("Parakeet version", "Версия Parakeet"))
                parakeetVersion.target = self
                parakeetVersion.action = #selector(parakeetVersionChanged)
                accessories.insert(parakeetVersion, at: 0)
            }
            return ChoiceCard(id: id, title: title, detail: detail, accessories: accessories)
        }
        localEngineCards.adopt(localCards)
        localEngineCards.onChange = { [weak self] id in self?.localEnginePicked(id) }

        let localRow = SetupLayout.row(
            leading: localSwitch,
            title: SetupLayout.title(localised("On this Mac", "На этом маке")),
            detail: SetupLayout.detail(
                localised(
                    "Audio is processed on this Mac. Diarization can be enabled below.",
                    "Звук обрабатывается на этом Mac. Диаризацию можно включить ниже."),
                lines: 2, width: 440),
            trailing: [])

        let localOptions = NSStackView(views: [choiceCards(localEngineCards.cards)])
        localOptions.orientation = .vertical
        localOptions.alignment = .leading
        localOptions.spacing = 9
        localOptionsView = localOptions
        localOptions.edgeInsets = NSEdgeInsets(top: 0, left: 58, bottom: 13, right: 14)
        for option in localOptions.arrangedSubviews {
            option.widthAnchor.constraint(
                equalTo: localOptions.widthAnchor, constant: -72).isActive = true
        }

        let localBlock = NSStackView(views: [localRow, localOptions])
        localBlock.orientation = .vertical
        localBlock.alignment = .leading
        localBlock.spacing = 0
        for row in localBlock.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: localBlock.widthAnchor).isActive = true
        }

        let cloudBlock = SetupLayout.group([cloudRow, providerRow()], spacing: 0)
        return SetupLayout.box([cloudBlock, localBlock])
    }

    /// Each provider owns its editor, so drafts and checks cannot follow a selection.
    private func providerRow() -> NSView {
        let assembly = ChoiceCard(
            id: "assemblyai",
            title: "AssemblyAI",
            detail: localised(
                "$0.23 an hour. No limit on meeting length.",
                "$0,23 за час. Без ограничения на длину встречи."),
            accessories: providerKeyControls(
                "assemblyai", title: "AssemblyAI", keyURL: "https://www.assemblyai.com/dashboard/signup"))
        let openai = ChoiceCard(
            id: "openai",
            title: "OpenAI",
            detail: localised(
                "$0.36 an hour. Same key as summaries.",
                "$0,36 за час. Тот же ключ, что и для сводки."),
            accessories: providerKeyControls(
                "openai", title: "OpenAI", keyURL: "https://platform.openai.com/api-keys"))
        let elevenlabs = ChoiceCard(
            id: "elevenlabs",
            title: "ElevenLabs",
            detail: localised(
                "Scribe v2. $0.44 an hour for a two-channel call.",
                "Scribe v2. $0,44 за час разговора с двумя каналами."),
            accessories: providerKeyControls(
                "elevenlabs", title: "ElevenLabs", keyURL: "https://elevenlabs.io/app/developers/api-keys"))
        providerCards.adopt([assembly, openai, elevenlabs])
        providerCards.onChange = { [weak self] id in self?.providerPicked(id) }

        let stack = NSStackView(views: [choiceCards(providerCards.cards)])
        cloudOptions = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // Indented to the width of a switch plus its gap, so the cards read as
        // the cloud row's detail rather than as a third choice beside it.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 58, bottom: 13, right: 14)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -72).isActive = true
        }
        return stack
    }

    private func providerKeyControls(_ id: String, title: String, keyURL: String) -> [NSView] {
        let field = NSSecureTextField()
        field.identifier = .init("transcription.key.\(id)")
        field.setAccessibilityLabel(localised("\(title) API key", "API-ключ \(title)"))
        field.font = SetupLayout.detailFont
        field.delegate = self
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cloudKeys[id] = field

        let status = SetupLayout.status()
        status.identifier = .init("transcription.key.\(id).status")
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 0
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cloudKeyStatuses[id] = status
        return [field, status, link(localised("Get a key", "Получить ключ"), keyURL)]
    }

    /// A menu rather than the two-letter code this used to ask for. The code
    /// was never a question anybody could answer from the window: nothing said
    /// whether it wanted `ru`, `rus` or `ru-RU`, and a typo went to stderr,
    /// where nobody was reading. What is stored is still the code.
    private func languageRow() -> NSView {
        let label = SetupLayout.title(localised("Meeting language", "Язык встреч"))

        language.target = self
        language.action = #selector(languageChanged)
        language.identifier = NSUserInterfaceItemIdentifier("transcription.language")
        language.setAccessibilityLabel(label.stringValue)
        buildLanguageMenu()

        languageNote.font = SetupLayout.statusFont
        languageNote.textColor = .secondaryLabelColor
        languageNote.lineBreakMode = .byWordWrapping
        languageNote.maximumNumberOfLines = 0
        languageNote.preferredMaxLayoutWidth = 520
        languageNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let picker = NSStackView(views: [label, language])
        picker.orientation = .vertical
        picker.alignment = .leading
        picker.spacing = 6
        return SetupLayout.row(title: picker, detail: languageNote)
    }

    /// Detect first, then the five languages verbemo is actually used in, then
    /// the alphabet. Each item carries its own config value, so the menu can
    /// be reordered without a table of indices to keep in step with it.
    private func buildLanguageMenu() {
        let menu = NSMenu()
        let detect = NSMenuItem(
            title: localised("Detect automatically", "Определять автоматически"),
            action: nil, keyEquivalent: "")
        menu.addItem(detect)
        menu.addItem(.separator())
        for (index, choice) in MeetingLanguages.menu.enumerated() {
            if index == MeetingLanguages.pinned.count { menu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
            item.representedObject = choice.code
            menu.addItem(item)
        }
        language.menu = menu
    }

    private var selectedLanguage: String? {
        language.selectedItem?.representedObject as? String
    }

    private func liveTranscriptionRow() -> NSView {
        liveTranscription.target = self
        liveTranscription.action = #selector(liveTranscriptionToggled)
        liveStatus.font = SetupLayout.statusFont
        liveStatus.textColor = .secondaryLabelColor
        liveStatus.lineBreakMode = .byTruncatingTail

        return SetupLayout.row(
            leading: liveTranscription,
            title: SetupLayout.title(localised(
                "I want a live transcript during meetings",
                "Показывать расшифровку прямо во время встречи")),
            detail: SetupLayout.detail(
                localised(
                    "Nemotron 3.5 ASR. Live and final transcription use the same downloaded files. The final-transcription model is selected independently.",
                    "Nemotron 3.5 ASR. Живая и итоговая расшифровка используют одни скачанные файлы. Модель для итоговой обработки выбирается отдельно."),
                lines: 2, width: 520),
            trailing: [liveStatus, liveDownloadProgress])
    }

    private func diarizationRow() -> NSView {
        diarizationSwitch.target = self
        diarizationSwitch.action = #selector(diarizationToggled)
        let cards = DiarizationModel.allCases.map { model in
            let download = SetupLayout.actionButton(
                localised("Download…", "Скачать…"), target: self,
                action: #selector(downloadDiarizationClicked(_:)))
            download.identifier = .init("transcription.diarization.download.\(model.rawValue)")
            diarizationDownloadButtons[model] = download
            let progress = ModelDownloadProgress(
                model: model.title,
                identifier: "transcription.diarization.cancel.\(model.rawValue)",
                target: self, action: #selector(cancelDiarizationClicked(_:)))
            diarizationDownloadProgress[model] = progress
            let size = ModelStorage.describe(bytes: model.advertisedBytes)
            let detail = localised(
                "(\(model.detailEnglish))\n\(model == .nemotron3 ? "Recommended · " : "")about \(size)",
                "(\(model.detailRussian))\n\(model == .nemotron3 ? "Рекомендуется · " : "")около \(size)")
            let card = ChoiceCard(id: "diarization.\(model.rawValue)", title: model.title,
                                  detail: detail, accessories: [download, progress])
            return card
        }
        diarizationCards.adopt(cards)
        diarizationCards.onChange = { [weak self] id in self?.diarizationModelPicked(id) }
        let row = SetupLayout.row(
            leading: diarizationSwitch,
            title: SetupLayout.title(localised(
                "Enable diarization", "Включить диаризацию")),
            detail: diarizationDetail)
        let options = NSStackView(views: [choiceCards(diarizationCards.cards)])
        diarizationOptions = options
        options.orientation = .vertical
        options.alignment = .leading
        options.edgeInsets = NSEdgeInsets(top: 0, left: 58, bottom: 13, right: 14)
        options.arrangedSubviews[0].widthAnchor.constraint(
            equalTo: options.widthAnchor, constant: -72).isActive = true
        let block = NSStackView(views: [row, options])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 0
        row.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        options.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return block
    }

    @objc private func diarizationToggled() {
        guard Platform.supportsLocalModels, transcriptionChoice.local,
              Config.problems().isEmpty else { refreshDiarization(); return }
        let enabled = diarizationSwitch.state == .on
        write(["transcription", "local_diarization"], enabled ? true : nil)
        refresh()
    }

    private func diarizationModelPicked(_ id: String) {
        guard let model = DiarizationModel(rawValue: String(id.dropFirst("diarization.".count))),
              diarizationSwitch.isEnabled, diarizationSwitch.state == .on,
              diarizationCards.card(id)?.isEnabled == true else { refreshDiarization(); return }
        write(["transcription", "diarization_model"], model.rawValue)
        refresh()
        downloadDiarizationIfNeeded(model)
    }

    @objc private func downloadDiarizationClicked(_ sender: NSButton) {
        let prefix = "transcription.diarization.download."
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix(prefix),
              let model = DiarizationModel(rawValue: String(raw.dropFirst(prefix.count))),
              sender.isEnabled else { return }
        downloadDiarizationIfNeeded(model)
    }

    private func downloadDiarizationIfNeeded(_ model: DiarizationModel) {
        guard Platform.supportsLocalModels, !Config.settingsUnknown,
              diarizationDownloads[model] == nil, !diarizationIsHere(model) else { return }
        let operation = UUID()
        diarizationErrors[model] = nil
        diarizationOperations[model] = operation
        diarizationDownloadProgress[model]?.begin()
        diarizationDownloads[model] = Task { [weak self, model, operation] in
            guard let self else { return }
            do {
                try await fetchDiarization(model) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.diarizationOperations[model] == operation,
                              self.diarizationDownloads[model]?.isCancelled == false else { return }
                        self.diarizationDownloadProgress[model]?.update(fraction)
                    }
                }
                try Task.checkCancellation()
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    diarizationErrors[model] = (error as? VerifiedModelStore.Error)?.description
                        ?? error.localizedDescription
                }
            }
            guard diarizationOperations[model] == operation else { return }
            diarizationDownloads[model] = nil
            diarizationOperations[model] = nil
            diarizationDownloadProgress[model]?.end()
            refreshDiarization()
            refreshStorageControls()
            onStateChange?()
        }
        refreshDiarization()
        refreshStorageControls()
    }

    @objc private func cancelDiarizationClicked(_ sender: NSButton) {
        let prefix = "transcription.diarization.cancel."
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix(prefix),
              let model = DiarizationModel(rawValue: String(raw.dropFirst(prefix.count))),
              let task = diarizationDownloads[model]
        else { return }
        task.cancel()
        diarizationDownloadProgress[model]?.cancelling()
    }

    private func refreshDiarization() {
        let localAvailable = Platform.supportsLocalModels && transcriptionChoice.local
            && Config.problems().isEmpty
        diarizationSwitch.isEnabled = localAvailable
        diarizationSwitch.state = Config.localDiarizationEnabled() ? .on : .off
        diarizationDetail.stringValue = !Platform.supportsLocalModels
            ? localised("Needs Apple Silicon.", "Нужен Apple Silicon.")
            : transcriptionChoice.local
            ? localised("Separates speech by speaker after local transcription. Audio stays on this Mac.",
                        "Разделяет речь по говорящим после локальной расшифровки. Звук остаётся на этом маке.")
            : localised("Available with On this Mac enabled.",
                        "Доступно при включённом «На этом Mac».")
        diarizationSwitch.setAccessibilityHelp(diarizationDetail.stringValue)
        diarizationCards.select("diarization.\(Config.diarizationModel().rawValue)")
        let enabled = localAvailable && diarizationSwitch.state == .on
        diarizationOptions?.isHidden = !enabled && diarizationDownloads.isEmpty
        for model in DiarizationModel.allCases {
            let card = diarizationCards.card("diarization.\(model.rawValue)")
            let button = diarizationDownloadButtons[model]
            let ready = diarizationIsHere(model)
            card?.isEnabled = enabled
            button?.isEnabled = enabled && diarizationDownloads[model] == nil && !ready
            button?.isHidden = ready || diarizationDownloads[model] != nil
            button?.title = diarizationErrors[model] == nil
                ? localised("Download…", "Скачать…")
                : localised("Retry…", "Повторить…")
            if diarizationDownloads[model] != nil {
                diarizationDownloadProgress[model]?.isHidden = false
                card?.report("")
            } else if ready {
                diarizationDownloadProgress[model]?.end()
                card?.report(localised("ready · ", "готова · ")
                    + ModelStorage.describe(bytes: modelStorage.diarizationModel(model).bytes), good: true)
            } else if let error = diarizationErrors[model] {
                diarizationDownloadProgress[model]?.end()
                card?.report(localised("download failed: ", "ошибка загрузки: ") + error)
            } else if !Platform.supportsLocalModels {
                diarizationDownloadProgress[model]?.end()
                card?.report(localised("needs Apple Silicon", "нужен Apple Silicon"))
            } else {
                diarizationDownloadProgress[model]?.end()
                card?.report("")
            }
        }
    }

    /// Where the recordings live, and the one thing worth saying about the
    /// default: it is outside Documents, Desktop and Downloads, so macOS never
    /// has to ask a background recorder for permission to write there.
    @objc private func openRecordingsFolder() { onOpenFolder?() }

    private func folderRow() -> NSView {
        recordingsPath.font = SetupLayout.monoFont
        recordingsPath.lineBreakMode = .byTruncatingMiddle

        folderDetail.stringValue = Self.folderAdvice
        return SetupLayout.row(
            symbol: "folder",
            title: recordingsPath,
            detail: folderDetail,
            trailing: (mode == .settings ? [SetupLayout.actionButton(
                localised("Open folder", "Открыть папку"),
                target: self, action: #selector(openRecordingsFolder))] : []) + [SetupLayout.actionButton(
                localised("Choose…", "Выбрать…"),
                target: self, action: #selector(chooseFolder))])
    }

    /// What the line under the folder says, until a folder is chosen during
    /// a recording and it has something more pressing to say.
    private static var folderAdvice: String {
        localised(
            "Outside Documents and Desktop, so macOS never has to ask.",
            "Вне Документов и Рабочего стола — macOS не будет спрашивать.")
    }

    private let folderDetail = SetupLayout.detail("", lines: 2)

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Config.resolveRoot(cliOverride: nil)
        panel.prompt = localised("Use folder", "Выбрать папку")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        // Store it the way a person would write it: a path under the home
        // directory stays readable, and stays right if the account is renamed.
        Config.update(path: ["recordings_dir"], value: Home.current.abbreviating(chosen.path))
        // Taken up at once when nothing is recording; a recording running now
        // finishes in the folder it started in, and that is worth saying
        // before somebody goes looking for it in the new one.
        folderDetail.stringValue = isRecording?() == true
            ? localised(
                "The recording in progress stays in the old folder; the next one goes here.",
                "Идущая запись останется в старой папке, следующая ляжет сюда.")
            : Self.folderAdvice
        refresh()
    }

    /// The one checkbox in a window of switches, and the only row whose words
    /// did not start where the words above them started — the checkbox stood
    /// in the column the folder symbol uses, and its title six points to the
    /// left of the path's. It is a switch now, and its label still toggles it.
    private func keepAudioRow() -> NSView {
        keepAudio.target = self
        keepAudio.action = #selector(keepAudioChanged)
        return SetupLayout.row(
            symbol: "waveform",
            title: SetupLayout.title(localised(
                "Keep the audio after transcribing", "Оставлять звук после расшифровки")),
            trailing: [keepAudio])
    }

    private func summaryChoices() -> NSView {
        let claude = ChoiceCard(
            id: "claude-cli",
            title: "Claude Code",
            detail: localised(
                "On the subscription you're already signed into. No key.",
                "По подписке, в которую вы уже вошли. Ключ не нужен."),
            accessories: [link(
                localised("Install it", "Установить"),
                "https://claude.com/product/claude-code")])
        let codex = ChoiceCard(
            id: "codex-cli",
            title: "Codex",
            detail: localised(
                "Same deal, on your OpenAI subscription.",
                "То же самое, но по подписке OpenAI."),
            accessories: [link(
                localised("Install it", "Установить"),
                "https://developers.openai.com/codex/cli/")])

        // Without this the switch still slides when you push it — NSSwitch
        // animates itself — while nothing at all happens: the choice is never
        // written, the cards below stay live, and every meeting is summarised
        // by a program the person just told to stop. It went unwired from the
        // day the section was built, because the only check for it was a
        // manual one nobody had run.
        summariesOn.target = self
        summariesOn.action = #selector(summariesToggled)

        keyProvider.selectedSegment = 1
        keyProvider.target = self
        keyProvider.action = #selector(keyProviderChanged)
        summaryKey.placeholderString = "sk-ant-…"
        summaryKey.identifier = NSUserInterfaceItemIdentifier("summary.key")
        summaryKeyStatus.identifier = NSUserInterfaceItemIdentifier("summary.key.status")
        summaryKey.font = SetupLayout.detailFont
        summaryKey.delegate = self
        summaryKeyStatus.font = SetupLayout.statusFont
        summaryKeyStatus.textColor = .secondaryLabelColor
        summaryKeyStatus.lineBreakMode = .byWordWrapping
        summaryKeyStatus.maximumNumberOfLines = 2
        configureSummaryField(summaryOpenAIBaseURL, id: "summary.openai_base_url")
        configureSummaryField(summaryOpenAIModel, id: "summary.openai_model")
        summaryOpenAIOptions.orientation = .vertical
        summaryOpenAIOptions.alignment = .leading
        summaryOpenAIOptions.spacing = 6
        let baseURLRow = summaryFieldRow(localised("Base URL", "URL сервера"), summaryOpenAIBaseURL)
        summaryOpenAIBaseURLRow = baseURLRow
        summaryOpenAIOptions.addArrangedSubview(baseURLRow)
        summaryOpenAIOptions.addArrangedSubview(summaryFieldRow(
            localised("Model", "Модель"), summaryOpenAIModel))
        let keyFields = SetupLayout.group([keyProvider, summaryKey, summaryOpenAIOptions, summaryKeyStatus, summaryKeyLink])
        summaryKeyFields = keyFields
        let key = ChoiceCard(
            id: "api-key",
            title: localised("My own key", "Свой ключ"),
            detail: localised(
                "Billed per meeting, needs no CLI.",
                "Оплата за встречу, без CLI."),
            accessories: [keyFields])

        // Ollama is a fallback, not a fourth peer: a whole card beside the
        // three real choices reads as a recommendation, and its summaries are
        // the weakest of the four. One slim row keeps it choosable and says so.
        configureSummaryField(summaryOllamaBaseURL, id: "summary.ollama_base_url")
        configureSummaryField(summaryOllamaModel, id: "summary.ollama_model")
        let ollamaOptions = NSStackView(views: [
            summaryFieldRow(localised("Base URL", "URL сервера"), summaryOllamaBaseURL),
            summaryFieldRow(localised("Model", "Модель"), summaryOllamaModel),
        ])
        ollamaOptions.orientation = .vertical
        ollamaOptions.alignment = .leading
        ollamaOptions.spacing = 6
        summaryOllamaFields = ollamaOptions
        let ollama = ChoiceCard(
            id: "ollama",
            title: "Ollama",
            detail: localised(
                "Local by default. A remote URL sends the transcript there.",
                "По умолчанию локально. Удалённый URL получит расшифровку."),
            accessories: [
                ollamaOptions,
                link(
                localised("Install Ollama", "Установить Ollama"),
                "https://ollama.com/download/mac")])

        let automatic = ChoiceCard(id: "auto", title: localised("Automatic", "Автоматически"),
            detail: localised("Use the available summary services in the configured fallback order.", "Использовать доступные сервисы по порядку резервирования."))
        summaryCards.adopt([automatic, claude, codex, key, ollama])
        summaryCards.onChange = { [weak self] id in
            guard let self else { return }
            let backend = id == "claude-cli" ? "claude-cli"
                : id == "auto" ? nil : SetupSelection.summaryBackend(choice: id, keyBackend: self.selectedKeyBackend)
            Config.update(path: ["summary", "backend"], value: backend)
            self.refresh()
        }
        let disclosure = SetupLayout.detail(
            localised(
                "Claude, Codex and API models receive meeting content. Ollama stays on this Mac only with a localhost URL.",
                "Claude, Codex и API-модели получают данные встречи. Ollama остаётся на этом маке только с localhost URL."),
            lines: 2,
            width: 520)
        let options = SetupLayout.group(
            [choiceCards([automatic, claude, codex, key]), ollama, disclosure],
            spacing: SetupLayout.cardGap)
        summaryOptions = options
        return options
    }

    private func startAtLoginRow() -> NSView {
        launchSwitch.target = self
        launchSwitch.action = #selector(startAtLogin)
        let row = SetupLayout.row(
            leading: launchSwitch,
            title: SetupLayout.title(localised("Start at login", "Запуск при входе")),
            detail: launchDetail)
        row.identifier = NSUserInterfaceItemIdentifier("access.login")
        return row
    }

    /// The two places a person can find a running verbemo, each of which can be
    /// given up. Both, if they like: what is left then is the program itself,
    /// which is opened the way any program is opened, and `noIconsNote` says
    /// so at the moment it becomes true.
    private func menuBarIconRow() -> NSView {
        menuBarIcon.target = self
        menuBarIcon.action = #selector(iconsChanged)
        return SetupLayout.row(
            leading: menuBarIcon,
            title: SetupLayout.title(localised("In the menu bar", "В строке меню")),
            detail: SetupLayout.detail(
                localised(
                    "The wave, with the clock beside it while a meeting records — and the "
                        + "menu with everything in it.",
                    "Волна, во время встречи рядом с ней часы, и меню со всем остальным."),
                lines: 2, width: 520))
    }

    private func dockIconRow() -> NSView {
        dockIcon.target = self
        dockIcon.action = #selector(iconsChanged)
        return SetupLayout.row(
            leading: dockIcon,
            title: SetupLayout.title(localised("In the Dock", "В доке")),
            detail: SetupLayout.detail(
                localised(
                    "Keep the icon in the Dock and ⌘-Tab when the window is minimized or closed. "
                        + "The icon is always shown while the window is open.",
                    "Оставлять значок в доке и ⌘-Tab, когда окно свёрнуто или закрыто. "
                        + "При открытом окне значок виден всегда."),
                lines: 2, width: 520))
    }

    private func autoRecordRow() -> NSView {
        autoRecord.target = self
        autoRecord.action = #selector(autoRecordToggled)
        return SetupLayout.row(
            leading: autoRecord,
            title: SetupLayout.title(localised(
                "Start recording automatically when a call app takes the mic",
                "Начинать запись, когда приложение звонка берёт микрофон")),
            detail: SetupLayout.detail(
                localised(
                    "And stop when it lets go. A call shorter than 45 seconds is thrown away.",
                    "И заканчивать, когда отпустит. Звонок короче 45 секунд выбрасывается."),
                lines: 2, width: 520))
    }

    private func link(_ title: String, _ url: String) -> NSButton {
        SetupLayout.link(title, url, target: self, action: #selector(linkClicked(_:)))
    }

    /// What is left when neither icon is on, and nothing at all while either
    /// is. Static and free of AppKit so the sentence can be checked without a
    /// window: it is the only instruction verbemo gives for reaching itself,
    /// and it is shown exactly when it is the only way in.
    nonisolated static func noIconsNote(menuBar: Bool, dock: Bool) -> String {
        guard !menuBar, !dock else { return "" }
        return localised(
            "When the window is minimized or closed, verbemo keeps recording without an icon. To bring it back, open Verbemo "
                + "again — from Spotlight, or from Applications.",
            "Когда окно свёрнуто или закрыто, verbemo продолжит записывать без значка. Чтобы вернуть окно, "
                + "откройте Verbemo ещё раз — из Spotlight или из папки «Программы».")
    }

    /// "18 Aug" — enough to tell this week from last spring, and short enough
    /// to sit beside a row title.
    ///
    /// Built on each use rather than once. A `static let` is made the first
    /// time anything asks for it and keeps whatever language was in force
    /// then — which is right in a program that settles its language at
    /// startup and wrong the moment anything else changes it, and a formatter
    /// that is right by luck is worth less than one that is right by
    /// construction. Two rows a person opens a window to read is not a rate
    /// worth caching for.
    private static var day: DateFormatter {
        let formatter = DateFormatter()
        // The window's language, on the Mac's own region: a Russian window
        // saying "heard the tone · 19 Aug" is two languages in one line, and
        // a locale built from the language alone would take the day and month
        // out of the order this Mac writes them in as well.
        var locale = Locale.Components(locale: .current)
        locale.languageComponents.languageCode = .init(InterfaceLanguage.current.rawValue)
        formatter.locale = Locale(components: locale)
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }

    // MARK: - actions

    private func wireActions() {
        micRow.onAct = { [weak self] in Task { await self?.askMicrophone() } }
        audioRow.onAct = { [weak self] in Task { await self?.testSystemAudio() } }
        calendarRow.onAct = { [weak self] in Task { await self?.askCalendar() } }
    }

    @objc private func linkClicked(_ sender: NSButton) {
        guard let url = sender.identifier.flatMap({ URL(string: $0.rawValue) }) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Written the moment they are clicked, and taken up the moment they are
    /// written — the app reads the same file change and moves its icons. So
    /// the switch that has just emptied the menu bar is on screen beside the
    /// evidence of it, which is what makes turning both off a safe thing to
    /// let anyone do.
    ///
    /// One action for both switches, because `Config.update` writes only what
    /// differs: the half nobody touched costs a comparison and leaves the
    /// file, and its timestamp, alone.
    @objc private func iconsChanged() {
        Config.update(path: ["menu_bar_icon"], value: menuBarIcon.state == .on ? nil : false)
        Config.update(path: ["dock_icon"], value: dockIcon.state == .on ? nil : false)
    }

    @objc private func keepAudioChanged() {
        Config.update(path: ["keep_audio"], value: keepAudio.state == .on ? true : nil)
    }

    /// A missing key opens configuration without enabling cloud processing.
    @objc private func cloudToggled() {
        if cloudSwitch.state == .on { localSwitch.state = .off }
        if cloudSwitch.state == .on, !Credentials.hasTranscriptionKey(for: provider) {
            pendingProvider = provider
            commitTranscription()
            focusKeyField()
            return
        }
        pendingProvider = nil
        commitTranscription()
    }

    /// Picking a card is how you say "use this one", so a card with a working
    /// key also switches the cloud on. A card without one only opens the key
    /// field: what is in force stays in force until the new key is accepted.
    private func providerPicked(_ id: String) {
        cloudSwitch.state = .on
        localSwitch.state = .off
        guard Credentials.hasTranscriptionKey(for: id) else {
            pendingProvider = id
            commitTranscription()
            focusKeyField()
            return
        }
        pendingProvider = nil
        provider = id
        cloudSwitch.state = .on
        commitTranscription()
    }

    /// The switch is the download button: there is nothing to decide between
    /// "I want this" and "fetch the model", so asking twice is a step for its
    /// own sake.
    ///
    /// The choice is written before the download starts, and that order is
    /// the whole of it. Starting the download first redraws the form — so
    /// the footer says what is happening from the first second — and the
    /// redraw puts the switch back where the config still has it, which is
    /// off; the write that followed then read the switch and saved the
    /// arrangement the click was trying to leave. Written first, the redraw
    /// reads a config that already says local, so the download's own redraw
    /// has nothing left to undo.
    ///
    /// It also means a download that fails or is abandoned leaves the choice
    /// on disk, which is what makes the footer go on offering it: the button
    /// asks whether the local model is wanted and missing, and a choice that
    /// was never written is not wanted.
    @objc private func localToggled() {
        if localSwitch.state == .on {
            cloudSwitch.state = .off
            pendingProvider = nil
        }
        commitTranscription()
        if localSwitch.state == .on { downloadLocalIfNeeded() }
    }

    private func localEnginePicked(_ id: String) {
        localEngineCards.select(id)
        commitTranscription()
        if localSwitch.state == .on { downloadLocalIfNeeded(id) }
    }

    @objc private func downloadLocalClicked(_ sender: NSButton) {
        let prefix = "transcription.download."
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix(prefix)
        else { return }
        let id = String(raw.dropFirst(prefix.count))
        guard Config.localEngines.contains(id) else { return }
        localEngineCards.select(id)
        localSwitch.state = .on
        localToggled()
    }

    private func commitTranscription() {
        let selectedLocal = localEngineCards.selected
            ?? transcriptionChoice.localEngine
        let choice = TranscriptionChoice(
            cloud: pendingProvider == nil ? cloudSwitch.state == .on : transcriptionChoice.cloud,
            local: localSwitch.state == .on && Platform.supportsLocalModels,
            provider: provider,
            localEngine: selectedLocal)
        if !choice.local || choice.localEngine != "nemotron" { nemotronDownloads["final"]?.cancel() }
        for update in choice.updates {
            write(update.path, update.value)
        }
        refresh()
    }

    /// The main window hosting the mounted settings or permissions page.
    private func focusKeyField() {
        formWindow?.makeFirstResponder(cloudKeys[pendingProvider ?? provider])
    }

    @objc private func liveTranscriptionToggled() {
        let enabled = liveTranscription.state == .on
        Config.update(path: ["live_transcription", "enabled"], value: enabled ? true : nil)
        if enabled { downloadLiveModel() }
        else { nemotronDownloads["live"]?.cancel() }
        refresh()
    }

    private func downloadLiveModel() { downloadNemotron(for: "live") }

    private func downloadNemotron(for consumer: String) {
        guard nemotronDownloads[consumer] == nil else { return }
        let prompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
        guard !liveModelStore.isReady(language: prompt) else { refresh(); return }
        let operation = UUID()
        nemotronOperations[consumer] = operation
        nemotronDownloads[consumer] = Task { [weak self] in
            guard let self else { return }
            do { _ = try await liveModelStore.download(language: prompt) }
            catch { /* The shared store publishes the common failure/cancellation state. */ }
            guard nemotronOperations[consumer] == operation else { return }
            nemotronOperations[consumer] = nil
            nemotronDownloads[consumer] = nil
            refresh()
        }
        refresh()
    }

    private func refreshNemotron() {
        let prompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
        let state = liveModelStore.state(language: prompt)
        localDownloadErrors["nemotron"] = nil
        liveStatus.textColor = .secondaryLabelColor
        switch state {
        case .ready:
            liveStatus.stringValue = Self.downloaded(modelStorage.nemotronModel())
            liveStatus.textColor = .systemGreen
        case .downloading(let fraction):
            liveStatus.stringValue = localised("Downloading · ", "Загрузка · ") + "\(Int(fraction * 100))%"
        case .failed(let error):
            liveStatus.stringValue = error
            localDownloadErrors["nemotron"] = error
        case .idle:
            liveStatus.stringValue = localised("Not downloaded", "Не скачана")
        }
        for (consumer, progress) in [("live", liveDownloadProgress), ("final", localDownloadProgress["nemotron"]), ("files", nemotronFilesProgress)] {
            guard let progress else { continue }
            if case .downloading(let fraction) = state {
                if progress.isHidden { progress.begin() }
                progress.update(fraction)
                progress.setCancellable(nemotronDownloads[consumer] != nil)
            } else { progress.end() }
        }
    }

    @objc private func autoRecordToggled() {
        Config.update(
            path: ["auto_record", "enabled"], value: autoRecord.state == .on ? nil : false)
    }

    @objc private func summariesToggled() {
        let enabled = summariesOn.state == .on
        if enabled && Config.summary().backend == "none" { Config.update(path: ["summary", "backend"], value: nil) }
        Config.update(path: ["summary", "enabled"], value: enabled ? nil : false)
        refresh()
    }

    @objc private func keyProviderChanged() {
        // Only here, not in every redraw: a redraw follows the very write
        // that says a key was saved, and used to wipe "key works" off the
        // screen the moment it appeared.
        summaryKeyStatus.stringValue = ""
        summaryKey.stringValue = ""
        let backend = selectedKeyBackend
        let compatible = keyProvider.selectedSegment == 2
        if backend == "openai-api" {
            Config.update(path: ["summary", "openai_compatible"], value: compatible)
        }
        if summaryCards.selected == "api-key" {
            Config.update(path: ["summary", "backend"], value: backend)
        }
        showKeyProvider()
    }

    /// Everything the Anthropic/OpenAI control changes about how its card
    /// *looks* — and nothing it writes.
    ///
    /// Split out because `refresh` needs the looking and must not do the
    /// writing. A redraw that writes rewrites the config file every time
    /// anything is drawn, and once something listens for writes in order to
    /// redraw — which is the whole point of `Config.didChange` — a redraw that
    /// writes is a redraw that never stops.
    private func showKeyProvider() {
        summaryKey.placeholderString = selectedKeyBackend == "anthropic-api"
            ? "sk-ant-…" : localised("API key", "API-ключ")
        summaryOpenAIOptions.isHidden = selectedKeyBackend != "openai-api"
        summaryOpenAIBaseURLRow?.isHidden = keyProvider.selectedSegment != 2
        summaryKeyLink.isHidden = keyProvider.selectedSegment == 2
        summaryKeyLink.identifier = NSUserInterfaceItemIdentifier(
            selectedKeyBackend == "anthropic-api"
                ? "https://console.anthropic.com/settings/keys"
                : "https://platform.openai.com/api-keys")
    }

    private var selectedKeyBackend: String {
        keyProvider.selectedSegment == 1 ? "anthropic-api" : "openai-api"
    }

    private func configureSummaryField(_ field: NSTextField, id: String) {
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.font = SetupLayout.detailFont
        field.delegate = self
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func summaryFieldRow(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = SetupLayout.detailFont
        label.textColor = .secondaryLabelColor
        // Wide enough for "URL сервера": at 62 the Russian label was cut to
        // "URL сервер" in the Ollama card, the width having been measured
        // against "Base URL" alone.
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        field.setAccessibilityLabel(title)
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    /// Change registration here; only macOS approval needs System Settings.
    @objc private func startAtLogin() {
        loginItemError = nil
        let state = loginItemStatus()
        if state == .needsApproval {
            openLoginItemSettings()
            refresh()
            return
        }
        if isRecording?() == true {
            loginItemError = localised(
                "not while a recording is running — stop it and try again",
                "не сейчас: идёт запись — остановите её и попробуйте снова")
            refresh()
            return
        }
        let enabling = state != .enabled
        do {
            let state = try setLoginItemEnabled(enabling)
            // Registered but held: macOS wants a person to say yes, and the
            // only place they can is System Settings.
            if state == .needsApproval { openLoginItemSettings() }
        } catch {
            loginItemError = (enabling
                ? localised("couldn't enable start at login: ", "не удалось включить запуск при входе: ")
                : localised("couldn't disable start at login: ", "не удалось отключить запуск при входе: ")) + error.localizedDescription
        }
        refresh()
    }

    private func askMicrophone() async {
        let state = await SetupPermissions.requestMicrophone()
        if state == .denied { SetupPermissions.openSettings(.microphone) }
        refresh()
    }

    private func askCalendar() async {
        let state = await SetupPermissions.requestCalendar()
        calendarGrant = state
        if state == .denied { SetupPermissions.openSettings(.calendar) }
        refresh()
    }

    /// What the calendar prompt answered, for as long as this window is open.
    /// Kept because EventKit will not admit to a grant given in this process
    /// until the next launch, and a row that still says "optional" after the
    /// person has just said yes is the button looking broken all over again.
    private var calendarGrant: SetupPermissions.State?

    /// Play a tone and listen for it through a tap of our own.
    ///
    /// Never during a recording, which the comment on `isRecording` promised
    /// and only the login item kept: the test opens a second tap beside the
    /// one recording the meeting and plays 440 Hz out of the speakers, into
    /// the call — the far end hears it, and it lands in the recording too.
    /// The setup page's button reaches this as well as the row's, so the refusal
    /// is here rather than on either button.
    private func testSystemAudio() async {
        if isRecording?() == true {
            toneRefused = true
            refresh()
            return
        }
        audioRow.working(localised("playing a tone…", "играет тон…"))
        let result = await playTestTone()
        systemAudio = result
        if result == .heard { SetupState.rememberSystemAudioHeard() }
        switch result {
        case .heard:
            break
        case .silent, .refused:
            SetupPermissions.openSettings(.systemAudio)
        }
        refresh()
    }

    /// The test was asked for during a recording and refused. Kept rather
    /// than written once into the row, because the next redraw — any write
    /// to the config, from anywhere — would put the row back as if nothing
    /// had been asked, while the recording that is the reason goes on.
    private var toneRefused = false

    /// Seeded from the last tone that was heard, because macOS will not tell
    /// us and a working Mac should not be asked to prove itself every time.
    private lazy var systemAudio: SetupPermissions.SystemAudioResult? =
        SetupPermissions.rememberedSystemAudio(heardAt: SetupState.systemAudioHeardAt())

    private func downloadLocalIfNeeded(_ requestedEngine: String? = nil) {
        let engine = requestedEngine ?? transcriptionChoice.localEngine
        localDownloadErrors[engine] = nil
        if engine == "whisper" {
            downloadWhisperIfNeeded()
        } else if engine == "gigaam" {
            downloadGigaAMIfNeeded()
        } else if engine == "nemotron" {
            downloadNemotron(for: "final")
        } else {
            downloadParakeetIfNeeded()
        }
    }

    private func downloadGigaAMIfNeeded() {
        guard gigaAMModelStore.bytesOnDisk == 0, gigaAMDownloadTask == nil else { return }
        let asset = "gigaam-v3-e2e-ctc-q8_0"
        let operation = UUID()
        localDownloadOperations["gigaam"] = operation
        localDownloadProgress["gigaam"]?.begin()
        Analytics.track(.modelDownloadStarted, [.asset: .text(asset)])
        gigaAMDownloadTask = Task { [self, gigaAMModelStore, operation] in
            do {
                _ = try await gigaAMModelStore.download { update in
                    Task { @MainActor [self] in
                        guard localDownloadOperations["gigaam"] == operation,
                              gigaAMDownloadTask?.isCancelled == false else { return }
                        localDownloadProgress["gigaam"]?.update(update.fraction)
                    }
                }
                try Task.checkCancellation()
                Analytics.track(.modelDownloadFinished, [.asset: .text(asset)])
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    Analytics.track(.modelDownloadFailed, [
                        .asset: .text(asset),
                        .reason: .text(Analytics.reason(for: error).rawValue),
                    ])
                    localDownloadErrors["gigaam"] =
                        localised("download failed: ", "не удалось скачать: ") + "\(error)"
                }
            }
            guard localDownloadOperations["gigaam"] == operation else { return }
            localDownloadOperations["gigaam"] = nil
            gigaAMDownloadTask = nil
            localDownloadProgress["gigaam"]?.end()
            refresh()
        }
        refresh()
    }

    private func downloadWhisperIfNeeded() {
        guard whisperModelStore.bytesOnDisk == 0, whisperDownloadTask == nil else { return }
        let operation = UUID()
        localDownloadOperations["whisper"] = operation
        localDownloadProgress["whisper"]?.begin()
        Analytics.track(.modelDownloadStarted, [.asset: .text("whisper-large-v3-turbo-q5_0")])
        whisperDownloadTask = Task { [self, whisperModelStore, operation] in
            do {
                _ = try await whisperModelStore.download { update in
                    Task { @MainActor [self] in
                        guard self.localDownloadOperations["whisper"] == operation,
                              self.whisperDownloadTask?.isCancelled == false else { return }
                        self.localDownloadProgress["whisper"]?.update(update.fraction)
                    }
                }
                try Task.checkCancellation()
                Analytics.track(.modelDownloadFinished, [
                    .asset: .text("whisper-large-v3-turbo-q5_0"),
                ])
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    Analytics.track(.modelDownloadFailed, [
                        .asset: .text("whisper-large-v3-turbo-q5_0"),
                        .reason: .text(Analytics.reason(for: error).rawValue),
                    ])
                    self.localDownloadErrors["whisper"] =
                        localised("download failed: ", "не удалось скачать: ") + "\(error)"
                }
            }
            guard self.localDownloadOperations["whisper"] == operation else { return }
            self.localDownloadOperations["whisper"] = nil
            self.whisperDownloadTask = nil
            self.localDownloadProgress["whisper"]?.end()
            self.refresh()
        }
        refresh()
    }

    private func downloadParakeetIfNeeded() {
        guard !parakeetIsHere() else { return }
        guard parakeetDownload == nil else { return }
        let asset = Config.transcriptionModel() == "v2" ? "parakeet-v2" : "parakeet-v3"
        let operation = UUID()
        localDownloadOperations["parakeet"] = operation
        localDownloadProgress["parakeet"]?.begin()
        Analytics.track(.modelDownloadStarted, [.asset: .text(asset)])
        watchParakeetSize()
        let fetch = fetchParakeet
        parakeetDownload = Task { [weak self, operation] in
            var failure: String?
            do {
                try await fetch()
                try Task.checkCancellation()
                Analytics.track(.modelDownloadFinished, [.asset: .text(asset)])
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    Analytics.track(.modelDownloadFailed, [
                        .asset: .text(asset),
                        .reason: .text(Analytics.reason(for: error).rawValue),
                    ])
                    failure = localised("download failed: ", "не удалось скачать: ") + "\(error)"
                }
            }
            guard let self, localDownloadOperations["parakeet"] == operation else { return }
            if let failure { localDownloadErrors["parakeet"] = failure }
            localDownloadOperations["parakeet"] = nil
            parakeetDownload = nil
            parakeetProgress?.invalidate()
            parakeetProgress = nil
            localDownloadProgress["parakeet"]?.end()
            refresh()
        }
        // So the footer button says what is happening from the first second,
        // rather than at the end of it.
        refresh()
    }

    @objc private func cancelLocalClicked(_ sender: NSButton) {
        let prefix = "transcription.cancel."
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix(prefix) else { return }
        let id = String(raw.dropFirst(prefix.count))
        let task: Task<Void, Never>?
        switch id {
        case "parakeet": task = parakeetDownload
        case "whisper": task = whisperDownloadTask
        case "gigaam": task = gigaAMDownloadTask
        case "nemotron": task = nemotronDownloads["final"]
        default: return
        }
        guard let task else { return }
        task.cancel()
        localDownloadProgress[id]?.cancelling()
        if id == "parakeet" {
            parakeetProgress?.invalidate()
            parakeetProgress = nil
        }
    }

    /// FluidAudio reports each file separately; cache growth gives one
    /// approximate percentage for the complete multi-file download.
    private func watchParakeetSize() {
        parakeetProgress?.invalidate()
        let cache = ParakeetEngine.cacheDirectory(for: ParakeetEngine.configuredVersion())
        let operation = localDownloadOperations["parakeet"]
        parakeetProgress = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.localDownloadOperations["parakeet"] == operation,
                      self.parakeetDownload?.isCancelled == false else { return }
                let mb = Self.megabytes(of: cache)
                self.localDownloadProgress["parakeet"]?.update(
                    Double(mb) / Double(Self.parakeetMegabytes))
            }
        }
    }

    private static func megabytes(of dir: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total / 1_048_576
    }

    // MARK: - text fields

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if let target = cloudKeys.first(where: { $0.value === field })?.key {
            Task { await saveCloudKey(for: target) }
        }
        if field === summaryKey { Task { await saveSummaryKey() } }
        let summaryPaths: [(NSTextField, String)] = [
            (summaryOpenAIBaseURL, "openai_base_url"),
            (summaryOpenAIModel, "openai_model"),
            (summaryOllamaBaseURL, "ollama_base_url"),
            (summaryOllamaModel, "ollama_model"),
        ]
        if let key = summaryPaths.first(where: { $0.0 === field })?.1 {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Config.update(path: ["summary", key], value: value.isEmpty ? nil : value)
            refresh()
        }
    }

    /// Return in a key field submits the key and stops there.
    ///
    /// Left alone, the newline travels on to the window's default button —
    /// Done — so the window closes on the very keystroke that submits the key.
    /// The check against the API then finishes into a window nobody can see,
    /// and the one answer worth waiting for, whether the key was accepted,
    /// is delivered to nothing at all. Someone who pasted a key and pressed
    /// Return has no way to learn what happened except to open Setup again.
    ///
    /// Ending editing here is the same path a click elsewhere takes — it fires
    /// `controlTextDidEndEditing`, which saves — and returning true keeps the
    /// keystroke from travelling any further. Only these fields swallow
    /// Return: everywhere else in the window it should still mean Done.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy selector: Selector
    ) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)),
              cloudKeys.values.contains(where: { $0 === control }) || control === summaryKey
                || control === summaryOpenAIBaseURL || control === summaryOpenAIModel
                || control === summaryOllamaBaseURL || control === summaryOllamaModel
        else { return false }
        control.window?.makeFirstResponder(nil)
        return true
    }

    @objc private func languageChanged() {
        let previous = liveModelStore.variantDirectory(language: LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage()))
        Config.update(path: ["transcription", "language"], value: selectedLanguage)
        let next = liveModelStore.variantDirectory(language: LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage()))
        if previous != next {
            for task in nemotronDownloads.values { task.cancel() }
            nemotronDownloads = [:]
            nemotronOperations = [:]
            if Config.liveTranscriptionEnabled() { downloadLiveModel() }
            if transcriptionChoice.local && transcriptionChoice.localEngine == "nemotron" { downloadNemotron(for: "final") }
        }
        refresh()
    }

    /// What the choice above actually promises, in the one place somebody is
    /// looking at it. Picking English says nothing worth saying — it is the
    /// language the second slot would have added anyway.
    private static func note(forLanguage code: String?) -> String {
        guard let code else {
            return localised(
                "Both engines work it out from the audio. Naming a language "
                    + "keeps a short or noisy meeting from being taken for another one.",
                "Оба движка определяют язык по звуку. Названный язык не даст принять "
                    + "короткую или шумную встречу за другую.")
        }
        guard code != "en" else { return "" }
        return localised(
            "English meetings are recognised too — nothing to switch.",
            "Встречи на английском тоже распознаются — переключать ничего не надо.")
    }

    /// Shared wording while a transcription or summary key is being checked.
    private static var checkingKey: String { localised("checking…", "проверяю…") }

    /// Check first, write second.
    ///
    /// The other order costs someone their working key: two characters typed
    /// into the field by accident used to replace a good key on disk, and the
    /// only sign was every later meeting failing to transcribe with HTTP 401.
    /// A key that isn't accepted never reaches the file.
    func saveCloudKey(for target: String) async {
        guard let field = cloudKeys[target], let status = cloudKeyStatuses[target] else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !Config.settingsUnknown else { return }
        let slot = Credentials.transcriptionSlot(for: target, in: Config.raw())
        status.isHidden = false
        guard slot.isVerbemos else {
            status.stringValue = Credentials.notOursToWrite(slot)
            return
        }
        // Collapsing the cloud section can submit the focused key again while its check is pending.
        if let pending = cloudKeyChecks[target], pending.key == key, pending.slot == slot { return }
        let operation = UUID()
        cloudKeyChecks[target] = (operation, key, slot)
        defer {
            if cloudKeyChecks[target]?.operation == operation { cloudKeyChecks[target] = nil }
        }
        status.stringValue = Self.checkingKey

        let service: Credentials.Check.Service
        switch target {
        // Transcription only ever talks to OpenAI itself, whatever endpoint
        // the summaries are pointed at.
        case "openai": service = .openAI(baseURL: "https://api.openai.com/v1")
        case "elevenlabs": service = .elevenLabs
        default: service = .assemblyAI
        }
        let verdict = await checkKey(Credentials.Check(service: service, key: key))
        guard cloudKeyChecks[target]?.operation == operation else { return }
        guard field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == key else {
            status.stringValue = ""
            status.isHidden = true
            return
        }
        guard verdict == .works else {
            status.stringValue = verdict.sentence(
                keepingSaved: Credentials.hasTranscriptionKey(for: target))
            return
        }
        guard !Config.settingsUnknown,
              Credentials.transcriptionSlot(for: target, in: Config.raw()) == slot else {
            status.stringValue = localised(
                "Key settings changed — enter the key again.",
                "Настройки ключа изменились — введите ключ ещё раз.")
            return
        }
        do {
            try Credentials.writeSecret(key, to: slot.path)
        } catch {
            status.stringValue =
                localised("couldn't save the key: ", "не удалось сохранить ключ: ") + "\(error)"
            return
        }
        field.stringValue = ""
        status.stringValue = ""
        // A completed check must not undo a later provider selection or cloud-off click.
        if cloudSwitch.state == .on, providerCards.selected == target {
            provider = target
            pendingProvider = nil
            commitTranscription()
        } else {
            refresh()
        }
    }

    /// The same order as the cloud key, into the slot the summary actually
    /// reads — which for an OpenAI-compatible endpoint is not OpenAI's.
    func saveSummaryKey() async {
        let key = summaryKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let backend = selectedKeyBackend
        let config = Config.raw()
        let slot = Credentials.summarySlot(for: backend, in: config)
        guard slot.isVerbemos else {
            summaryKeyStatus.stringValue = Credentials.notOursToWrite(slot)
            return
        }
        summaryKeyStatus.stringValue = Self.checkingKey
        let service: Credentials.Check.Service = backend == "anthropic-api"
            ? .anthropic
            : .openAI(baseURL: Config.summary(in: config).openAIBaseURL)
        let verdict = await checkKey(Credentials.Check(service: service, key: key))
        guard verdict == .works else {
            summaryKeyStatus.stringValue = verdict.sentence(
                keepingSaved: Config.secret(at: slot.path) != nil)
            return
        }
        do {
            try Credentials.writeSecret(key, to: slot.path)
        } catch {
            summaryKeyStatus.stringValue =
                localised("couldn't save the key: ", "не удалось сохранить ключ: ") + "\(error)"
            return
        }
        summaryKey.stringValue = ""
        summaryKeyStatus.stringValue = verdict.sentence(keepingSaved: true)
        Config.update(path: ["summary", "backend"], value: backend)
        refresh()
    }

    // MARK: - reading the machine

    func detectTools() async {
        // The form is reopened for exactly one reason: something about the
        // machine changed. Usually it is the **Install it** link having been
        // followed — so the cached "not here" from the last look is the one
        // answer guaranteed to be wrong now.
        Tooling.forget()

        // Off the main actor: `Tooling` may start a login shell and run the
        // binaries it finds, which is seconds, not milliseconds.
        let claude = await Task.detached { Tooling.probe("claude") }.value
        let codex = await Task.detached { Tooling.probe("codex") }.value
        let ollama = await Task.detached { Tooling.probe("ollama") }.value
        let models = await Tooling.ollamaModels()

        for (id, tool) in [("claude-cli", claude), ("codex-cli", codex)] {
            summaryCards.card(id)?.report(Self.describe(tool), good: tool?.version != nil)
            summaryCards.card(id)?.showLink(tool == nil)
        }

        let ollamaCard = summaryCards.card("ollama")
        let ollamaIsLocal = OllamaClient.isLocal(baseURL: Config.summary().ollamaBaseURL)
        if let models {
            let names = models.prefix(2).map(\.name).joined(separator: ", ")
            let selected = SetupSelection.ollamaModel(
                named: Config.summary().ollamaModel, in: models)
            ollamaCard?.report(
                models.isEmpty
                    ? localised("running, no models", "работает, моделей нет")
                    : selected == nil
                        ? localised(
                            "selected model missing · ",
                            "нет выбранной модели · ") + names
                        : localised("running · ", "работает · ")
                        + names
                        + (ollamaIsLocal && selected?.isRemote == false
                            ? "" : localised(" · remote", " · удалённо")),
                good: selected != nil)
        } else {
            ollamaCard?.report(ollama == nil
                ? localised("not here", "не установлена")
                : localised("installed, not running", "установлена, но не запущена"))
        }
        ollamaCard?.showLink(ollama == nil && ollamaIsLocal)

        summaryToolRuns = [
            "claude-cli": claude?.runs == true,
            "codex-cli": codex?.runs == true,
            "ollama": models.map {
                SetupSelection.ollamaModel(
                    named: Config.summary().ollamaModel, in: $0) != nil
            } ?? false,
        ]
        refresh()
    }

    private static func describe(_ tool: Tooling.Found?) -> String {
        guard let tool else { return localised("not here", "не установлен") }
        guard let version = tool.version else {
            return localised(
                "found but it doesn't run from here", "нашёлся, но отсюда не запускается")
        }
        return localised("answers · ", "отвечает · ") + version
    }

    /// Whether the local model is on this Mac. A Mac that cannot run it at
    /// all is not missing it, so the question is answered yes there and the
    /// window stops asking.
    private var localModelIsDownloaded: Bool {
        guard Platform.supportsLocalModels else { return true }
        switch transcriptionChoice.localEngine {
        case "whisper": return whisperModelStore.bytesOnDisk > 0
        case "gigaam": return gigaAMModelStore.bytesOnDisk > 0
        case "nemotron": return liveModelStore.isReady(language: LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage()))
        default: return parakeetIsHere()
        }
    }

    private var transcriptionChoice: TranscriptionChoice {
        var choice = storedTranscription()
        // Show the primary route of legacy auto settings; a new selection writes one explicit engine.
        if choice.cloud && choice.local {
            choice.cloud = Credentials.hasTranscriptionKey(for: choice.provider)
            choice.local = !choice.cloud
        }
        return choice
    }

    /// Whether the selected local model still needs downloading.
    private var localModelIsWantedAndMissing: Bool {
        transcriptionChoice.needsLocalModel(downloaded: localModelIsDownloaded)
    }

    /// Summaries are on and the thing chosen to write them is not on this
    /// Mac. The card says "not here" in orange; this is what puts it in the
    /// one line somebody reads before pressing Done.
    private var chosenSummaryIsMissing: Bool {
        let summary = Config.summary()
        guard summary.enabled else { return false }
        switch SetupSelection.summaryChoice(backend: summary.backend) {
        case let looked where summaryToolRuns[looked] != nil:
            return summaryToolRuns[looked] == false
        case "api-key":
            return summary.backend == "openai-api"
                ? Credentials.summaryOpenAIKey() == nil
                : Config.anthropicKey() == nil
        default:
            return false
        }
    }

    // MARK: - refresh

    /// Redraw everything from the machine and the config file. Cheap: no
    /// subprocesses, no network — those write into fields this only reads.
    /// Other settings pages write the same keys, so visible controls follow them.
    func refresh() {
        let loginState = loginItemStatus()
        launchSwitch.state = loginState == .enabled ? .on : .off
        launchSwitch.isEnabled = loginState != .unavailable
        switch loginState {
        case .enabled, .notRegistered:
            launchDetail.stringValue = localised(
                "Open verbemo automatically when you log in to your Mac.",
                "Открывать verbemo автоматически при входе в систему.")
        case .needsApproval:
            launchDetail.stringValue = localised(
                "macOS wants this allowed in Login Items.",
                "macOS хочет, чтобы это разрешили в объектах входа.")
        case .unavailable:
            launchDetail.stringValue = localised(
                "Only Verbemo.app can register itself; this is a bare build.",
                "Зарегистрировать себя может только Verbemo.app, а это голая сборка.")
        }
        if let loginItemError { launchDetail.stringValue = loginItemError }
        launchDetail.textColor = loginItemError == nil ? .secondaryLabelColor : .systemRed
        launchSwitch.setAccessibilityHelp(launchDetail.stringValue)
        micRow.update(SetupPermissions.microphone())
        calendarRow.update(calendarGrant ?? SetupPermissions.calendar())

        if toneRefused, isRecording?() != true { toneRefused = false }
        switch systemAudio {
        case _ where toneRefused:
            audioRow.update(.denied, detail: localised(
                "not while a recording is running — the test tone would play into the call",
                "не во время записи — тестовый тон прозвучит в звонке"))
        case .heard:
            audioRow.update(
                .granted,
                note: SetupState.systemAudioHeardAt().map {
                    localised("heard the tone · ", "тон услышан · ")
                        + Self.day.string(from: $0)
                } ?? localised("heard the tone", "тон услышан"),
                action: localised("Test again", "Проверить ещё раз"))
        case .silent:
            audioRow.update(.denied, detail: localised(
                "Recorded silence. Check the grant, or turn the volume up, and test again.",
                "Записалась тишина. Проверьте разрешение или прибавьте громкость и "
                    + "попробуйте снова."))
        case .refused(let why): audioRow.update(.denied, detail: why)
        case nil: audioRow.update(.notAsked)
        }

        let config = Config.raw()
        refreshNemotron()
        refreshTranscription()
        // A code the menu doesn't offer — hand-edited, or a leftover "ru-RU"
        // — selects Detect automatically, which is what the engines will
        // actually do with it. Shown as it will behave rather than as it is
        // written, and left in the file for its owner to change.
        let stored = Config.transcriptionLanguage()
        let item = language.menu?.items.first { $0.representedObject as? String == stored }
        language.select(item ?? language.menu?.items.first)
        languageNote.stringValue = Self.note(forLanguage: item?.representedObject as? String)
        languageNote.isHidden = languageNote.stringValue.isEmpty
        keepAudio.state = Config.keepAudio() ? .on : .off

        liveTranscription.state = Config.liveTranscriptionEnabled() ? .on : .off
        refreshDiarization()

        recordingsPath.stringValue = Home.current.abbreviating(
            Config.resolveRoot(cliOverride: nil).path)

        let summary = Config.summary()
        let summariesEnabled = summary.enabled && summary.backend != "none"
        summariesOn.state = summariesEnabled ? .on : .off
        let backendIsKey = summary.backend == "anthropic-api" || summary.backend == "openai-api"
        summaryCards.select(summary.backend == "auto" ? "auto" : SetupSelection.summaryChoice(backend: summary.backend))
        if backendIsKey {
            keyProvider.selectedSegment = summary.backend == "anthropic-api" ? 1
                : (summary.openAICompatible ? 2 : 0)
        }
        if summaryOpenAIBaseURL.currentEditor() == nil { summaryOpenAIBaseURL.stringValue = summary.openAIBaseURL }
        if summaryOpenAIModel.currentEditor() == nil { summaryOpenAIModel.stringValue = summary.openAIModel }
        if summaryOllamaBaseURL.currentEditor() == nil { summaryOllamaBaseURL.stringValue = summary.ollamaBaseURL }
        if summaryOllamaModel.currentEditor() == nil { summaryOllamaModel.stringValue = summary.ollamaModel }
        showKeyProvider()
        for card in summaryCards.cards { card.isEnabled = summariesEnabled }
        summaryOptions?.isHidden = !summariesEnabled
        summaryKeyFields?.isHidden = !backendIsKey && summary.backend != "auto"
        summaryOllamaFields?.isHidden = summary.backend != "ollama" && summary.backend != "auto"

        menuBarIcon.state = Config.menuBarIcon() ? .on : .off
        dockIcon.state = Config.dockIcon() ? .on : .off
        noIconsNote.stringValue = Self.noIconsNote(
            menuBar: Config.menuBarIcon(), dock: Config.dockIcon())
        noIconsNote.isHidden = noIconsNote.stringValue.isEmpty

        let autoRecordOn = Config.flag(.autoRecordEnabled, in: config)
        autoRecord.state = autoRecordOn ? .on : .off

        let problems = Config.problems()
        configProblems.stringValue = problems.map(\.explanation).joined(separator: "\n")
        configProblems.isHidden = problems.isEmpty

        highlightNextGrant()
        refreshStorageControls()
        onStateChange?()
    }

    /// The transcription section, redrawn from the config and from what is
    /// actually on disk: which keys exist, whether the local model is there.
    private func refreshTranscription() {
        let choice = transcriptionChoice
        provider = choice.provider
        pendingProvider = TranscriptionChoice.stillPending(pendingProvider) {
            Credentials.hasTranscriptionKey(for: $0)
        }

        cloudSwitch.state = choice.cloud || pendingProvider != nil ? .on : .off
        cloudOptions?.isHidden = !choice.cloud && pendingProvider == nil
        localOptionsView?.isHidden = !choice.local
        let version = Config.transcriptionModel() == "v2" ? "v2" : "v3"
        parakeetVersion.selectItem(withTitle: version)
        parakeetVersion.isEnabled = parakeetDownload == nil && !Config.settingsUnknown
        let languages = version == "v2" ? localised("English", "Английский язык") : localised("25 European languages", "25 европейских языков")
        let size = ModelStorage.describe(bytes: modelStorage.parakeet(version: ParakeetEngine.configuredVersion()).advertisedBytes)
        localEngineCards.card("parakeet")?.describe(title: "Parakeet \(version)", detail: languages + localised(" · about ", " · около ") + size)
        // A provider waiting for a key is the one shown chosen.
        providerCards.select(pendingProvider ?? provider)

        for card in providerCards.cards {
            let known = Credentials.hasTranscriptionKey(for: card.id)
            card.report(
                known
                    ? localised("key saved", "ключ сохранён")
                    : localised("no key yet", "ключа ещё нет"),
                good: known)
            card.showLink(!known)
            cloudKeys[card.id]?.placeholderString = known
                ? localised("Enter a new API key to replace", "Введите новый API-ключ для замены")
                : localised("Enter API key", "Введите API-ключ")
            if let status = cloudKeyStatuses[card.id] {
                status.isHidden = status.stringValue.isEmpty
            }
        }
        // The cards below carry the price and the key state, so the row speaks
        // only when a missing key is what holds the switch down.
        cloudStatus.stringValue = TranscriptionChoice.rowNeedsKey(
            pending: pendingProvider, cloudOn: choice.cloud)
            ? localised("needs a key", "нужен ключ") : ""

        localSwitch.isEnabled = Platform.supportsLocalModels
        localSwitch.state = choice.local ? .on : .off
        localEngineCards.select(choice.localEngine)
        for card in localEngineCards.cards {
            card.isEnabled = Platform.supportsLocalModels
            let button = localDownloadButtons[card.id]
            let progress = localDownloadProgress[card.id]
            guard Platform.supportsLocalModels else {
                card.report(localised("needs Apple Silicon", "нужен Apple Silicon"))
                button?.isHidden = true
                progress?.end()
                continue
            }

            let model = localModel(card.id)
            if localModelIsDownloading(card.id) {
                card.report("")
                button?.isHidden = true
                progress?.isHidden = false
            } else if isLocalModelDownloaded(card.id, model: model) {
                progress?.end()
                card.report(
                    model.bytes > 0
                        ? Self.downloaded(model)
                        : localised("downloaded", "скачана"),
                    good: true)
                button?.isHidden = true
            } else if let error = localDownloadErrors[card.id] {
                progress?.end()
                card.report(error)
                button?.isHidden = false
                button?.title = localised("Retry…", "Повторить…")
            } else {
                progress?.end()
                card.report("")
                button?.isHidden = false
                button?.title = localised("Download…", "Скачать…")
            }
        }
    }

    @objc private func parakeetVersionChanged() {
        guard parakeetDownload == nil, !Config.settingsUnknown else { refresh(); return }
        write(["transcription", "model"], parakeetVersion.titleOfSelectedItem == "v2" ? "v2" : nil)
        refresh()
    }

    private func localModel(_ id: String) -> ModelStorage.Model {
        switch id {
        case "whisper": return modelStorage.whisperModel()
        case "gigaam": return modelStorage.gigaAMModel()
        case "nemotron": return modelStorage.nemotronModel()
        default: return modelStorage.parakeet(version: ParakeetEngine.configuredVersion())
        }
    }

    /// File operations reuse the same download task; they never select a working model.
    func modelFilesControl(for model: ModelStorage.Model) -> (button: NSButton, status: NSView) {
        if let cached = storageControls[model.directory.path] { return (cached.button, cached.view) }
        let button = NSButton(title: localised("Download", "Скачать"), target: self, action: #selector(storageDownloadClicked(_:)))
        button.identifier = .init(model.directory.path)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let note = SetupLayout.status()
        let progress: NSView?
        switch model.kind {
        case .parakeet: progress = localDownloadProgress["parakeet"]?.mirroredView()
        case .whisper: progress = localDownloadProgress["whisper"]?.mirroredView()
        case .gigaAM: progress = localDownloadProgress["gigaam"]?.mirroredView()
        case .diarization: progress = model.diarizationModel.flatMap { diarizationDownloadProgress[$0]?.mirroredView() }
        case .nemotron: progress = nemotronFilesProgress.mirroredView()
        }
        let group = NSStackView(views: [note] + (progress.map { [$0] } ?? []))
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        if let progress { progress.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        storageControls[model.directory.path] = (group, button, note, model)
        refreshStorageControls()
        return (button, group)
    }
    private func refreshStorageControls() {
        for (_, entry) in storageControls {
            let model = entry.model
            let downloading: Bool
            let error: String?
            switch model.kind {
            case .parakeet: downloading = localModelIsDownloading("parakeet"); error = localDownloadErrors["parakeet"]
            case .whisper: downloading = localModelIsDownloading("whisper"); error = localDownloadErrors["whisper"]
            case .gigaAM: downloading = localModelIsDownloading("gigaam"); error = localDownloadErrors["gigaam"]
            case .diarization: downloading = model.diarizationModel.flatMap { diarizationDownloads[$0] } != nil; error = model.diarizationModel.flatMap { diarizationErrors[$0] }
            case .nemotron:
                downloading = liveDownloading
                if case .failed(let message) = liveModelStore.state(language: LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())) {
                    error = message
                } else { error = nil }
            }
            let ready = modelStorage.isReady(model)
            entry.button.isHidden = ready || downloading
            entry.button.isEnabled = !Config.settingsUnknown && !downloading
            entry.note.stringValue = error ?? ""
            entry.note.isHidden = entry.note.stringValue.isEmpty
        }
    }
    @objc private func storageDownloadClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let entry = storageControls[id], sender.isEnabled else { return }
        switch entry.model.kind {
        case .parakeet: downloadLocalIfNeeded("parakeet")
        case .whisper: downloadLocalIfNeeded("whisper")
        case .gigaAM: downloadLocalIfNeeded("gigaam")
        case .nemotron: downloadNemotron(for: "files")
        case .diarization:
            guard let model = entry.model.diarizationModel else { return }
            downloadDiarizationIfNeeded(model)
        }
        refreshStorageControls()
    }
    @objc private func cancelLiveDownload() {
        nemotronDownloads["live"]?.cancel()
        liveDownloadProgress.cancelling()
    }

    @objc private func cancelNemotronFiles() { nemotronDownloads["files"]?.cancel() }

    private func isLocalModelDownloaded(_ id: String, model: ModelStorage.Model) -> Bool {
        if id == "nemotron" { return liveModelStore.isReady(language: LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())) }
        return id == "parakeet" ? parakeetIsHere() : model.isDownloaded
    }

    private func localModelIsDownloading(_ id: String) -> Bool {
        switch id {
        case "whisper": return whisperDownloadTask != nil
        case "gigaam": return gigaAMDownloadTask != nil
        case "nemotron": return liveDownloading
        default: return parakeetDownload != nil
        }
    }

    /// Show installed size beside model selection as well as in Storage.
    private static func downloaded(_ model: ModelStorage.Model) -> String {
        localised("downloaded · ", "скачана · ") + ModelStorage.describe(bytes: model.bytes)
    }

    /// Tint the row the primary button is about to act on — and only that
    /// one. The order below is the same one `nextAction` walks, because the
    /// highlight is meant to point at the button, not compete with it.
    private func highlightNextGrant() {
        let rows = [micRow, audioRow, calendarRow]
        let pending: AccessRow?
        if SetupPermissions.microphone() != .granted {
            pending = micRow
        } else if SetupPermissions.needsSystemAudioTest(systemAudio) || systemAudio == .silent {
            pending = audioRow
        } else {
            pending = nil
        }
        for row in rows { row.setAttention(row === pending) }
    }

    /// The machine as it stands for onboarding and download state.
    /// Read on every ask: the permission
    /// reads cost a round trip each, and `ThisTurn` is what keeps a redraw
    /// from paying for them more than once.
    var progress: SetupProgress {
        let prompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
        let live = Config.liveTranscriptionEnabled()
        return SetupProgress(SetupProgress.Machine(
            loginItem: mode == .permissions ? .enabled : loginItemStatus(),
            microphone: SetupPermissions.microphone(),
            systemAudio: systemAudio,
            missingLocalModel: mode == .settings && localModelIsWantedAndMissing
                ? transcriptionChoice.localEngine : nil,
            localModelDownloading: parakeetDownload != nil || whisperDownloadTask != nil
                || gigaAMDownloadTask != nil || liveDownloading,
            liveModelWanted: mode == .settings && live,
            liveModelReady: live && liveModelStore.isReady(language: prompt),
            liveModelDownloading: liveDownloading,
            summaryToolMissing: mode == .settings && chosenSummaryIsMissing))
    }

    /// What the setup page's primary button will do, or nil when there is
    /// nothing left to offer.
    var nextAction: (() -> Void)? {
        switch progress.next {
        case .startAtLogin: return { [weak self] in self?.startAtLogin() }
        case .askMicrophone: return { [weak self] in Task { await self?.askMicrophone() } }
        case .testSystemAudio: return { [weak self] in Task { await self?.testSystemAudio() } }
        case .downloadLocalModel: return { [weak self] in self?.downloadLocalIfNeeded() }
        case .downloadLiveModel: return { [weak self] in self?.downloadLiveModel() }
        case nil: return nil
        }
    }

    typealias Missing = SetupProgress.Missing

    /// What the machine still owes, in the order it has to be dealt with.
    var outstanding: [Missing] { progress.outstanding }

    /// The same list in a sentence for the setup page.
    var outstandingSentence: String { progress.sentence }

    nonisolated static func sentence(for outstanding: [Missing]) -> String {
        SetupProgress.sentence(for: outstanding)
    }

    /// Whether a model is coming down right now — the work a host must not
    /// offer to start a second time.
    var isDownloading: Bool { progress.isDownloading }

    /// What the setup page's primary button says, given where things stand.
    var nextActionTitle: String { progress.nextTitle }

    private func report(_ row: AccessRow, _ message: String) {
        row.update(.denied, detail: message)
    }
}
