import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome, .speaking(.english))
struct ProcessingPresentationTests {
    @Test("Only the operation's actual stage animates, even outside the queue")
    func operationStages() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(SessionInventory.item(for: dir, policy: .init(names: true, summary: true)))
        let operations = ProcessingOperations.shared
        let ticket = try operations.register(session: dir, kind: .transcription)
        #expect(MeetingPresentation.stages(item)[1].state == .waiting)
        try await ticket.run {
            for (kind, symbol) in [(ProcessingOperations.Kind.transcription, "doc.text"), (.diarization, "person.wave.2"), (.postProcessing, "person.text.rectangle"), (.summary, "checklist")] {
                operations.stage(kind)
                let active = MeetingPresentation.stages(item).filter { $0.state == .active }
                #expect(active.count == 1)
                #expect(active.first.map { $0.activitySymbol ?? $0.symbol } == symbol)
                await MainActor.run {
                    let row = MeetingListView(item: item)
                    #expect(row.allDescendants.contains { $0.identifier?.rawValue == "stage.symbol.\(symbol)" })
                }
            }
            operations.stage(.transcription, state: .waiting)
            #expect(MeetingPresentation.stages(item).allSatisfy { $0.state != .active })
            operations.cancel(ticket.id)
            #expect(MeetingPresentation.stages(item)[1].title.contains("Cancelling"))
            #expect(MeetingPresentation.stages(item).allSatisfy { $0.state != .active })
        }
        #expect(MeetingPresentation.stages(item).allSatisfy { $0.state != .active })
        try SessionClaim.acquire(dir, stage: .transcribe)
        defer { SessionClaim.release(dir) }
        #expect(MeetingPresentation.stages(item).allSatisfy { $0.state != .active }, "A claim alone is not an executing stage")
    }

    @Test("Motion is reserved for running work and respects Reduce Motion", arguments: [false, true])
    @MainActor func statusMotion(reduceMotion: Bool) throws {
        for state in [MeetingPresentation.StageState.done, .active, .paused, .pending, .waiting, .off, .failed] {
            let icon = MeetingListView.icon(.init(symbol: "doc.text", title: "Stage \(state)", state: state), reduceMotion: reduceMotion)
            #expect(icon.accessibilityLabel() == "Stage \(state)")
            let animated = icon.allDescendants.contains { $0.layer?.animation(forKey: "stage-progress") != nil }
            #expect(animated == (state == .active && !reduceMotion))
        }
        for symbol in ["doc.text", "checklist", "person.wave.2", "person.text.rectangle", "clock", "checkmark", "exclamationmark.circle"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
    }
}
