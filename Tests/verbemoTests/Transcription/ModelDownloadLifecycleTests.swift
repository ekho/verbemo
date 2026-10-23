import Foundation
import Testing
@testable import verbemo

struct ModelDownloadLifecycleTests {
    @Test("The cancelled last download consumer waits for shared cleanup")
    func lastConsumerWaitsForCleanup() async throws {
        let entered = Gate(), cancelled = Gate(), release = Gate(), cleaned = Flag(), returned = Flag()
        defer { release.open() }
        let download = SharedDownload<Double>(work: { _ in
            try await withTaskCancellationHandler {
                entered.open()
                await release.pass()
                cleaned.raise()
                try Task.checkCancellation()
                return URL(fileURLWithPath: "/synthetic-model")
            } onCancel: { cancelled.open() }
        }, finished: { _ in })
        let id = UUID()
        #expect(download.reserve(id))
        let task = Task {
            defer { returned.raise() }
            return try await download.wait(id: id, progress: { _ in })
        }
        await entered.pass()
        task.cancel()
        await cancelled.pass()
        for _ in 0..<20 { await Task.yield() }
        #expect(!returned.isRaised, "the last consumer escaped while download resources were still held")
        release.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cleaned.isRaised)
    }

    @Test("A cancelled consumer returns without waiting for another consumer's download")
    func sharedConsumerCancellationStaysIndependent() async throws {
        let entered = Gate(), release = Gate(), workCancelled = Flag()
        defer { release.open() }
        let url = URL(fileURLWithPath: "/synthetic-shared-model")
        let download = SharedDownload<Double>(work: { _ in
            try await withTaskCancellationHandler {
                entered.open()
                await release.pass()
                try Task.checkCancellation()
                return url
            } onCancel: { workCancelled.raise() }
        }, finished: { _ in })
        let first = UUID(), second = UUID()
        #expect(download.reserve(first))
        #expect(download.reserve(second))
        let leaving = Task { try await download.wait(id: first, progress: { _ in }) }
        await entered.pass()
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(!workCancelled.isRaised)
        let staying = Task { try await download.wait(id: second, progress: { _ in }) }
        release.open()
        #expect(try await staying.value == url)
    }

    @MainActor
    @Test("Download before diarization belongs to the meeting and cancellation releases its claim")
    func meetingDownloadOwnsClaimUntilCancelled() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let request = DiarizationState.Request(engine: "whisper", threshold: 0.7, explicit: true, model: .nemotron3)
        try DiarizationState(request: request, status: .deferred).write(to: dir)
        let entered = Gate(), cancelled = Gate(), release = Gate(), resumed = Flag()
        defer { release.open() }
        let task = Task {
            try await MeetingModelDownload.continueDiarization(dir, download: { model in
                #expect(model == .nemotron3)
                await withTaskCancellationHandler {
                    entered.open()
                    await release.pass()
                } onCancel: { cancelled.open() }
            }, resume: { _, _ in resumed.raise() })
        }
        await entered.pass()
        let entry = try #require(ProcessingOperations.shared.snapshot().first {
            $0.session == dir.standardizedFileURL.resolvingSymlinksInPath()
        })
        #expect(entry.kind == .diarization)
        #expect(SessionClaim.isHeld(dir))
        let stop = Task { await ProcessingOperations.shared.cancelAndWait(entry.id) }
        await cancelled.pass()
        #expect(SessionClaim.isHeld(dir))
        release.open()
        await stop.value
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!resumed.isRaised)
        #expect(!SessionClaim.isHeld(dir))
        #expect(DiarizationState.read(dir)?.request == request)
    }
}
