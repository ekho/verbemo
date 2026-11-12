import Foundation
import Testing
import CallIntegrations
@testable import verbemo

struct CallIntegrationBridgeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let application = CallApplication(bundleID: "kontur.talk", name: "Толк")
    func observation(_ state: CallParticipation, age: Double = 0) -> CallObservation {
        .init(integrationID: "ktalk", application: application, observedAt: now.addingTimeInterval(-age),
              participation: state, source: .application,
              call: state == .inCall ? .init(id: "synthetic", title: "Probe", microphoneMuted: true) : nil)
    }
    let silent = MicActivityMonitor.Result(active: false, names: [], families: [], allHolders: [])

    @Test func mutedJoinedCallCountsButPreparationDoesNot() {
        let active = CallIntegrationBridge.signal(microphone: silent, observations: [observation(.inCall)], settings: .init(), now: now)
        #expect(active.microphone.active)
        #expect(active.microphone.families == ["kontur.talk"])
        #expect(active.observation?.call?.microphoneMuted == true)
        let prejoin = CallIntegrationBridge.signal(microphone: silent, observations: [observation(.preparing)], settings: .init(), now: now)
        #expect(!prejoin.microphone.active)
        #expect(!prejoin.unknown)
    }
    @Test func staleAndMissingSourcesAreUnknownWithoutOldRoster() {
        for item in [observation(.unknown), observation(.inCall, age: 10)] {
            let value = CallIntegrationBridge.signal(microphone: silent, observations: [item], settings: .init(), now: now)
            #expect(value.unknown)
            #expect(!value.microphone.active)
            #expect(value.observation == nil)
        }
    }
    @Test func otherAppsAndIgnorePolicyRemainEffective() {
        let zoom = MicActivityMonitor.Result(active: true, names: ["Zoom"], families: ["us.zoom.xos"], allHolders: ["Zoom"])
        var settings = Config.AutoRecordSettings()
        settings.ignoreApps = ["kontur.talk"]
        let value = CallIntegrationBridge.signal(microphone: zoom, observations: [observation(.inCall)], settings: settings, now: now)
        #expect(value.microphone.active)
        #expect(value.microphone.families == ["us.zoom.xos"])
        #expect(value.observation == nil)
        settings.ignoreApps = []; settings.callApps = ["us.zoom.xos"]
        #expect(!CallIntegrationBridge.signal(microphone: silent, observations: [observation(.inCall)], settings: settings, now: now).microphone.active)
    }
}
