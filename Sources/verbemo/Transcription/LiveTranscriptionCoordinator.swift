@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os.lock

/// Runs the optional low-latency transcript beside the durable recorder. The
/// two speakers get independent streaming state while sharing the heavyweight
/// CoreML model bundle.
actor LiveTranscriptionCoordinator {
    private struct AudioPacket: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer
        var milliseconds: Int? = nil
    }

    enum Status: Sendable, Equatable {
        case idle
        case paused
        case downloading(Double)
        case loading
        case live
        case modelMissing
        case overloaded
        case error(String)
    }

    struct Snapshot: Sendable {
        let isRecording: Bool
        let isEnabled: Bool
        let entries: [LiveTranscriptState.Entry]
        let status: Status
    }

    struct SessionSinks: Sendable {
        let mic: LiveAudioBufferRelay.Sink
        let system: LiveAudioBufferRelay.Sink
        var participants: ParticipantAudioRecorder.Sink? = nil
    }

    private enum Source: Sendable, Hashable {
        case mic
        case system
        case participant(id: String, name: String)

        var speaker: LiveTranscriptState.Speaker {
            switch self {
            case .mic: .you
            case .system: .them
            case .participant(let id, let name): .participant(id: id, name: name)
            }
        }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.speaker == rhs.speaker }
        func hash(into hasher: inout Hasher) { hasher.combine(speaker) }
    }

    private let modelStore: NemotronModelStore
    private let preload: @Sendable (URL) async throws -> SharedNemotronMultilingualModels
    private var retirement: Task<Void, Never>?
    private var transcript = LiveTranscriptState()
    private var status: Status = .idle
    private var isRecording = false
    private var startedAt = Date()
    private var update: (@Sendable (Snapshot) -> Void)?
    /// Handing the recorders their sinks is deferred until the model is
    /// actually consuming audio — see `startPipeline`.
    private var attach: (@Sendable (SessionSinks?) -> Void)?
    private var pendingSinks: SessionSinks?
    private var drops: [Date] = []
    /// The engine reports one running transcript per speaker and never says
    /// where an utterance ended, so the pause is what ends it here.
    private var partials = CumulativePartials()
    private var silentSeconds: [Source: Double] = [:]
    /// Set by the engine's callback the moment it decodes something, and read
    /// by the consumer that fed it. Both run outside this actor, and a hop
    /// through it would arrive after the audio it belongs to had been counted.
    private var decodedSomething: [Source: OSAllocatedUnfairLock<Bool>] = [:]

    private var loadTask: Task<Void, Never>?
    private var consumerTasks: [Task<Void, Never>] = []
    private var continuations: [AsyncStream<AudioPacket>.Continuation] = []
    private var managers: [Source: StreamingNemotronMultilingualAsrManager] = [:]
    private var sharedModels: SharedNemotronMultilingualModels?
    private var sharedModelDirectory: URL?
    private var participantMode = false
    private var participantContinuation: AsyncStream<ParticipantAudioRecorder.LiveEvent>.Continuation?
    private var participantQueues: [Source: AsyncStream<AudioPacket>.Continuation] = [:]
    private var participantConsumers: [Source: Task<Void, Never>] = [:]
    private var participantLabels: [Source: LiveTranscriptState.Speaker] = [:]
    private var sourceTimes: [Source: Int] = [:]

    init(modelStore: NemotronModelStore = .init(),
         preload: @escaping @Sendable (URL) async throws -> SharedNemotronMultilingualModels = {
             try await StreamingNemotronMultilingualAsrManager.preloadShared(from: $0)
         }) {
        self.modelStore = modelStore
        self.preload = preload
    }

    var snapshot: Snapshot {
        Snapshot(
            isRecording: isRecording,
            isEnabled: transcript.isEnabled,
            entries: LiveEchoFilter.visibleEntries(transcript.entries),
            status: status
        )
    }

    func beginRecording(
        enabled: Bool,
        language: String,
        participants: Bool = false,
        startedAt: Date = Date(),
        update: @escaping @Sendable (Snapshot) -> Void,
        attach: @escaping @Sendable (SessionSinks?) -> Void
    ) {
        stopPipeline(releaseSharedModels: true)
        self.update = update
        self.attach = attach
        self.startedAt = startedAt
        participantMode = participants
        isRecording = true
        status = enabled ? .loading : .paused
        let epoch = transcript.beginRecording(enabled: enabled)
        publish()
        guard enabled else { return }
        startPipeline(language: language, epoch: epoch, allowDownload: false)
    }

    /// The caller detaches the old sinks before calling this, so no audio can
    /// enter a closing epoch; new sinks arrive through `attach` once the model
    /// is loaded and consuming.
    func setEnabled(_ enabled: Bool, language: String) {
        guard isRecording else { return }
        stopPipeline(releaseSharedModels: false)
        let epoch = transcript.setEnabled(enabled)
        status = enabled ? .loading : .paused
        publish()
        guard enabled else { return }
        startPipeline(language: language, epoch: epoch, allowDownload: true)
    }

    func useOrdinarySources(language: String) {
        guard isRecording, participantMode else { return }
        stopPipeline(releaseSharedModels: false)
        participantMode = false
        transcript.invalidateActiveEpoch()
        status = transcript.isEnabled ? .loading : .paused
        publish()
        if transcript.isEnabled { startPipeline(language: language, epoch: transcript.epoch, allowDownload: false) }
    }

    func finishRecording() async {
        transcript.finishRecording()
        isRecording = false
        status = .idle
        publish()
        // AppController's closures capture the recording session, while this
        // actor lives for the whole app. Keeping them here keeps its mic engine
        // and an explicitly enabled voice-processing route alive after Stop.
        update = nil
        attach = nil

        // In contrast to a temporary toggle, meeting stop is a hard memory
        // boundary: wait for an in-progress preload and both managers to let
        // go before the canonical Parakeet job is allowed to start.
        stopPipeline(releaseSharedModels: false)
        await retirement?.value
        sharedModels = nil
        sharedModelDirectory = nil
    }

    /// Builds the queues and their sinks but does not hand the sinks over.
    ///
    /// Loading Nemotron takes several seconds, and audio pushed into a queue
    /// nobody is reading yet fills five seconds of buffer and then overflows —
    /// which used to be reported as "your Mac couldn't keep up" before a
    /// single word had been transcribed. The recorders start feeding the
    /// queues at the moment the model starts consuming them, and not before.
    private func startPipeline(language: String, epoch: Int, allowDownload: Bool) {
        let downloading: Bool
        if case .downloading = modelStore.state(language: language) { downloading = true }
        else { downloading = false }
        guard allowDownload || modelStore.isReady(language: language) || downloading else {
            status = .modelMissing
            publish()
            return
        }
        drops.removeAll(keepingCapacity: true)
        partials.reset()
        silentSeconds.removeAll(keepingCapacity: true)
        decodedSomething = [
            .mic: .init(initialState: false),
            .system: .init(initialState: false),
        ]

        let micPair = AsyncStream<AudioPacket>.makeStream(
            bufferingPolicy: .bufferingOldest(48))
        let systemPair = AsyncStream<AudioPacket>.makeStream(
            bufferingPolicy: .bufferingOldest(48))
        continuations = [micPair.continuation, systemPair.continuation]

        pendingSinks = SessionSinks(
            mic: makeSink(continuation: micPair.continuation, epoch: epoch),
            system: makeSink(continuation: systemPair.continuation, epoch: epoch))
        let previous = retirement
        loadTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            await self.loadAndConsume(
                mic: micPair.stream,
                system: systemPair.stream,
                language: language,
                epoch: epoch
            )
        }
    }

    nonisolated private func makeSink(
        continuation: AsyncStream<AudioPacket>.Continuation,
        epoch: Int
    ) -> LiveAudioBufferRelay.Sink {
        { [weak self] buffer in
            switch continuation.yield(AudioPacket(buffer: buffer)) {
            case .enqueued:
                break
            case .dropped:
                Task { await self?.pipelineOverloaded(epoch: epoch) }
            case .terminated:
                break
            @unknown default:
                break
            }
        }
    }

    private func loadAndConsume(
        mic: AsyncStream<AudioPacket>,
        system: AsyncStream<AudioPacket>,
        language: String,
        epoch: Int
    ) async {
        guard !Task.isCancelled, transcript.epoch == epoch, transcript.isEnabled else { return }
        do {
            // Only an explicit enable or an existing download gets here with missing files.
            if !modelStore.isReady(language: language) {
                status = .downloading(0)
                publish()
            }
            let directory = try await modelStore.download(language: language) { [weak self] fraction in
                Task { await self?.downloadProgress(fraction, epoch: epoch) }
            }
            try Task.checkCancellation()
            guard transcript.epoch == epoch, transcript.isEnabled else { return }
            status = .loading
            publish()
            let shared: SharedNemotronMultilingualModels
            if let sharedModels, sharedModelDirectory == directory {
                shared = sharedModels
            } else {
                shared = try await preload(directory)
            }
            guard transcript.epoch == epoch, transcript.isEnabled else { return }
            sharedModels = shared
            sharedModelDirectory = directory

            if participantMode {
                let pair = Self.participantStream { [weak self] in
                    Task { await self?.fail(localised("Participant preview queue is full", "Очередь онлайн-расшифровки участников заполнена"), epoch: epoch) }
                }
                participantContinuation = pair.continuation
                consumerTasks = [Task { [weak self] in
                    for await event in pair.stream {
                        guard !Task.isCancelled else { return }
                        await self?.receiveParticipant(event, language: language, epoch: epoch)
                    }
                }]
                if var sinks = pendingSinks {
                    pendingSinks = nil
                    sinks.participants = pair.sink
                    status = .live
                    publish()
                    attach?(sinks)
                }
                return
            }

            let micManager = StreamingNemotronMultilingualAsrManager()
            let systemManager = StreamingNemotronMultilingualAsrManager()
            try await micManager.loadFromShared(shared)
            try await systemManager.loadFromShared(shared)
            await micManager.setLanguage(language)
            await systemManager.setLanguage(language)
            await installCallback(on: micManager, source: .mic, epoch: epoch)
            await installCallback(on: systemManager, source: .system, epoch: epoch)
            guard transcript.epoch == epoch, transcript.isEnabled else {
                await micManager.cleanup()
                await systemManager.cleanup()
                return
            }

            managers = [.mic: micManager, .system: systemManager]
            consumerTasks = [
                consume(
                    mic, from: .mic, with: micManager,
                    spoken: decodedSomething[.mic], epoch: epoch),
                consume(
                    system, from: .system, with: systemManager,
                    spoken: decodedSomething[.system], epoch: epoch),
            ]
            status = .live
            publish()
            if let sinks = pendingSinks {
                pendingSinks = nil
                attach?(sinks)
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error.localizedDescription, epoch: epoch)
        }
    }

    private func installCallback(
        on manager: StreamingNemotronMultilingualAsrManager,
        source: Source,
        epoch: Int
    ) async {
        let pulse = decodedSomething[source]
        await manager.setPartialCallback { [weak self] text in
            pulse?.withLock { $0 = true }
            Task { await self?.received(text, from: source, epoch: epoch) }
        }
    }

    private func downloadProgress(_ fraction: Double, epoch: Int) {
        guard transcript.epoch == epoch, transcript.isEnabled,
              case .downloading = status, fraction < 1 else { return }
        status = .downloading(fraction)
        publish()
    }

    nonisolated private func consume(
        _ stream: AsyncStream<AudioPacket>,
        from source: Source,
        with manager: StreamingNemotronMultilingualAsrManager,
        spoken pulse: OSAllocatedUnfairLock<Bool>?,
        epoch: Int
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for await packet in stream {
                    guard !Task.isCancelled else { return }
                    if let milliseconds = packet.milliseconds {
                        await self?.markTime(milliseconds, source: source, epoch: epoch)
                    }
                    let seconds = Double(packet.buffer.frameLength)
                        / packet.buffer.format.sampleRate
                    _ = try await manager.process(audioBuffer: packet.buffer)
                    let spoken = pulse?.withLock { decoded -> Bool in
                        defer { decoded = false }
                        return decoded
                    } ?? false
                    await self?.decoded(
                        seconds: seconds, spoken: spoken, from: source, epoch: epoch)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.fail(error.localizedDescription, epoch: epoch)
            }
        }
    }

    private func received(_ text: String, from source: Source, epoch: Int) {
        guard transcript.epoch == epoch, managers[source] != nil else { return }
        let speaker = participantLabels[source] ?? source.speaker
        guard let text = partials.text(from: text, for: speaker) else { return }
        let milliseconds = sourceTimes[source] ?? Int(Date().timeIntervalSince(startedAt) * 1000)
        transcript.applyPartial(
            speaker: speaker,
            text: text,
            startMilliseconds: milliseconds,
            epoch: epoch
        )
        publish()
    }

    /// How much audio a side has to go through without decoding a word before
    /// its block is closed. Tokens only arrive while someone is speaking, so a
    /// gap in them is a pause — the audio needs no second listen to hear it.
    ///
    /// Measured in audio rather than on the clock: the model can fall a couple
    /// of seconds behind while it warms up, and a stopwatch reads that as a
    /// pause and cuts the sentence it is still working through.
    private static let pauseEndingABlock: Double = 2

    private func decoded(
        seconds: Double, spoken: Bool, from source: Source, epoch: Int
    ) async {
        guard transcript.epoch == epoch, managers[source] != nil else { return }
        guard !spoken else {
            silentSeconds[source] = 0
            return
        }
        let silence = (silentSeconds[source] ?? 0) + seconds
        silentSeconds[source] = silence
        guard silence >= Self.pauseEndingABlock else { return }
        await endSegment(on: source, epoch: epoch)
    }

    /// Closes the block and asks the engine to commit, which clears the
    /// accumulation the next block would otherwise be appended to — the whole
    /// meeting decoded again on every chunk, into one paragraph per speaker.
    private func endSegment(on source: Source, epoch: Int) async {
        guard transcript.endSegment(speaker: source.speaker, epoch: epoch) else { return }
        partials.close(source.speaker)
        publish()
        _ = try? await managers[source]?.finish()
    }

    /// A dropped buffer here and there is what a bounded queue is for. Live
    /// text is a preview, and losing a fifth of a second of it is not worth
    /// tearing the pipeline down — falling steadily behind is.
    private static let dropWindow: TimeInterval = 5
    private static let dropsBeforeGivingUp = 20

    private func pipelineOverloaded(epoch: Int) {
        guard transcript.epoch == epoch else { return }
        let now = Date()
        drops.append(now)
        drops.removeAll { now.timeIntervalSince($0) > Self.dropWindow }
        guard drops.count >= Self.dropsBeforeGivingUp else { return }

        stopPipeline(releaseSharedModels: false)
        transcript.invalidateActiveEpoch()
        status = .overloaded
        publish()
    }

    private func fail(_ message: String, epoch: Int) {
        guard transcript.epoch == epoch else { return }
        stopPipeline(releaseSharedModels: false)
        transcript.invalidateActiveEpoch()
        status = .error(message)
        publish()
    }

    /// Synchronous cancellation keeps toggle/stop deterministic. Manager
    /// cleanup is scheduled separately; shared models are retained across a
    /// temporary disable and released at the end of the recording.
    private func stopPipeline(releaseSharedModels: Bool) {
        pendingSinks = nil
        attach?(nil)
        let detached = detachPipeline()
        if detached.load != nil || !detached.managers.isEmpty || !detached.consumers.isEmpty {
            let previous = retirement
            retirement = Task {
                await previous?.value
                await detached.load?.value
                for consumer in detached.consumers { await consumer.value }
                for manager in detached.managers { await manager.cleanup() }
            }
        }
        if releaseSharedModels { sharedModels = nil; sharedModelDirectory = nil }
    }

    private func detachPipeline() -> (
        load: Task<Void, Never>?, consumers: [Task<Void, Never>],
        managers: [StreamingNemotronMultilingualAsrManager]
    ) {
        let oldLoad = loadTask
        oldLoad?.cancel()
        loadTask = nil
        continuations.forEach { $0.finish() }
        continuations.removeAll(keepingCapacity: false)
        participantContinuation?.finish()
        participantContinuation = nil
        participantQueues.values.forEach { $0.finish() }
        participantQueues.removeAll()
        let oldConsumers = consumerTasks + Array(participantConsumers.values)
        participantConsumers.removeAll()
        participantLabels.removeAll()
        sourceTimes.removeAll()
        oldConsumers.forEach { $0.cancel() }
        consumerTasks.removeAll(keepingCapacity: false)
        let oldManagers = Array(managers.values)
        managers.removeAll(keepingCapacity: false)
        return (oldLoad, oldConsumers, oldManagers)
    }

    nonisolated static func participantStream(onOverflow: @escaping @Sendable () -> Void) -> (
        stream: AsyncStream<ParticipantAudioRecorder.LiveEvent>,
        continuation: AsyncStream<ParticipantAudioRecorder.LiveEvent>.Continuation,
        sink: ParticipantAudioRecorder.Sink
    ) {
        let pair = AsyncStream<ParticipantAudioRecorder.LiveEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        return (pair.stream, pair.continuation, { event in
            if case .dropped = pair.continuation.yield(event) { onOverflow() }
        })
    }

    private func markTime(_ milliseconds: Int, source: Source, epoch: Int) {
        guard transcript.epoch == epoch, managers[source] != nil else { return }
        sourceTimes[source] = milliseconds
    }

    private func receiveParticipant(_ event: ParticipantAudioRecorder.LiveEvent, language: String, epoch: Int) async {
        guard transcript.epoch == epoch, transcript.isEnabled, participantMode, let sharedModels else { return }
        switch event {
        case .track(let track):
            let source = Source.participant(id: track.fileKey, name: track.name)
            participantLabels[source] = source.speaker
            guard managers[source] == nil else { return }
            guard participantQueues.count < 256 else { fail("Too many live participant streams", epoch: epoch); return }
            let manager = StreamingNemotronMultilingualAsrManager()
            do {
                try await manager.loadFromShared(sharedModels)
                await manager.setLanguage(language)
                decodedSomething[source] = .init(initialState: false)
                await installCallback(on: manager, source: source, epoch: epoch)
                guard transcript.epoch == epoch, transcript.isEnabled, participantMode else {
                    await manager.cleanup(); return
                }
                let pair = AsyncStream<AudioPacket>.makeStream(bufferingPolicy: .bufferingOldest(48))
                managers[source] = manager
                participantQueues[source] = pair.continuation
                participantConsumers[source] = consume(pair.stream, from: source, with: manager,
                                                       spoken: decodedSomething[source], epoch: epoch)
            } catch {
                await manager.cleanup()
                fail(error.localizedDescription, epoch: epoch)
            }
        case .audio(let track, let buffer, let milliseconds):
            let source = Source.participant(id: track.fileKey, name: track.name)
            if case .dropped = participantQueues[source]?.yield(AudioPacket(buffer: buffer, milliseconds: milliseconds)) {
                pipelineOverloaded(epoch: epoch)
            }
        case .removed(let id):
            let source = Source.participant(id: id, name: "")
            participantQueues.removeValue(forKey: source)?.finish()
            // Drain queued preview audio, then flush while the callback is still admitted.
            if let consumer = participantConsumers[source] { await consumer.value }
            guard transcript.epoch == epoch else { return }
            participantConsumers.removeValue(forKey: source)
            if let manager = managers[source], let final = try? await manager.finish() {
                received(final, from: source, epoch: epoch)
            }
            guard transcript.epoch == epoch else { return }
            _ = transcript.endSegment(speaker: source.speaker, epoch: epoch)
            partials.remove(source.speaker)
            publish()
            if let manager = managers.removeValue(forKey: source) { await manager.cleanup() }
            participantLabels.removeValue(forKey: source)
            decodedSomething.removeValue(forKey: source)
            silentSeconds.removeValue(forKey: source)
            sourceTimes.removeValue(forKey: source)
        }
    }

    private func publish() {
        update?(snapshot)
    }
}
