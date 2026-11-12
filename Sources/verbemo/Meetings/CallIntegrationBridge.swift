import Foundation
import CallIntegrations

enum CallIntegrationBridge {
    struct Signal {
        var microphone: MicActivityMonitor.Result
        var unknown: Bool
        var observation: CallObservation?
    }
    static func signal(microphone: MicActivityMonitor.Result, observations: [CallObservation],
                       settings: Config.AutoRecordSettings, now: Date) -> Signal {
        let enabled = observations.filter { observation in
            let app = observation.application
            return !settings.ignoreApps.contains(where: { app.bundleID == $0 || app.bundleID.hasPrefix($0 + ".") || app.name == $0 })
                && (settings.callApps.isEmpty || settings.callApps.contains(where: { app.bundleID == $0 || app.bundleID.hasPrefix($0 + ".") || app.name == $0 }))
        }
        let fresh = enabled.filter { (0...5).contains(now.timeIntervalSince($0.observedAt)) }
        let joined = fresh.filter { $0.participation == .inCall }
        var mic = microphone
        for observation in joined {
            if !mic.families.contains(observation.application.bundleID) {
                mic.families.append(observation.application.bundleID)
                mic.names.append(observation.application.name)
            }
        }
        mic.active = microphone.active || !joined.isEmpty
        return Signal(microphone: mic,
                      unknown: fresh.count != enabled.count || fresh.contains(where: { $0.participation == .unknown }),
                      observation: joined.count == 1 ? joined[0] : nil)
    }
}
