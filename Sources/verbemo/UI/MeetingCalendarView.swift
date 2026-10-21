import AppKit
import EventKit

@MainActor
final class MeetingCalendarView: NSStackView {
    var onConfirm: (() throws -> Void)?
    var onOpen: (() -> Void)?
    var onParticipants: (() -> Void)?
    private var agenda: NSView?
    private var eventKey: String?
    private var expanded = false
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ metadata: MeetingCalendarMetadata?) {
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        guard let metadata, metadata.isConfirmed || metadata.association == "candidate" else { isHidden = true; return }
        isHidden = false
        let title = NSTextField(wrappingLabelWithString: metadata.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [title, NSView()])
        heading.spacing = 8
        addArrangedSubview(heading)
        let key = (metadata.eventID ?? "") + (metadata.start ?? "")
        if eventKey != key { expanded = false; eventKey = key }
        let date = Self.dateLine(metadata)
        let detail = NSTextField(wrappingLabelWithString: [metadata.calendarTitle, date.isEmpty ? nil : date].compactMap { $0 }.joined(separator: " · "))
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        addArrangedSubview(detail)
        if metadata.isConfirmed {
            let open = NSButton(title: localised("Open in Calendar ↗", "Открыть в календаре ↗"), target: self, action: #selector(openEvent))
            open.identifier = .init("calendar.open")
            heading.addArrangedSubview(open)
            if metadata.agenda != nil || !metadata.participants.isEmpty {
                let disclosure = NSButton(checkboxWithTitle: localised("Agenda and invitees", "Повестка и приглашённые"), target: self, action: #selector(toggleAgenda(_:)))
                disclosure.setButtonType(.onOff)
                disclosure.bezelStyle = .disclosure
                disclosure.state = expanded ? .on : .off
                addArrangedSubview(disclosure)
                let details = NSStackView()
                details.orientation = .vertical
                details.alignment = .leading
                details.spacing = 6
                if let notes = metadata.agenda {
                    let body = NSTextField(wrappingLabelWithString: notes)
                    body.isSelectable = true
                    body.font = .systemFont(ofSize: 12)
                    details.addArrangedSubview(body)
                    body.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
                }
                let invited = NSButton(title: localised("Invited: \(metadata.participants.count)", "Приглашены: \(metadata.participants.count)"), target: self, action: #selector(openParticipants))
                invited.toolTip = localised("Invitees may not have attended the meeting.", "Список приглашённых не подтверждает присутствие на встрече.")
                details.addArrangedSubview(invited)
                details.isHidden = !expanded
                agenda = details
                addArrangedSubview(details)
            }
        } else {
            let confirm = NSButton(title: localised("Link to this event", "Связать с этим событием"), target: self, action: #selector(confirmEvent))
            confirm.identifier = .init("calendar.confirm")
            addArrangedSubview(confirm)
        }
        for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor, constant: -16).isActive = true }
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
    @objc private func toggleAgenda(_ sender: NSButton) { expanded = sender.state == .on; agenda?.isHidden = !expanded }
    @objc private func confirmEvent() {
        do { try onConfirm?() } catch { if let window { NSAlert(error: error).beginSheetModal(for: window) } }
    }
    @objc private func openEvent() { onOpen?() }
    @objc private func openParticipants() { onParticipants?() }
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
