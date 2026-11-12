import AppKit

@MainActor
final class RecordingBarView: NSStackView {
    var onOpen: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    private let name = NSButton()
    private let time = NSTextField(labelWithString: "00:00")
    private let pause = NSButton()
    private let stop = NSButton()
    private let dot = NSTextField(labelWithString: "●")
    var title: String {
        get { name.title }
        set { name.title = newValue; name.setAccessibilityLabel(localised("Open recording: ", "Открыть запись: ") + newValue) }
    }
    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        wantsLayer = true
        layer?.cornerRadius = 9
        identifier = .init("recording-bar")
        name.title = localised("New meeting", "Новая встреча")
        name.isBordered = false
        name.alignment = .left
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.cell?.lineBreakMode = .byTruncatingTail
        name.target = self
        name.action = #selector(openClicked)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        time.textColor = StudioStyle.muted
        for (button, symbol, label, selector) in [
            (pause, "pause", localised("Pause recording", "Приостановить запись"), #selector(pauseClicked)),
            (stop, "stop.fill", localised("Stop and save recording", "Остановить и сохранить запись"), #selector(stopClicked))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.setAccessibilityLabel(label)
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.target = self
            button.action = selector
        }
        dot.textColor = .systemRed
        dot.setAccessibilityLabel(localised("Recording active", "Запись активна"))
        stop.title = localised("Finish", "Завершить")
        stop.imagePosition = .imageLeading
        stop.contentTintColor = .systemRed
        setViews([dot, name, NSView(), time, pause, stop], in: .center)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = StudioStyle.inset.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    func update(state: MenuBarController.State, elapsed: String?) {
        isHidden = state == .idle
        time.stringValue = elapsed ?? "00:00"
        dot.textColor = state == .recording ? .systemRed : StudioStyle.muted
        dot.setAccessibilityLabel(state == .recording ? localised("Recording active", "Запись активна")
            : state == .preparing ? localised("Preparing audio", "Подготовка звука") : localised("Recording inactive", "Запись неактивна"))
        pause.isEnabled = state != .waiting
        let paused = state == .paused
        pause.image = NSImage(systemSymbolName: paused ? "play" : "pause", accessibilityDescription: nil)
        pause.setAccessibilityLabel(paused ? localised("Resume recording", "Продолжить запись") : localised("Pause recording", "Приостановить запись"))
    }
    @objc private func openClicked() { onOpen?() }
    @objc private func pauseClicked() { onPause?() }
    @objc private func stopClicked() { onStop?() }
}
