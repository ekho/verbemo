import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct StudioDensityTests {
    @Test(.freshHome, .speaking(.english)) func transcriptUsesOneGutterAndStartsNearTabs() async throws {
        _ = NSApplication.shared
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: SessionFixture.make(), to: root.appendingPathComponent("fixture"))
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.show()
        app.panel.setContentSize(.init(width: 1340, height: 820))
        let tab = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "meeting.result.transcript" })
        #expect(NSApp.sendAction(try #require(tab.action), to: tab.target, from: tab))
        for _ in 0..<4 { app.panel.contentView?.layoutSubtreeIfNeeded(); await Task.yield() }
        let document = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.document" })
        let transcript = try #require(document.allDescendants.first { $0 is MeetingTranscriptView } as? MeetingTranscriptView)
        let table = try #require(transcript.documentView as? NSTableView)
        let title = try #require(document.allDescendants.first { $0.identifier?.rawValue == "meeting.title" })
        let toggle = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "workspace.toggle-library" })
        for (width, hideLibrary) in [(1340.0, false), (760, false), (760, true), (1340, false)] {
            app.panel.setContentSize(.init(width: width, height: 600))
            let split = try #require(app.panel.contentView?.allDescendants.first { $0 is WorkspaceSplitView } as? NSSplitView)
            if split.arrangedSubviews[0].isHidden != hideLibrary {
                #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
            }
            for _ in 0..<4 {
                app.panel.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            let currentCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            currentCell.layoutSubtreeIfNeeded()
            let currentBadge = try #require(currentCell.allDescendants.compactMap { $0 as? NSTextField }.first { $0.frame.width == 26 })
            let badgeRect = currentBadge.convert(currentBadge.bounds, to: document)
            let tabsRect = tab.convert(tab.bounds, to: document)
            #expect(badgeRect.minX <= 25, "One page gutter, without a second inset around the transcript")
            #expect(abs(badgeRect.minX - title.convert(title.bounds, to: document).minX) <= 2)
            #expect(abs(transcript.bounds.width - (document.bounds.width - 48)) <= 1)
            #expect((0...16).contains(tabsRect.minY - badgeRect.maxY), "Text starts directly below the tab strip at width \(width), library hidden \(hideLibrary)")
        }
    }

    @Test func voiceLetterIsVerticallyCentered() throws {
        _ = NSApplication.shared
        let badge = StudioStyle.voiceBadge("A")
        badge.appearance = NSAppearance(named: .aqua)
        badge.frame = .init(x: 0, y: 0, width: 26, height: 24)
        let bitmap = try #require(badge.bitmapImageRepForCachingDisplay(in: badge.bounds))
        badge.cacheDisplay(in: badge.bounds, to: bitmap)
        let corner = try #require(bitmap.colorAt(x: 1, y: 1))
        #expect(corner.alphaComponent > 0.99, "The badge fills its whole fixed box, not only the text drawing rect")
        var foreground: NSColor?
        badge.effectiveAppearance.performAsCurrentDrawingAppearance { foreground = badge.textColor?.usingColorSpace(bitmap.colorSpace) }
        let ink = try #require(foreground)
        var ys: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y), c.alphaComponent > 0.8 else { continue }
                let difference = abs(c.redComponent - ink.redComponent) + abs(c.greenComponent - ink.greenComponent) + abs(c.blueComponent - ink.blueComponent)
                if difference < 0.2 { ys.append(y) }
            }
        }
        let top = try #require(ys.min()), bottom = try #require(ys.max())
        #expect(abs(Double(top + bottom + 1) / 2 - Double(bitmap.pixelsHigh) / 2) <= 2)
    }

    @Test func longUtteranceKeepsIdentityAtTheTopAndFitsItsRow() throws {
        _ = NSApplication.shared
        let view = MeetingTranscriptView()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        view.update(transcript: .init(engine: "test", model: "test", created_at: "test", segments: [
            .init(speaker: "them A", start_ms: 0, end_ms: 1000,
                  text: String(repeating: "Нужно согласовать сроки, проверить материалы и записать решение. ", count: 8)),
        ]), names: nil, participants: [], canEdit: false)
        view.layoutSubtreeIfNeeded()
        let table = try #require(view.documentView as? NSTableView)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let fields = cell.allDescendants.compactMap { $0 as? NSTextField }
        let badge = try #require(fields.first { $0.frame.width == 26 })
        let body = try #require(fields.first { $0.identifier?.rawValue == "transcript.words" })
        let badgeRect = badge.convert(badge.bounds, to: cell), bodyRect = body.convert(body.bounds, to: cell)
        let needed = try #require(body.cell).cellSize(forBounds: .init(x: 0, y: 0, width: body.bounds.width, height: 10000)).height
        #expect(abs(badgeRect.maxY - bodyRect.maxY) <= 2)
        #expect(body.bounds.height >= needed - 1)
        #expect(bodyRect.minY >= 9)
    }

    @Test func differentVoicesHaveDistinctBadgesAndReuseKeepsTheirColor() throws {
        _ = NSApplication.shared
        let view = MeetingTranscriptView()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let segments: [Transcript.Segment] = ["me", "them A", "them B"].enumerated().map { index, speaker in
            .init(speaker: speaker, start_ms: index * 1000, end_ms: (index + 1) * 1000, text: "Short utterance")
        }
        let transcript = Transcript(engine: "test", model: "test", created_at: "test", segments: segments)
        view.update(transcript: transcript, names: nil, participants: [], canEdit: false)
        view.layoutSubtreeIfNeeded()
        let table = try #require(view.documentView as? NSTableView)
        func color(_ row: Int) throws -> NSColor {
            let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
            let badge = try #require(cell.allDescendants.compactMap { $0 as? NSTextField }.first { $0.frame.width == 26 })
            var resolved: NSColor?
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                resolved = badge.backgroundColor?.usingColorSpace(.sRGB)
            }
            return try #require(resolved)
        }
        let colors = try (0..<3).map(color)
        #expect(colors[0] != colors[1] && colors[1] != colors[2] && colors[0] != colors[2])
        view.setSearch(matches: [1: [.init(location: 0, length: 5)]])
        view.layoutSubtreeIfNeeded()
        #expect(try (0..<3).map(color) == colors)
    }
    @Test func legacyScrollbarDoesNotClipTheLastLine() async throws {
        _ = NSApplication.shared
        let view = MeetingTranscriptView()
        view.scrollerStyle = .legacy
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1044, height: 514), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let words = "Реплика 1. Обсуждаем подготовку учебного проекта. " + String(repeating: "Нужно согласовать сроки, проверить материалы и записать решение. ", count: 4)
        view.update(transcript: .init(engine: "test", model: "test", created_at: "test", segments: (0..<18).map {
            .init(speaker: "them A", start_ms: $0 * 1000, end_ms: ($0 + 1) * 1000, text: words)
        }), names: nil, participants: [], canEdit: false)
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let table = try #require(view.documentView as? NSTableView)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let body = try #require(cell.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "transcript.words" })
        let bodyRect = body.convert(body.bounds, to: cell)
        let needed = try #require(body.cell).cellSize(forBounds: .init(x: 0, y: 0, width: body.bounds.width, height: 10000)).height
        #expect(body.bounds.height >= needed - 1)
        #expect(bodyRect.minY >= 9)
    }
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua]) func voicePaletteHasReadableContrast(appearance: NSAppearance.Name) throws {
        func luminance(_ c: NSColor) -> Double {
            func linear(_ v: CGFloat) -> Double { let n = Double(v); return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        let theme = try #require(NSAppearance(named: appearance))
        for index in 0..<9 {
            let badge = StudioStyle.voiceBadge("A", colorIndex: index)
            var ink: NSColor?, background: NSColor?
            theme.performAsCurrentDrawingAppearance {
                ink = badge.textColor?.usingColorSpace(.sRGB)
                background = badge.backgroundColor?.usingColorSpace(.sRGB)
            }
            let a = luminance(try #require(ink)), b = luminance(try #require(background))
            #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
        }
    }

}
