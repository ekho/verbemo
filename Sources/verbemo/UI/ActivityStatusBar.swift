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
        return kindTitle(job.kind)
    }

    static func kindTitle(_ kind: ProcessingOperations.Kind) -> String {
        switch kind {
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
    var directCallReady = false

    var denied: Bool {
        if microphone == .denied || calendar == .denied { return true }
        if case .refused = systemAudio { return true }
        return false
    }
    var ready: Bool { (directCallReady || (microphone == .granted && systemAudio == .heard)) && (calendar == nil || calendar == .granted) }
    var automaticBlockReason: String? {
        if microphone != .granted && !directCallReady { return localised("Microphone access needed", "Нужен доступ к микрофону") }
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
        if directCallReady {
            return localised("Direct call audio is available. Microphone and system audio access is needed only for fallback.",
                "Доступен прямой звук звонка. Доступ к микрофону и системному звуку нужен только для резервной записи.")
        }
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
    var onCancelImport: (() -> Void)?
    var settingsExplainsConfigProblem: (() -> Bool)?
    var readAudioLevels: (() -> (mic: AudioMeter.Reading, system: AudioMeter.Reading))?
    private let automatic = NSButton()
    private let microphoneAccess = NSButton()
    private let systemAccess = NSButton()
    private let calendarAccess = NSButton()
    private let messages = NSButton()
    private let messagePopover = NSPopover()
    private var serviceViews: [NSView] = []
    private var serviceContainers: [NSStackView] = []
    private var accessState = ActivityAccess(microphone: .unknown, systemAudio: nil, calendar: nil)
    private var previousReadings: (mic: AudioMeter.Reading, system: AudioMeter.Reading)?
    private let recording = NSButton()
    private let queue = NSButton()
    let queuePopover: ActivityQueuePopover
    private let queueNotice = NSStackView()
    private let queueResult = NSTextField(wrappingLabelWithString: "")
    private var queueResults: [String] = []
    private let job = NSButton()
    private let warning = NSButton()
    private let attentionPopover = ActivityAttentionPopover()
    private let spinner = NSProgressIndicator()
    let serviceContent = NSStackView()
    private let importStatus = MediaImportStatusView()
    private let serviceError = NSTextField(labelWithString: "")
    private let mic = AudioLevelView(title: localised("Microphone", "Микрофон"), source: "status-mic", compact: true)
    private let system = AudioLevelView(title: localised("System", "Система"), source: "status-system", compact: true)
    private let levels = NSStackView()
    private var levelTimer: Timer?
    private var currentSession: URL?
    private var automaticEnabled = false
    private var automaticDestination = ApplicationNavigationState.Destination.recording
    private var recordingState = MenuBarController.State.idle
    private var warningDetail: String?
    private var importFailed = false
    private var work = ActivityWork([])
    private var jobTitle: (URL) -> String = { $0.lastPathComponent }

    init(operations: ProcessingOperations = .shared) {
        queuePopover = ActivityQueuePopover(operations: operations)
        super.init(frame: .zero)
        identifier = .init("activity-status-bar")
        orientation = .horizontal
        alignment = .centerY
        spacing = 9
        edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        for (button, id, action) in [
            (microphoneAccess, "activity.microphone-access", #selector(microphoneClicked)),
            (systemAccess, "activity.system-access", #selector(systemClicked)),
            (calendarAccess, "activity.calendar-access", #selector(calendarSettings)),
            (messages, "activity.messages", #selector(showMessages)),
            (recording, "activity.recording", #selector(recordingClicked)),
            (queue, "activity.queue", #selector(queueClicked)),
            (job, "activity.job", #selector(jobClicked)),
            (warning, "activity.warning", #selector(warningClicked))
        ] {
            button.identifier = .init(id)
            button.title = ""
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
        automatic.title = ""
        automatic.isBordered = false
        automatic.imagePosition = .imageOnly
        automatic.setButtonType(.toggle)
        let menu = NSMenu()
        let settings = NSMenuItem(title: localised("Automatic recording settings", "Настройки автозаписи"),
                                  action: #selector(automaticDetails), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        automatic.menu = menu
        automatic.target = self
        automatic.action = #selector(automaticClicked)
        levels.setViews([microphoneAccess, mic, systemAccess, system, calendarAccess], in: .center)
        levels.spacing = 4
        levels.setHuggingPriority(.required, for: .horizontal)
        for meter in [mic, system] { meter.widthAnchor.constraint(equalToConstant: 32).isActive = true }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true
        job.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        job.setContentHuggingPriority(.init(1), for: .horizontal)
        messages.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recording.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        importStatus.onCancel = { [weak self] in
            self?.onCancelImport?()
            self?.refreshMessages()
        }
        serviceError.font = .systemFont(ofSize: 11)
        serviceError.textColor = .systemOrange
        serviceError.isHidden = true
        serviceError.identifier = .init("activity.error")
        queueResult.font = .systemFont(ofSize: 11)
        queueResult.textColor = JournalStyle.ink
        let dismissResult = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                                     target: self, action: #selector(dismissQueueResults))
        dismissResult.bezelStyle = .inline
        dismissResult.setAccessibilityLabel(localised("Dismiss queue messages", "Скрыть сообщения очереди"))
        queueNotice.setViews([queueResult, dismissResult], in: .center)
        queueNotice.alignment = .top
        queueNotice.isHidden = true
        queueNotice.identifier = .init("activity.queue-result")
        queuePopover.onOpenProcessing = { [weak self] in self?.onQueue?() }
        attentionPopover.onOpenMeeting = { [weak self] in self?.onJob?($0) }
        attentionPopover.onOpenSettings = { [weak self] in self?.onAccess?(.general) }
        queuePopover.onResult = { [weak self] in self?.reportQueueResult($0) }
        queuePopover.onChange = { [weak self] in
            guard let self else { return }
            updateWork(operations.snapshot(), title: jobTitle)
        }
        configureMessages()
        setServiceViews([])
        let capture = NSStackView(views: [automatic, recording, levels])
        capture.spacing = 6
        capture.alignment = .centerY
        capture.setHuggingPriority(.required, for: .horizontal)
        let workGroup = NSStackView(views: [queue, spinner, job, messages])
        workGroup.spacing = 6
        workGroup.alignment = .centerY
        workGroup.setHuggingPriority(.init(1), for: .horizontal)
        setViews([capture, workGroup, warning], in: .center)
        updateAutomatic(false, reason: nil)
        updateRecording(.idle, elapsed: nil)
        updateAccess(.init(microphone: .unknown, systemAudio: nil, calendar: nil))
        updateWork([], title: { $0.lastPathComponent })
        refreshWarning()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func updateAutomatic(_ enabled: Bool, reason: String?, blocked: Bool = false) {
        automaticEnabled = enabled
        automatic.state = enabled ? .on : .off
        let unavailable = enabled && blocked
        automatic.image = unavailable ? Self.blockedAutomaticImage : Self.automaticImage
        automatic.contentTintColor = unavailable ? .systemOrange : enabled ? .systemGreen : JournalStyle.muted
        let detail = (unavailable ? localised("Auto-record blocked", "Автозапись заблокирована")
            : enabled ? localised("Auto-record on", "Автозапись включена") : localised("Auto-record off", "Автозапись выключена"))
            + (reason.map { "\n" + $0 } ?? "")
        let hint = automaticNeedsMicrophone
            ? localised("Click for recording settings", "Клик открывает настройки записи")
            : localised("Right-click for settings", "Правый клик открывает настройки")
        describe(automatic, detail + "\n" + hint)
    }

    private var automaticNeedsMicrophone: Bool { automaticEnabled && accessState.microphone != .granted }

    private static let automaticImage = automaticGlyph(crossed: false)
    private static let blockedAutomaticImage = automaticGlyph(crossed: true)

    private static func automaticGlyph(crossed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            let letter = NSBezierPath()
            letter.move(to: NSPoint(x: 5.5, y: 12))
            letter.line(to: NSPoint(x: 9, y: 5.5))
            letter.line(to: NSPoint(x: 12.5, y: 12))
            letter.move(to: NSPoint(x: 7, y: 9.5))
            letter.line(to: NSPoint(x: 11, y: 9.5))
            letter.lineWidth = 1.4
            NSGraphicsContext.current?.compositingOperation = .clear
            letter.stroke()
            if crossed {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 2))
                slash.line(to: NSPoint(x: 16, y: 15))
                slash.lineWidth = 3
                slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 2, y: 3))
                line.line(to: NSPoint(x: 15, y: 16))
                line.lineWidth = 1.4
                line.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func updateAccess(_ state: ActivityAccess) {
        let changed = accessState.microphone != state.microphone || accessState.systemAudio != state.systemAudio
            || accessState.calendar != state.calendar
        accessState = state
        automaticDestination = state.automaticDestination
        if changed || microphoneAccess.image == nil { refreshSources() }
    }

    private func refreshSources() {
        let parts = accessState.detail.components(separatedBy: "\n")
        let micNeedsAccess = accessState.microphone != .granted
        let systemDenied: Bool
        if case .refused = accessState.systemAudio { systemDenied = true } else { systemDenied = false }
        let micLost = !micNeedsAccess && previousReadings?.mic == .unavailable
        let systemLost = previousReadings?.system == .unavailable
        source(microphoneAccess, symbol: micNeedsAccess || micLost ? "mic.slash" : "mic",
               detail: accessState.microphone == .denied ? localised("Microphone access denied", "Доступ к микрофону запрещён")
                   : micLost ? localised("Microphone signal unavailable", "Сигнал микрофона недоступен") : parts[0],
               caution: micNeedsAccess || micLost)
        source(systemAccess, symbol: systemDenied || systemLost ? "speaker.slash" : "speaker.wave.2",
               detail: systemDenied ? localised("System audio access denied", "Доступ к звуку системы запрещён")
                   : systemLost ? localised("System audio signal unavailable", "Сигнал звука системы недоступен") : parts[1],
               caution: SetupPermissions.needsSystemAudioTest(accessState.systemAudio) || systemLost)
        calendarAccess.isHidden = accessState.calendar == nil
        if let calendar = accessState.calendar {
            let unavailable = calendar != .granted
            source(calendarAccess, symbol: "calendar", detail: calendar == .denied
                ? localised("Calendar access denied", "Доступ к календарю запрещён") : parts[2],
                caution: unavailable)
            if unavailable, let image = calendarAccess.image {
                let crossed = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                    image.draw(in: rect.insetBy(dx: 2, dy: 2))
                    let slash = NSBezierPath()
                    slash.move(to: NSPoint(x: 2, y: 16))
                    slash.line(to: NSPoint(x: 16, y: 2))
                    NSGraphicsContext.current?.compositingOperation = .clear
                    slash.lineWidth = 3.5
                    slash.stroke()
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                    NSColor.black.setStroke()
                    slash.lineWidth = 1.4
                    slash.stroke()
                    return true
                }
                crossed.isTemplate = true
                calendarAccess.image = crossed
            }
        }
    }

    private func source(_ button: NSButton, symbol: String, detail: String, caution: Bool) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.contentTintColor = caution ? .systemOrange : JournalStyle.muted
        describe(button, detail)
    }

    private func describe(_ button: NSButton, _ detail: String) {
        button.toolTip = detail
        button.setAccessibilityLabel(detail)
    }

    func updateRecording(_ state: MenuBarController.State, elapsed: String?) {
        recordingState = state
        let title: String
        let symbol: String
        switch state {
        case .idle: title = localised("Not recording", "Нет записи"); symbol = "circle"
        case .recording: title = localised("Recording", "Запись"); symbol = "circle.fill"
        case .paused: title = localised("Paused", "Пауза"); symbol = "pause.fill"
        case .preparing: title = localised("Preparing audio…", "Подготовка звука…"); symbol = "hourglass"
        case .waiting: title = localised("Call ended — finish recording", "Звонок завершён — завершите запись"); symbol = "stop.circle"
        }
        recording.title = state == .idle ? "" : elapsed ?? "0:00"
        recording.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        recording.imagePosition = state == .idle ? .imageOnly : .imageLeading
        describe(recording, title + (state == .idle ? "" : " " + recording.title))
        recording.isEnabled = state != .idle
        recording.contentTintColor = state == .recording ? .systemRed : state == .paused ? .systemOrange : JournalStyle.muted
        mic.isHidden = state == .idle
        system.isHidden = state == .idle
        refreshAudioLevels()
    }

    func updateWork(_ operations: [ProcessingOperations.Snapshot], title: @escaping (URL) -> String) {
        work = ActivityWork(operations)
        jobTitle = title
        queue.title = "\(work.running) · \(work.waiting)"
        queue.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        queue.imagePosition = .imageLeading
        queue.contentTintColor = work.running > 0 ? .systemBlue : JournalStyle.muted
        queue.setAccessibilityLabel(localised("Running: \(work.running). Waiting: \(work.waiting). Open task queue.",
            "Выполняется: \(work.running). Ожидают: \(work.waiting). Открыть очередь задач."))
        queue.toolTip = ([localised("Running: \(work.running) · Waiting: \(work.waiting)",
                                    "Выполняется: \(work.running) · Ожидают: \(work.waiting)")] + work.jobs.map { ($0.session.map(title) ?? localised("Import", "Импорт")) + " · " + ActivityWork.stage($0) }).joined(separator: "\n")
        spinner.toolTip = queue.toolTip
        if work.running > 0 { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        queuePopover.update(work, title: title)
        refreshJob()
    }

    var serviceRows: [NSView] { [importStatus, serviceError, queueNotice] + serviceViews }

    func setServiceViews(_ views: [NSView]) {
        serviceContent.setViews([], in: .center)
        serviceViews = views
        serviceContainers = serviceRows.map { view in
            let row = NSStackView(views: [view])
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return row
        }
        serviceContent.setViews(serviceContainers, in: .center)
        for (view, row) in zip(serviceRows, serviceContainers) {
            row.widthAnchor.constraint(equalTo: serviceContent.widthAnchor, constant: -24).isActive = true
            view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            wrapMessageLabels(in: view)
        }
        refreshMessages()
    }

    private func wrapMessageLabels(in view: NSView) {
        if let label = view as? NSTextField {
            label.maximumNumberOfLines = 0
            label.cell?.usesSingleLineMode = false
            label.cell?.wraps = true
            label.lineBreakMode = .byWordWrapping
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for child in view.subviews { wrapMessageLabels(in: child) }
    }

    private func configureMessages() {
        serviceContent.orientation = .vertical
        serviceContent.alignment = .leading
        serviceContent.distribution = .fill
        serviceContent.spacing = 8
        serviceContent.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let size = NSSize(width: 520, height: 240)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = serviceContent
        serviceContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            serviceContent.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            serviceContent.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            serviceContent.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        let controller = NSViewController()
        controller.view = scroll
        controller.preferredContentSize = size
        messagePopover.contentViewController = controller
        messagePopover.behavior = .transient
        messagePopover.contentSize = size
        messages.imagePosition = .imageLeading
    }

    func refreshMessages() {
        func text(_ view: NSView) -> String? {
            guard !view.isHidden else { return nil }
            if let label = view as? NSTextField, !label.stringValue.isEmpty { return label.stringValue }
            return view.subviews.lazy.compactMap(text).first
        }
        let rows = zip(serviceRows, serviceContainers).compactMap { view, container -> (String, Int)? in
            let id = view.identifier?.rawValue ?? ""
            let duplicateConfig = id == "activity.config-problem" && (warningDetail != nil || settingsExplainsConfigProblem?() == true)
            let duplicateCapture = id == "meeting.work-status" && recordingState != .idle
                && (view as? NSTextField).map { label in
                    [localised("Recording paused", "Запись приостановлена"),
                     localised("Recording in progress", "Идёт запись")].contains(label.stringValue)
                } == true
            let visible = !view.isHidden && !duplicateConfig && !duplicateCapture
            if container.isHidden == visible { container.isHidden = !visible }
            guard visible else { return nil }
            let message = text(view) ?? (view as? NSButton)?.title ?? ""
            let priority = ["activity.error", "meeting.operation-error"].contains(id)
                || view === importStatus && importFailed ? 0 : view === importStatus ? 1 : 2
            return (message, priority)
        }.sorted { $0.1 < $1.1 }
        messages.isHidden = rows.isEmpty
        guard let first = rows.first else { messagePopover.close(); return }
        let title = "\(rows.count)" + (first.0.isEmpty ? "" : " · " + first.0)
        let detail = localised("Messages: \(rows.count)", "Сообщения: \(rows.count)") + "\n" + rows.map(\.0).joined(separator: "\n")
        if messages.title != title { messages.title = title }
        if messages.toolTip != detail { describe(messages, detail) }
        let symbol = first.1 == 0 ? "exclamationmark.circle" : "text.bubble"
        if messages.image?.accessibilityDescription != symbol {
            messages.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        }
        messages.contentTintColor = first.1 == 0 ? .systemRed : first.1 == 1 ? .systemBlue : JournalStyle.ink
    }

    @objc private func showMessages() {
        if messagePopover.isShown { messagePopover.close(); return }
        messagePopover.show(relativeTo: messages.bounds, of: messages, preferredEdge: .maxY)
    }
    func reportError(_ message: String?) {
        serviceError.stringValue = message?.split(whereSeparator: \.isNewline).joined(separator: " ") ?? ""
        serviceError.toolTip = message
        serviceError.isHidden = message == nil
        refreshMessages()
        NSAccessibility.post(element: serviceError, notification: .valueChanged)
    }

    private func reportQueueResult(_ message: String) {
        queueResults.append(message.split(whereSeparator: \.isNewline).joined(separator: " "))
        queueResults = Array(queueResults.suffix(4))
        queueResult.stringValue = queueResults.joined(separator: "\n")
        queueResult.toolTip = queueResult.stringValue
        queueNotice.isHidden = false
        refreshMessages()
        NSAccessibility.post(element: queueResult, notification: .valueChanged)
    }

    @objc private func dismissQueueResults() {
        queueResults.removeAll()
        queueResult.stringValue = ""
        queueNotice.isHidden = true
        refreshMessages()
    }
    func showImport(_ update: MediaImportCoordinator.Update) {
        importFailed = false
        importStatus.update(update)
        refreshJob()
        refreshMessages()
    }
    func finishImport(_ result: MediaImportCoordinator.Result) {
        importFailed = !result.failures.isEmpty
        importStatus.finish(result)
        refreshJob()
        refreshMessages()
    }
    private func refreshJob() {
        let current = work.current
        currentSession = current?.session
        let text = current.map { ($0.session.map(jobTitle).map { $0 + " · " } ?? "") + ActivityWork.stage($0) } ?? ""
        job.title = current.map(ActivityWork.stage) ?? ""
        job.toolTip = text
        job.setAccessibilityLabel(text)
        job.isEnabled = current != nil
        job.isHidden = current == nil || current?.kind == .importMedia && !importStatus.isHidden
    }

    func updateAttention(_ meetings: [MeetingPresentation.Attention], detail: String?) {
        attentionPopover.update(meetings, settingsProblem: detail)
        warningDetail = detail
        refreshWarning()
        refreshMessages()
    }
    private func refreshWarning() {
        let count = attentionPopover.meetings.count + (warningDetail == nil ? 0 : 1)
        warning.isHidden = count == 0
        warning.title = "\(count)"
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        warning.imagePosition = .imageLeading
        warning.contentTintColor = .systemOrange
        var details = [localised("\(count) need attention", "Требуют внимания: \(count)")]
        if let warningDetail { details.append(warningDetail) }
        let detail = details.joined(separator: "\n")
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
                guard self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
                self.refreshMessages()
                if self.recordingState != .idle { self.refreshAudioLevels() }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }
    func stop() {
        levelTimer?.invalidate()
        levelTimer = nil
        spinner.stopAnimation(nil)
        messagePopover.close()
        queuePopover.stop()
        attentionPopover.close()
    }
    func refreshAudioLevels() {
        let readings = recordingState == .idle ? (mic: AudioMeter.Reading.off, system: .off)
            : recordingState == .paused ? (mic: AudioMeter.Reading.paused, system: .paused)
            : readAudioLevels?() ?? (.off, .off)
        let sourceChanged = (previousReadings?.mic == .unavailable) != (readings.mic == .unavailable)
            || (previousReadings?.system == .unavailable) != (readings.system == .unavailable)
        previousReadings = readings
        mic.update(accessState.microphone == .denied ? .off : readings.mic)
        if case .refused = accessState.systemAudio { system.update(.off) } else { system.update(readings.system) }
        if sourceChanged { refreshSources() }
    }
    @objc private func automaticClicked() {
        if automaticNeedsMicrophone {
            automatic.state = .on
            onAccess?(.recording)
        } else {
            onToggleAutomatic?()
        }
    }
    @objc private func automaticDetails() { onAccess?(automaticDestination) }
    @objc private func microphoneClicked() {
        if previousReadings?.mic == .unavailable && accessState.microphone == .granted { onRecording?() }
        else { onAccess?(.recording) }
    }
    @objc private func systemClicked() {
        if case .refused = accessState.systemAudio { onAccess?(.recording) }
        else if previousReadings?.system == .unavailable { onRecording?() }
        else { onAccess?(.recording) }
    }
    @objc private func calendarSettings() { onAccess?(.calendar) }
    @objc private func recordingClicked() { onRecording?() }
    @objc private func queueClicked() { queuePopover.toggle(from: queue) }
    @objc private func jobClicked() { onJob?(currentSession) }
    @objc private func warningClicked() {
        if !attentionPopover.meetings.isEmpty { attentionPopover.toggle(from: warning) }
        else if warningDetail != nil { onAccess?(.general) }
    }
}
