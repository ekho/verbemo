import AppKit
import EventKit

@MainActor
final class CalendarSettingsView: NSStackView {
    private struct CalendarOption: Equatable {
        let id: String
        let title: String
        let account: String
    }

    private let calendar: CalendarWatcher
    private let all = NSButton(checkboxWithTitle: localised("All calendars, including new ones", "Все календари, включая новые"), target: nil, action: nil)
    private let list = NSStackView()
    private let status = SetupLayout.detail("", lines: 0)
    private let error = SetupLayout.detail("", lines: 0)
    private var options: [CalendarOption] = []
    private var buttons: [NSButton] = []
    private var observers: [ConfigWatch.Token] = []

    init(calendar: CalendarWatcher = CalendarWatcher()) {
        self.calendar = calendar
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        identifier = .init("calendar_ids")
        all.identifier = .init("calendar_ids.all")
        all.target = self
        all.action = #selector(allChanged)
        all.lineBreakMode = .byTruncatingTail
        all.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        error.identifier = .init("calendar_ids.error")
        error.textColor = .systemRed
        error.isHidden = true
        status.identifier = .init("calendar_ids.status")
        let help = SetupLayout.detail(localised(
            "Used for matching, choosing events, and starting recordings from events. Changes apply immediately.",
            "Используются для сопоставления, выбора событий и запуска записи по событиям. Изменения действуют сразу."), lines: 0)
        for view in [all, help, list, status, error] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        observers.append(ConfigWatch.observe { [weak self] in self?.refresh() })
        let home = Home.current
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification] {
            observers.append(ConfigWatch.Token(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { Home.$scoped.withValue(home) { self?.refresh() } }
            }))
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let available = calendar.availableCalendars()
        let current = (available ?? []).map {
            CalendarOption(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "")
        }.sorted {
            if $0.account != $1.account { return $0.account.localizedStandardCompare($1.account) == .orderedAscending }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
        // Keep controls alive during selection changes so keyboard focus stays put.
        if current != options {
            options = current
            for row in list.arrangedSubviews {
                list.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            buttons = options.enumerated().map { index, option in
                let button = NSButton(checkboxWithTitle: option.title, target: self, action: #selector(calendarChanged(_:)))
                button.identifier = .init("calendar_ids.\(option.id)")
                button.tag = index
                button.lineBreakMode = .byTruncatingTail
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                button.toolTip = [option.title, option.account].filter { !$0.isEmpty }.joined(separator: " — ")
                button.setAccessibilityLabel([option.title, option.account].filter { !$0.isEmpty }.joined(separator: ", "))
                let account = SetupLayout.detail(option.account, lines: 0)
                account.isHidden = option.account.isEmpty
                let row = SetupLayout.group([button, account], spacing: 2)
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                return button
            }
        }
        let selected = Config.calendarIDs().map(Set.init)
        all.state = selected == nil ? .on : .off
        all.isEnabled = available != nil
        for (option, button) in zip(options, buttons) {
            button.state = (selected?.contains(option.id) ?? true) ? .on : .off
        }
        var messages: [String] = []
        if available == nil {
            messages.append(localised("Allow calendar access above to choose calendars.", "Разрешите доступ к календарю выше, чтобы выбрать календари."))
        } else {
            if options.isEmpty {
                messages.append(localised("No calendars available. Add a calendar in the Calendar app.", "Нет доступных календарей. Добавьте календарь в приложении «Календарь»."))
            } else if selected?.isEmpty == true {
                messages.append(localised("No calendars selected. Events will not be used.", "Календари не выбраны. События не будут использоваться."))
            }
            if let selected, !selected.subtracting(options.map(\.id)).isEmpty {
                messages.append(localised("Some selected calendars are unavailable. Check your selection after syncing or reconnecting an account.", "Часть выбранных календарей недоступна. Проверьте выбор после синхронизации или повторного подключения учётной записи."))
            }
        }
        status.stringValue = messages.joined(separator: "\n")
        status.isHidden = messages.isEmpty
    }

    @objc private func allChanged() {
        save(all.state == .on ? nil : options.map(\.id))
    }

    @objc private func calendarChanged(_ sender: NSButton) {
        guard options.indices.contains(sender.tag) else { return }
        var selected = Set(Config.calendarIDs() ?? options.map(\.id))
        let id = options[sender.tag].id
        if sender.state == .on { selected.insert(id) } else { selected.remove(id) }
        save(selected.sorted())
    }

    private func save(_ ids: [String]?) {
        let saved = Config.update(path: Config.Key.calendarIDs.path, value: ids)
        error.stringValue = saved ? "" : localised("Couldn't save the calendar selection. Check the settings file and try again.", "Не удалось сохранить выбор календарей. Проверьте файл настроек и попробуйте снова.")
        error.isHidden = saved
        refresh()
    }
}
