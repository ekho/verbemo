import Foundation
import Testing
import os
@testable import verbemo

struct ParticipantLiveTranscriptionTests {
    @Test func equalNamesAndRenamesKeepIndependentPartials() {
        var state = LiveTranscriptState()
        let epoch = state.beginRecording(enabled: true)
        let one = LiveTranscriptState.Speaker.participant(id: "p1", name: "Same")
        let two = LiveTranscriptState.Speaker.participant(id: "p2", name: "Same")
        state.applyPartial(speaker: one, text: "first", startMilliseconds: 100, epoch: epoch)
        state.applyPartial(speaker: two, text: "second", startMilliseconds: 200, epoch: epoch)
        state.applyPartial(speaker: .participant(id: "p1", name: "Renamed"), text: "first updated", startMilliseconds: 300, epoch: epoch)
        #expect(state.entries.count == 2)
        guard case .speech(let first) = state.entries[0] else { Issue.record("Missing first participant"); return }
        #expect(first.text == "first updated")
        #expect(first.speaker.label == "Renamed")
        #expect(first.startMilliseconds == 100)
        let ended = state.endSegment(speaker: two, epoch: epoch)
        #expect(ended)
        state.invalidateActiveEpoch()
        state.applyPartial(speaker: one, text: "stale", startMilliseconds: 400, epoch: epoch)
        state.applyPartial(speaker: .you, text: "fallback", startMilliseconds: 500, epoch: state.epoch)
        #expect(state.entries.count == 3)
        state.finishRecording()
        state.applyPartial(speaker: one, text: "after stop", startMilliseconds: 600, epoch: state.epoch)
        #expect(state.entries.count == 3)
    }

    @Test func participantQueueIsBoundedAndClosedSinksCannotRestartIt() async {
        let overflow = OSAllocatedUnfairLock(initialState: 0)
        let pair = LiveTranscriptionCoordinator.participantStream { overflow.withLock { $0 += 1 } }
        let track = CallAudioMetadata.Track(fileKey: "call_test", sourceID: "p", speakerID: "call_test",
            participantID: "p", name: "Same", isLocal: false, generation: 1, sampleRate: 48000)
        for _ in 0..<257 { pair.sink(.track(track)) }
        #expect(overflow.withLock { $0 } == 1)
        pair.continuation.finish()
        var count = 0
        for await _ in pair.stream { count += 1 }
        #expect(count == 256)
        pair.sink(.track(track))
        #expect(overflow.withLock { $0 } == 1)
    }

    @Test func fallbackDuringLoadingRetiresTheParticipantPipeline() async throws {
        let root = NemotronFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NemotronModelStore(root: root)
        try NemotronFixtures.install(at: store.variantDirectory(language: "auto"))
        let entered = Gate(), cancelled = Gate(), cleanup = Gate()
        let live = LiveTranscriptionCoordinator(modelStore: store, preload: { _ in
            await withTaskCancellationHandler {
                entered.open(); await cleanup.pass()
            } onCancel: { cancelled.open() }
            throw CancellationError()
        })
        let attached = OSAllocatedUnfairLock(initialState: 0)
        await live.beginRecording(enabled: true, language: "auto", participants: true,
            update: { _ in }, attach: { sinks in if sinks != nil { attached.withLock { $0 += 1 } } })
        await entered.pass()
        await live.useOrdinarySources(language: "auto")
        await cancelled.pass()
        cleanup.open()
        await live.finishRecording()
        #expect(attached.withLock { $0 } == 0)
        #expect(await live.snapshot.isRecording == false)
    }
}
