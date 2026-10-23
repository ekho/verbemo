import Foundation
import Testing
@testable import verbemo

struct ProcessingOperationsTests {
    @Test("Cancellation waits for cleanup and retains the cancelling run")
    func cleanupBarrier() async throws {
        let operations = ProcessingOperations()
        let entered = Gate(), cancelled = Gate(), cleanup = Gate(), returned = Flag()
        let ticket = try operations.register(session: URL(fileURLWithPath: "/synthetic/a"), kind: .transcription)
        let task = Task {
            try await ticket.run {
                entered.open()
                await withTaskCancellationHandler { await cleanup.pass() } onCancel: { cancelled.open() }
            }
        }
        await entered.pass()
        let stop = Task { await operations.cancelAndWait(ticket.id); returned.raise() }
        await cancelled.pass()
        #expect(operations.snapshot().first?.state == .cancelling)
        #expect(!returned.isRaised)
        cleanup.open()
        await stop.value
        _ = try? await task.value
        #expect(operations.snapshot().isEmpty)
    }

    @Test("Queued cancellation never starts work; repeated cancellation is harmless")
    func waitingCancellation() async throws {
        let operations = ProcessingOperations(), ran = Flag()
        let ticket = try operations.register(session: nil, kind: .transcription)
        #expect(operations.snapshot().first?.state == .waiting)
        await operations.cancelAndWait(ticket.id)
        await operations.cancelAndWait(ticket.id)
        do { try await ticket.run { ran.raise() }; Issue.record("cancelled ticket ran") }
        catch is CancellationError {} catch { Issue.record("unexpected: \(error)") }
        #expect(!ran.isRaised)
        #expect(operations.snapshot().isEmpty)
    }

    @Test("Old run handles do not cancel a new run of the same meeting")
    func generationIsolation() async throws {
        let operations = ProcessingOperations(), entered = Gate(), release = Gate()
        let session = URL(fileURLWithPath: "/synthetic/a")
        let old = try operations.register(session: session, kind: .summary)
        try await old.run {}
        let current = try operations.register(session: session, kind: .summary)
        let task = Task { try await current.run { entered.open(); await release.pass(); try Task.checkCancellation() } }
        await entered.pass()
        await operations.cancelAndWait(old.id)
        #expect(operations.snapshot().first?.id == current.id)
        #expect(operations.snapshot().first?.state == .running)
        release.open()
        try await task.value
    }

    @Test("Nested stages reuse a run and closure rejects only new work")
    func nestingAndClose() async throws {
        let operations = ProcessingOperations(), entered = Gate(), proceed = Gate()
        let session = URL(fileURLWithPath: "/synthetic/a")
        let task = Task {
            try await operations.run(session: session, kind: .transcription) {
                entered.open(); await proceed.pass()
                try await operations.run(session: session, kind: .postProcessing) {
                    #expect(operations.snapshot().count == 1)
                    #expect(operations.snapshot().first?.kind == .postProcessing)
                }
            }
        }
        await entered.pass()
        operations.closeAdmission()
        do { _ = try operations.register(session: nil, kind: .importMedia); Issue.record("accepted after close") }
        catch is CancellationError {} catch { Issue.record("unexpected: \(error)") }
        proceed.open()
        try await task.value
        await operations.cancelAllAndWait()
        #expect(operations.snapshot().isEmpty)
    }

    @Test("Cancelling a meeting leaves independent work running")
    func sessionIsolation() async throws {
        let operations = ProcessingOperations(), entered = Gate(), release = Gate()
        let a = try operations.register(session: URL(fileURLWithPath: "/synthetic/a"), kind: .diarization)
        let b = try operations.register(session: URL(fileURLWithPath: "/synthetic/b"), kind: .archive)
        let task = Task { try await b.run { entered.open(); await release.pass(); try Task.checkCancellation() } }
        await entered.pass()
        await operations.cancelAndWait(session: URL(fileURLWithPath: "/synthetic/a"))
        #expect(operations.snapshot().map(\.id) == [b.id])
        do { try await a.run {}; Issue.record("cancelled waiting meeting ran") } catch {}
        release.open(); try await task.value
    }
    @Test("Completion racing cancellation never removes another generation")
    func completionRace() async throws {
        let operations = ProcessingOperations()
        for _ in 0..<50 {
            let ticket = try operations.register(session: nil, kind: .summary)
            let task = Task { try await ticket.run { await Task.yield() } }
            async let stop: Void = operations.cancelAndWait(ticket.id)
            _ = try? await task.value
            await stop
            #expect(operations.snapshot().isEmpty)
        }
    }

    @Test("An expired inherited context cannot bypass closed admission")
    func expiredContext() async throws {
        let operations = ProcessingOperations(), release = Gate(), ran = Flag()
        let child = try await operations.run(kind: .sweep) {
            Task {
                await release.pass()
                try await operations.run(kind: .sweep) { ran.raise() }
            }
        }
        operations.closeAdmission(); release.open()
        do { try await child.value; Issue.record("accepted an expired context after closure") }
        catch is CancellationError {}
        #expect(!ran.isRaised)
        #expect(operations.snapshot().isEmpty)
    }

    @Test("Shutdown cancels all running work before waiting for every cleanup")
    func globalCleanupBarrier() async throws {
        let operations = ProcessingOperations(), returned = Flag()
        let enteredA = Gate(), enteredB = Gate(), cancelledA = Gate(), cancelledB = Gate()
        let cleanupA = Gate(), cleanupB = Gate()
        defer { cleanupA.open(); cleanupB.open() }
        let a = Task {
            try await operations.run(session: URL(fileURLWithPath: "/synthetic/a"), kind: .summary) {
                await withTaskCancellationHandler {
                    enteredA.open(); await cleanupA.pass()
                } onCancel: { cancelledA.open() }
            }
        }
        let b = Task {
            try await operations.run(session: URL(fileURLWithPath: "/synthetic/b"), kind: .archive) {
                await withTaskCancellationHandler {
                    enteredB.open(); await cleanupB.pass()
                } onCancel: { cancelledB.open() }
            }
        }
        await enteredA.pass(); await enteredB.pass()
        let stop = Task { await operations.cancelAllAndWait(); returned.raise() }
        await cancelledA.pass(); await cancelledB.pass()
        #expect(!operations.isAccepting)
        #expect(operations.snapshot().count == 2)
        #expect(operations.snapshot().allSatisfy { $0.state == .cancelling })
        cleanupA.open(); try await a.value
        #expect(!returned.isRaised)
        cleanupB.open(); try await b.value
        await stop.value
        #expect(operations.snapshot().isEmpty)
    }

    @Test("A retained snapshot distinguishes cancellation from a completed generation")
    func snapshotCompletion() async throws {
        let operations = ProcessingOperations()
        let session = URL(fileURLWithPath: "/synthetic/a")
        let completed = try operations.register(session: session, kind: .summary)
        let completedSnapshot = try #require(operations.snapshot().first)
        try await completed.run {}
        #expect(await operations.cancelAndWait(completedSnapshot) == .completed)
        let waiting = try operations.register(session: session, kind: .summary)
        let waitingSnapshot = try #require(operations.snapshot().first)
        #expect(await operations.cancelAndWait(waitingSnapshot) == .cancelled)
        #expect(await operations.cancelAndWait(completedSnapshot) == .completed)
        do { try await waiting.run {}; Issue.record("Cancelled reservation started") }
        catch is CancellationError {}
        #expect(operations.isAccepting)
    }

    @Test("Snapshot outcome waits for cleanup and preserves a real failure")
    func snapshotFailureBarrier() async throws {
        let operations = ProcessingOperations(), entered = Gate(), release = Gate(), cancelled = Gate()
        let ticket = try operations.register(session: URL(fileURLWithPath: "/synthetic/a"), kind: .summary)
        let snapshot = try #require(operations.snapshot().first)
        let task = Task {
            try await ticket.run {
                await withTaskCancellationHandler {
                    entered.open(); await release.pass()
                } onCancel: { cancelled.open() }
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        await entered.pass()
        let stop = Task { await operations.cancelAndWait(snapshot) }
        await cancelled.pass()
        #expect(operations.snapshot().first?.state == .cancelling)
        release.open()
        let outcome = await stop.value
        if case .failed(let message) = outcome { #expect(!message.isEmpty) }
        else { Issue.record("A real error was replaced by cancellation: \(outcome)") }
        _ = try? await task.value
        #expect(operations.snapshot().isEmpty)
    }

    @Test("Normal completion wins even when cancellation was requested during cleanup")
    func successfulCompletionAfterRequest() async throws {
        let operations = ProcessingOperations(), entered = Gate(), release = Gate(), cancelled = Gate()
        let ticket = try operations.register(session: URL(fileURLWithPath: "/synthetic/a"), kind: .summary)
        let snapshot = try #require(operations.snapshot().first)
        let task = Task {
            try await ticket.run {
                await withTaskCancellationHandler {
                    entered.open(); await release.pass()
                } onCancel: { cancelled.open() }
                return "published result"
            }
        }
        await entered.pass()
        let stop = Task { await operations.cancelAndWait(snapshot) }
        await cancelled.pass(); release.open()
        #expect(await stop.value == .completed)
        #expect(try await task.value == "published result")
    }

}
