import AppKit
import Foundation
import Testing

@testable import verbemo

/// Keyboard and VoiceOver behavior of the Journal settings pages.
@Suite(.serialized)
@MainActor
struct AccessibilityTests {
    private static func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// A card was a plain view with a mouseDown: nothing else could choose
    /// it, and VoiceOver read it as loose text.
    @Test("A choice card is a radio button: named, valued, pressable")
    func cardIsARadioButton() {
        let card = ChoiceCard(id: "openai", title: "OpenAI", detail: "$0.36 an hour.")
        var chosen: [String] = []
        card.onSelect = { chosen.append($0) }

        #expect(card.isAccessibilityElement())
        #expect(card.accessibilityRole() == .radioButton)
        #expect(card.accessibilityLabel() == "OpenAI")
        #expect(card.accessibilityHelp()?.contains("$0.36 an hour.") == true)
        #expect((card.accessibilityValue() as? NSNumber)?.intValue == 0)
        card.isSelected = true
        #expect((card.accessibilityValue() as? NSNumber)?.intValue == 1)

        #expect(card.accessibilityPerformPress())
        #expect(chosen == ["openai"])

        card.isEnabled = false
        #expect(!card.accessibilityPerformPress())
        #expect(!card.acceptsFirstResponder)
        #expect(chosen == ["openai"])
    }

    @Test("Space and Return choose a focused card; the arrows move along its group")
    func cardsAnswerTheKeyboard() throws {
        let group = ChoiceGroup()
        let cards = ["a", "b", "c"].map { ChoiceCard(id: $0, title: $0.uppercased(), detail: "") }
        group.adopt(cards)
        var changes: [String] = []
        group.onChange = { changes.append($0) }

        #expect(cards[0].acceptsFirstResponder)
        cards[0].keyDown(with: try Self.key(" ", code: 49))
        #expect(group.selected == "a")

        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        cards[0].keyDown(with: try Self.key(right, code: 124))
        #expect(group.selected == "b")

        cards[2].isEnabled = false
        cards[1].keyDown(with: try Self.key(right, code: 124))
        #expect(group.selected == "b", "the arrow chose a card that is switched off")

        cards[2].isEnabled = true
        cards[2].keyDown(with: try Self.key("\r", code: 36))
        #expect(changes == ["a", "b", "c"])
    }

    /// No `setAccessibilityLabel` anywhere: every switch in the window was
    /// announced as "switch" and nothing more.
    @Test("Every settings switch is named for its row", .freshHome)
    func everySwitchIsNamed() {
        let application = ApplicationWindow()
        defer { withExtendedLifetime(application) {} }
        var switches: [NSSwitch] = []
        for destination in ApplicationNavigationState.Destination.allCases
            where !destination.isMeetings && destination != .about {
            application.navigate(destination)
            switches += application.panel.contentView?.allDescendants.compactMap { $0 as? NSSwitch } ?? []
        }
        #expect(switches.count >= 8)
        for toggle in switches {
            let name = toggle.accessibilityLabel() ?? ""
            #expect(!name.isEmpty, "\(toggle.identifier?.rawValue ?? "a switch") has no name")
        }
        let keepAudio = switches.first { $0.identifier?.rawValue == "files.keep-audio" }
        #expect(keepAudio?.accessibilityLabel() == "Keep the audio after transcribing")
        let summaries = switches.first { $0.identifier?.rawValue == "summary.enabled" }
        #expect(summaries?.accessibilityLabel() == "Summary")
    }

    @Test("Every settings card is a named radio button", .freshHome)
    func everyCardIsNamed() {
        let application = ApplicationWindow()
        defer { withExtendedLifetime(application) {} }
        var cards: [ChoiceCard] = []
        for destination: ApplicationNavigationState.Destination in [.transcription, .summary] {
            application.navigate(destination)
            cards += application.panel.contentView?.allDescendants.compactMap { $0 as? ChoiceCard } ?? []
        }
        #expect(!cards.isEmpty)
        for card in cards {
            #expect(card.accessibilityRole() == .radioButton)
            #expect(card.accessibilityLabel()?.isEmpty == false, "\(card.id) has no name")
        }
    }

    @Test("An Access row's button says which grant it asks for", .freshHome)
    func accessButtonsSayWhatFor() throws {
        let application = ApplicationWindow()
        application.navigate(.recording)
        defer { withExtendedLifetime(application) {} }
        let button = try #require(application.panel.contentView?.allDescendants
            .first { $0.identifier?.rawValue == "access.microphone.action" } as? NSButton)
        #expect(button.accessibilityLabel()?.contains("Microphone") == true)
    }

    @Test("Every schema control is named for its setting", .freshHome)
    func schemaControlsAreNamed() {
        let application = ApplicationWindow()
        let settings = application.settings
        defer { withExtendedLifetime(application) {} }
        #expect(!settings.renderedControls.isEmpty)
        for control in settings.renderedControls {
            #expect(control.accessibilityLabel()?.isEmpty == false,
                    "\(control.identifier?.rawValue ?? "a control") has no name")
        }
    }
}
