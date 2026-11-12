import Foundation
import Testing
import CallIntegrations
@testable import KTalkIntegration

struct KTalkResolverTests {
    @Test func directParticipationWinsOverAnOverlayOrConflictingUI() {
        let call = CallInfo(id: "call-a", title: "Synthetic room", participants: [])
        for state in [CallParticipation.unknown, .idle, .preparing, .inCall] {
            let result = KTalkResolver.resolve(cdp: .init(participation: .inCall, call: call),
                                              accessibility: .init(participation: state))
            #expect(result.0.participation == .inCall)
            #expect(result.0.call == call)
            #expect(result.1 == .application)
        }
    }

    @Test func fallbackDoesNotInventParticipantsAndLossIsNotExit() {
        let ui = KTalkReading(participation: .inCall, call: .init(id: "window-b", title: "Room B"))
        let fallback = KTalkResolver.resolve(cdp: .init(participation: .unknown), accessibility: ui)
        #expect(fallback.0 == ui)
        #expect(fallback.0.call?.participants == nil)
        #expect(fallback.1 == .accessibility)
        let lost = KTalkResolver.resolve(cdp: .init(participation: .unknown), accessibility: .init(participation: .unknown))
        #expect(lost.0.participation == .unknown)
        #expect(lost.0.call == nil)
    }

    @Test func explicitPrejoinIsNotOverruledByOldUI() {
        let result = KTalkResolver.resolve(cdp: .init(participation: .preparing),
                                          accessibility: .init(participation: .inCall))
        #expect(result.0.participation == .preparing)
        #expect(result.1 == .application)
    }
}
