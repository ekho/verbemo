import AppKit
import SwiftUI
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct StudioMeetingHeaderTests {
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
        let host = NSHostingView(rootView: StudioMeetingHeader(state: state, versions: versions, tabs: tabs, search: search))
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
    @Test(.freshHome) func meetingFindCommandAndLibraryResize() throws {
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
        #expect(split.subviews[0].isHidden)
        #expect(app.primaryActionsAreVisible)
        _ = NSApp.sendAction(action, to: toggle.target, from: toggle)
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(split.subviews[0].frame.width - 320) < 2)
        let search = try #require(library.contentView.allDescendants.compactMap { $0 as? NSSearchField }
            .first { $0.identifier?.rawValue == "meeting.search" })
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: app.panel.windowNumber, context: nil, characters: "f",
            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(app.panel.performKeyEquivalent(with: event))
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
    }

}
