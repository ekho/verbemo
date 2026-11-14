import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome) @MainActor
struct InspectorResizeTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func dragKeyboardAndReopeningKeepBothPanesUsable(appearance: NSAppearance.Name) async throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: SessionFixture.make(), to: root.appendingPathComponent("saved"))
        let app = ApplicationWindow()
        defer { app.hide() }
        app.panel.appearance = NSAppearance(named: appearance)
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.setContentSize(.init(width: 760, height: 600))
        app.show()
        await library.settled()
        // Ordering a window can constrain it to the CI display; size the fixture afterwards.
        app.panel.setContentSize(.init(width: 1340, height: 820))
        let divider = try #require(library.contentView.allDescendants.compactMap { $0 as? InspectorDivider }.first)
        let inspector = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.inspector-content" })
        let document = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.document" })
        let toggle = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "meeting.inspector" })
        func layout() {
            app.panel.contentView?.layoutSubtreeIfNeeded()
            library.updateCompactLayout()
            app.panel.contentView?.layoutSubtreeIfNeeded()
        }
        func key(_ code: UInt16) throws {
            divider.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: app.panel.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
            layout()
        }
        layout()
        try #require(!divider.isHidden && !inspector.isHidden && !document.isHidden)
        try #require(abs(inspector.frame.width - 270) < 1)
        let initial = inspector.frame.width
        let start = divider.convert(.init(x: 3, y: 30), to: nil)
        func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .init(x: x, y: start.y), modifierFlags: [],
                timestamp: 0, windowNumber: app.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        divider.mouseDown(with: try mouse(.leftMouseDown, x: start.x))
        divider.mouseDragged(with: try mouse(.leftMouseDragged, x: start.x - 90))
        divider.mouseUp(with: try mouse(.leftMouseUp, x: start.x - 90))
        layout()
        #expect(abs(inspector.frame.width - initial - 90) < 1)
        #expect(app.panel.firstResponder === divider)
        app.panel.recalculateKeyViewLoop()
        await Task.yield()
        app.panel.recalculateKeyViewLoop()
        let previous = try #require(divider.previousValidKeyView)
        app.panel.makeFirstResponder(previous)
        app.panel.selectNextKeyView(nil)
        #expect(app.panel.firstResponder === divider, "Tab must reach the resize control")
        try key(123)
        let preferred = inspector.frame.width
        #expect(preferred > initial + 90)
        #expect(divider.accessibilityRole() == .splitter)
        #expect(divider.accessibilityLabel()?.isEmpty == false)
        #expect(divider.accessibilityPerformDecrement())
        layout()
        #expect(inspector.frame.width < preferred)
        #expect(divider.accessibilityPerformIncrement())
        layout()
        #expect(abs(inspector.frame.width - preferred) < 1)
        #expect(toggle.sendAction(toggle.action, to: toggle.target))
        layout()
        #expect(inspector.isHidden && divider.isHidden && !document.isHidden)
        #expect(toggle.sendAction(toggle.action, to: toggle.target))
        layout()
        #expect(abs(inspector.frame.width - preferred) < 1)
        try key(119)
        let widest = inspector.frame.width
        try key(123)
        #expect(inspector.frame.width == widest)
        #expect(document.frame.width >= 420)
        try key(115)
        let narrowest = inspector.frame.width
        try key(124)
        #expect(inspector.frame.width == narrowest && narrowest < widest)
        try key(119)
        app.panel.setContentSize(.init(width: 1140, height: 700))
        layout()
        #expect(!document.isHidden && document.frame.width >= 420)
        #expect(inspector.frame.width < widest && inspector.frame.width >= narrowest)
        app.panel.setContentSize(.init(width: 760, height: 600))
        layout()
        #expect(divider.isHidden && document.isHidden && !inspector.isHidden)
        #expect(toggle.sendAction(toggle.action, to: toggle.target))
        layout()
        #expect(!document.isHidden && inspector.isHidden)
        #expect(app.panel.contentLayoutRect.width <= 762)
        app.panel.setContentSize(.init(width: 1340, height: 820))
        layout()
        #expect(toggle.sendAction(toggle.action, to: toggle.target))
        layout()
        #expect(abs(inspector.frame.width - widest) < 1)
    }
}
