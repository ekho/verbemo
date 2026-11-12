@preconcurrency import AVFoundation
import Foundation
import os.lock

/// Holds only local PCM in memory until the mute observer has had time to react.
final class MicrophonePrivacyFilter: @unchecked Sendable {
    struct Output { let buffer: AVAudioPCMBuffer; let padding: AVAudioFrameCount }
    let gate: MicrophonePrivacyGate
    private struct Pending {
        let buffer: AVAudioPCMBuffer
        let padding: AVAudioFrameCount
        let at: TimeInterval
        let ticket: MicrophonePrivacyGate.Ticket
        let epoch: Int
    }
    private struct State { var pending: [Pending] = []; var epoch = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(gate: MicrophonePrivacyGate) { self.gate = gate }
    func process(_ buffer: AVAudioPCMBuffer, padding: AVAudioFrameCount = 0,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Output] {
        guard let owned = TrackWriter.copy(buffer) else { return [] }
        let ticket = gate.ticket(now: now)
        return state.withLockUnchecked { s in
            s.pending.append(Pending(buffer: owned, padding: padding, at: now, ticket: ticket, epoch: s.epoch))
            var output: [Output] = []
            while let first = s.pending.first,
                  now - first.at >= MicrophonePrivacyGate.holdback || s.pending.count > 256 {
                let pending = s.pending.removeFirst()
                let allowed = pending.epoch == s.epoch && s.pending.count < 256 && gate.accepts(pending.ticket, now: now)
                if let pcm = allowed ? pending.buffer : AudioLevel.silence(like: pending.buffer) {
                    output.append(Output(buffer: pcm, padding: pending.padding))
                }
            }
            return output
        }
    }
    func silencePending() { state.withLockUnchecked { $0.epoch += 1 } }
    func finish() -> [Output] {
        state.withLockUnchecked { s in
            defer { s.pending.removeAll(); s.epoch += 1 }
            return s.pending.compactMap { pending in
                AudioLevel.silence(like: pending.buffer).map { Output(buffer: $0, padding: pending.padding) }
            }
        }
    }
}
