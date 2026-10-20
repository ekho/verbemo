import AppKit
import EventKit

@MainActor
final class MeetingCalendarView: NSStackView {
    var onConfirm: (() throws -> Void)?
    var onOpen: (() -> Void)?
    var onParticipants: (() -> Void)?
    private var agenda: NSView?
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ metadata: MeetingCalendarMetadata?) {
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        guard let metadata, metadata.isConfirmed || metadata.association == "candidate" else { isHidden = true; return }
        isHidden = false
        let title = NSTextField(wrappingLabelWithString: metadata.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        addArrangedSubview(title)
        let detail = NSTextField(wrappingLabelWithString: [metadata.calendarTitle, metadata.start].compactMap { $0 }.joined(separator: " · "))
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        addArrangedSubview(detail)
        if metadata.isConfirmed {
            let open = NSButton(title: localised("Open in Calendar ↗", "Открыть в календаре ↗"), target: self, action: #selector(openEvent))
            open.identifier = .init("calendar.open")
            addArrangedSubview(open)
            if let notes = metadata.agenda {
                let disclosure = NSButton(checkboxWithTitle: localised("Meeting agenda", "Повестка встречи"), target: self, action: #selector(toggleAgenda(_:)))
                disclosure.setButtonType(.onOff)
                disclosure.bezelStyle = .disclosure
                addArrangedSubview(disclosure)
                let body = NSTextField(wrappingLabelWithString: notes)
                body.isSelectable = true
                body.font = .systemFont(ofSize: 12)
                body.isHidden = true
                agenda = body
                addArrangedSubview(body)
            }
            let invited = NSButton(title: localised("Invited: \(metadata.participants.count)", "Приглашены: \(metadata.participants.count)"), target: self, action: #selector(openParticipants))
            invited.toolTip = localised("Invitees may not have attended the meeting.", "Список приглашённых не подтверждает присутствие на встрече.")
            addArrangedSubview(invited)
        } else {
            let confirm = NSButton(title: localised("Link to this event", "Связать с этим событием"), target: self, action: #selector(confirmEvent))
            confirm.identifier = .init("calendar.confirm")
            addArrangedSubview(confirm)
        }
        for view in arrangedSubviews { view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -28).isActive = true }
    }
    @objc private func toggleAgenda(_ sender: NSButton) { agenda?.isHidden = sender.state != .on }
    @objc private func confirmEvent() {
        do { try onConfirm?() } catch { NSAlert(error: error).runModal() }
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
