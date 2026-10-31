import AppKit
import SwiftUI
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct StudioMeetingHeaderTests {
    @Test func nativeControlsStackAtNarrowWidth() async throws {
        let state = StudioMeetingHeaderState()
        let versions = NSPopUpButton()
        versions.addItem(withTitle: "Current")
        let search = NSSearchField()
        let host = StudioMeetingHeaderHost(rootView: StudioMeetingHeader(state: state, versions: versions,
            tabs: NSStackView(), search: search))
        for width: CGFloat in [420, 800] {
            host.frame = NSRect(x: 0, y: 0, width: width, height: 120)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); await Task.yield() }
            let versionY = versions.convert(versions.bounds, to: host).midY
            let searchY = search.convert(search.bounds, to: host).midY
            #expect((abs(versionY - searchY) > 10) == (width < 560))
        }
    }
    @Test func presentationUpdatesDoNotDispatchUserActions() throws {
        let state = StudioMeetingHeaderState()
        var steps: [Bool] = []
        var clears = 0
        state.onStep = { steps.append($0) }
        state.onClear = { clears += 1 }
        let versions = NSPopUpButton()
        versions.addItems(withTitles: ["Current", "Archive"])
        let tabs = NSStackView(views: [NSButton(title: "Transcript", target: nil, action: nil)])
        let search = NSSearchField()
        let host = StudioMeetingHeaderHost(rootView: StudioMeetingHeader(state: state, versions: versions, tabs: tabs, search: search))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 110)
        state.matchCount = 4
        state.matchIndex = 2
        state.hasQuery = true
        host.layoutSubtreeIfNeeded()
        #expect(steps.isEmpty && clears == 0)
        #expect(versions.indexOfSelectedItem == 0)
        state.step(forward: true)
        state.step(forward: false)
        state.clear()
        #expect(steps == [true, false])
        #expect(clears == 1)
    }
    @Test(.freshHome) func collapsedLibraryHasNoVisibleDividerOverContent() async throws {
        _ = NSApplication.shared
        let app = ApplicationWindow()
        defer { app.hide() }
        app.show()
        app.panel.contentView?.layoutSubtreeIfNeeded()
        app.panel.displayIfNeeded()
        let split = try #require(app.panel.contentView?.allDescendants.first { $0 is WorkspaceSplitView } as? NSSplitView)
        _ = try #require(split.layer)
        try await Task.sleep(for: .milliseconds(100))
        let toggle = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "workspace.toggle-library" })
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        app.panel.displayIfNeeded()
        func visibleVerticalLines(_ layer: CALayer) -> [CALayer] {
            guard !layer.isHidden else { return [] }
            let isLine = layer.frame.width > 0 && layer.frame.width <= split.dividerThickness
                && layer.frame.height >= split.bounds.height - 1
                && layer.frame.minX > 0 && layer.frame.maxX < split.bounds.width
            return (isLine ? [layer] : []) + (layer.sublayers ?? []).flatMap(visibleVerticalLines)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(visibleVerticalLines(try #require(split.layer)).isEmpty)
        #expect(split.arrangedSubviews.last?.frame == split.bounds)
    }

    @Test(.freshHome, arguments: ["f", "а"]) func meetingFindCommandAndLibraryResize(unmodified: String) throws {
        _ = NSApplication.shared
        let dir = Home.current.url.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"title":"Planning"}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: Home.current.url, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.show()
        app.panel.setContentSize(NSSize(width: 1340, height: 820))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let split = try #require(app.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "workspace.library-split" } as? NSSplitView)
        split.setPosition(320, ofDividerAt: 0)
        let toggle = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "workspace.toggle-library" })
        let action = try #require(toggle.action)
        _ = NSApp.sendAction(action, to: toggle.target, from: toggle)
        #expect(split.arrangedSubviews[0].isHidden)
        #expect(app.primaryActionsAreVisible)
        _ = NSApp.sendAction(action, to: toggle.target, from: toggle)
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(split.arrangedSubviews[0].frame.width - 320) < 2)
        let search = try #require(library.contentView.allDescendants.compactMap { $0 as? NSSearchField }
            .first { $0.identifier?.rawValue == "meeting.search" })
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: app.panel.windowNumber, context: nil, characters: "f",
            charactersIgnoringModifiers: unmodified, isARepeat: false, keyCode: 3))
        #expect(app.panel.performKeyEquivalent(with: event))
        #expect(search.currentEditor() != nil)
        app.panel.makeFirstResponder(nil)
        #expect(app.panel.contentView?.performKeyEquivalent(with: event) == true)
        #expect(search.currentEditor() != nil)
        app.panel.setContentSize(NSSize(width: 760, height: 820))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        library.updateCompactLayout()
        let details = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "meeting.inspector" })
        _ = NSApp.sendAction(try #require(details.action), to: details.target, from: details)
        #expect(search.isHiddenOrHasHiddenAncestor)
        #expect(app.panel.performKeyEquivalent(with: event))
        #expect(!search.isHiddenOrHasHiddenAncestor)
        #expect(search.currentEditor() != nil)
        _ = NSApp.sendAction(action, to: toggle.target, from: toggle)
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(split.arrangedSubviews[1].frame.maxX <= split.bounds.maxX + 1)
        let header = try #require(app.panel.contentView?.allDescendants.first { $0.identifier?.rawValue == "meeting.studio-header" })
        #expect(header.convert(header.bounds, to: app.panel.contentView).maxX <= app.panel.contentView!.bounds.maxX + 1)
    }

}
