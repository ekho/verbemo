import Foundation
import Testing
@testable import verbemo

@Suite(.serialized)
@MainActor
struct SessionDeletionTests {
    @Test(.freshHome) func undoNeverTouchesFilesAndReleasesClaim() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        var recycled = 0
        let controller = SessionDeletionController(delay: 60) { _, completion in recycled += 1; completion(nil) }
        let id = try controller.schedule(dir) { _ in }
        #expect(SessionClaim.isHeld(dir))
        #expect(controller.isPending(dir))
        #expect(controller.undo(id))
        #expect(!controller.undo(id))
        #expect(recycled == 0)
        #expect(!SessionClaim.isHeld(dir))
        #expect(PostProcessor.readTranscript(dir) != nil)
    }
    @Test(.freshHome) func recycleFailureRestoresAvailabilityAndKeepsSource() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        var failed = false
        let controller = SessionDeletionController(delay: 60) { _, completion in completion(CocoaError(.fileWriteNoPermission)) }
        let id = try controller.schedule(dir) { result in if case .failure = result { failed = true } }
        controller.commit(id)
        #expect(failed)
        #expect(!controller.hasWork)
        #expect(!SessionClaim.isHeld(dir))
        #expect(PostProcessor.readTranscript(dir) != nil)
    }
    @Test(.freshHome) func recordingCannotBeScheduledAndClosingCancelsPendingDeletion() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = SessionDeletionController(delay: 60) { _, _ in Issue.record("Should not recycle") }
        let marker = dir.appendingPathComponent(".recording.json")
        try Data("{}".utf8).write(to: marker)
        #expect(throws: (any Error).self) { try controller.schedule(dir) { _ in } }
        try FileManager.default.removeItem(at: marker)
        _ = try controller.schedule(dir) { _ in }
        controller.cancelAll()
        #expect(!controller.hasWork)
        #expect(!SessionClaim.isHeld(dir))
    }
    @Test(.freshHome) func quitWaitsForCommittedRecycleAndClaimRelease() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        var completion: (@MainActor @Sendable (Error?) -> Void)?
        let controller = SessionDeletionController(delay: 60) { _, done in completion = done }
        let id = try controller.schedule(dir) { _ in }
        controller.commit(id)
        let cleanup = controller.stopForTermination()
        let returned = Flag()
        let wait = Task { await cleanup.value; returned.raise() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!returned.isRaised)
        #expect(SessionClaim.isHeld(dir))
        completion?(nil)
        await wait.value
        #expect(!controller.hasWork)
        #expect(!SessionClaim.isHeld(dir))
        #expect(throws: CancellationError.self) { try controller.schedule(dir) { _ in } }
    }

}
