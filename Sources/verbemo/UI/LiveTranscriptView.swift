import AppKit

@MainActor
final class LiveTranscriptView: NSView, NSTextFieldDelegate {
    var readAudioLevels: (() -> (mic: AudioMeter.Reading, system: AudioMeter.Reading))?
    private let micLevel = AudioLevelView(title: localised("Microphone", "Микрофон"), source: "mic")
    private let systemLevel = AudioLevelView(title: localised("Computer audio", "Звук компьютера"), source: "system")
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    private let sources = NSStackView()
    private let trackRows = FlippedStackView()
    private lazy var tracksScroll = SetupLayout.scroller(around: trackRows)
    private var displayedTracks: [CallAudioMetadata.Track]?
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
        sources.setViews([micLevel, systemLevel], in: .center)
        sources.distribution = .fillEqually
        sources.spacing = 24
        trackRows.orientation = .vertical
        trackRows.alignment = .leading
        trackRows.spacing = 6
        tracksScroll.identifier = .init("recording.tracks")
        tracksScroll.setAccessibilityLabel(localised("Captured KTalk tracks", "Получаемые дорожки KTalk"))
        tracksScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        tracksScroll.isHidden = true
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
        let stack = NSStackView(views: [titleRow, recordingBar, sourceLabel, sources, tracksScroll, transcript])
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
            tracksScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            transcript.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        transcript.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateCaptureSource(.ordinary)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateCaptureSource(_ source: RecordingSession.CaptureSource, tracks: [CallAudioMetadata.Track] = [], recovering: Bool = false) {
        sourceLabel.stringValue = source == .preparing && recovering
            ? localised("KTalk audio unavailable — preparing microphone and computer audio…",
                        "Звук KTalk недоступен — подготовка микрофона и звука компьютера…")
            : source.title
        sourceLabel.textColor = source == .fallback || source == .failed || recovering ? .systemOrange : JournalStyle.muted
        sources.isHidden = source != .ordinary && source != .fallback
        tracksScroll.isHidden = source != .direct
        let current = source == .direct ? tracks : []
        guard displayedTracks != current else { return }
        displayedTracks = current
        let labels = current.isEmpty
            ? [localised("No participant audio is arriving", "Звук участников пока не поступает")]
            : current.map { track in
                let name = track.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let role = track.isLocal ? localised("You", "Вы") : localised("Participant", "Участник")
                return role + " — " + (name.isEmpty ? localised("name unknown", "имя неизвестно") : name)
            }
        let rows = labels.map { text in
            let row = NSTextField(wrappingLabelWithString: text)
            row.font = SetupLayout.detailFont
            row.textColor = StudioStyle.ink
            row.maximumNumberOfLines = 2
            row.toolTip = text
            row.setAccessibilityLabel(text)
            row.identifier = .init("recording.track")
            return row
        }
        trackRows.setViews(rows, in: .center)
        for row in rows { row.widthAnchor.constraint(equalTo: trackRows.widthAnchor).isActive = true }
    }

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
