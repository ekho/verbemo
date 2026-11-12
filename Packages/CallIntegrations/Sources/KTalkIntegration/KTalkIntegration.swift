import Foundation
import CallIntegrations

public actor KTalkIntegration: CallAudioIntegration {
    public nonisolated let id = "ktalk"
    public nonisolated let application = CallApplication(bundleID: "kontur.talk", name: "Толк")
    private let cdp: KTalkCDP
    private let accessibility = KTalkAccessibility()
    private let accessibilityEnabled: Bool
    private var stopped = false
    private let spaceURL: URL?
    private let port: Int

    public init(spaceURL: URL? = nil, port: Int = 9333, accessibilityEnabled: Bool = true) throws {
        guard (1024...65535).contains(port), spaceURL.map(KTalkModel.validSpace) ?? true else { throw ConfigurationError.invalidEndpoint }
        cdp = KTalkCDP(space: spaceURL, port: port)
        self.spaceURL = spaceURL; self.port = port
        self.accessibilityEnabled = accessibilityEnabled
    }

    public enum ConfigurationError: Error { case invalidEndpoint }

    public func makeAudioCapture(for callID: String) throws -> any CallAudioCapture {
        guard !stopped, let spaceURL else { throw CallAudioFailure.unavailable }
        return try KTalkAudioCapture(space: spaceURL, port: port, callID: callID)
    }

    // shortcut: polling misses mute cycles between samples; qualify mute events before promising an instantaneous privacy interlock.
    public func observe() async -> CallObservation {
        let began = Date()
        guard !stopped else { return observation(.init(participation: .unknown), source: nil, at: began) }
        let direct = await cdp.read()
        let fallback = direct.participation == .unknown && accessibilityEnabled ? await accessibility.read() : KTalkReading(participation: .unknown)
        guard !stopped else { return observation(.init(participation: .unknown), source: nil, at: began) }
        let (reading, source) = KTalkResolver.resolve(cdp: direct, accessibility: fallback)
        return observation(reading, source: source, at: began)
    }

    public func stop() async {
        stopped = true
        await cdp.stop()
        await accessibility.stop()
    }

    private func observation(_ reading: KTalkReading, source: CallObservationSource?, at date: Date) -> CallObservation {
        .init(integrationID: id, application: application, observedAt: date,
              participation: reading.participation, source: source, call: reading.call)
    }
}
