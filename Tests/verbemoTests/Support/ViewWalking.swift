import AppKit
import Testing
@testable import verbemo

extension NSView {
    /// Every view under this one, depth first — how the window tests find a
    /// control by what it says or by its identifier.
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }
}

@MainActor
extension ActivityStatusBar {
    var serviceDescendants: [NSView] {
        serviceRows.flatMap { [$0] + $0.allDescendants }
    }

    func openServiceMessagesForTest() throws {
        refreshMessages()
        let trigger = try #require(allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "activity.messages" && !$0.isHiddenOrHasHiddenAncestor })
        #expect(trigger.sendAction(trigger.action, to: trigger.target))
        let content = try #require(serviceContent.window?.contentView)
        content.layoutSubtreeIfNeeded()
    }
}
