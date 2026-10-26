import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome) @MainActor
struct EmailAddressesTests {
    @Test func parsesPastedListsAndRefusesInvalidEntriesWithoutPartialResults() {
        #expect(EmailAddresses.parse(" Work@Example.test ; personal+tag@example.test\nwork@example.test ")
                == ["work@example.test", "personal+tag@example.test"])
        #expect(EmailAddresses.parse("good@example.test, not an address") == nil)
        #expect(EmailAddresses.parse("Name <me@example.test>") == nil)
        #expect(EmailAddresses.parse("me@@example.test") == nil)
    }

    @Test(.freshHome(config: #"{"user_email":" Legacy@Example.test "}"#))
    func readsLegacyAddressWithoutRewritingAndAcceptsLists() {
        #expect(Config.userEmails() == ["legacy@example.test"])
        #expect(Config.problems().isEmpty)
        #expect(Config.raw()["user_email"] as? String == " Legacy@Example.test ")
        #expect(Config.update(path: ["user_email"], value: ["Work@example.test", "work@example.test", "personal@example.test"]))
        #expect(Config.userEmails() == ["work@example.test", "personal@example.test"])
        #expect(Config.problems().isEmpty)
    }

    @Test func calendarExtractionRequiresExplicitSelfAndAMailtoAddress() throws {
        let url = try #require(URL(string: "mailto:Me%2Bwork@Example.test"))
        #expect(CalendarEmailDiscovery.ownAddress(url: url, isCurrentUser: true) == "me+work@example.test")
        #expect(CalendarEmailDiscovery.ownAddress(url: url, isCurrentUser: false) == nil)
        #expect(CalendarEmailDiscovery.ownAddress(url: URL(string: "https://example.test/me")!, isCurrentUser: true) == nil)
    }

    @Test(.freshHome(config: #"{"user_email":"manual@example.test"}"#))
    func firstGrantMergesOnceAndNeverRestoresDeletedAddresses() {
        CalendarEmailDiscovery.importAfterFirstGrant(["WORK@example.test", "manual@example.test"])
        #expect(Config.userEmails() == ["manual@example.test", "work@example.test"])
        #expect(SetupState.calendarEmailsImported())
        Config.update(path: ["user_email"], value: nil)
        SetupState.reset()
        CalendarEmailDiscovery.importAfterFirstGrant(["work@example.test"])
        #expect(Config.userEmails().isEmpty)
    }

    @Test func emptyFirstSearchStillDoesNotStartRepeatingImports() {
        CalendarEmailDiscovery.importAfterFirstGrant([])
        CalendarEmailDiscovery.importAfterFirstGrant(["later@example.test"])
        #expect(Config.userEmails().isEmpty)
    }

    @Test(.freshHome(config: "not json"))
    func failedSaveDoesNotMarkImportComplete() {
        CalendarEmailDiscovery.importAfterFirstGrant(["work@example.test"])
        #expect(!SetupState.calendarEmailsImported())
    }

    @Test(.freshHome(config: #"{"user_email":"old@example.test"}"#))
    func editorAddsWithReturnRemovesIndividuallyAndPreservesInvalidDraft() throws {
        let app = ApplicationWindow()
        defer { app.settings.setup.stop(); app.hide() }
        app.navigate(.calendar)
        let page = app.settings.content(for: .calendar)
        let editor = try #require(page.allDescendants.compactMap { $0 as? EmailAddressesEditor }.first)
        #expect(editor.accessibilityChildren()?.isEmpty == false)
        let input = try #require(editor.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "user_email.input" })
        input.stringValue = "NEW@example.test; old@example.test"
        #expect(input.sendAction(input.action, to: input.target))
        #expect(Config.userEmails() == ["old@example.test", "new@example.test"])
        #expect(input.stringValue.isEmpty)
        input.stringValue = "bad address"
        #expect(input.sendAction(input.action, to: input.target))
        #expect(Config.userEmails().count == 2)
        #expect(input.stringValue == "bad address")
        let remove = try #require(editor.allDescendants.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "user_email.remove" && $0.tag == 0
        })
        #expect(remove.sendAction(remove.action, to: remove.target))
        #expect(Config.userEmails() == ["new@example.test"])
        if let output = ProcessInfo.processInfo.environment["VERBEMO_EMAIL_SNAPSHOT"] {
            app.panel.setContentSize(NSSize(width: 1100, height: 760))
            app.panel.contentView?.layoutSubtreeIfNeeded()
            let content = try #require(app.panel.contentView)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
}
