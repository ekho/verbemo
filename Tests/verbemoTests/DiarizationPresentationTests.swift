import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome, .speaking(.english)) @MainActor
struct DiarizationPresentationTests {
    @Test("Unreadable diarization is an error even before a transcript exists")
    func unreadableBeforeTranscript() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        try SessionState.amend(dir, with: [DiarizationState.key: "unreadable"])
        let item = try #require(SessionInventory.item(for: dir))
        let stage = try #require(MeetingPresentation.stages(item).first { $0.symbol == "doc.text" })
        #expect(stage.state == .failed)
        #expect(stage.title.contains("cannot be read"))
        let row = MeetingListView(item: item)
        #expect(row.allDescendants.first { $0.identifier?.rawValue == "meeting.list-status" }?.toolTip == stage.title)
    }

    @Test("Diarization details and recovery belong to the transcript, without a duplicate footer",
          arguments: [DiarizationState.Status.pending, .failed, .completed, .skipped], [NSAppearance.Name.aqua, .darkAqua])
    func unifiedDetails(status: DiarizationState.Status, appearance: NSAppearance.Name) async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        try SessionFixture.transcript.write(to: dir)
        var state = DiarizationState(request: .init(engine: "nemotron", threshold: 0.6), status: status)
        state.confirmedSpeakers = status == .completed ? 2 : 0
        if status == .failed { state.reason = "Synthetic inference failure requiring a deliberate retry or skip; the source audio remains available." }
        try state.write(to: dir)
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: recordings.root, hostWindow: app.panel)
        defer { _ = library.stopForTermination(); app.hide() }
        library.onRetryDiarization = { _ in }
        library.onSkipDiarization = { _ in }
        app.libraryProvider = { library }; app.show()
        app.panel.appearance = NSAppearance(named: appearance)
        app.panel.setContentSize(.init(width: 1100, height: 640))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let labels = library.contentView.allDescendants.compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue == "diarization.status" }
        let label = try #require(labels.first)
        #expect(labels.count == 1)
        let group = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "meeting.processing-transcript" })
        #expect(label.isDescendant(of: group))
        #expect(label.stringValue.contains("Speakers: 3"))
        #expect(!group.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("diarization enabled") })
        #expect(label.bounds.height >= label.cell!.cellSize(forBounds: .init(x: 0, y: 0, width: label.bounds.width, height: 2000)).height - 1)
        let retry = try #require(group.allDescendants.first { $0.identifier?.rawValue == "diarization.retry" } as? NSButton)
        let skip = try #require(group.allDescendants.first { $0.identifier?.rawValue == "diarization.skip" } as? NSButton)
        #expect(retry.isHidden == state.isFinal)
        #expect(skip.isHidden == state.isFinal)
        #expect(!retry.isHidden ? retry.isEnabled : true)
        if status == .completed { #expect(label.stringValue.contains("2 confirmed speakers")) }
        if status == .failed { #expect(label.stringValue.contains(state.reason!)) }
        let item = try #require(SessionInventory.item(for: dir))
        let stage = try #require(MeetingPresentation.stages(item).first { $0.symbol == "doc.text" })
        #expect(stage.diarized == (status == .completed))
        #expect(stage.state == (status == .failed ? .failed : status == .pending ? .waiting : .done))
        #expect(DiarizationState.read(dir) == state)
    }
}
