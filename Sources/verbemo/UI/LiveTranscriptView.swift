import AppKit

@MainActor
final class LiveTranscriptView: NSView, NSTextFieldDelegate {
    var readAudioLevels: (() -> (mic: AudioMeter.Reading, system: AudioMeter.Reading))?
    private let micLevel = AudioLevelView(title: localised("Microphone", "Микрофон"), source: "mic")
    private let systemLevel = AudioLevelView(title: localised("Computer audio", "Звук компьютера"), source: "system")
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    var captureSource: RecordingSession.CaptureSource = .ordinary {
        didSet {
            sourceLabel.stringValue = captureSource.title
            sourceLabel.textColor = captureSource == .fallback ? .systemOrange : JournalStyle.muted
            micLevel.title = captureSource == .direct ? localised("Your call audio", "Ваш звук в звонке") : localised("Microphone", "Микрофон")
            systemLevel.title = captureSource == .direct ? localised("Other participants", "Остальные участники") : localised("Computer audio", "Звук компьютера")
        }
    }
    private var levelTimer: Timer?
    var onRename: ((String) throws -> Void)?
    private let name = NSTextField()
    let meetingActionsHost = NSStackView()
    private var savedTitle = ""
    var onError: ((String?) -> Void)?
    var title: String {
        get { savedTitle }
        set {
            savedTitle = newValue
            if name.currentEditor() == nil { name.stringValue = newValue }
        }
    }
    init(content: NSView, recordingBar: RecordingBarView) {
        super.init(frame: .zero)
        name.font = JournalStyle.titleFont()
        name.textColor = JournalStyle.ink
        name.isBordered = false
        name.drawsBackground = false
        name.identifier = .init("recording-title")
        name.setAccessibilityLabel(localised("Current meeting title", "Название текущей встречи"))
        name.delegate = self
        let sources = NSStackView(views: [
            micLevel, systemLevel,
        ])
        sources.distribution = .fillEqually
        sources.spacing = 24
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meetingActionsHost.setContentHuggingPriority(.required, for: .horizontal)
        meetingActionsHost.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = NSStackView(views: [name, meetingActionsHost])
        titleRow.spacing = 12
        let transcript = NSBox()
        transcript.boxType = .custom
        transcript.borderType = .lineBorder
        transcript.borderColor = StudioStyle.line
        transcript.fillColor = .clear
        transcript.cornerRadius = 9
        transcript.contentViewMargins = .zero
        transcript.contentView = content
        transcript.identifier = .init("recording.transcript")
        sourceLabel.font = SetupLayout.detailFont
        sourceLabel.maximumNumberOfLines = 0
        sourceLabel.identifier = .init("recording.source")
        let stack = NSStackView(views: [titleRow, recordingBar, sourceLabel, sources, transcript])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recordingBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sourceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sources.widthAnchor.constraint(equalTo: stack.widthAnchor),
            transcript.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        transcript.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        levelTimer?.invalidate()
        levelTimer = nil
        refreshAudioLevels()
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
                self.refreshAudioLevels()
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    func refreshAudioLevels() {
        let levels = readAudioLevels?() ?? (.off, .off)
        micLevel.update(levels.0)
        systemLevel.update(levels.1)
    }

    func beginRenaming() { name.selectText(nil) }

    func controlTextDidEndEditing(_ notification: Notification) {
        let proposed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard proposed != savedTitle else { return }
        do {
            try onRename?(proposed)
            title = proposed
            onError?(nil)
        } catch {
            name.stringValue = savedTitle
            onError?(error.localizedDescription)
        }
    }
}
