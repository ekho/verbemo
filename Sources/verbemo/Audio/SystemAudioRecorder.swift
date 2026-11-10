import AVFoundation
import CoreAudio
import Foundation
import os.lock

/// Records system audio output to a file via a Core Audio process tap
/// (macOS 14.2+). No virtual device, no kernel extension — the tap mixes the
/// chosen processes' output to stereo and hands us buffers through a private
/// aggregate device. First use triggers the one-time "System Audio Recording"
/// TCC prompt and lights the purple recording indicator while active.
// Native resources stay on the main thread; callbacks share only locked state and the serial queue.
final class SystemAudioRecorder: @unchecked Sendable {
    /// Whose output lands on the far-end track.
    enum Scope: Equatable {
        /// Everything the Mac plays. Safe and indiscriminate: notification
        /// dings, music and the video you opened afterwards all count as "the
        /// meeting", both in the transcript and in the auto-record loop's
        /// judgement of whether anyone is still talking.
        case everything
        /// Only processes belonging to these bundle-id families — the call
        /// app. Cleaner recordings, and a far-end silence signal that means
        /// what it says.
        case apps([String])
    }

    enum RecorderError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):
                return "process tap creation failed (OSStatus \(s)) — check System Settings → Privacy & Security → Screen & System Audio Recording"
            case .tapFormatUnreadable(let s): return "couldn't read tap stream format (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "aggregate device creation failed (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s): return "device start failed (OSStatus \(s))"
            case .fileCreationFailed(let e): return "output file creation failed: \(e)"
            }
        }
    }

    private(set) var scope: Scope = .everything
    /// The audio objects currently in the tap. Compared on refresh so a tap is
    /// only rewritten when the app's set of processes has actually changed.
    private var tappedObjects: [AudioObjectID] = []
    private var refreshFailed = false

    private var tap: SystemAudioTap?
    private var probe: SystemAudioTap?
    private var healthTimer: DispatchSourceTimer?
    private var sessionDir: URL?
    private let queue = DispatchQueue(label: "name.ekho.verbemo.system-tap")
    private let liveAudio = LiveAudioBufferRelay()
    private(set) var isRecording = false

    // Thread-safe shared state: accessed from both the main thread and the
    // IOProc callback (background serial queue) without further sync.
    private struct LockedState {
        var file: AVAudioFile?
        var firstBufferAt: Date?
        var lastSoundAt: Date?
        var levelMeasurable = true
        var meter = AudioMeter()
        var muted = false
        var activeTap: UUID?
        var probeTap: UUID?
        var recovery = SystemAudioRecovery(lastSignalAt: 0)
        var lastAudioEnd: Double?
        var handoffPending = false
    }
    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    /// Wall-clock time of the last buffer louder than the noise floor — the
    /// far end saying something. nil means nothing audible yet.
    var lastSoundAt: Date? { state.withLock { $0.lastSoundAt } }

    /// False once a buffer arrived in a sample format we can't measure.
    var levelMeasurable: Bool { state.withLock { $0.levelMeasurable } }

    var audioLevel: AudioMeter.Reading {
        let running = isRecording
        return state.withLock { $0.meter.read(running: running, paused: $0.muted) }
    }

    /// While muted the tap keeps running and silence is written instead of the
    /// audio, so the track stays wall-clock aligned across a pause.
    var isMuted: Bool {
        get { state.withLock { $0.muted } }
        set { state.withLock { $0.muted = newValue; $0.meter.reset() } }
    }

    private var file: AVAudioFile? {
        get { state.withLockUnchecked { $0.file } }
        set { state.withLock { $0.file = newValue } }
    }

    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date? {
        get { state.withLock { $0.firstBufferAt } }
        set { state.withLock { $0.firstBufferAt = newValue } }
    }

    /// Start capturing system audio as PCM in `url` (use a .caf extension —
    /// CAF needs no finalization pass, so a crash mid-meeting loses nothing
    /// already written).
    func start(writingTo url: URL, scope: Scope = .everything) throws {
        guard !isRecording else { return }
        state.withLock { $0.meter.reset() }

        let (description, objects) = Self.describe(scope)
        self.scope = objects.isEmpty ? .everything : scope
        tappedObjects = objects

        do {
            let tap = try SystemAudioTap(description: description)
            self.tap = tap
            file = try makeFile(url: url, format: tap.format)
            sessionDir = url.deletingLastPathComponent()
            let id = tap.uuid
            state.withLock {
                $0.activeTap = id
                $0.recovery = SystemAudioRecovery(lastSignalAt: ProcessInfo.processInfo.systemUptime)
            }
            try start(tap)
        } catch {
            cleanup()
            throw error
        }

        isRecording = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        healthTimer = timer
        timer.resume()
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        healthTimer?.cancel()
        healthTimer = nil
        cleanup()
        liveAudio.install(nil)
    }

    func installLiveAudioSink(_ sink: LiveAudioBufferRelay.Sink?) {
        liveAudio.install(sink)
    }

    func setLiveAudioPaused(_ paused: Bool) {
        liveAudio.isPaused = paused
    }

    /// Re-point the tap at the app's processes as they come and go — a
    /// browser renderer restarted by a reloaded tab, a helper the call app
    /// spawns when someone shares their screen, or a second call app joining
    /// the session. Cheap enough for the 15-second liveness tick.
    ///
    /// The tap's description is settable, so this never touches the aggregate
    /// device or the file — nothing about the recording is interrupted. If the
    /// system refuses, the existing tap keeps running and we say so once
    /// rather than every fifteen seconds for an hour.
    func refresh(scope newScope: Scope) {
        finishRecovery()
        guard isRecording, case .apps = newScope else { return }

        let (description, objects) = Self.describe(newScope)
        guard !objects.isEmpty, objects != tappedObjects else { return }
        if let probe {
            let id = probe.uuid
            let inactive = state.withLock { s in
                guard s.activeTap != id else { return false }
                s.probeTap = nil
                s.recovery.endProbe()
                return true
            }
            if inactive { probe.stop(); self.probe = nil }
            else { finishRecovery() }
        }
        guard let tap else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        description.uuid = tap.uuid
        var value = description
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                tap.id, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer
            )
        }
        guard status == noErr else {
            if !refreshFailed {
                refreshFailed = true
                FileHandle.standardError.write(Data(
                    ("system tap: can't update the tapped processes (OSStatus \(status)) — "
                        + "keeping the ones it started with\n").utf8
                ))
            }
            return
        }
        tappedObjects = objects
        scope = newScope
        state.withLock { $0.meter.reset() }
        FileHandle.standardError.write(Data(
            "system tap: now following \(objects.count) process(es)\n".utf8
        ))
    }

    // MARK: -

    /// Build a tap description for a scope, plus the audio objects it covers.
    /// An app scope that matches no running process comes back as a global tap
    /// — recording everything is wrong in a small way, recording nothing is
    /// wrong in the way that loses the meeting.
    private static func describe(_ scope: Scope, reportingFallback: Bool = true) -> (CATapDescription, [AudioObjectID]) {
        var objects: [AudioObjectID] = []
        var bundleIDs: [String] = []
        if case .apps(let families) = scope {
            let processes = AudioProcesses.matching(families: families)
            objects = processes.map(\.object)
            bundleIDs = Array(Set(processes.map(\.bundleID))).sorted()
            if objects.isEmpty, reportingFallback {
                FileHandle.standardError.write(Data(
                    ("system tap: nothing running for \(families.joined(separator: ", ")) — "
                        + "recording all system audio instead\n").utf8
                ))
            }
        }

        let description = objects.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: objects)
        description.name = "verbemo system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        if !objects.isEmpty, #available(macOS 26.0, *) {
            // Ask the system to keep following these apps across restarts: a
            // call app that relaunches mid-meeting otherwise drops out of the
            // tap silently, and a silent far-end track is the failure this
            // program exists to avoid.
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
        }
        return (description, objects)
    }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: AudioFormats.pcmSettings(
                    sampleRate: format.sampleRate, channels: format.channelCount
                ),
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    private func start(_ tap: SystemAudioTap) throws {
        let id = tap.uuid
        try tap.start(queue: queue) { [weak self] buffer, time in
            self?.receive(buffer, from: id, at: time)
        }
    }

    private func receive(_ buffer: AVAudioPCMBuffer, from id: UUID, at time: Double) {
        guard buffer.frameLength > 0, let file else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let peak = AudioLevel.peak(of: buffer)
        let accepted = state.withLock { s -> Bool in
            if id == s.activeTap {
                s.recovery.record(peak: peak, at: now)
                return true
            }
            guard id == s.probeTap, !s.muted,
                  s.recovery.hearsReplacement(peak: peak, at: now) else { return false }
            s.activeTap = id
            s.handoffPending = true
            s.recovery.record(peak: peak, at: now)
            return true
        }
        guard accepted else { return }
        if firstBufferAt == nil { firstBufferAt = Date() }
        let rate = buffer.format.sampleRate
        let end = time + Double(buffer.frameLength) / rate
        let adjustment = state.withLock { s -> Int in
            guard s.handoffPending, let previousEnd = s.lastAudioEnd else { return 0 }
            return Int(((time - previousEnd) * rate).rounded())
        }
        do {
            var outgoing = buffer
            if adjustment > 0 {
                try writeSilence(frames: adjustment, format: buffer.format, to: file)
            } else if adjustment < 0 {
                let skip = min(-adjustment, Int(buffer.frameLength))
                guard skip < buffer.frameLength,
                      let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format,
                          frameCapacity: buffer.frameLength - AVAudioFrameCount(skip)) else { return }
                trimmed.frameLength = trimmed.frameCapacity
                let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
                let input = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let output = UnsafeMutableAudioBufferListPointer(trimmed.mutableAudioBufferList)
                for index in input.indices {
                    guard let source = input[index].mData, let destination = output[index].mData else { return }
                    memcpy(destination, source.advanced(by: skip * bytesPerFrame), Int(output[index].mDataByteSize))
                }
                outgoing = trimmed
            }
            try writeTracked(outgoing, to: file)
            state.withLock { $0.lastAudioEnd = end; $0.handoffPending = false }
        } catch {
            FileHandle.standardError.write(Data("system track write failed: \(error)\n".utf8))
        }
    }

    private func writeSilence(frames: Int, format: AVAudioFormat, to file: AVAudioFile) throws {
        guard let silence = AVAudioPCMBuffer(pcmFormat: format,
            frameCapacity: AVAudioFrameCount(format.sampleRate)) else { throw CocoaError(.fileWriteUnknown) }
        silence.frameLength = silence.frameCapacity
        for audio in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
        }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, Int(silence.frameCapacity)))
            try file.write(from: silence)
            liveAudio.forward(silence)
            remaining -= Int(silence.frameLength)
        }
    }

    private func checkHealth() {
        guard isRecording else { return }
        finishRecovery()
        let now = ProcessInfo.processInfo.systemUptime
        if let probe {
            let id = probe.uuid
            let expired = state.withLock { s in
                guard s.activeTap != id, s.recovery.probeFinished(at: now, paused: s.muted) else { return false }
                s.probeTap = nil
                s.recovery.endProbe()
                return true
            }
            if expired { probe.stop(); self.probe = nil }
        }
        guard probe == nil, state.withLock({ $0.recovery.shouldProbe(at: now, paused: $0.muted) }) else { return }
        let (description, objects) = Self.describe(scope, reportingFallback: false)
        // An empty app selection must never broaden a recovery probe to other apps.
        if case .apps = scope, objects.isEmpty { return }
        state.withLock { $0.recovery.beginProbe(at: now) }
        do {
            let candidate = try SystemAudioTap(description: description)
            // shortcut: preserve the file format; add resampling if recovery must change sample rates.
            guard candidate.format == file?.processingFormat else {
                throw RecorderError.tapFormatUnreadable(kAudioHardwareUnsupportedOperationError)
            }
            probe = candidate
            let id = candidate.uuid
            state.withLock { $0.probeTap = id }
            try start(candidate)
        } catch {
            state.withLock { $0.probeTap = nil; $0.recovery.endProbe() }
            probe?.stop()
            probe = nil
            logRecovery("system audio recovery probe failed: \(error)")
        }
    }

    private func finishRecovery() {
        guard let probe else { return }
        let id = probe.uuid
        guard state.withLock({ $0.activeTap == id }) else { return }
        let old = tap
        tap = probe
        self.probe = nil
        state.withLock { $0.probeTap = nil; $0.recovery.endProbe() }
        old?.stop()
        logRecovery("system audio recovered: a fresh tap heard audio while the previous tap was silent")
    }

    private func logRecovery(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        if let sessionDir { appendSessionLog(message, to: sessionDir) }
    }

    /// Write one tapped buffer, tracking its level on the way through and
    /// substituting silence while paused.
    private func writeTracked(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) throws {
        let peak = AudioLevel.peak(of: buffer)
        let hasFrames = buffer.frameLength > 0
        let muted: Bool = state.withLock { s in
            if !s.muted, hasFrames { s.meter.record(peak: peak) }
            if let peak {
                if peak >= AudioLevel.speechThreshold { s.lastSoundAt = Date() }
            } else {
                s.levelMeasurable = false
            }
            return s.muted
        }

        var outgoing = buffer
        if muted {
            // The tap's buffer is Core Audio's memory, borrowed no-copy — the
            // silence has to be written into a buffer of our own.
            guard let silent = AudioLevel.silence(like: buffer) else { throw CocoaError(.fileWriteUnknown) }
            outgoing = silent
        }
        try file.write(from: outgoing)
        liveAudio.forward(outgoing)
    }

    private func cleanup() {
        probe?.stop()
        tap?.stop()
        queue.sync {}
        probe = nil
        tap = nil
        file = nil
        state.withLock {
            $0.meter.reset()
            $0.activeTap = nil
            $0.probeTap = nil
            $0.recovery.endProbe()
        }
    }
}
