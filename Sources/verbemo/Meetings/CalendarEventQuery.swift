import Foundation

/// Empty search reads the recording day. A date can be followed by a title.
struct CalendarEventQuery {
    let range: DateInterval
    let title: String
    let date: Date

    init(date: Date, text: String = "", calendar: Calendar = .current) {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var day = date
        var words = tokens
        var explicitDate = false
        if let first = tokens.first {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.isLenient = false
            for format in ["dd.MM.yyyy", "yyyy-MM-dd", "dd.MM"] {
                formatter.dateFormat = format
                let value = format == "dd.MM" ? first + ".\(calendar.component(.year, from: date))" : first
                if format == "dd.MM" { formatter.dateFormat = "dd.MM.yyyy" }
                if let parsed = formatter.date(from: value), formatter.string(from: parsed) == value {
                    day = parsed
                    words.removeFirst()
                    explicitDate = true
                    break
                }
            }
        }
        self.date = day
        title = words.joined(separator: " ")
        if title.isEmpty || explicitDate {
            range = calendar.dateInterval(of: .day, for: day)!
        } else {
            // shortcut: title-only search spans ±1 year; use an explicit date for older events.
            range = DateInterval(start: calendar.date(byAdding: .year, value: -1, to: day)!,
                                 end: calendar.date(byAdding: .year, value: 1, to: day)!)
        }
    }

    func matches(_ meeting: CalendarWatcher.Meeting) -> Bool {
        meeting.start < range.end && meeting.end > range.start
            && (title.isEmpty || meeting.title.localizedStandardContains(title))
    }
}

enum CalendarSelectionError: LocalizedError {
    case accessDenied, integrationDisabled, missingEvent
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            localised("Calendar access is unavailable. Allow access in Settings → Calendar, then reopen the list.",
                      "Нет доступа к календарю. Разрешите доступ в Настройки → Календарь и откройте список снова.")
        case .integrationDisabled:
            localised("Enable Calendar integration in settings to choose an event.",
                      "Включите интеграцию с календарём в настройках для выбора события.")
        case .missingEvent:
            localised("This event is no longer available. Reopen the list to refresh it. The saved details remain unchanged.",
                      "Событие больше недоступно. Откройте список снова для обновления. Сохранённые сведения не изменены.")
        }
    }
}
