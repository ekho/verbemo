import Foundation
import Testing
@testable import verbemo

@MainActor
struct AppTerminationTests {
    @Test("Quit closes admission synchronously, awaits recording handoff, then cleanup")
    func recordingBeforeProcessingCleanup() async throws {
        let operations = ProcessingOperations()
        let handoff = Gate(), cancelled = Gate(), cleanup = Gate()
        let entered = Gate(), completed = Flag(), servicesFinished = Flag()
        let work = Task {
            try await operations.run(kind: .summary) {
                await withTaskCancellationHandler {
                    entered.open(); await cleanup.pass()
                } onCancel: { cancelled.open() }
            }
        }
        await entered.pass()
        let termination = AppTermination(operations: operations)
        var stops = 0
        let first = termination.begin(stop: {
            #expect(!operations.isAccepting)
            stops += 1
        }, finishRecording: {
            await handoff.pass()
        }, finishServices: { servicesFinished.raise() })
        let second = termination.begin(stop: { stops += 1 }, finishRecording: {}, finishServices: {})
        #expect(stops == 1)
        #expect(!operations.isAccepting)
        #expect(!servicesFinished.isRaised)
        let reply = Task { await first.value; completed.raise() }
        #expect(operations.snapshot().first?.state == .running)
        handoff.open()
        await cancelled.pass()
        #expect(!completed.isRaised)
        #expect(!servicesFinished.isRaised)
        cleanup.open()
        await second.value; await reply.value
        try await work.value
        #expect(completed.isRaised)
        #expect(servicesFinished.isRaised)
        #expect(operations.snapshot().isEmpty)
    }
    @Test("Shutdown awaits the original handoff and a new recording waits for old live finish")
    func originalHandoff() async {
        let transitions = LiveTranscriptionTransitions()
        let stopping = Gate(), released = Gate(), nextStarted = Flag()
        transitions.append { stopping.open(); await released.pass() }
        await stopping.pass()
        transitions.append { nextStarted.raise() }
        let returned = Flag()
        let wait = Task { await transitions.wait(); returned.raise() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!returned.isRaised)
        #expect(!nextStarted.isRaised)
        released.open()
        await wait.value
        #expect(nextStarted.isRaised)
    }

}
