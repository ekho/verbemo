import AppKit

@MainActor
enum JournalStyle {
    static let sidebarWidth: CGFloat = 248
    static let paper = color("paper", light: 0xfffefa, dark: 0x242a25)
    static let sidebar = color("sidebar", light: 0xeeeee7, dark: 0x1d241e)
    static let inset = color("inset", light: 0xf5f4ee, dark: 0x202620)
    static let ink = color("ink", light: 0x272e27, dark: 0xeeeede)
    static let muted = color("muted", light: 0x59665c, dark: 0xa8b1a3)
    static let accent = color("accent", light: 0x285846, dark: 0xaad2ad)
    static let selection = color("selection", light: 0xdfe9df, dark: 0x354739)
    static let line = color("line", light: 0xdedfd5, dark: 0x414a40)
    static func titleFont(_ size: CGFloat = 34) -> NSFont {
        .systemFont(ofSize: size, weight: .bold)
    }
    private static func color(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("journal.\(name)")) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
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
        contentTintColor = selected ? JournalStyle.ink : JournalStyle.muted
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if state == .on {
            JournalStyle.accent.setFill()
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
