import AppKit

@MainActor
enum JournalStyle {
    static let sidebarWidth: CGFloat = 248
    static let paper = StudioStyle.paper
    static let sidebar = StudioStyle.sidebar
    static let inset = StudioStyle.inset
    static let ink = StudioStyle.ink
    static let muted = StudioStyle.muted
    static let accent = StudioStyle.accent
    static let selection = StudioStyle.selection
    static let line = StudioStyle.line
    static func titleFont(_ size: CGFloat = 34) -> NSFont {
        .systemFont(ofSize: size, weight: .bold)
    }
    static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10, weight: .medium)
        field.textColor = muted
        return field
    }
}

@MainActor
final class JournalTabButton: NSButton {
    var selectedTint = JournalStyle.ink
    var unselectedTint = JournalStyle.muted
    var markerTint = JournalStyle.accent
    init(title: String, symbol: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        setButtonType(.toggle)
        setAccessibilityRole(.radioButton)
        font = .systemFont(ofSize: 13, weight: .semibold)
        heightAnchor.constraint(equalToConstant: 40).isActive = true
        let preferredWidth = widthAnchor.constraint(equalToConstant: intrinsicContentSize.width + 12)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func select(_ selected: Bool) {
        state = selected ? .on : .off
        font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        contentTintColor = selected ? selectedTint : unselectedTint
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if state == .on {
            markerTint.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: isFlipped ? bounds.height - 3 : 0,
                                            width: bounds.width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

@MainActor
class JournalSurface: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ color: NSColor) { self.color = color; super.init(frame: .zero); wantsLayer = true; clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// A missing feature stays visible and links to the work needed to enable it.
@MainActor
final class JournalUnavailableView: NSStackView {
    enum Feature: Int, CaseIterable {
        case summaryProvider = 28, diarizationChoice, cancelProcessing
    }
    let feature: Feature
    init(_ feature: Feature, title: String? = nil) {
        self.feature = feature
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        identifier = .init("unavailable.\(feature.rawValue)")
        if let title {
            let heading = NSTextField(wrappingLabelWithString: title)
            heading.font = .systemFont(ofSize: 12, weight: .medium)
            addArrangedSubview(heading)
        }
        let message = NSTextField(wrappingLabelWithString: localised("This feature is not implemented yet", "Функция пока не реализована"))
        message.font = .systemFont(ofSize: 11)
        message.textColor = JournalStyle.muted
        addArrangedSubview(message)
        let issue = NSButton(title: localised("Follow issue #\(feature.rawValue) ↗", "Задача #\(feature.rawValue) ↗"), target: self, action: #selector(openIssue))
        issue.isBordered = false
        issue.font = .systemFont(ofSize: 11)
        issue.contentTintColor = JournalStyle.accent
        issue.alignment = .left
        addArrangedSubview(issue)
        for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openIssue() {
        NSWorkspace.shared.open(URL(string: "https://github.com/ekho/verbemo/issues/\(feature.rawValue)")!)
    }
}
