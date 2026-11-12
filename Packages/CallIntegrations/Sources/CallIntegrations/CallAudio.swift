import Foundation

public struct CallAudioTrack: Codable, Sendable, Equatable {
    public let id: String
    public let participant: CallParticipant
    public let generation: Int
    public let sampleRate: Int

    public init(id: String, participant: CallParticipant, generation: Int, sampleRate: Int) {
        self.id = id; self.participant = participant
        self.generation = generation; self.sampleRate = sampleRate
    }
}

public struct CallAudioChunk: Sendable, Equatable {
    public let trackID: String
    public let generation: Int
    /// AudioContext frame, shared by every track in one capture run.
    public let frameStart: Int64
    public let sampleRate: Int
    public let samples: [Float]

    public init(trackID: String, generation: Int, frameStart: Int64, sampleRate: Int, samples: [Float]) {
        self.trackID = trackID; self.generation = generation; self.frameStart = frameStart
        self.sampleRate = sampleRate; self.samples = samples
    }
}

public enum CallAudioEvent: Sendable, Equatable {
    case track(CallAudioTrack)
    case audio(CallAudioChunk)
    case removed(String)
    case heartbeat(frame: Int64, sampleRate: Int)
    case ended
}

public enum CallAudioFailure: Error, Sendable, Equatable {
    case invalidConfiguration, unavailable, invalidData, unsupportedSchema, overloaded, timedOut, stopped
}

public protocol CallAudioCapture: Sendable {
    var events: AsyncThrowingStream<CallAudioEvent, Error> { get }
    func start() async throws
    func stop() async
}

/// Optional capability: metadata-only providers need not acquire audio.
public protocol CallAudioIntegration: CallIntegration {
    func makeAudioCapture(for callID: String) async throws -> any CallAudioCapture
}
