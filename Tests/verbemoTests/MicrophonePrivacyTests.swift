import Foundation
import Testing
@testable import verbemo

struct MicrophonePrivacyTests {
    @Test func permissionExpiresWithoutAnyTimerOrObserverCallback() {
        let gate = MicrophonePrivacyGate()
        #expect(!gate.ticket(now: 0).allowed)
        gate.update(unmuted: true, validFor: 1, now: 10)
        let allowed = gate.ticket(now: 10.2)
        #expect(allowed.allowed)
        #expect(gate.accepts(allowed, now: 10.8))
        #expect(!gate.accepts(allowed, now: 11.1))
    }
    @Test func muteAndUnknownInvalidateAlreadyBufferedAudioPermanently() {
        let gate = MicrophonePrivacyGate()
        gate.update(unmuted: true, validFor: 1, now: 10)
        let prior = gate.ticket(now: 10.1)
        gate.update(unmuted: false, validFor: 1, now: 10.2)
        gate.update(unmuted: true, validFor: 1, now: 10.3)
        #expect(!gate.accepts(prior, now: 10.4))
        #expect(gate.ticket(now: 10.4).allowed)
        gate.update(unmuted: false, validFor: 0, now: 10.5)
        #expect(!gate.ticket(now: 10.5).allowed)
    }
    @Test func lateRenewalCannotResurrectAudioFromAnObservationGap() {
        let gate = MicrophonePrivacyGate()
        gate.update(unmuted: true, validFor: 0.5, now: 10)
        let prior = gate.ticket(now: 10.1)
        gate.update(unmuted: true, validFor: 1, now: 12)
        #expect(!gate.accepts(prior, now: 12.1))
        #expect(gate.ticket(now: 12.1).allowed)
    }
}
