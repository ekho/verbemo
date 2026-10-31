import AppKit

/// Studio tokens apply only to the meeting workspace; settings keep their existing palette.
@MainActor
enum StudioStyle {
    static let paper = color("paper", light: 0xffffff, dark: 0x1c2532)
    static let sidebar = color("sidebar", light: 0xe9edf1, dark: 0x141d29)
    static let inset = sidebar
    static let ink = color("ink", light: 0x172b3b, dark: 0xedf3fa)
    static let muted = color("muted", light: 0x475d6b, dark: 0xaebbcd)
    static let accent = color("accent", light: 0x294d9b, dark: 0x9bbcf5)
    static let selection = color("selection", light: 0xdbe4f4, dark: 0x2f405c)
    static let line = color("line", light: 0xc3ced7, dark: 0x405169)
    static func titleFont() -> NSFont { .systemFont(ofSize: 20, weight: .bold) }
    static func caption(_ text: String) -> NSTextField {
        let field = JournalStyle.caption(text)
        field.textColor = muted
        return field
    }
    static func voiceLabel(_ speaker: String) -> String {
        speaker == "me" ? localised("Me", "Я") : speaker.replacingOccurrences(of: "them ", with: "")
    }
    private static let voicePalette: [(background: UInt32, ink: UInt32)] = [
        (0xe2eef0, 0x23565c), (0xeee4f0, 0x684374), (0xeee6d8, 0x765321),
        (0xdfe9f4, 0x385e83), (0xeee0df, 0x794744), (0xe0eadc, 0x46673b),
        (0xe6e1f3, 0x59467b), (0xdcece6, 0x2d6553), (0xe7e9db, 0x606737),
    ]
    static func voiceBadge(_ text: String, colorIndex: Int? = nil) -> NSTextField {
        let badge = NSTextField(labelWithString: text)
        badge.cell = CenteredVoiceCell(textCell: text)
        badge.isEditable = false
        badge.isSelectable = false
        badge.isBezeled = false
        badge.isBordered = false
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.drawsBackground = true
        badge.alignment = .center
        badge.widthAnchor.constraint(equalToConstant: 26).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 24).isActive = true
        configureVoiceBadge(badge, text: text, colorIndex: colorIndex)
        return badge
    }
    static func configureVoiceBadge(_ badge: NSTextField, text: String, colorIndex: Int?) {
        badge.stringValue = text
        badge.setAccessibilityLabel(localised("Voice ", "Голос ") + text)
        if let colorIndex, colorIndex >= 0 {
            let index = colorIndex % voicePalette.count
            let pair = voicePalette[index]
            badge.textColor = color("voice-\(index)-ink", light: pair.ink, dark: pair.background)
            badge.backgroundColor = color("voice-\(index)-background", light: pair.background, dark: pair.ink)
        } else {
            badge.textColor = muted
            badge.backgroundColor = inset
        }
    }
    private static func color(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("studio.\(name)")) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
}

@MainActor
private final class CenteredVoiceCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawing = super.drawingRect(forBounds: rect)
        let height = min(drawing.height, cellSize(forBounds: rect).height)
        drawing.origin.y += (drawing.height - height) / 2
        drawing.size.height = height
        return drawing
    }
}
