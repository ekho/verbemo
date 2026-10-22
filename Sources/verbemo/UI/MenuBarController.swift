import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
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
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    /// Says the config file cannot be used, and opens the settings page —
    /// the one surface that names the file and offers to reveal it.
    private let configProblemItem: NSMenuItem
    private let startItem: NSMenuItem
    private let toggleItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let autoRecordItem: NSMenuItem
    private let autoRecordStatus: NSMenuItem
    private let setupItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleAutoRecord: (() -> Void)?
    var onShowMeetings: (() -> Void)?
    var onImport: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowSetup: (() -> Void)?
    var onShowTranscription: (() -> Void)?
    var onQuit: (() -> Void)?

    init(visible: Bool = true) {
        menu = NSMenu()
        menu.autoenablesItems = false
        // The first line of the menu carries the same clock the icon does,
        // and it ticks while the menu is open. Setting the font on the menu
        // rather than on that one item is what keeps the rest of it alone:
        // an item drawn from an attributed title loses the grey the system
        // gives a disabled one, and the state line is disabled.
        menu.font = NSFont.menuFont(ofSize: 0).tabularFigures

        stateLabel = .sectionHeader(title: "")
        menu.addItem(stateLabel)

        startItem = NSMenuItem(title: localised("Start recording", "Начать запись"),
            action: #selector(toggleClicked), keyEquivalent: "r")
        startItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        menu.addItem(startItem)

        pauseItem = NSMenuItem(title: localised("Pause", "Пауза"),
            action: #selector(pauseClicked), keyEquivalent: "p")
        toggleItem = NSMenuItem(title: localised("Finish recording", "Завершить запись"),
            action: #selector(toggleClicked), keyEquivalent: "r")
        menu.addItem(pauseItem)
        menu.addItem(toggleItem)

        transcriptionLabel = NSMenuItem(title: "", action: #selector(transcriptionClicked), keyEquivalent: "")
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        let importItem = NSMenuItem(title: localised("Import recording…", "Импортировать запись…"),
            action: #selector(importClicked), keyEquivalent: "i")
        menu.addItem(importItem)
        autoRecordItem = NSMenuItem(title: localised("Automatic meeting recording", "Автозапись встреч"),
            action: #selector(autoRecordClicked), keyEquivalent: "")
        menu.addItem(autoRecordItem)
        autoRecordStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        autoRecordStatus.isHidden = true
        menu.addItem(autoRecordStatus)
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
        let meetings = NSMenuItem(title: localised("Open Verbemo", "Открыть Verbemo"),
            action: #selector(showMeetingsClicked), keyEquivalent: "l")
        menu.addItem(meetings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: localised("Quit Verbemo", "Выйти из Verbemo"),
            action: #selector(quitClicked), keyEquivalent: "q")
        menu.addItem(quit)

        for item in [startItem, toggleItem, pauseItem, transcriptionLabel, autoRecordItem,
                     autoRecordStatus, importItem, settings, configProblemItem, setupItem, meetings, quit] {
            item.target = self
        }
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
        startItem.keyEquivalent = state == .idle ? "r" : ""
        toggleItem.keyEquivalent = state == .idle ? "" : "r"
        pauseItem.keyEquivalent = state == .idle ? "" : "p"
        stateLabel.isHidden = state == .idle
        startItem.isHidden = state != .idle
        startItem.isEnabled = state == .idle
        pauseItem.isHidden = state == .idle
        toggleItem.isHidden = state == .idle
        toggleItem.isEnabled = state != .idle
        switch state {
        case .idle:
            stateLabel.title = localised("ready", "готов")
            pauseItem.title = localised("Pause", "Пауза")
            pauseItem.isEnabled = false
            statusItem?.button?.image = Self.icon(color: nil)
            statusItem?.button?.title = ""
        case .recording:
            stateLabel.title = localised("● Recording · ", "● Идёт запись · ") + (elapsed ?? "0:00")
            pauseItem.title = localised("Pause", "Пауза")
            pauseItem.isEnabled = true
            statusItem?.button?.image = Self.icon(color: .systemRed)
            // The elapsed time next to the icon is the difference between
            // "something is recording" and "I know it's recording" at a glance.
            statusItem?.button?.title = " \(elapsed ?? "0:00")"
        case .paused:
            stateLabel.title = localised("Ⅱ Recording paused · ", "Ⅱ Запись на паузе · ") + (elapsed ?? "0:00")
            pauseItem.title = localised("Resume", "Продолжить")
            pauseItem.isEnabled = true
            statusItem?.button?.image = Self.icon(color: .systemOrange)
            statusItem?.button?.title =
                " " + (elapsed ?? "0:00") + localised(" paused", " пауза")
        }
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
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
        autoRecordStatus.indentationLevel = 1
    }

    /// Menu-bar status icons are nominally 18pt tall; 16 leaves a little air.
    private static func icon(color: NSColor?) -> NSImage? {
        WaveIcon.image(size: 16, color: color)
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func autoRecordClicked() { onToggleAutoRecord?() }
    @objc private func showSettingsClicked() { onShowSettings?() }
    @objc private func showSetupClicked() { onShowSetup?() }
    @objc private func showMeetingsClicked() { onShowMeetings?() }
    @objc private func importClicked() { onImport?() }
    @objc private func transcriptionClicked() { onShowTranscription?() }
    @objc private func quitClicked() { onQuit?() }
}
