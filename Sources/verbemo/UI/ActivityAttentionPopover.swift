import AppKit

@MainActor
final class ActivityAttentionPopover: NSObject {
    var onOpenMeeting: ((URL) -> Void)?
    var onOpenSettings: (() -> Void)?
    private(set) var meetings: [MeetingPresentation.Attention] = []
    private let popover = NSPopover()
    private let rows = NSStackView()
    private let closeButton = NSButton()
    private let settings = NSButton()
    private let settingsRow = NSStackView()
    private lazy var scroll = SetupLayout.scroller(around: rows)
    private lazy var scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 42)
    private weak var anchor: NSButton?

    override init() {
        super.init()
        let view = JournalSurface(JournalStyle.paper)
        view.identifier = .init("activity.attention-popover")
        let title = NSTextField(labelWithString: localised("Meetings needing attention", "Встречи требуют внимания"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = JournalStyle.ink
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityLabel(localised("Close meetings needing attention", "Закрыть список встреч, требующих внимания"))
        closeButton.target = self
        closeButton.action = #selector(close)
        let header = NSStackView(views: [title, SetupLayout.spacer(), closeButton])
        header.alignment = .centerY
        header.heightAnchor.constraint(equalToConstant: 42).isActive = true

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        scrollHeight.isActive = true
        settings.title = localised("Open settings", "Открыть настройки")
        settings.bezelStyle = .rounded
        settings.identifier = .init("activity.attention-settings")
        settings.target = self
        settings.action = #selector(openSettings)
        settingsRow.setViews([settings, SetupLayout.spacer()], in: .center)
        settingsRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let stack = NSStackView(views: [header, scroll, settingsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 420),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        popover.behavior = .transient
    }

    func update(_ meetings: [MeetingPresentation.Attention], settingsProblem: String?) {
        guard self.meetings != meetings || settings.toolTip != settingsProblem else { return }
        let window = popover.contentViewController?.view.window
        let focused = window?.firstResponder as? NSButton
        let focusedMeeting = focused.flatMap { meeting(for: $0)?.dir }
        self.meetings = meetings
        settings.toolTip = settingsProblem
        settings.setAccessibilityLabel([settings.title, settingsProblem].compactMap { $0 }.joined(separator: ". "))
        if meetings.isEmpty {
            close()
        } else if popover.isShown {
            render()
            if let focusedMeeting {
                let index = meetings.firstIndex { $0.dir == focusedMeeting }
                let row = index.map { rows.arrangedSubviews[$0] }
                window?.makeFirstResponder(row ?? closeButton)
                if let row { rows.scrollToVisible(row.frame) }
            } else if focused === settings && settingsProblem == nil {
                window?.makeFirstResponder(closeButton)
            }
        }
    }

    func toggle(from button: NSButton) {
        guard button.window != nil, !meetings.isEmpty else { return }
        if popover.isShown { close(); return }
        anchor = button
        render()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeFirstResponder(closeButton)
    }

    @objc func close() {
        guard popover.isShown else { return }
        popover.close()
        if let anchor { anchor.window?.makeFirstResponder(anchor) }
    }

    private func render() {
        let origin = popover.isShown ? scroll.contentView.bounds.origin : .zero
        for row in rows.arrangedSubviews {
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for (index, meeting) in meetings.enumerated() {
            let detail = meeting.problems.joined(separator: " · ")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSMutableAttributedString(string: meeting.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: JournalStyle.ink,
                .paragraphStyle: paragraph,
            ])
            text.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: JournalStyle.muted,
                .paragraphStyle: paragraph,
            ]))
            let button = NSButton(title: "", target: self, action: #selector(openMeeting(_:)))
            button.tag = index
            button.isBordered = false
            button.cell?.usesSingleLineMode = false
            button.cell?.wraps = true
            button.alignment = .left
            button.attributedTitle = text
            button.toolTip = meeting.title + "\n" + detail
            button.setAccessibilityLabel(meeting.title + ", " + detail)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
        let hasSettingsProblem = settings.toolTip != nil
        settingsRow.isHidden = !hasSettingsProblem
        scrollHeight.constant = min(264, max(42, rows.fittingSize.height))
        let size = NSSize(width: 420, height: 74 + scrollHeight.constant + (hasSettingsProblem ? 36 : 0))
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func openMeeting(_ sender: NSButton) {
        guard let meeting = meeting(for: sender) else { return }
        close()
        onOpenMeeting?(meeting.dir)
    }

    private func meeting(for button: NSButton) -> MeetingPresentation.Attention? {
        guard button.superview === rows, meetings.indices.contains(button.tag) else { return nil }
        return meetings[button.tag]
    }

    @objc private func openSettings() {
        close()
        onOpenSettings?()
    }
}
