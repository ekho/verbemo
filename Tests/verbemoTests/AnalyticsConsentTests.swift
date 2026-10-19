import ArgumentParser
import Foundation
import Testing

@testable import verbemo

@Suite("Product analytics disabled", .serialized)
struct DisabledAnalyticsTests {
    @Test("Legacy config cannot enable collection or network requests", .freshHome,
          arguments: ["{}", #"{"analytics":true}"#, #"{"analytics":false}"#,
                      #"{"analytics":"yes"}"#, #"{"analytics":true"#])
    func lifecycleDoesNothing(config: String) throws {
        try Home.current.writeConfig(text: config)
        let before = Home.current.configText
        let identity = Home.current.configDirectory.appendingPathComponent("analytics.json")
        let pending = Home.current.configDirectory.appendingPathComponent("analytics-pending.json")
        // A real legacy queue must not be replayed, rewritten, or deleted.
        let oldQueue = try JSONSerialization.data(withJSONObject: ["pending": [[
            "queue_id": "legacy-event", "type": "event", "payload": [
                "id": "legacy-installation", "website": "legacy-site", "hostname": "legacy.invalid",
                "name": "recording_started", "timestamp": Date().timeIntervalSince1970,
                "data": ["trigger": "manual"],
            ],
        ]]])
        try oldQueue.write(to: pending)
        let previousCalls = DisabledAnalyticsHTTP.calls.count
        URLProtocol.registerClass(DisabledAnalyticsHTTP.self)
        defer { URLProtocol.unregisterClass(DisabledAnalyticsHTTP.self) }

        Analytics.start(surface: .app)
        Analytics.start(surface: .cli)
        Analytics.track(.recordingStarted, [.trigger: .text("manual")])
        Analytics.track(.recordingFinished, [.durationBucket: .text("5_15m")])
        Analytics.settingChanged(path: ["user_name"], value: "private name")
        Analytics.flushOnExit()
        var status = try AnalyticsCommand.parse([])
        try status.run()
        status = try AnalyticsCommand.parse(["off"])
        try status.run()
        status = try AnalyticsCommand.parse(["on"])
        #expect(throws: ValidationError.self) { try status.run() }

        #expect(!Analytics.isEnabled)
        #expect(DisabledAnalyticsHTTP.calls.count == previousCalls)
        #expect(!FileManager.default.fileExists(atPath: identity.path))
        #expect(try Data(contentsOf: pending) == oldQueue)
        #expect(Home.current.configText == before)
    }

    @Test("A fresh launch and CLI create no analytics state", .freshHome)
    func freshLaunchCreatesNothing() throws {
        Analytics.start(surface: .app)
        Analytics.track(.recordingStarted)
        Analytics.flushOnExit()
        var command = try AnalyticsCommand.parse([])
        try command.run()
        command = try AnalyticsCommand.parse(["on"])
        #expect(throws: ValidationError.self) { try command.run() }
        #expect(!FileManager.default.fileExists(atPath: Home.current.configDirectory.path))
    }
}

/// Intercepts the inherited telemetry destination, never sends a real request.
private final class DisabledAnalyticsHTTP: URLProtocol, @unchecked Sendable {
    static let calls = DisabledTransportSpy()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stats.amanu.me"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.note()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private final class DisabledTransportSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func note() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}
