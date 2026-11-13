import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome) @MainActor
struct StudioLibraryTests {
    @Test(.speaking(.russian))
    func filterBesideSearchPreservesTheQueryAndSelectedMeeting() async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, title) in [("2026-10-31", "Атлас — планирование"), ("2026-10-30", "Атлас — обзор"), ("2026-10-29", "Другое") ] {
            try FileManager.default.moveItem(at: SessionFixture.make(meta: ["title": title]), to: root.appendingPathComponent(name))
        }
        Config.update(path: ["speaker_names", "enabled"], value: false)
        Config.update(path: ["summary", "enabled"], value: false)
        let dir = root.appendingPathComponent("2026-10-31")
        try SessionClaim.acquire(dir, stage: .transcribe)
        defer { SessionClaim.release(dir) }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.show()
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let search = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSSearchField }.first)
        let filter = try #require(library.listContentView.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "library.filter" })
        let field = search.convert(search.bounds, to: library.listContentView)
        let button = filter.convert(filter.bounds, to: library.listContentView)
        #expect(abs(field.midY - button.midY) < 2)
        #expect(button.minX > field.maxX)
        search.stringValue = "Атлас"
        #expect(search.sendAction(search.action, to: search.target))
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        let title = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.title" } as? NSTextField)
        #expect(table.numberOfRows == 2)
        let selected = title.stringValue
        #expect(selected == "Атлас — планирование")
        #expect(filter.sendAction(filter.action, to: filter.target))
        await Task.yield()
        let options = NSApp.windows.flatMap { $0.contentView?.allDescendants ?? [] }.compactMap { $0 as? NSButton }
            .filter { $0.identifier?.rawValue.hasPrefix("library.filter.") == true }
        #expect(options.count == 3)
        let left = options.map { $0.frame.minX }
        #expect((left.max() ?? 0) - (left.min() ?? 0) <= 1, "Filter choices keep their radio markers aligned")
        for option in options {
            #expect(option.frame.width >= option.fittingSize.width - 1, "A choice must fit inside the popover")
        }
        let processing = try #require(options.first { $0.identifier?.rawValue == "library.filter.processing" })
        #expect(processing.sendAction(processing.action, to: processing.target))
        for _ in 0..<3 { await Task.yield() }
        #expect(library.currentFilter == .processing)
        #expect(search.stringValue == "Атлас")
        #expect(title.stringValue == selected)
        #expect(table.numberOfRows == 1)
        #expect(filter.state == .on)
        #expect(filter.accessibilityLabel()?.contains("В обработке") == true)
        #expect(app.panel.firstResponder === filter)
        library.applyFilter(.allMeetings)
        #expect(filter.state == .off)
        #expect(search.stringValue == "Атлас")
        #expect(title.stringValue == selected)
        #expect(table.numberOfRows == 2)
    }

    @Test(.speaking(.russian), arguments: [NSScroller.Style.overlay, .legacy])
    func longMeetingTitlesWrapAndResizeWithoutClipping(scrollerStyle: NSScroller.Style) async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let title = "Атлас — обсуждение материалов, сроков и подготовки первого запуска учебного проекта"
        for index in 0..<12 {
            try FileManager.default.moveItem(at: SessionFixture.make(meta: ["title": title]), to: root.appendingPathComponent("meeting-\(index)"))
        }
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(.init(width: 1340, height: 600))
        app.show()
        let split = try #require(app.panel.contentView?.allDescendants.first { $0 is WorkspaceSplitView } as? NSSplitView)
        let table = try #require(library.listContentView.allDescendants.first { $0 is MeetingTableView } as? NSTableView)
        let scroll = try #require(table.enclosingScrollView)
        scroll.scrollerStyle = scrollerStyle
        let sidebar = try #require(app.panel.contentView?.allDescendants.first { $0 is SidebarView })
        var heights: [CGFloat] = []
        for width in [220.0, 400, 220] {
            split.setPosition(width, ofDividerAt: 0)
            for _ in 0..<4 { app.panel.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
            let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
            row.layoutSubtreeIfNeeded()
            let label = try #require(row.allDescendants.compactMap { $0 as? NSTextField }.first { $0.stringValue == title })
            #expect(label.lineBreakMode == .byWordWrapping)
            let needed = try #require(label.cell).cellSize(forBounds: .init(x: 0, y: 0, width: label.bounds.width, height: 1000)).height
            #expect(label.bounds.height >= needed - 1)
            #expect(label.bounds.height > 25, "A multi-line title must not collapse to the old single line")
            let frame = label.convert(label.bounds, to: row)
            #expect(row.bounds.insetBy(dx: 0, dy: -1).contains(frame))
            #expect(abs(scroll.convert(scroll.bounds, to: sidebar).maxX - sidebar.bounds.maxX) <= 1)
            let scroller = try #require(scroll.verticalScroller)
            let textRight = label.convert(label.bounds, to: scroll).maxX
            #expect(textRight <= scroller.convert(scroller.bounds, to: scroll).minX)
            heights.append(table.rect(ofRow: 0).height)
        }
        #expect(heights[0] > heights[1])
        #expect(abs(heights[0] - heights[2]) <= 1)
        table.selectRowIndexes([11], byExtendingSelection: false)
        table.scrollRowToVisible(11)
        #expect(table.selectedRow == 11 && scroll.documentVisibleRect.minY > 0)
    }

    @Test(.speaking(.english))
    func everyMeetingHasAnAccurateCompactStatusAndDuration() throws {
        _ = NSApplication.shared
        for (step, label) in [(SessionInventory.Step.done, "Ready"), (.pending, "Transcript not created"), (.failed("Model unavailable"), "Model unavailable")] {
            let item = SessionInventory.Item(dir: Home.current.url, name: "fixture", title: "Planning", started: nil,
                duration: 183, trigger: nil, engine: nil, transcript: step, diarization: nil, unreadableDiarization: false,
                speakers: .off, summary: .off, namedSpeakers: nil, sizeBytes: 0, hasAudio: true)
            let row = MeetingListView(item: item)
            let status = try #require(row.allDescendants.first { $0.identifier?.rawValue == "meeting.list-status" })
            #expect(status.accessibilityLabel() == label)
            #expect(status.accessibilityRole() == .image)
            let meta = try #require(row.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "meeting.list-date" })
            #expect(meta.stringValue.contains("03:03"), "The list retains seconds rather than rounding to minutes")
        }
    }

    @Test(.speaking(.english))
    func unfinishedSpeakerNamesAreNotReportedAsReady() throws {
        _ = NSApplication.shared
        for (step, label) in [(SessionInventory.Step.pending, "Speaker names pending"), (.failed("Naming unavailable"), "Naming unavailable")] {
            let item = SessionInventory.Item(dir: Home.current.url, name: "fixture", title: "Planning", started: nil,
                duration: 3603, trigger: nil, engine: nil, transcript: .done, diarization: nil, unreadableDiarization: false,
                speakers: step, summary: .off, namedSpeakers: nil, sizeBytes: 0, hasAudio: true)
            let row = MeetingListView(item: item)
            let status = try #require(row.allDescendants.first { $0.identifier?.rawValue == "meeting.list-status" })
            #expect(status.accessibilityLabel() == label)
            #expect(status.accessibilityRole() == .image)
            let meta = try #require(row.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "meeting.list-date" })
            #expect(meta.stringValue.contains("1:00:03"))
        }
    }
}
