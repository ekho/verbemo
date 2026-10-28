import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording and processing state at
/// a glance, and provides recording controls and navigation into the main window.
///
/// The item can be taken away — `menu_bar_icon: false` — so it is held as an
/// optional and the menu is kept apart from it. That way the menu outlives
/// every removal: it is built once, the callbacks wired to it stay wired, and
/// putting the icon back is handing the same menu to a new status item rather
/// than rebuilding a second one that would have to be kept in step with the
/// first.
@MainActor
final class MenuBarController {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    let menu: NSMenu
    /// Nil while the icon is switched off.
    private var statusItem: NSStatusItem?
    /// What the icon would be showing if it were here, so that one put back
    /// mid-meeting shows the meeting rather than an idle wave.
    private var state: State = .idle
    private var elapsed: String?
    private var isProcessing = false
    private let stateLabel: NSMenuItem
    private let recordingRow = RecordingMenuRow()
    /// Says the config file cannot be used, and opens the settings page —
    /// the one surface that names the file and offers to reveal it.
    private let configProblemItem: NSMenuItem
    private let toggleItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let autoRecordItem: NSMenuItem
    private let autoRecordStatus: NSMenuItem
    private let setupItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleAutoRecord: (() -> Void)?
    var onShowMeetings: (() -> Void)?
    var onShowRecording: (() -> Void)?
    var onImport: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowSetup: (() -> Void)?
    var onQuit: (() -> Void)?

    init(visible: Bool = true) {
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = NSFont.menuFont(ofSize: 0).tabularFigures

        let meetings = NSMenuItem(title: localised("Open Verbemo", "Открыть Verbemo"),
            action: #selector(showMeetingsClicked), keyEquivalent: "l")
        menu.addItem(meetings)
        menu.addItem(.separator())

        autoRecordItem = NSMenuItem(title: localised("Automatic meeting recording", "Автозапись встреч"),
            action: #selector(autoRecordClicked), keyEquivalent: "")
        menu.addItem(autoRecordItem)
        autoRecordStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        autoRecordStatus.isHidden = true
        menu.addItem(autoRecordStatus)

        stateLabel = NSMenuItem(title: "", action: #selector(statusClicked), keyEquivalent: "")
        stateLabel.view = recordingRow
        menu.addItem(stateLabel)

        pauseItem = NSMenuItem(title: localised("Pause", "Пауза"),
            action: #selector(pauseClicked), keyEquivalent: "p")
        toggleItem = NSMenuItem(title: localised("Finish recording", "Завершить запись"),
            action: #selector(toggleClicked), keyEquivalent: "r")
        menu.addItem(pauseItem)
        menu.addItem(toggleItem)
        // shortcut: inline controls use ⌘P/⌘R; add individual focus navigation if Tab support is required.
        for item in [pauseItem, toggleItem] {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }

        let importItem = NSMenuItem(title: localised("Import recording…", "Импортировать запись…"),
            action: #selector(importClicked), keyEquivalent: "i")
        menu.addItem(importItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: localised("Settings…", "Настройки…"),
            action: #selector(showSettingsClicked), keyEquivalent: ",")
        menu.addItem(settings)
        configProblemItem = NSMenuItem(title: "", action: #selector(showSettingsClicked), keyEquivalent: "")
        configProblemItem.isHidden = true
        menu.addItem(configProblemItem)
        setupItem = NSMenuItem(title: localised("Finish setup…", "Завершить настройку…"),
            action: #selector(showSetupClicked), keyEquivalent: "")
        menu.addItem(setupItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: localised("Quit", "Выйти"),
            action: #selector(quitClicked), keyEquivalent: "q")
        menu.addItem(quit)

        for item in [stateLabel, toggleItem, pauseItem, autoRecordItem,
                     autoRecordStatus, importItem, settings, configProblemItem, setupItem, meetings, quit] {
            item.target = self
        }
        recordingRow.onOpen = { [weak self] in self?.statusClicked() }
        recordingRow.onToggle = { [weak self] in self?.toggleClicked() }
        recordingRow.onPause = { [weak self] in self?.pauseClicked() }
        update(state: .idle, elapsed: nil)
        setVisible(visible)
    }

    /// Put the icon in the menu bar, or take it away.
    ///
    /// Removal is real rather than a zero-width item: a status item with no
    /// width still occupies its slot, still opens its menu when the place it
    /// used to be is clicked, and still counts against the room the menu bar
    /// has — so a person who turned the icon off would keep bumping into it.
    func setVisible(_ visible: Bool) {
        guard visible != (statusItem != nil) else { return }
        if visible {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            item.button?.imagePosition = .imageLeft
            // The clock ticks once a second, and in the menu bar font every
            // digit has its own width — so 1:19 becoming 1:20 changes the
            // length of the title and the whole item jitters sideways under
            // the eye. Asking the same font for its tabular figures sets the
            // numerals on one common advance and holds the item still; the
            // font itself is left alone, since the only thing wrong with it
            // was the spacing of ten glyphs.
            if let button = item.button, let font = button.font {
                button.font = font.tabularFigures
            }
            statusItem = item
            update(state: state, elapsed: elapsed)
        } else {
            statusItem.map(NSStatusBar.system.removeStatusItem)
            statusItem = nil
        }
    }

    /// Whether the icon is currently in the menu bar.
    var isVisible: Bool { statusItem != nil }

    /// First-run permissions remain available until setup is completed.
    /// `verbemo setup` resets the marker and makes the entry available again.
    func setupAvailable(_ available: Bool) {
        setupItem.isHidden = !available
    }

    /// Visible commands in their display order.
    var offeredItemTitles: [String] {
        offeredItems.map(\.title)
    }

    private var offeredItems: [NSMenuItem] {
        menu.items.filter { !$0.isHidden }
    }

    /// Drive a visible, enabled command through its normal AppKit action.
    @discardableResult
    func performOfferedItem(titled title: String) -> Bool {
        guard let item = offeredItems.first(where: { $0.isEnabled && $0.title == title }) else {
            return false
        }
        guard let action = item.action else { return false }
        return NSApplication.shared.sendAction(action, to: item.target, from: item)
    }

    /// What the item says beside its icon in the menu bar, which is words as
    /// well as a clock — "paused" is in there, and it is the one string in
    /// this class that is not in the menu at all.
    var statusItemTitle: String { statusItem?.button?.title ?? "" }
    var statusItemImage: NSImage? { statusItem?.button?.image }

    func updateActivity(_ operations: [ProcessingOperations.Snapshot]) {
        isProcessing = ActivityWork(operations).running > 0
        update(state: state, elapsed: elapsed)
    }

    /// Reflect recording state in the icon and the menu. Called once a second
    /// while recording.
    ///
    /// The icon is redrawn rather than tinted. A template image asks the system
    /// to render it in the menu bar's own foreground colour, and
    /// `contentTintColor` doesn't reliably win that argument — over a dark
    /// wallpaper the "red" icon comes out near-black on near-black and the
    /// icon effectively vanishes while recording, which is the one state that
    /// must never be invisible (upstream issue #15). Drawing the colour into a
    /// non-template image takes the system out of the decision.
    func update(state: State, elapsed: String?) {
        // Remembered whether or not there is an icon to draw it on: the menu
        // says the same things the icon does, and both are wanted the moment
        // the icon comes back.
        self.state = state
        self.elapsed = elapsed
        pauseItem.keyEquivalent = state == .idle ? "" : "p"
        toggleItem.title = state == .idle
            ? localised("Start recording", "Начать запись")
            : localised("Finish recording", "Завершить запись")
        switch state {
        case .idle:
            stateLabel.title = localised("Start recording", "Начать запись")
            pauseItem.title = localised("Pause", "Пауза")
            pauseItem.isEnabled = false
            statusItem?.button?.title = ""
        case .recording:
            stateLabel.title = localised("● Recording · ", "● Идёт запись · ") + (elapsed ?? "0:00")
            pauseItem.title = localised("Pause", "Пауза")
            pauseItem.isEnabled = true
            // The elapsed time next to the icon is the difference between
            // "something is recording" and "I know it's recording" at a glance.
            statusItem?.button?.title = " \(elapsed ?? "0:00")"
        case .paused:
            stateLabel.title = localised("Ⅱ Recording paused · ", "Ⅱ Запись на паузе · ") + (elapsed ?? "0:00")
            pauseItem.title = localised("Resume", "Продолжить")
            pauseItem.isEnabled = true
            statusItem?.button?.title =
                " " + (elapsed ?? "0:00") + localised(" paused", " пауза")
        }
        let color = WaveIcon.color(recording: state == .recording, paused: state == .paused)
            ?? (isProcessing ? .systemBlue : nil)
        statusItem?.button?.image = Self.icon(color: color)
        recordingRow.update(state: state, title: stateLabel.title)
    }

    /// The config file's problem in one line, or nil when it has none.
    func updateConfigProblem(_ headline: String?) {
        configProblemItem.title = headline.map { "⚠︎ " + $0 } ?? ""
        configProblemItem.isHidden = headline == nil
    }

    /// Keep routine detection status quiet; show only exceptions.
    func updateAutoRecord(enabled: Bool, notice: AutoRecordController.Notice?) {
        autoRecordItem.state = enabled ? .on : .off
        autoRecordStatus.title = notice?.title ?? ""
        autoRecordStatus.isHidden = !enabled || notice == nil
        autoRecordStatus.action = notice == .microphoneAccess ? #selector(showSetupClicked) : nil
        autoRecordStatus.isEnabled = notice == .microphoneAccess
    }

    /// Menu-bar status icons are nominally 18pt tall; 16 leaves a little air.
    private static func icon(color: NSColor?) -> NSImage? {
        WaveIcon.image(size: 16, color: color)
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func statusClicked() {
        if state == .idle { onToggle?() }
        else { onShowRecording?() }
    }
    @objc private func autoRecordClicked() { onToggleAutoRecord?() }
    @objc private func showSettingsClicked() { onShowSettings?() }
    @objc private func showSetupClicked() { onShowSetup?() }
    @objc private func showMeetingsClicked() { onShowMeetings?() }
    @objc private func importClicked() { onImport?() }
    @objc private func quitClicked() { onQuit?() }
}

@MainActor
private final class RecordingMenuRow: NSView {
    var onOpen: (() -> Void)?
    var onToggle: (() -> Void)?
    var onPause: (() -> Void)?
    private let headline = NSButton()
    private let start = NSButton()
    private let pause = NSButton()
    private let stop = NSButton()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        autoresizingMask = [.width]
        identifier = .init("tray.recording")
        headline.isBordered = false
        headline.alignment = .left
        headline.font = NSFont.menuFont(ofSize: 0).tabularFigures
        headline.cell?.lineBreakMode = .byTruncatingTail
        headline.identifier = .init("tray.recording.open")
        headline.target = self
        headline.action = #selector(openClicked)
        headline.setContentHuggingPriority(.init(1), for: .horizontal)
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, id, symbol, title, action) in [
            (start, "start", "record.circle", localised("Start recording", "Начать запись"), #selector(toggleClicked)),
            (pause, "pause", "pause.fill", localised("Pause recording", "Приостановить запись"), #selector(pauseClicked)),
            (stop, "stop", "stop.fill", localised("Finish recording", "Завершить запись"), #selector(toggleClicked)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = .init("tray.recording.\(id)")
            button.setAccessibilityLabel(title)
            button.toolTip = title + (button === pause ? " (⌘P)" : " (⌘R)")
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        start.contentTintColor = .systemRed
        stop.contentTintColor = .systemRed
        let controls = NSStackView(views: [start, pause, stop])
        controls.spacing = 6
        controls.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [headline, controls])
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            // Match the native menu title column, leaving room for its checkmark.
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            headline.heightAnchor.constraint(equalToConstant: 32),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: MenuBarController.State, title: String) {
        headline.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0).tabularFigures, .foregroundColor: NSColor.labelColor,
        ])
        headline.toolTip = state == .idle ? title : localised("Open current recording", "Открыть текущую запись")
        start.isHidden = state != .idle
        pause.isHidden = state == .idle
        stop.isHidden = state == .idle
        let paused = state == .paused
        let pauseTitle = paused ? localised("Resume recording", "Продолжить запись")
            : localised("Pause recording", "Приостановить запись")
        pause.image = NSImage(systemSymbolName: paused ? "record.circle" : "pause.fill", accessibilityDescription: nil)
        pause.setAccessibilityLabel(pauseTitle)
        pause.toolTip = pauseTitle + " (⌘P)"
    }
    override func mouseUp(with event: NSEvent) { openClicked() }
    private func perform(_ action: (() -> Void)?) {
        enclosingMenuItem?.menu?.cancelTracking()
        action?()
    }
    @objc private func openClicked() { perform(onOpen) }
    @objc private func toggleClicked() { perform(onToggle) }
    @objc private func pauseClicked() { perform(onPause) }
}
