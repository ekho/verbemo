import AppKit

@MainActor
final class SidebarView: JournalSurface {
    var onNavigate: ((ApplicationNavigationState.Destination) -> Void)?
    var onStart: (() -> Void)?
    var onImport: (() -> Void)?
    var onToggleAutomatic: (() -> Void)?
    private let libraryHost = NSView()
    private let start = NSButton()
    private let settings = NSButton()
    private let automatic = NSSwitch()

    init() {
        super.init(JournalStyle.sidebar)
        identifier = .init("journal.sidebar")
        let brand = NSTextField(labelWithString: "verbemo")
        brand.font = .systemFont(ofSize: 24, weight: .semibold)
        brand.textColor = JournalStyle.ink
        let logo = NSImageView(image: NSApplication.shared.applicationIconImage)
        logo.widthAnchor.constraint(equalToConstant: 30).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let identity = NSStackView(views: [logo, brand, NSView()])
        identity.spacing = 9
        start.title = localised("●  New recording", "●  Новая запись")
        start.font = .systemFont(ofSize: 13, weight: .medium)
        start.bezelStyle = .regularSquare
        start.bezelColor = NSColor(srgbRed: 0.16, green: 0.34, blue: 0.27, alpha: 1)
        start.contentTintColor = .white
        start.wantsLayer = true
        start.layer?.cornerRadius = 7
        start.layer?.masksToBounds = true
        start.identifier = .init("journal.new-recording")
        start.keyEquivalent = "n"
        start.keyEquivalentModifierMask = .command
        start.target = self
        start.action = #selector(startClicked)
        start.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let importButton = NSButton(title: localised("Import", "Импортировать"), target: self, action: #selector(importClicked))
        importButton.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        importButton.imagePosition = .imageLeading
        importButton.imageHugsTitle = true
        importButton.bezelStyle = .regularSquare
        importButton.isBordered = true
        importButton.font = .systemFont(ofSize: 13, weight: .medium)
        importButton.wantsLayer = true
        importButton.layer?.cornerRadius = 7
        importButton.layer?.masksToBounds = true
        importButton.identifier = .init("journal.import")
        importButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        settings.title = localised("Settings", "Настройки")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.imagePosition = .imageLeading
        settings.isBordered = false
        settings.alignment = .left
        settings.identifier = .init("journal.settings")
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        settings.action = #selector(settingsClicked)
        settings.heightAnchor.constraint(equalToConstant: 30).isActive = true
        automatic.controlSize = .small
        automatic.target = self
        automatic.action = #selector(automaticClicked)
        automatic.identifier = .init("navigation.auto-record")
        let automaticLabel = JournalStyle.caption(localised("Auto-record calls", "Автозапись звонков"))
        automatic.setAccessibilityLabel(automaticLabel.stringValue)
        let autoRow = NSStackView(views: [automaticLabel, NSView(), automatic])
        let divider = NSBox(); divider.boxType = .separator
        let stack = NSStackView(views: [identity, start, importButton, libraryHost, divider, settings, autoRow])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(22, after: identity)
        stack.setCustomSpacing(20, after: importButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        libraryHost.setContentHuggingPriority(.init(1), for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func mountLibrary(_ view: NSView) {
        guard view.superview !== libraryHost else { return }
        libraryHost.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        libraryHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: libraryHost.leadingAnchor), view.trailingAnchor.constraint(equalTo: libraryHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: libraryHost.topAnchor), view.bottomAnchor.constraint(equalTo: libraryHost.bottomAnchor),
        ])
    }
    func select(_ destination: ApplicationNavigationState.Destination) {
        settings.contentTintColor = destination.isMeetings ? JournalStyle.ink : JournalStyle.accent
        settings.setAccessibilityValue(destination.isMeetings ? 0 : 1)
    }
    func updateRecording(_ recording: Bool) { start.isEnabled = !recording }
    func updateAutomatic(_ enabled: Bool, reason: String?) {
        automatic.state = enabled ? .on : .off
        automatic.toolTip = reason
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.characters == "f", let search = libraryHost.journalSearchField {
            window?.makeFirstResponder(search)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    @objc private func startClicked() { onStart?() }
    @objc private func importClicked() { onImport?() }
    @objc private func settingsClicked() { onNavigate?(.general) }
    @objc private func automaticClicked() { onToggleAutomatic?() }
}

private extension NSView {
    var journalSearchField: NSSearchField? {
        if let search = self as? NSSearchField { return search }
        return subviews.lazy.compactMap(\.journalSearchField).first
    }
}
