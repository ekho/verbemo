import AppKit
import QuartzCore

@MainActor
final class MeetingListView: NSTableCellView {
    private let title: NSTextField
    private var snippet: NSTextField?
    static func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = StudioStyle.ink
        label.lineBreakMode = .byWordWrapping
        return label
    }
    static func snippetLabel(_ hit: MeetingLibrarySearch.Hit) -> NSTextField {
        let source = switch hit.source {
        case .title: localised("Title", "Название")
        case .metadata: localised("Meeting", "Встреча")
        case .transcript: localised("Transcript", "Расшифровка")
        case .summary: localised("Summary", "Сводка")
        }
        let text = source + " · " + hit.excerpt
        let label = NSTextField(wrappingLabelWithString: text)
        label.identifier = .init("meeting.list-snippet")
        label.font = .systemFont(ofSize: 12)
        label.textColor = StudioStyle.muted
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        let marked = NSMutableAttributedString(string: text, attributes: [.font: label.font!, .foregroundColor: StudioStyle.muted])
        for range in MeetingTextSearch.matches(in: text, query: hit.query) {
            marked.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25), range: range)
        }
        label.attributedStringValue = marked
        // AppKit's intrinsic size can ignore maximumNumberOfLines for attributed text.
        label.heightAnchor.constraint(equalToConstant: 2 * ceil(NSLayoutManager().defaultLineHeight(for: label.font!))).isActive = true
        label.toolTip = text
        label.setAccessibilityLabel(text)
        return label
    }
    init(item: SessionInventory.Item, active: MeetingPresentation.ActiveRecording? = nil, hit: MeetingLibrarySearch.Hit? = nil) {
        title = Self.titleLabel(item.title ?? item.name)
        super.init(frame: .zero)
        let duration = item.duration.map { seconds in
            let total = seconds.isFinite ? Int(max(0, seconds)) : 0
            return " · " + (total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                : String(format: "%02d:%02d", total / 60, total % 60))
        } ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = item.started.map { formatter.string(from: $0) } ?? localised("Undated", "Без даты")
        let meta = NSTextField(labelWithString: date + duration)
        meta.identifier = .init("meeting.list-date")
        meta.toolTip = item.started.map { MeetingPresentation.date($0) + duration } ?? meta.stringValue
        meta.setAccessibilityLabel(meta.toolTip)
        meta.font = .systemFont(ofSize: 12)
        meta.textColor = StudioStyle.muted
        meta.lineBreakMode = .byTruncatingTail
        let stages = MeetingPresentation.stages(item, active: active)
        let naming: MeetingPresentation.Stage? = switch item.speakers {
        case .failed(let reason): .init(symbol: "person", title: reason, state: .failed)
        case .pending, .deferred: .init(symbol: "person", title: localised("Speaker names pending", "Имена говорящих ожидают обработки"), state: .pending)
        case .done, .off: nil
        }
        let status = stages.first { $0.state == .failed } ?? (naming?.state == .failed ? naming : nil)
            ?? stages.first { $0.state == .active || $0.state == .paused || $0.state == .pending } ?? naming
        let failed = status?.state == .failed || item.unreadableDiarization || item.diarization?.status == .failed
        let symbol = failed ? "exclamationmark.triangle" : status.map {
            switch $0.state {
            case .active: $0.symbol == "mic" ? "record.circle" : "arrow.triangle.2.circlepath"
            case .paused: "pause.circle"
            case .pending: "clock"
            default: "checkmark.circle"
            }
        } ?? "checkmark.circle"
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.identifier = .init("meeting.list-status")
        image.contentTintColor = failed ? .systemRed : status?.state == .active ? StudioStyle.accent : StudioStyle.muted
        image.toolTip = failed && status?.state != .failed ? localised("Speaker separation needs attention", "Диаризация требует внимания")
            : status?.title ?? localised("Ready", "Готово")
        image.setAccessibilityElement(true)
        image.setAccessibilityRole(.image)
        image.setAccessibilityLabel(image.toolTip)
        image.widthAnchor.constraint(equalToConstant: 16).isActive = true
        image.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let metaRow = NSStackView(views: [meta, image, NSView()])
        metaRow.spacing = 6
        let stack = NSStackView(views: [title, metaRow])
        if let hit, hit.source != .title {
            let snippet = Self.snippetLabel(hit)
            self.snippet = snippet
            stack.addArrangedSubview(snippet)
            snippet.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor), metaRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        title.preferredMaxLayoutWidth = max(1, bounds.width - 20)
        snippet?.preferredMaxLayoutWidth = max(1, bounds.width - 20)
        super.layout()
    }
    static func icon(_ stage: MeetingPresentation.Stage) -> NSView {
        let host = NSView()
        host.widthAnchor.constraint(equalToConstant: 22).isActive = true
        host.heightAnchor.constraint(equalToConstant: 22).isActive = true
        host.toolTip = stage.title
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.image)
        host.setAccessibilityLabel(stage.title)
        let image = NSImageView(image: NSImage(systemSymbolName: stage.symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        image.contentTintColor = stage.state == .off || stage.state == .waiting ? StudioStyle.muted : stage.state == .failed ? .systemOrange : .controlAccentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(image)
        NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16), image.centerXAnchor.constraint(equalTo: host.centerXAnchor), image.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
        func badge(_ symbol: String, left: Bool) {
            let badge = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            badge.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
            badge.contentTintColor = image.contentTintColor
            badge.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(badge)
            NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 10), badge.heightAnchor.constraint(equalToConstant: 9), badge.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: 2), left ? badge.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: -2) : badge.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: 1)])
        }
        if stage.diarized { badge("person.2.fill", left: true) }
        if stage.state == .done && stage.symbol != "calendar" { badge("checkmark", left: false) }
        if stage.state == .paused { badge("pause.fill", left: false) }
        if stage.state == .pending { badge("clock", left: false) }
        if stage.state == .failed { badge("exclamationmark.circle", left: false) }
        if stage.state == .active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            image.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            image.layer?.add(pulse, forKey: "stage-progress")
        }
        return host
    }

}

@MainActor
final class MeetingTableView: NSTableView {
    var onContext: ((Int) -> Void)?
    private var measuredWidth: CGFloat = 0
    override func layout() {
        super.layout()
        if let width = tableColumns.first?.width, abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<numberOfRows))
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onContext?(row) }
        return super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109 && event.modifierFlags.contains(.shift), selectedRow >= 0 {
            onContext?(selectedRow)
            menu?.popUp(positioning: nil, at: rect(ofRow: selectedRow).origin, in: self)
        } else { super.keyDown(with: event) }
    }
}
