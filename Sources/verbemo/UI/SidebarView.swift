import AppKit

@MainActor
final class SidebarView: JournalSurface {
    var onNavigate: ((ApplicationNavigationState.Destination) -> Void)?
    var onStart: (() -> Void)?
    var onImport: (() -> Void)?
    private let libraryHost = NSView()
    private let start = NSButton()
    private let settings = SidebarSettingsButton()

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
        settings.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let divider = NSBox(); divider.boxType = .separator
        let stack = NSStackView(views: [identity, start, importButton, libraryHost, divider, settings])
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
        settings.state = destination.isMeetings ? .off : .on
        settings.contentTintColor = destination.isMeetings ? JournalStyle.ink : JournalStyle.accent
        settings.setAccessibilityValue(destination.isMeetings ? 0 : 1)
        settings.needsDisplay = true
    }
    func updateRecording(_ recording: Bool) { start.isEnabled = !recording }
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
}

@MainActor
private final class SidebarSettingsButton: NSButton {
    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }
    private final class Cell: NSButtonCell {
        override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
            super.drawInterior(withFrame: frame.insetBy(dx: 12, dy: 0), in: controlView)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            JournalStyle.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private extension NSView {
    var journalSearchField: NSSearchField? {
        if let search = self as? NSSearchField { return search }
        return subviews.lazy.compactMap(\.journalSearchField).first
    }
}
