#!/usr/bin/env swift
// Rebuild macOS, Windows and website icons from the approved wave artwork.
import AppKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
guard CommandLine.arguments.count <= 2 else { fail("usage: swift scripts/make-icon.swift [output-root]") }
let output = CommandLine.arguments.count == 2
    ? URL(fileURLWithPath: CommandLine.arguments[1]) : root
guard let sourceData = try? Data(contentsOf: root.appendingPathComponent("Resources/Verbemo-wave-master.png")),
      let source = NSBitmapImageRep(data: sourceData),
      let sourceCG = source.cgImage else { fail("could not read wave artwork") }

// Ignore the generated preview's faint detached alpha pixels outside the tile.
var left = source.pixelsWide, top = source.pixelsHigh, right = 0, bottom = 0
guard let wave = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
    bytesPerRow: 0, bitsPerPixel: 0), let wavePixels = wave.bitmapData
else { fail("could not allocate wave layer") }
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide {
        guard let color = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            fail("could not read artwork pixel")
        }
        if color.alphaComponent >= 0.98 {
            left = min(left, x); right = max(right, x)
            top = min(top, y); bottom = max(bottom, y)
        }
        // Ivory is neutral; the jade rim can be bright but remains green/blue.
        let ivory = color.alphaComponent >= 0.98
            && color.redComponent >= color.greenComponent * 0.75
            && color.redComponent >= color.blueComponent * 0.75
        let coverage = ivory
            ? max(0, min(1, (min(color.redComponent, color.greenComponent, color.blueComponent) - 0.32) / 0.20)) : 0
        let index = y * wave.bytesPerRow + x * 4
        let alpha = UInt8(max(0, min(255, color.alphaComponent * coverage * 255)))
        if alpha == 0 {
            for channel in 0..<4 { wavePixels[index + channel] = 0 }
            continue
        }
        wavePixels[index] = UInt8(max(0, min(255, color.redComponent * 255)))
        wavePixels[index + 1] = UInt8(max(0, min(255, color.greenComponent * 255)))
        wavePixels[index + 2] = UInt8(max(0, min(255, color.blueComponent * 255)))
        wavePixels[index + 3] = alpha
    }
}
guard right > left, bottom > top,
      let tile = sourceCG.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
else { fail("artwork has no opaque tile") }
let tileImage = NSImage(cgImage: tile, size: .zero)

func render(_ pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { fail("could not create \(pixels)px icon") }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let n = CGFloat(pixels)
    let side = n * 0.824
    let rect = NSRect(x: (n - side) / 2, y: (n - side) / 2 + n * 0.012, width: side, height: side)
    let clip = NSBezierPath()
    for step in 0...720 {
        let t = CGFloat(step) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = NSPoint(x: rect.midX + side / 2 * copysign(pow(abs(c), 0.4), c),
                            y: rect.midY + side / 2 * copysign(pow(abs(s), 0.4), s))
        if step == 0 { clip.move(to: point) } else { clip.line(to: point) }
    }
    clip.close()
    clip.addClip()
    tileImage.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data {
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("PNG encoding failed") }
    return data
}

func write(_ data: Data, _ path: String) throws {
    let url = output.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("verbemo-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("Verbemo.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
for (points, scale) in [(16,1), (16,2), (32,1), (32,2), (128,1), (128,2), (256,1), (256,2), (512,1), (512,2)] {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    try png(render(points * scale)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}
let classic = output.appendingPathComponent("Resources/Verbemo.icns")
try FileManager.default.createDirectory(at: classic.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", classic.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

// Windows 11 accepts PNG entries in ICO; keep every shell/tray size explicit.
func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
let sizes = [16, 24, 32, 48, 64, 128, 256]
let images = sizes.map { png(render($0)) }
var ico = littleEndian(UInt16(0)) + littleEndian(UInt16(1)) + littleEndian(UInt16(sizes.count))
var offset = 6 + 16 * sizes.count
for (size, data) in zip(sizes, images) {
    ico.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0])
    ico.append(littleEndian(UInt16(1)))
    ico.append(littleEndian(UInt16(32)))
    ico.append(littleEndian(UInt32(data.count)))
    ico.append(littleEndian(UInt32(offset)))
    offset += data.count
}
for data in images { ico.append(data) }
try write(ico, "windows/src/Verbemo.App/Assets/Verbemo.ico")
try write(png(wave), "Resources/Verbemo.icon/Assets/Verbemo-wave.png")
try write(png(render(512)), "landing/assets/icon.png")
try write(png(render(180)), "landing/assets/icon-180.png")
print("wrote macOS, Windows and website wave icons under \(output.path)")
