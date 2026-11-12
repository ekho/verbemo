import Foundation

public enum CallParticipation: String, Codable, Sendable {
    case unknown, idle, preparing, inCall
}

public enum CallObservationSource: String, Codable, Sendable {
    case application, accessibility
}

public struct CallApplication: Codable, Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

public struct CallParticipant: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var isLocal: Bool
    public var isGuest: Bool
    public var microphoneMuted: Bool?
    public var cameraMuted: Bool?
    public init(id: String, name: String, isLocal: Bool, isGuest: Bool,
                microphoneMuted: Bool? = nil, cameraMuted: Bool? = nil) {
        self.id = id; self.name = name; self.isLocal = isLocal; self.isGuest = isGuest
        self.microphoneMuted = microphoneMuted; self.cameraMuted = cameraMuted
    }
}

public struct CallInfo: Codable, Sendable, Equatable {
    /// Provider-scoped identity for this local call, not a display name.
    public var id: String
    public var title: String?
    public var url: URL?
    /// nil means unavailable; [] means a successfully read empty roster.
    public var participants: [CallParticipant]?
    public var localParticipantID: String?
    public var microphoneMuted: Bool?
    public var cameraMuted: Bool?
    public init(id: String, title: String? = nil, url: URL? = nil,
                participants: [CallParticipant]? = nil, localParticipantID: String? = nil,
                microphoneMuted: Bool? = nil, cameraMuted: Bool? = nil) {
        self.id = id; self.title = title; self.url = url; self.participants = participants
        self.localParticipantID = localParticipantID
        self.microphoneMuted = microphoneMuted; self.cameraMuted = cameraMuted
    }
}

public struct CallObservation: Codable, Sendable, Equatable {
    public var integrationID: String
    public var application: CallApplication
    public var observedAt: Date
    public var participation: CallParticipation
    public var source: CallObservationSource?
    public var call: CallInfo?
    public init(integrationID: String, application: CallApplication, observedAt: Date,
                participation: CallParticipation, source: CallObservationSource? = nil, call: CallInfo? = nil) {
        self.integrationID = integrationID; self.application = application; self.observedAt = observedAt
        self.participation = participation; self.source = source; self.call = call
    }
}

/// Implementations own transports, permissions and vendor-specific state.
/// Consumers never infer an ended call from a failed observation.
public protocol CallIntegration: Sendable {
    var id: String { get }
    var application: CallApplication { get }
    func observe() async -> CallObservation
    func stop() async
}
