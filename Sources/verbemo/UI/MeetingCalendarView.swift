import AppKit
import EventKit

@MainActor
final class MeetingCalendarView: NSStackView {
    var onOpen: (() -> Void)?
    private var metadata: MeetingCalendarMetadata?
    private var eventKey: String?
    private var agendaExpanded = false
    private var inviteesExpanded = false
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ metadata: MeetingCalendarMetadata?) {
        self.metadata = metadata
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        guard let metadata, metadata.isConfirmed || metadata.association == "candidate" else {
            isHidden = true; eventKey = nil; return
        }
        isHidden = false
        let key = (metadata.eventID ?? "") + (metadata.start ?? "")
        if eventKey != key { agendaExpanded = false; inviteesExpanded = false; eventKey = key }
        if metadata.isConfirmed {
            let title = NSButton(title: metadata.title, target: self, action: #selector(openEvent))
            title.identifier = .init("calendar.open")
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            title.isBordered = false
            title.alignment = .left
            title.contentTintColor = JournalStyle.accent
            title.cell?.wraps = true
            title.cell?.lineBreakMode = .byWordWrapping
            title.toolTip = localised("Open calendar event", "Открыть событие календаря")
            addArrangedSubview(title)
        } else {
            let title = NSTextField(wrappingLabelWithString: metadata.title)
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            addArrangedSubview(title)
        }
        let date = Self.dateLine(metadata)
        let detail = body([metadata.calendarTitle, date.isEmpty ? nil : date].compactMap { $0 }.joined(separator: " · "))
        detail.textColor = JournalStyle.muted
        addArrangedSubview(detail)
        if metadata.isConfirmed {
            if let notes = metadata.agenda {
                addArrangedSubview(JournalStyle.caption(localised("AGENDA", "ПОВЕСТКА")))
                let rendered = CalendarAgenda.render(notes)
                let preview = Self.agendaPreview(rendered.string)
                let text = body("")
                text.allowsEditingTextAttributes = true
                text.attributedStringValue = agendaExpanded ? rendered : rendered.attributedSubstring(
                    from: NSRange(location: 0, length: preview.utf16.count))
                text.identifier = .init("calendar.agenda")
                addArrangedSubview(text)
                if preview != rendered.string {
                    addArrangedSubview(expansionButton(
                        agendaExpanded ? localised("Show less", "Свернуть") : localised("Show in full", "Показать полностью"),
                        id: "calendar.expand-agenda", action: #selector(toggleAgenda)))
                }
            }
            if !metadata.participants.isEmpty {
                addArrangedSubview(JournalStyle.caption(localised("INVITEES", "ПРИГЛАШЁННЫЕ")))
                let visible = inviteesExpanded ? metadata.participants : Array(metadata.participants.prefix(4))
                let people = body(visible.map(\.name).joined(separator: "\n"))
                people.identifier = .init("calendar.invitees")
                addArrangedSubview(people)
                if metadata.participants.count > 4 {
                    addArrangedSubview(expansionButton(
                        inviteesExpanded ? localised("Show less", "Свернуть") : localised("Show all", "Показать всех"),
                        id: "calendar.expand-invitees", action: #selector(toggleInvitees)))
                }
                let notice = body(localised("Invitees may not have attended.", "Приглашение не подтверждает присутствие."))
                notice.textColor = JournalStyle.muted
                notice.font = .systemFont(ofSize: 10)
                addArrangedSubview(notice)
            }
        }
        for view in arrangedSubviews {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.widthAnchor.constraint(equalTo: widthAnchor, constant: -16).isActive = true
        }
    }
    static func agendaPreview(_ text: String) -> String {
        guard text.count > 100 else { return text }
        let boundary = text.index(text.startIndex, offsetBy: 100)
        let prefix = text[..<boundary]
        if text[boundary].isWhitespace { return String(prefix).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let end = prefix.lastIndex(where: { $0.isWhitespace }) else { return "" }
        return String(prefix[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func body(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.isSelectable = true
        return field
    }
    private func expansionButton(_ title: String, id: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.identifier = .init(id)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = JournalStyle.accent
        return button
    }
    static func dateLine(_ metadata: MeetingCalendarMetadata, timeZone: TimeZone = .current) -> String {
        func parse(_ value: String?) -> Date? {
            guard let value else { return nil }
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: value) { return date }
            iso.formatOptions.insert(.withFractionalSeconds)
            return iso.date(from: value)
        }
        guard let start = parse(metadata.start) else { return "" }
        let first = MeetingPresentation.date(start, timeZone: timeZone)
        var line = first
        if let end = parse(metadata.end), end >= start {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            line += calendar.isDate(start, inSameDayAs: end)
                ? "–" + MeetingPresentation.date(end, timeZone: timeZone).suffix(5)
                : " – " + MeetingPresentation.date(end, timeZone: timeZone)
        }
        if let identifier = metadata.timeZoneIdentifier, let eventZone = TimeZone(identifier: identifier),
           eventZone.identifier != timeZone.identifier {
            line += " · \(timeZone.identifier)" + localised("; event: ", "; событие: ") + eventZone.identifier
        }
        return line
    }
    @objc private func toggleAgenda() { agendaExpanded.toggle(); update(metadata) }
    @objc private func toggleInvitees() { inviteesExpanded.toggle(); update(metadata) }
    @objc private func openEvent() { onOpen?() }
}

@MainActor
enum CalendarEventOpener {
    static func open(_ snapshot: MeetingCalendarMetadata) -> String? {
        if let url = snapshot.eventURL, ["https", "http"].contains(url.scheme ?? "") {
            return NSWorkspace.shared.open(url) ? nil : localised("Could not open the event link.", "Не удалось открыть ссылку на событие.")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return localised("Calendar access is unavailable. The saved meeting details remain here.", "Нет доступа к календарю. Сохранённые сведения о встрече остаются здесь.")
        }
        let store = EKEventStore()
        guard let id = snapshot.eventID, let event = store.event(withIdentifier: id), let currentID = event.eventIdentifier else {
            return localised("This event is no longer available. The saved meeting details remain here.", "Событие больше недоступно. Сохранённые сведения о встрече остаются здесь.")
        }
        // shortcut: Calendar's URL is not a public EventKit API; replace when Apple exposes an opener.
        let path = currentID.replacingOccurrences(of: ":", with: "/").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "x-apple-calevent://" + path), NSWorkspace.shared.open(url) else {
            return localised("Calendar could not open this event. The saved details remain here.", "Календарь не смог открыть событие. Его сохранённые сведения остаются здесь.")
        }
        return nil
    }
}
