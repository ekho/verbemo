@preconcurrency import AVFoundation
import CallIntegrations
import Foundation
import os.lock

/// File writes and pause share one lock; live consumers receive owned buffers.
final class ParticipantAudioRecorder: @unchecked Sendable {
    enum LiveEvent: @unchecked Sendable {
        case track(CallAudioMetadata.Track)
        case audio(CallAudioMetadata.Track, AVAudioPCMBuffer, milliseconds: Int)
        case removed(String)
    }
    typealias Sink = @Sendable (LiveEvent) -> Void

    struct Snapshot: Sendable {
        var tracks: [CallAudioMetadata.Track] = []
        var files: [String: String] = [:]
        var offsets: [String: Int] = [:]
    }
    private struct Entry {
        var descriptor: CallAudioTrack
        var index: Int
        var file: AVAudioFile
        var nextFrame: Int64?
    }
    private struct State {
        var snapshot = Snapshot()
        var entries: [String: Entry] = [:]
        var paused = false
        var pausedSince: Date?
        var pauses: [DateInterval] = []
        var closed = false
        var sink: Sink?
        var localMeter = AudioMeter()
        var remoteMeter = AudioMeter()
        var localSoundAt: Date?
        var remoteSoundAt: Date?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let directory: URL
    private let offsetMs: Int
    private let clockOrigin: Date

    init(directory: URL, offsetMs: Int, clockOrigin: Date = Date(), pauses: [DateInterval] = []) {
        self.directory = directory
        self.offsetMs = max(0, offsetMs)
        self.clockOrigin = clockOrigin
        state.withLock { $0.pauses = pauses }
    }

    var snapshot: Snapshot { state.withLock { $0.snapshot } }
    var isPaused: Bool {
        get { state.withLock { $0.paused } }
        set { setPaused(newValue) }
    }

    func setPaused(_ paused: Bool, at date: Date = Date()) {
        state.withLock { state in
            guard !state.closed, state.paused != paused else { return }
            state.paused = paused
            if paused {
                state.pausedSince = date
            } else if let since = state.pausedSince {
                state.pauses.append(DateInterval(start: since, end: max(since, date)))
                state.pausedSince = nil
            }
        }
    }

    var audioLevels: (mic: AudioMeter.Reading, system: AudioMeter.Reading) {
        state.withLock { s in
            (s.localMeter.read(running: !s.closed, paused: s.paused),
             s.remoteMeter.read(running: !s.closed, paused: s.paused))
        }
    }
    var lastSoundAt: (local: Date?, remote: Date?) { state.withLock { ($0.localSoundAt, $0.remoteSoundAt) } }

    func installLiveSink(_ sink: Sink?) {
        state.withLock { state in
            guard !state.closed else { return }
            state.sink = sink
            for entry in state.entries.values { sink?(.track(state.snapshot.tracks[entry.index])) }
        }
    }

    /// True means the recovery manifest needs a fresh physical index.
    @discardableResult
    func consume(_ event: CallAudioEvent) throws -> Bool {
        try state.withLock { state in
            guard !state.closed else { throw CallAudioFailure.stopped }
            switch event {
            case .track(let descriptor):
                guard !descriptor.id.isEmpty, descriptor.id.utf8.count <= 512,
                      !descriptor.participant.id.isEmpty, descriptor.participant.id.utf8.count <= 512,
                      descriptor.participant.name.utf8.count <= 4096, descriptor.generation > 0,
                      (8000...192000).contains(descriptor.sampleRate)
                else { throw CallAudioFailure.invalidData }
                if var old = state.entries[descriptor.id], old.descriptor.generation == descriptor.generation {
                    guard old.descriptor.participant.id == descriptor.participant.id,
                          old.descriptor.sampleRate == descriptor.sampleRate else { throw CallAudioFailure.invalidData }
                    old.descriptor = descriptor
                    state.entries[descriptor.id] = old
                    state.snapshot.tracks[old.index].name = descriptor.participant.name
                    state.sink?(.track(state.snapshot.tracks[old.index]))
                    return true
                }
                guard state.snapshot.tracks.count < 4096 else { throw CallAudioFailure.overloaded }
                let previous = state.snapshot.tracks.last { $0.sourceID == descriptor.id }
                if let previous {
                    guard descriptor.generation > previous.generation,
                          descriptor.participant.id == previous.participantID else { throw CallAudioFailure.invalidData }
                    state.sink?(.removed(previous.fileKey))
                }
                let key = "call_" + UUID().uuidString
                let name = key + ".caf"
                let track = CallAudioMetadata.Track(fileKey: key, sourceID: descriptor.id,
                    speakerID: previous?.speakerID ?? key, participantID: descriptor.participant.id,
                    name: descriptor.participant.name, isLocal: descriptor.participant.isLocal,
                    generation: descriptor.generation, sampleRate: descriptor.sampleRate)
                let file = try AVAudioFile(forWriting: directory.appendingPathComponent(name),
                    settings: AudioFormats.pcmSettings(sampleRate: Double(descriptor.sampleRate), channels: 1))
                state.entries[descriptor.id] = Entry(descriptor: descriptor, index: state.snapshot.tracks.count, file: file)
                state.snapshot.tracks.append(track)
                state.snapshot.files[key] = name
                state.snapshot.offsets[key] = offsetMs
                state.sink?(.track(track))
                return true
            case .audio(let chunk):
                guard var entry = state.entries[chunk.trackID], entry.descriptor.generation == chunk.generation,
                      entry.descriptor.sampleRate == chunk.sampleRate, !chunk.samples.isEmpty,
                      chunk.samples.count <= 4096, chunk.samples.allSatisfy(\.isFinite), chunk.frameStart >= 0,
                      chunk.frameStart <= Int64(chunk.sampleRate) * 86400,
                      chunk.frameStart >= (entry.nextFrame ?? 0)
                else { throw CallAudioFailure.invalidData }
                let first = entry.nextFrame == nil
                let key = state.snapshot.tracks[entry.index].fileKey
                let milliseconds = offsetMs + Int(chunk.frameStart * 1000 / Int64(chunk.sampleRate))
                if first { state.snapshot.offsets[key] = milliseconds }
                var gap = chunk.frameStart - (entry.nextFrame ?? chunk.frameStart)
                // An active worklet emits even when muted; a minute without PCM is a failed source.
                guard gap <= Int64(chunk.sampleRate) * 60 else { throw CallAudioFailure.timedOut }
                let hadGap = gap > 0
                state.snapshot.tracks[entry.index].missingFrames += gap
                while gap > 0 {
                    let count = Int(min(4096, gap))
                    try write(Array(repeating: 0, count: count), to: entry.file)
                    gap -= Int64(count)
                }
                var samples = state.paused ? Array(repeating: Float(0), count: chunk.samples.count) : chunk.samples
                // Delivery may lag Resume; redact by the capture clock before disk and live ASR.
                if !state.paused {
                    let rate = Double(chunk.sampleRate), frame = Double(chunk.frameStart), count = Double(samples.count)
                    for pause in state.pauses {
                        let start = Int(max(0, min(count, floor(pause.start.timeIntervalSince(clockOrigin) * rate - frame))))
                        let end = Int(max(0, min(count, ceil(pause.end.timeIntervalSince(clockOrigin) * rate - frame))))
                        if start < end { samples.replaceSubrange(start..<end, with: repeatElement(0, count: end - start)) }
                    }
                }
                let buffer = try write(samples, to: entry.file)
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                if entry.descriptor.participant.isLocal {
                    state.localMeter.record(peak: peak)
                    if peak >= AudioLevel.speechThreshold { state.localSoundAt = Date() }
                } else {
                    state.remoteMeter.record(peak: peak)
                    if peak >= AudioLevel.speechThreshold { state.remoteSoundAt = Date() }
                }
                entry.nextFrame = chunk.frameStart + Int64(samples.count)
                state.entries[chunk.trackID] = entry
                state.sink?(.audio(state.snapshot.tracks[entry.index], buffer, milliseconds: milliseconds))
                return first || hadGap
            case .removed(let id):
                if let entry = state.entries.removeValue(forKey: id) {
                    state.sink?(.removed(state.snapshot.tracks[entry.index].fileKey))
                }
                return false
            case .heartbeat, .ended: return false
            }
        }
    }

    func close() {
        state.withLock { state in
            state.closed = true
            for entry in state.entries.values { state.sink?(.removed(state.snapshot.tracks[entry.index].fileKey)) }
            state.sink = nil
            state.entries.removeAll()
        }
    }

    @discardableResult
    private func write(_ samples: [Float], to file: AVAudioFile) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw CallAudioFailure.invalidData }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: buffer)
        return buffer
    }
}
