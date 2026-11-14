import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome) @MainActor
struct MeetingHoverTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func scrollingUnderStationaryPointerTransfersHover(appearance: NSAppearance.Name) throws {
        _ = NSApplication.shared
        let window = HoverWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let library = MeetingLibraryController(root: Home.current.url, hostWindow: window)
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSTableView }.first)
        let rows = try (0..<3).map { try #require(library.tableView(table, rowViewForRow: $0)) }
        let document = NSView(frame: .init(x: 0, y: 0, width: 300, height: 300))
        for (index, row) in rows.enumerated() {
            row.frame = .init(x: 0, y: index * 100, width: 300, height: 100)
            row.backgroundColor = .clear
            document.addSubview(row)
        }
        let scroll = NSScrollView(frame: try #require(window.contentView).bounds)
        scroll.documentView = document
        window.contentView = scroll
        scroll.contentView.scroll(to: .zero)
        window.pointer = rows[0].convert(.init(x: 150, y: 50), to: nil)
        let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: window.pointer,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        rows[0].mouseEntered(with: entered)
        #expect(try highlighted(rows[0]))
        rows[2].isSelected = true

        // Scrolling replaces tracking areas without a mouse move or a balanced exit event.
        for offset in [100, 0, 100] {
            scroll.contentView.scroll(to: .init(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            rows[0].mouseEntered(with: entered)
            rows[1].mouseExited(with: entered)
            #expect(try highlighted(rows[offset == 0 ? 0 : 1]), "Scrolling must update hover before tracking areas are rebuilt")
            #expect(try !highlighted(rows[offset == 0 ? 1 : 0]), "Late tracking events must not reinstate stale hover")
            for row in rows { row.updateTrackingAreas() }
            #expect(try highlighted(rows[offset == 0 ? 0 : 1]))
            #expect(try !highlighted(rows[offset == 0 ? 1 : 0]))
            #expect(rows[2].isSelected)
        }
        window.pointer = .init(x: -10, y: -10)
        for row in rows { row.updateTrackingAreas() }
        #expect(try !highlighted(rows[0]))
        #expect(try !highlighted(rows[1]))
        #expect(rows[2].isSelected)
    }

    private func highlighted(_ row: NSTableRowView) throws -> Bool {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor.clear.setFill()
        row.bounds.fill(using: .copy)
        row.drawBackground(in: row.bounds)
        return (bitmap.colorAt(x: 150, y: 50)?.alphaComponent ?? 0) > 0.1
    }
}

@MainActor final class HoverWindow: NSWindow {
    var pointer = NSPoint.zero
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    override var isKeyWindow: Bool { true }
}
