import Foundation

/// Held under each recorder's existing lock; never calls or queues UI work.
struct AudioMeter {
    enum Reading: Equatable {
        case off, paused, unavailable
        case level(Float)
    }

    private var latest: Float?
    private var sampledAt: TimeInterval?
    private var pendingPeak: Float?
    private var pendingSince: TimeInterval?

    mutating func reset() { self = AudioMeter() }

    mutating func record(peak: Float?, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let peak, peak.isFinite, peak >= 0 else { reset(); return }
        let bounded = min(1, peak)
        latest = bounded
        sampledAt = now
        // Bound peak hold even when the live page isn't being polled.
        if pendingSince.map({ now - $0 > 0.2 }) ?? true {
            pendingPeak = nil
            pendingSince = now
        }
        pendingPeak = max(pendingPeak ?? 0, bounded)
    }

    mutating func read(running: Bool, paused: Bool,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Reading {
        guard running else { reset(); return .off }
        guard !paused else { reset(); return .paused }
        guard let sampledAt, now - sampledAt < 0.5, let latest else {
            reset()
            return .unavailable
        }
        let peak = pendingPeak ?? latest
        pendingPeak = nil
        pendingSince = nil
        return .level(peak)
    }
}
