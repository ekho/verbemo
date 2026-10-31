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
    static func titleFont() -> NSFont { .systemFont(ofSize: 24, weight: .bold) }
    static func caption(_ text: String) -> NSTextField {
        let field = JournalStyle.caption(text)
        field.textColor = muted
        return field
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
