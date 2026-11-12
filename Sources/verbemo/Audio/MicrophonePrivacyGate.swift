import Foundation
import os.lock

/// A short-lived permission, checked by the audio callback without the UI thread.
final class MicrophonePrivacyGate: @unchecked Sendable {
    struct Ticket: Equatable { let generation: Int; let allowed: Bool }
    static let holdback: TimeInterval = 2
    static let maximumAge: TimeInterval = 1.5
    private struct State {
        var generation = 0
        var allowed = false
        var until: TimeInterval = 0
        mutating func expire(at now: TimeInterval) {
            if allowed && now >= until { generation += 1; allowed = false }
        }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func update(unmuted: Bool, validFor: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        state.withLock { s in
            s.expire(at: now)
            let allow = unmuted && validFor.isFinite && validFor > 0
            if s.allowed && !allow { s.generation += 1 }
            s.allowed = allow
            s.until = now + min(Self.maximumAge, max(0, validFor.isFinite ? validFor : 0))
        }
    }
    func ticket(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Ticket {
        state.withLock { s in
            s.expire(at: now)
            return Ticket(generation: s.generation, allowed: s.allowed)
        }
    }
    func accepts(_ ticket: Ticket, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let current = self.ticket(now: now)
        return ticket.allowed && current.allowed && current.generation == ticket.generation
    }
}
