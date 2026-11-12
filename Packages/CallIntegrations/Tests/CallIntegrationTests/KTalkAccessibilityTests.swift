import Testing
@testable import KTalkIntegration

struct KTalkAccessibilityTests {
    @Test func settingsAndAmbiguousButtonsAreNotExit() {
        #expect(KTalkAccessibility.participation(labels: []) == .unknown)
        #expect(KTalkAccessibility.participation(labels: ["Покинуть комнату", "Присоединиться"]) == .unknown)
        #expect(KTalkAccessibility.participation(labels: ["\u{200B}Присоединиться"]) == .preparing)
        #expect(KTalkAccessibility.participation(labels: ["Покинуть комнату"]) == .inCall)
    }
    @Test func roomLinksDoNotExposeSecretsOrChooseFavourites() {
        #expect(KTalkAccessibility.cleanRoomURL("https://user:secret@qa.ktalk.ru/probe?pin=123#token")?.absoluteString == "https://qa.ktalk.ru/probe")
        #expect(KTalkAccessibility.cleanRoomURL("https://qa.ktalk.ru/") == nil)
        #expect(KTalkAccessibility.cleanRoomURL("https://qa.ktalk.ru.evil.test/probe") == nil)
    }
}
