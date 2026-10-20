import AppKit

@MainActor
final class SidebarView: NSVisualEffectView {
    var onNavigate: ((ApplicationNavigationState.Destination) -> Void)?
    private var buttons: [NSButton] = []
    private let automatic = NSButton()

    init() {
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        let brand = NSTextField(labelWithString: "Verbemo")
        brand.font = .systemFont(ofSize: 23, weight: .semibold)
        let logo = NSImageView(image: NSApplication.shared.applicationIconImage)
        logo.widthAnchor.constraint(equalToConstant: 32).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let identity = NSStackView(views: [logo, brand])
        identity.spacing = 10
        let meetings = group(localised("MEETINGS", "ВСТРЕЧИ"), destinations: [.allMeetings, .processing, .attention])
        let settings = group(localised("SETTINGS", "НАСТРОЙКИ"), destinations: [.general, .recording, .transcription, .summary, .storage, .about])
        automatic.title = localised("Auto-recording is on", "Автозапись включена")
        automatic.image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil)
        automatic.imagePosition = .imageLeading
        automatic.isBordered = false
        automatic.alignment = .left
        automatic.font = .systemFont(ofSize: 11)
        automatic.target = self
        automatic.action = #selector(openRecording)
        automatic.identifier = .init("navigation.auto-record")
        automatic.setAccessibilityLabel(localised("Open automatic recording settings", "Открыть настройки автоматической записи"))
        let spring = NSView()
        spring.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = FlippedStackView(views: [identity, meetings, spring, settings, automatic])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            meetings.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settings.widthAnchor.constraint(equalTo: stack.widthAnchor),
            automatic.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func group(_ title: String, destinations: [ApplicationNavigationState.Destination]) -> NSStackView {
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        caption.textColor = .secondaryLabelColor
        let views = destinations.map { destination -> NSButton in
            let button = NSButton(title: destination.title, target: self, action: #selector(clicked(_:)))
            button.identifier = .init(destination.rawValue)
            button.image = NSImage(systemSymbolName: destination.symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12)
            button.heightAnchor.constraint(equalToConstant: 35).isActive = true
            button.setAccessibilityLabel(destination.title)
            buttons.append(button)
            return button
        }
        let group = NSStackView(views: [caption] + views)
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        for button in views { button.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
        return group
    }
    func select(_ destination: ApplicationNavigationState.Destination) {
        for button in buttons {
            let selected = button.identifier?.rawValue == destination.rawValue
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
            button.setAccessibilityValue(selected ? 1 : 0)
        }
    }
    func updateAutomatic(_ enabled: Bool, reason: String?) {
        automatic.title = enabled ? localised("Auto-recording is on", "Автозапись включена") : localised("Auto-recording is off", "Автозапись выключена")
        automatic.toolTip = reason
    }
    @objc private func clicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let destination = ApplicationNavigationState.Destination(rawValue: id) else { return }
        onNavigate?(destination)
    }
    @objc private func openRecording() { onNavigate?(.recording) }
}
