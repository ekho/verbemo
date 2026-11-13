import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome, .speaking(.english))
struct SummaryPresentationTests {
    @Test("Summary explains a diarization decision instead of claiming preparation")
    func blockedByDiarization() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        var state = DiarizationState(request: .init(engine: "nemotron", threshold: 0.6), status: .pending)
        state.beginInference(fingerprint: "fixture")
        state.failInference("inference failed: noSpeechDetected")
        try state.write(to: dir)
        let item = try #require(SessionInventory.item(for: dir, policy: .init(names: false, summary: true)))
        let summary = try #require(MeetingPresentation.stages(item).last)
        #expect(summary.state == .waiting)
        #expect(summary.title.contains("diarization"))
        #expect(summary.title.contains("retry or skip"))
    }

    @Test("Only a real summary stage is active, including operations outside the queue")
    func actualOperationStage() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(SessionInventory.item(for: dir, policy: .init(names: true, summary: true)))
        let operations = ProcessingOperations.shared
        #expect(MeetingPresentation.stages(item).last?.title == "Summary not started")
        let ticket = try operations.register(session: dir, kind: .summary)
        #expect(MeetingPresentation.stages(item).last?.title == "Summary queued")
        try await ticket.run {
            #expect(MeetingPresentation.stages(item).last?.state == .active)
            operations.stage(.postProcessing)
            try SessionClaim.acquire(dir, stage: .finish)
            defer { SessionClaim.release(dir) }
            #expect(MeetingPresentation.stages(item).last?.state == .waiting)
            #expect(MeetingPresentation.stages(item).last?.title == "Summary waits for speaker naming")
            operations.stage(.summary)
            #expect(MeetingPresentation.stages(item).last?.state == .active)
        }
        #expect(MeetingPresentation.stages(item).last?.state != .active)
        try SessionClaim.acquire(dir, stage: .finish)
        defer { SessionClaim.release(dir) }
        #expect(MeetingPresentation.stages(item).last?.state == .waiting,
                "A claim alone does not establish which stage another process is running")
    }

    @Test("Waiting summary icons never animate and remain waiting in the library")
    @MainActor func waitingIcon() throws {
        let stage = MeetingPresentation.Stage(symbol: "checklist", title: "Summary waits for diarization", state: .waiting)
        let icon = MeetingListView.icon(stage)
        #expect(icon.allDescendants.allSatisfy { $0.layer?.animation(forKey: "stage-progress") == nil })
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DiarizationState(request: .init(engine: "nemotron", threshold: 0.6), status: .pending).write(to: dir)
        let item = try #require(SessionInventory.item(for: dir, policy: .init(names: false, summary: true)))
        let cell = MeetingListView(item: item)
        let status = try #require(cell.allDescendants.first { $0.identifier?.rawValue == "meeting.list-status" })
        #expect(status.toolTip?.contains("diarization") == true)
    }
}
