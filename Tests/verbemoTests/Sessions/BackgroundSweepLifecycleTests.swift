import Foundation
import Testing
@testable import verbemo

struct BackgroundSweepLifecycleTests {
    @MainActor
    @Test("The scheduled sweep is visible while waiting and cancelled requests never sweep")
    func cancellingWaitingSweepDoesNotRun() async throws {
        let operations = ProcessingOperations()
        let waiting = Gate(), drained = Gate(), cancelled = Gate()
        var sweeps = 0
        let scheduler = SweepScheduler(waitForQueue: {
            await withTaskCancellationHandler {
                waiting.open()
                await drained.pass()
            } onCancel: { cancelled.open() }
        }, sweep: { sweeps += 1 }, operations: operations)
        scheduler.request()
        let entry = try #require(operations.snapshot().first)
        #expect(entry.kind == .sweep)
        #expect(entry.state == .waiting)
        await waiting.pass()
        #expect(operations.snapshot().first?.state == .waiting)
        let stop = Task { await operations.cancelAndWait(entry.id) }
        await cancelled.pass()
        scheduler.request()
        drained.open()
        await stop.value
        for _ in 0..<20 where scheduler.isBusy { await Task.yield() }

        #expect(sweeps == 0)
        #expect(!scheduler.isBusy)
        #expect(operations.snapshot().isEmpty)
    }

    @MainActor
    @Test("Cancellation during a sweep discards the coalesced rerun")
    func cancelledSweepDoesNotRerun() async throws {
        let operations = ProcessingOperations()
        let entered = Gate(), release = Gate(), cancelled = Gate()
        var sweeps = 0
        let scheduler = SweepScheduler(waitForQueue: {}, sweep: {
            sweeps += 1
            await withTaskCancellationHandler {
                entered.open()
                await release.pass()
            } onCancel: { cancelled.open() }
        }, operations: operations)
        scheduler.request()
        await entered.pass()
        scheduler.request()
        let entry = try #require(operations.snapshot().first)
        let stop = Task { await operations.cancelAndWait(entry.id) }
        await cancelled.pass()
        #expect(operations.snapshot().first?.state == .cancelling)
        release.open()
        await stop.value
        for _ in 0..<20 where scheduler.isBusy { await Task.yield() }

        #expect(sweeps == 1)
        #expect(!scheduler.isBusy)
        #expect(operations.snapshot().isEmpty)
    }

}
