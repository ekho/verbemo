import AppKit

@MainActor
final class NewRecordingSheet: NSObject, NSTextFieldDelegate {
    typealias CalendarOptions = (suggested: CalendarWatcher.Meeting?, events: [CalendarWatcher.Meeting])
    enum Result {
        case start(title: String, meeting: CalendarWatcher.Meeting?)
        case cancel
        case settings
    }
    let panel: NSPanel
    let name = NSTextField(string: "")
    let calendarPicker = CalendarEventPicker()
    var date: NSDatePicker { calendarPicker.date }
    private let note = NSTextField(wrappingLabelWithString: "")
    private let start = NSButton()
    private let calendarEnabled: Bool
    private let loadCalendar: ((Date) async -> CalendarOptions?)?
    private let fallbackTitle: String
    private var suggestedTitle: String
    private var loadTask: Task<Void, Never>?
    private var finished = false
    var onComplete: ((Result) -> Void)?

    init(calendarEnabled: Bool, now: Date = Date(), loadCalendar: ((Date) async -> CalendarOptions?)?) {
        self.calendarEnabled = calendarEnabled
        self.loadCalendar = loadCalendar
        fallbackTitle = localised("Recording ", "Запись ") + MeetingPresentation.date(now)
        suggestedTitle = fallbackTitle
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = localised("New recording", "Новая запись")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = JournalStyle.paper
        let heading = NSTextField(labelWithString: panel.title)
        heading.font = JournalStyle.titleFont(20)
        heading.textColor = JournalStyle.ink
        let detail = NSTextField(wrappingLabelWithString: localised(
            "You can close the window while recording. Audio capture follows your recording settings.",
            "Во время записи можно закрыть окно. Источники звука определяются настройками записи."))
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = JournalStyle.muted
        name.delegate = self
        name.stringValue = fallbackTitle
        name.placeholderString = localised("Meeting title", "Название встречи")
        name.setAccessibilityLabel(localised("Meeting title", "Название встречи"))
        name.identifier = .init("recording.new-title")
        name.font = .systemFont(ofSize: 14)
        name.bezelStyle = .roundedBezel
        name.heightAnchor.constraint(equalToConstant: 30).isActive = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let fields = NSStackView(views: [heading, detail, name])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 16

        date.dateValue = now
        calendarPicker.identifier = .init("recording.calendar-event")
        calendarPicker.loadEvents = { query in
            guard let options = await loadCalendar?(query.date) else { throw CalendarSelectionError.accessDenied }
            return options.events.filter(query.matches)
        }
        calendarPicker.onSelect = { [weak self] meeting in
            self?.calendarPicker.setSelection(meeting)
            self?.eventChanged()
            self?.note.isHidden = true
            self?.resize()
        }
        note.font = .systemFont(ofSize: 12)
        note.textColor = JournalStyle.muted
        note.identifier = .init("recording.calendar-status")
        if calendarEnabled {
            let label = NSTextField(labelWithString: localised("Calendar event", "Событие календаря"))
            label.font = .systemFont(ofSize: 13, weight: .medium)
            let calendar = NSStackView(views: [label, calendarPicker, note])
            calendar.orientation = .vertical
            calendar.alignment = .leading
            calendar.spacing = 8
            for view in calendar.arrangedSubviews { view.widthAnchor.constraint(equalTo: calendar.widthAnchor).isActive = true }
            fields.addArrangedSubview(calendar)
        }

        configure(start, title: localised("Start", "Начать"), symbol: "record.circle", action: #selector(begin))
        start.identifier = .init("recording.start")
        start.keyEquivalent = "\r"
        let cancel = NSButton()
        configure(cancel, title: localised("Cancel", "Отмена"), symbol: "xmark", action: #selector(NewRecordingSheet.cancel))
        cancel.identifier = .init("recording.cancel")
        cancel.keyEquivalent = "\u{1b}"
        let settings = NSButton()
        configure(settings, title: "", symbol: "gearshape", action: #selector(settingsClicked))
        settings.imagePosition = .imageOnly
        settings.identifier = .init("recording.settings")
        settings.toolTip = localised("Recording settings", "Настройки записи")
        settings.setAccessibilityLabel(settings.toolTip)
        settings.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let buttons = NSStackView(views: [start, cancel, settings, SetupLayout.spacer()])
        buttons.spacing = 8
        fields.addArrangedSubview(buttons)
        fields.setCustomSpacing(24, after: fields.arrangedSubviews[fields.arrangedSubviews.count - 2])
        fields.widthAnchor.constraint(equalToConstant: 512).isActive = true
        for view in fields.arrangedSubviews { view.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true }
        let surface = JournalSurface(JournalStyle.paper)
        fields.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(fields)
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24),
            fields.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24),
            fields.topAnchor.constraint(equalTo: surface.topAnchor, constant: 24),
            fields.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -24),
        ])
        panel.contentView = surface
        panel.initialFirstResponder = name
        panel.defaultButtonCell = start.cell as? NSButtonCell
        resize()
    }

    private func configure(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = self
        button.action = action
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    private func resize() {
        panel.contentView?.layoutSubtreeIfNeeded()
        if let size = panel.contentView?.fittingSize { panel.setContentSize(size) }
    }
    func load() {
        guard calendarEnabled else { return }
        load(automaticallySelect: true)
    }
    private func load(automaticallySelect: Bool) {
        loadTask?.cancel()
        calendarPicker.button.isEnabled = false
        start.isEnabled = false
        note.isHidden = false
        note.stringValue = localised("Loading calendar events…", "Загрузка событий календаря…")
        resize()
        let requestedDate = date.dateValue
        loadTask = Task { [weak self] in
            guard let self else { return }
            var options = await loadCalendar?(requestedDate)
            guard !Task.isCancelled, !finished else { return }
            // An early join can suggest tomorrow's first event near midnight.
            if automaticallySelect, let suggested = options?.suggested, suggested.start > requestedDate,
               !Calendar.current.isDate(suggested.start, inSameDayAs: requestedDate) {
                date.dateValue = suggested.start
                let nextDay = await loadCalendar?(suggested.start)
                guard !Task.isCancelled, !finished else { return }
                options = nextDay.map { (suggested, $0.events) }
            }
            calendarPicker.setSelection(automaticallySelect ? options?.suggested : nil)
            calendarPicker.button.isEnabled = true
            start.isEnabled = true
            note.stringValue = options == nil
                ? localised("Calendar access is unavailable. You can start without an event or grant access in Calendar settings.", "Нет доступа к календарю. Можно начать без события или разрешить доступ в настройках календаря.")
                : (options?.events.isEmpty ?? true) ? localised("No events on this date. Choose another date or start without an event.", "На эту дату событий нет. Выберите другую дату или начните без события.") : ""
            note.isHidden = note.stringValue.isEmpty
            eventChanged()
            resize()
        }
    }
    func settled() async { await loadTask?.value }
    var selectedMeeting: CalendarWatcher.Meeting? { calendarPicker.selectedMeeting }
    @objc private func eventChanged() {
        let eventTitle = selectedMeeting?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTitle = eventTitle?.isEmpty == false ? eventTitle! : fallbackTitle
        if name.stringValue == suggestedTitle || name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name.stringValue = nextTitle
        }
        suggestedTitle = nextTitle
    }
    @objc private func begin() {
        guard start.isEnabled else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resultTitle = title.isEmpty ? suggestedTitle : title
        guard let event = selectedMeeting, let resolve = calendarPicker.resolveEvent else {
            finish(.start(title: resultTitle, meeting: selectedMeeting))
            return
        }
        start.isEnabled = false
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await resolve(event)
                guard !Task.isCancelled, !finished else { return }
                finish(.start(title: resultTitle, meeting: current))
            } catch {
                guard !Task.isCancelled, !finished else { return }
                start.isEnabled = true
                note.stringValue = error.localizedDescription
                note.isHidden = false
                resize()
            }
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancel()
        return true
    }
    @objc func cancel() { finish(.cancel) }
    @objc private func settingsClicked() { finish(.settings) }
    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        loadTask?.cancel()
        calendarPicker.cancel()
        onComplete?(result)
    }
}
