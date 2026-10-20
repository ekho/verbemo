import AppKit

/// A simplified wave for small status icons, without the app tile's shading.
enum WaveIcon {
    private static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.2"
    stroke-linecap="round" stroke-linejoin="round">
    <path d="M3 13 C5.3 13 5 7.5 7.5 7.5 S9.5 16.5 12 16.5 S14 7.5 16.5 7.5 S18.7 13 21 13"/>
    </svg>
    """

    private static let source: NSImage? = NSImage(data: Data(svg.utf8))

    /// The wave at `size`. With a colour it is painted in that colour and
    /// marked non-template; without one it is a template image the system
    /// renders to match its surroundings.
    ///
    /// Painting rather than tinting is deliberate: `contentTintColor` doesn't
    /// reliably override template rendering, and over a dark wallpaper the
    /// "red" recording icon came out near-black on near-black — invisible in
    /// the one state that must never be (upstream issue #15).
    static func image(size: CGFloat, color: NSColor?) -> NSImage? {
        guard let source = source?.copy() as? NSImage else { return nil }
        source.size = NSSize(width: size, height: size)

        guard let color else {
            source.isTemplate = true
            return source
        }
        let rect = NSRect(origin: .zero, size: source.size)
        let painted = NSImage(size: source.size)
        painted.lockFocus()
        source.draw(at: .zero, from: rect, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        painted.unlockFocus()
        painted.isTemplate = false
        return painted
    }

    /// Colour for a recording state, or nil for idle (template rendering).
    static func color(recording: Bool, paused: Bool) -> NSColor? {
        if paused { return .systemOrange }
        if recording { return .systemRed }
        return nil
    }
}
