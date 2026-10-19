import Foundation
import Testing

@testable import verbemo

@Suite("Config observer context")
@MainActor
struct ConfigWatchTests {
    @Test("A redraw uses its registering home when another home posts", .freshHome(config: #"{"keep_audio":false}"#))
    func redrawKeepsRegisteringHome() throws {
        let registeredPath = Config.path
        var observedPath: URL?
        var observedKeepAudio: Bool?
        let token = ConfigWatch.observe {
            observedPath = Config.path
            observedKeepAudio = Config.keepAudio()
        }
        defer { withExtendedLifetime(token) {} }

        try withFreshHome(config: ["keep_audio": true]) { other in
            let before = other.configText
            NotificationCenter.default.post(name: Config.didChange, object: nil)
            #expect(other.configText == before)
        }
        #expect(observedPath == registeredPath)
        #expect(observedKeepAudio == false)
    }
}
