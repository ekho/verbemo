import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome)
@MainActor
struct JournalAlertTests {
    @Test("Return never becomes a shortcut for a destructive first button")
    func destructiveChoiceHasNoDefaultButton() throws {
        _ = NSApplication.shared
        let parent = NSWindow()
        parent.isReleasedWhenClosed = false
        let alert = NSAlert()
        alert.messageText = "Delete synthetic model?"
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginJournalSheetModal(for: parent)
        let sheet = try #require(parent.attachedSheet)
        defer { parent.endSheet(sheet); parent.orderOut(nil) }
        #expect(sheet.defaultButtonCell == nil)
        #expect(alert.buttons[0].keyEquivalent.isEmpty)
    }

    @Test("Journal layout preserves native confirmation and cancellation", arguments: [0, 1], ["Cancel", "Отмена"])
    func buttonResponses(index: Int, cancelTitle: String) async throws {
        _ = NSApplication.shared
        let parent = NSWindow()
        parent.isReleasedWhenClosed = false
        let alert = NSAlert()
        alert.messageText = "Synthetic confirmation"
        alert.informativeText = "No meeting is changed."
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: cancelTitle).keyEquivalent = "\u{1b}"
        var response: NSApplication.ModalResponse?
        alert.beginJournalSheetModal(for: parent) { response = $0 }
        defer {
            if let sheet = parent.attachedSheet { parent.endSheet(sheet) }
            parent.orderOut(nil)
        }
        let button = alert.buttons[index]
        let sheet = try #require(parent.attachedSheet)
        #expect(sheet.defaultButtonCell === alert.buttons.first?.cell)
        if index == 1 {
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
                timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            sheet.sendEvent(escape)
        } else {
            #expect(button.sendAction(button.action, to: button.target))
        }
        for _ in 0..<200 where response == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(response == (index == 0 ? .alertFirstButtonReturn : .alertSecondButtonReturn))
    }

    @Test("System error descriptions and recovery buttons remain available")
    func errorDescription() throws {
        _ = NSApplication.shared
        let parent = NSWindow()
        parent.isReleasedWhenClosed = false
        let error = NSError(domain: "DialogTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Synthetic error",
            NSLocalizedRecoverySuggestionErrorKey: "Try the operation again.",
        ])
        let alert = NSAlert(error: error)
        alert.beginJournalSheetModal(for: parent)
        let sheet = try #require(parent.attachedSheet)
        defer { parent.endSheet(sheet); parent.orderOut(nil) }
        let text = try #require(sheet.contentView).allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(text.contains("Synthetic error"))
        #expect(text.contains("Try the operation again."))
        #expect(!alert.buttons.isEmpty)
        #expect((sheet.contentView as? JournalSurface)?.color == JournalStyle.paper)
    }

}
