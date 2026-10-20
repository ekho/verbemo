import AppKit
import QuartzCore

@MainActor
final class MeetingListView: NSTableCellView {
    private var hover = false
    private var tracking: NSTrackingArea?
    init(item: SessionInventory.Item, active: MeetingPresentation.ActiveRecording? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let title = NSTextField(labelWithString: item.title ?? item.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let duration = item.duration.map { " · \(max(1, Int($0 / 60))) " + localised("min", "мин") } ?? ""
        let invited = MeetingCalendarMetadata.read(from: item.dir)
        let people = invited?.isConfirmed == true ? localised(" · Invited: \(invited!.participants.count)", " · Приглашены: \(invited!.participants.count)") : item.namedSpeakers.map { localised(" · Speakers: \($0.total)", " · Участников: \($0.total)") } ?? ""
        let meta = NSTextField(labelWithString: MeetingPresentation.date(item.started) + duration + people)
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        let stages = NSStackView(views: MeetingPresentation.stages(item, active: active).map { Self.icon($0) })
        stages.spacing = 9
        let stack = NSStackView(views: [title, meta, stages])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor), meta.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        paint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private static func icon(_ stage: MeetingPresentation.Stage) -> NSView {
        let host = NSView()
        host.widthAnchor.constraint(equalToConstant: 22).isActive = true
        host.heightAnchor.constraint(equalToConstant: 22).isActive = true
        host.toolTip = stage.title
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.image)
        host.setAccessibilityLabel(stage.title)
        let image = NSImageView(image: NSImage(systemSymbolName: stage.symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        image.contentTintColor = stage.state == .off ? .tertiaryLabelColor : stage.state == .failed ? .systemOrange : .controlAccentColor
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
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hover = true; paint() }
    override func mouseExited(with event: NSEvent) { hover = false; paint() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (hover ? NSColor.controlColor : NSColor.controlBackgroundColor).cgColor
        }
    }
}

@MainActor
final class MeetingTableView: NSTableView {
    var onContext: ((Int) -> Void)?
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

@MainActor
final class MeetingLibrarySplitView: NSSplitView {
    var onResize: (() -> Void)?
    private var lastWidth: CGFloat = -1
    override func layout() {
        super.layout()
        if lastWidth != bounds.width { lastWidth = bounds.width; onResize?() }
    }
}
