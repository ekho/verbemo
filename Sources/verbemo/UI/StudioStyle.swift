import AppKit

/// Shared Studio colors for the workspace, settings and setup surfaces.
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
    static let inputHeight: CGFloat = 26
    static func drawInputBezel(in frame: NSRect) {
        let bezel = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        paper.setFill()
        bezel.fill()
        line.setStroke()
        bezel.lineWidth = 1
        bezel.stroke()
    }
    static func titleFont() -> NSFont { .systemFont(ofSize: 20, weight: .bold) }
    static func regenerationImage(symbol: String) -> NSImage {
        let content = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let refresh = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        let image = NSImage(size: .init(width: 24, height: 24), flipped: false) { _ in
            func draw(_ symbol: NSImage?, in box: NSRect) {
                guard let symbol else { return }
                let scale = min(box.width / symbol.size.width, box.height / symbol.size.height)
                let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: .init(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                                     width: size.width, height: size.height))
            }
            draw(content, in: .init(x: 0, y: 3, width: 18, height: 21))
            NSColor.clear.setFill()
            NSRect(x: 11, y: 0, width: 13, height: 13).fill(using: .copy)
            draw(refresh, in: .init(x: 12, y: 1, width: 11, height: 11))
            return true
        }
        image.isTemplate = true
        return image
    }
    static func caption(_ text: String) -> NSTextField {
        let field = JournalStyle.caption(text)
        field.textColor = muted
        return field
    }
    static func voiceLabel(_ speaker: String) -> String {
        speaker == "me" ? localised("Me", "Я") : speaker.replacingOccurrences(of: "them ", with: "")
    }
    private static let voicePalette: [(background: UInt32, ink: UInt32, transcriptDark: UInt32)] = [
        (0xe2eef0, 0x23565c, 0x20353d), (0xeee4f0, 0x684374, 0x332c40), (0xeee6d8, 0x765321, 0x383226),
        (0xdfe9f4, 0x385e83, 0x263345), (0xeee0df, 0x794744, 0x3a2b31), (0xe0eadc, 0x46673b, 0x293829),
        (0xe6e1f3, 0x59467b, 0x302d44), (0xdcece6, 0x2d6553, 0x233b36), (0xe7e9db, 0x606737, 0x343a27),
    ]
    static func voiceSurface(colorIndex: Int?) -> NSColor {
        guard let colorIndex, colorIndex >= 0 else { return paper }
        let index = colorIndex % voicePalette.count
        let pair = voicePalette[index]
        return color("voice-\(index)-surface", light: pair.background, dark: pair.transcriptDark)
    }
    static func voiceBadge(_ text: String, colorIndex: Int? = nil) -> NSTextField {
        let badge = CenteredVoiceBadge(labelWithString: text)
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
class StudioActionButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .accessoryBarAction
        showsBorderOnlyWhileMouseInside = true
        focusRingType = .exterior
        contentTintColor = StudioStyle.muted
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

@MainActor
private final class CenteredVoiceBadge: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        // Centering the cell's text must not shrink the badge background.
        backgroundColor?.setFill()
        bounds.fill()
        super.draw(dirtyRect)
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
