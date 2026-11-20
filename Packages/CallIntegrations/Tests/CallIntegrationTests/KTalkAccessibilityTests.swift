import ApplicationServices
import CallIntegrations
import Testing
@testable import KTalkIntegration

struct KTalkAccessibilityTests {
    @Test func settingsAndAmbiguousButtonsAreNotExit() {
        #expect(KTalkAccessibility.participation(labels: []) == .unknown)
        #expect(KTalkAccessibility.participation(labels: ["Покинуть комнату", "Присоединиться"]) == .unknown)
        #expect(KTalkAccessibility.participation(labels: ["\u{200B}Присоединиться"]) == .preparing)
        #expect(KTalkAccessibility.participation(labels: ["Покинуть комнату"]) == .inCall)
    }

    @Test func closingTheJoinedWindowWhileTheMainWindowRemains() {
        let main = AXUIElementCreateApplication(101)
        let meeting = AXUIElementCreateApplication(102)
        let next = AXUIElementCreateApplication(103)
        let dialog = AXUIElementCreateApplication(105)
        let replacementDialog = AXUIElementCreateApplication(106)
        let unknown = KTalkReading(participation: .unknown)
        let joined = KTalkReading(participation: .inCall, call: .init(id: "meeting"))
        var history = KTalkAccessibility.CallWindowState.unobserved
        var destroyed: Set<AXUIElement> = []
        func read(_ windows: [(AXUIElement, KTalkReading)], complete: Bool = true) -> KTalkReading {
            history.resolve(windows, completeWindowList: complete,
                            isAuxiliaryDialog: { $0 == dialog || $0 == replacementDialog },
                            isDestroyed: destroyed.contains)
        }

        #expect(read([(main, unknown)]).participation == .unknown)
        #expect(read([(main, unknown), (meeting, joined), (dialog, unknown)]) == joined)
        #expect(read([(main, unknown), (meeting, unknown)]).participation == .unknown)
        #expect(read([(main, unknown)]).participation == .unknown)
        destroyed.insert(meeting)
        #expect(read([(main, unknown)], complete: false).participation == .unknown)

        #expect(read([(main, unknown), (dialog, unknown)]) == KTalkReading(participation: .idle))
        #expect(read([(main, unknown), (replacementDialog, unknown)]).participation == .idle)
        #expect(read([]).participation == .idle)
        #expect(read([(main, unknown)], complete: false).participation == .unknown)
        #expect(read([(main, unknown)]).participation == .idle)
        #expect(read([(main, unknown), (next, unknown)]).participation == .unknown)
        #expect(read([(main, unknown)]).participation == .unknown)
        #expect(read([(main, unknown), (next, joined)]) == joined)
        destroyed.insert(next)
        #expect(read([(main, unknown), (AXUIElementCreateApplication(104), unknown)]).participation == .unknown)
    }

    @Test func roomLinksDoNotExposeSecretsOrChooseFavourites() {
        #expect(KTalkAccessibility.cleanRoomURL("https://user:secret@qa.ktalk.ru/probe?pin=123#token")?.absoluteString == "https://qa.ktalk.ru/probe")
        #expect(KTalkAccessibility.cleanRoomURL("https://qa.ktalk.ru/") == nil)
        #expect(KTalkAccessibility.cleanRoomURL("https://qa.ktalk.ru.evil.test/probe") == nil)
    }
}
