import Foundation

/// Silence alone is not failure: only a fresh tap hearing the same source proves it.
struct SystemAudioRecovery {
    var lastSignalAt: TimeInterval
    private(set) var lastAttemptAt: TimeInterval?
    private(set) var probeStartedAt: TimeInterval?
    private var probeSoundAt: TimeInterval?

    mutating func record(peak: Float?, at now: TimeInterval) {
        if peak == nil || !peak!.isFinite || peak! > 0.000001 {
            lastSignalAt = now
            probeSoundAt = nil
        }
    }

    func shouldProbe(at now: TimeInterval, paused: Bool) -> Bool {
        !paused && probeStartedAt == nil && now - lastSignalAt >= 3
            && (lastAttemptAt.map { now - $0 >= 15 } ?? true)
    }

    mutating func beginProbe(at now: TimeInterval) {
        lastAttemptAt = now
        probeStartedAt = now
        probeSoundAt = nil
    }

    mutating func hearsReplacement(peak: Float?, at now: TimeInterval) -> Bool {
        guard probeStartedAt != nil, now - lastSignalAt >= 3,
              let peak, peak.isFinite else {
            probeSoundAt = nil
            return false
        }
        guard peak >= AudioLevel.speechThreshold else { return false }
        if probeSoundAt == nil { probeSoundAt = now }
        return now - probeSoundAt! >= 0.15
    }

    func probeFinished(at now: TimeInterval, paused: Bool) -> Bool {
        guard let start = probeStartedAt else { return false }
        return paused || lastSignalAt > start || now - start >= 2
    }

    mutating func endProbe() {
        probeStartedAt = nil
        probeSoundAt = nil
    }
}
