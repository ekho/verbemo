import AppKit

struct ActivityWork {
    let jobs: [ProcessingOperations.Snapshot]
    init(_ operations: [ProcessingOperations.Snapshot]) {
        // Queue drains and sweeps own child jobs; they are not extra work for the user.
        jobs = operations.filter { $0.kind != .sweep && ($0.session != nil || $0.kind == .importMedia) }
    }
    var running: Int { jobs.filter { $0.state != .waiting }.count }
    var waiting: Int { jobs.count - running }
    var current: ProcessingOperations.Snapshot? { jobs.first { $0.state != .waiting } ?? jobs.first }

    static func stage(_ job: ProcessingOperations.Snapshot) -> String {
        if job.state == .cancelling { return localised("Cancelling…", "Отмена…") }
        if job.state == .waiting { return localised("Waiting", "Ожидание") }
        switch job.kind {
        case .transcription: return localised("Transcription", "Расшифровка")
        case .diarization: return localised("Separating speakers", "Разделение говорящих")
        case .postProcessing: return localised("Naming speakers", "Имена говорящих")
        case .summary: return localised("Creating summary", "Создание сводки")
        case .importMedia: return localised("Import", "Импорт")
        case .archive: return localised("Saving audio", "Сохранение аудио")
        case .sweep: return localised("Processing", "Обработка")
        }
    }
}

struct ActivityAccess {
    var microphone: SetupPermissions.State
    var systemAudio: SetupPermissions.SystemAudioResult?
    var calendar: SetupPermissions.State?
    var micActivity = true
    var autoCalendar = false
    var hasSelectedCalendar = true

    var denied: Bool {
        if microphone == .denied || calendar == .denied { return true }
        if case .refused = systemAudio { return true }
        return false
    }
    var ready: Bool { microphone == .granted && systemAudio == .heard && (calendar == nil || calendar == .granted) }
    var automaticBlockReason: String? {
        if microphone != .granted { return localised("Microphone access needed", "Нужен доступ к микрофону") }
        if !micActivity && !autoCalendar { return localised("Enable microphone or calendar triggering", "Включите запуск по микрофону или календарю") }
        if !micActivity && calendar != .granted { return localised("Calendar access needed", "Нужен доступ к календарю") }
        if !micActivity && !hasSelectedCalendar { return localised("Choose a calendar", "Выберите календарь") }
        return nil
    }
    var automaticDestination: ApplicationNavigationState.Destination {
        microphone == .granted && !micActivity && autoCalendar && automaticBlockReason != nil ? .calendar : .recording
    }
    var title: String { localised("Access: ", "Доступ: ") + (ready ? "✓" : denied ? "!" : "?") }
    var destination: ApplicationNavigationState.Destination {
        microphone == .granted && systemAudio == .heard && calendar != nil && calendar != .granted ? .calendar : .recording
    }
    var detail: String {
        var parts = [microphone == .granted
            ? localised("Microphone allowed", "Микрофон разрешён")
            : localised("Microphone access needed", "Нужен доступ к микрофону")]
        parts.append(systemAudio == .heard
            ? localised("System audio: recent sound test passed", "Звук системы: недавняя проверка звуком пройдена")
            : localised("System audio needs a sound test; macOS does not expose its permission state", "Звук системы нужно проверить звуком: macOS не сообщает состояние этого разрешения"))
        if let calendar {
            parts.append(calendar == .granted ? localised("Calendar allowed", "Календарь разрешён")
                : localised("Calendar access needed", "Нужен доступ к календарю"))
        }
        parts.append(localised("Permissions do not confirm that audio is being captured.", "Разрешения не подтверждают, что звук поступает."))
        return parts.joined(separator: "\n")
    }
}

@MainActor
final class ActivityStatusBar: NSStackView {
    var onToggleAutomatic: (() -> Void)?
    var onRecording: (() -> Void)?
    var onQueue: (() -> Void)?
    var onJob: ((URL?) -> Void)?
    var onAccess: ((ApplicationNavigationState.Destination) -> Void)?
    var onAttention: (() -> Void)?
    var readAudioLevels: (() -> (mic: AudioMeter.Reading, system: AudioMeter.Reading))?
    private let automatic = NSSwitch()
    private let autoLabel = NSButton()
    private let access = NSButton()
    private let recording = NSButton()
    private let queue = NSButton()
    private let job = NSButton()
    private let warning = NSButton()
    private let spinner = NSProgressIndicator()
    private let mic = AudioLevelView(title: localised("Microphone", "Микрофон"), source: "status-mic", compact: true)
    private let system = AudioLevelView(title: localised("System", "Система"), source: "status-system", compact: true)
    private let levels = NSStackView()
    private var levelTimer: Timer?
    private var currentSession: URL?
    private var accessDestination = ApplicationNavigationState.Destination.recording
    private var automaticDestination = ApplicationNavigationState.Destination.recording
    private var recordingState = MenuBarController.State.idle
    private var warningDetail: String?
    private var attentionCount = 0
    private var importProgress: MediaImportPresentation.Copy?
    private var work = ActivityWork([])
    private var jobTitle: (URL) -> String = { $0.lastPathComponent }

    init() {
        super.init(frame: .zero)
        identifier = .init("activity-status-bar")
        orientation = .horizontal
        alignment = .centerY
        spacing = 9
        edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        for (button, id, action) in [
            (autoLabel, "activity.automatic", #selector(automaticDetails)),
            (access, "activity.access", #selector(accessClicked)),
            (recording, "activity.recording", #selector(recordingClicked)),
            (queue, "activity.queue", #selector(queueClicked)),
            (job, "activity.job", #selector(jobClicked)),
            (warning, "activity.warning", #selector(warningClicked))
        ] {
            button.identifier = .init(id)
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.alignment = .left
            button.cell?.wraps = false
            button.cell?.lineBreakMode = .byTruncatingTail
            button.target = self
            button.action = action
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        automatic.identifier = .init("navigation.auto-record")
        automatic.controlSize = .mini
        automatic.setAccessibilityLabel(localised("Automatic meeting recording", "Автозапись встреч"))
        automatic.target = self
        automatic.action = #selector(automaticClicked)
        let auto = NSStackView(views: [autoLabel, automatic])
        auto.spacing = 4
        levels.setViews([mic, system], in: .center)
        levels.spacing = 6
        for meter in [mic, system] { meter.widthAnchor.constraint(equalToConstant: 48).isActive = true }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true
        job.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        job.setContentHuggingPriority(.init(1), for: .horizontal)
        recording.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        setViews([auto, access, recording, levels, queue, spinner, job, warning], in: .center)
        updateAutomatic(false, reason: nil)
        updateRecording(.idle, elapsed: nil)
        updateAccess(.init(microphone: .unknown, systemAudio: nil, calendar: nil))
        updateWork([], title: { $0.lastPathComponent })
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func updateAutomatic(_ enabled: Bool, reason: String?, blocked: Bool = false) {
        automatic.state = enabled ? .on : .off
        let text = localised("Auto-record", "Автозапись") + (enabled && blocked ? " !" : "")
        autoLabel.title = text
        autoLabel.contentTintColor = enabled && blocked ? .systemOrange : JournalStyle.muted
        let detail = (enabled ? localised("Auto-record on", "Автозапись включена") : localised("Auto-record off", "Автозапись выключена"))
            + (reason.map { "\n" + $0 } ?? "")
        autoLabel.toolTip = detail
        autoLabel.setAccessibilityLabel(detail)
        automatic.toolTip = detail
    }

    func updateAccess(_ state: ActivityAccess) {
        access.title = state.title
        access.toolTip = state.detail
        access.setAccessibilityLabel(state.title + "\n" + state.detail)
        access.contentTintColor = state.denied ? .systemOrange : JournalStyle.muted
        accessDestination = state.destination
        automaticDestination = state.automaticDestination
    }

    func updateRecording(_ state: MenuBarController.State, elapsed: String?) {
        recordingState = state
        switch state {
        case .idle: recording.title = localised("Not recording", "Нет записи")
        case .recording: recording.title = "● " + localised("Recording ", "Запись ") + (elapsed ?? "0:00")
        case .paused: recording.title = "Ⅱ " + localised("Paused ", "Пауза ") + (elapsed ?? "0:00")
        }
        recording.isEnabled = state != .idle
        recording.contentTintColor = state == .recording ? .systemRed : state == .paused ? .systemOrange : JournalStyle.muted
        levels.isHidden = state == .idle
        refreshAudioLevels()
    }

    func updateWork(_ operations: [ProcessingOperations.Snapshot], title: @escaping (URL) -> String) {
        work = ActivityWork(operations)
        jobTitle = title
        queue.title = work.jobs.isEmpty ? localised("Queue: 0", "Очередь: 0")
            : localised("Active: \(work.running) · Waiting: \(work.waiting)", "Работа: \(work.running) · Ждут: \(work.waiting)")
        queue.setAccessibilityLabel(localised("Running: \(work.running). Waiting: \(work.waiting). Open processing.",
            "Выполняется: \(work.running). Ожидают: \(work.waiting). Открыть обработку."))
        queue.toolTip = work.jobs.map { ($0.session.map(title) ?? localised("Import", "Импорт")) + " · " + ActivityWork.stage($0) }.joined(separator: "\n")
        if work.running > 0 { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refreshJob()
    }

    func updateImport(_ progress: MediaImportPresentation.Copy?) {
        importProgress = progress
        refreshJob()
    }
    private func refreshJob() {
        let current = work.current
        currentSession = current?.session
        var text = current.map { ($0.session.map(jobTitle).map { $0 + " · " } ?? "") + ActivityWork.stage($0) } ?? ""
        if let current, current.kind == .importMedia, current.state != .cancelling, let progress = importProgress {
            text = progress.label
            if let fraction = progress.fraction, fraction.isFinite {
                text += " · \(Int(min(1, max(0, fraction)) * 100))%"
            }
        }
        job.title = text
        job.toolTip = text
        job.setAccessibilityLabel(text)
        job.isEnabled = current != nil
    }

    func updateAttention(count: Int, detail: String?) {
        attentionCount = count
        warningDetail = detail
        refreshWarning()
    }
    private var sourceWarnings: [String] = []
    private func refreshWarning() {
        let count = attentionCount + (warningDetail == nil ? 0 : 1) + sourceWarnings.count
        warning.isHidden = count == 0
        warning.title = "⚠ \(count)"
        warning.contentTintColor = .systemOrange
        let detail = ([localised("\(count) need attention", "Требуют внимания: \(count)")] + [warningDetail].compactMap { $0 } + sourceWarnings).joined(separator: "\n")
        warning.toolTip = detail
        warning.setAccessibilityLabel(detail)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        levelTimer?.invalidate()
        levelTimer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor, self.recordingState != .idle else { return }
                self.refreshAudioLevels()
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }
    func stop() { levelTimer?.invalidate(); levelTimer = nil; spinner.stopAnimation(nil) }
    func refreshAudioLevels() {
        let readings = recordingState == .idle ? (mic: AudioMeter.Reading.off, system: .off)
            : recordingState == .paused ? (mic: AudioMeter.Reading.paused, system: .paused)
            : readAudioLevels?() ?? (.off, .off)
        mic.update(readings.mic)
        system.update(readings.system)
        sourceWarnings = []
        if readings.mic == .unavailable { sourceWarnings.append(localised("Microphone signal unavailable", "Сигнал микрофона недоступен")) }
        if readings.system == .unavailable { sourceWarnings.append(localised("System audio signal unavailable", "Сигнал звука системы недоступен")) }
        refreshWarning()
    }
    @objc private func automaticClicked() { onToggleAutomatic?() }
    @objc private func automaticDetails() { onAccess?(automaticDestination) }
    @objc private func accessClicked() { onAccess?(accessDestination) }
    @objc private func recordingClicked() { onRecording?() }
    @objc private func queueClicked() { onQueue?() }
    @objc private func jobClicked() { onJob?(currentSession) }
    @objc private func warningClicked() {
        if !sourceWarnings.isEmpty { onRecording?() }
        else if warningDetail != nil { onAccess?(.general) }
        else { onAttention?() }
    }
}
