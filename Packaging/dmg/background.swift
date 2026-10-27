// Reproducible Journal artwork; Finder supplies the actual app/folder icons.
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("DMG background: \(message)\n".utf8))
    exit(1)
}
guard CommandLine.arguments.count == 2 else {
    fail("usage: background.swift <output.tiff>")
}
let size = NSSize(width: 660, height: 420)
let paper = NSColor(srgbRed: 1, green: 254 / 255, blue: 250 / 255, alpha: 1)
let ink = NSColor(srgbRed: 39 / 255, green: 46 / 255, blue: 39 / 255, alpha: 1)
let accent = NSColor(srgbRed: 40 / 255, green: 88 / 255, blue: 70 / 255, alpha: 1)
var representations: [NSBitmapImageRep] = []

for scale in [1, 2] {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: 660 * scale, pixelsHigh: 420 * scale, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fail("Could not allocate background")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(scale))
    transform.concat()
    paper.setFill()
    NSRect(origin: .zero, size: size).fill()

    func text(_ value: String, top: CGFloat, font: NSFont, color: NSColor,
              centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .left
        (value as NSString).draw(in: NSRect(x: 40, y: 420 - top - 40, width: 580, height: 40),
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    text("Verbemo", top: 31, font: .systemFont(ofSize: 32, weight: .semibold), color: ink)
    text("Установка / Installation", top: 77, font: .systemFont(ofSize: 12),
         color: accent.withAlphaComponent(0.8))

    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: 440, y: 356))
    wave.curve(to: NSPoint(x: 490, y: 368), controlPoint1: NSPoint(x: 465, y: 330),
               controlPoint2: NSPoint(x: 473, y: 410))
    wave.curve(to: NSPoint(x: 540, y: 349), controlPoint1: NSPoint(x: 515, y: 308),
               controlPoint2: NSPoint(x: 522, y: 310))
    wave.curve(to: NSPoint(x: 613, y: 357), controlPoint1: NSPoint(x: 573, y: 420),
               controlPoint2: NSPoint(x: 569, y: 345))
    wave.lineWidth = 8
    wave.lineCapStyle = .round
    accent.withAlphaComponent(0.12).setStroke()
    wave.stroke()

    accent.withAlphaComponent(0.13).setFill()
    NSRect(x: 40, y: 300, width: 580, height: 1).fill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 299, y: 210))
    arrow.line(to: NSPoint(x: 361, y: 210))
    arrow.move(to: NSPoint(x: 350, y: 221))
    arrow.line(to: NSPoint(x: 361, y: 210))
    arrow.line(to: NSPoint(x: 350, y: 199))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    accent.setStroke()
    arrow.stroke()

    text("Перетащите Verbemo в Applications", top: 324,
         font: .systemFont(ofSize: 16, weight: .medium), color: ink, centered: true)
    text("Drag Verbemo to Applications", top: 352,
         font: .systemFont(ofSize: 13), color: accent, centered: true)
    NSGraphicsContext.restoreGraphicsState()
    rep.size = size
    representations.append(rep)
}
guard let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: representations) else {
    fail("Could not encode background")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
