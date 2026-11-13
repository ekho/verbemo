import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome, .speaking(.english)) @MainActor
struct ProcessingTabTests {
    private func text(_ tab: String, in library: MeetingLibraryController) throws -> String {
        let tabs = try #require(library.contentView.allDescendants.first { $0 is NSTabView } as? NSTabView)
        return tabs.tabViewItems.first { $0.identifier as? String == tab }?.view?.allDescendants
            .compactMap { $0 as? NSTextView }.map(\.string).joined(separator: "\n") ?? ""
    }
    private func button(_ id: String, in library: MeetingLibraryController) throws -> NSButton {
        try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == id } as? NSButton)
    }

    @Test("Empty tabs follow operations and the summary CTA reuses one guarded sheet")
    func emptyTabsAndCTA() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        try SessionState.amend(dir, with: [SessionState.Key.summaryStatus: nil])
        Config.update(path: ["transcription", "enabled"], value: true)
        Config.update(path: ["speaker_names", "enabled"], value: false)
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: recordings.root, hostWindow: app.panel)
        defer { _ = library.stopForTermination(); app.hide() }
        app.libraryProvider = { library }
        app.show()
        let cta = try button("meeting.empty-generate-summary", in: library)
        #expect(!cta.isEnabled)
        #expect(try text("summary", in: library).contains("Create a finished transcript first"))
        #expect(try text("transcript", in: library).contains("Transcript not created"))
        let entered = Flag(), release = Gate()
        let ticket = try ProcessingOperations.shared.register(session: dir, kind: .transcription)
        let task = Task {
            try await ticket.run { entered.raise(); await release.pass() }
        }
        defer { release.open(); task.cancel() }
        for _ in 0..<100 where !entered.isRaised { try await Task.sleep(for: .milliseconds(10)) }
        try #require(entered.isRaised)
        library.refresh(); await library.settled()
        #expect(try text("transcript", in: library) == "Transcription")
        #expect(try text("summary", in: library).contains("Summary waits for transcription"))
        #expect(!cta.isEnabled)
        ProcessingOperations.shared.cancel(ticket.id)
        library.refresh(); await library.settled()
        #expect(try text("transcript", in: library).contains("Cancelling"))
        release.open(); try await task.value
        try SessionFixture.transcript.write(to: dir)
        library.refresh(); await library.settled()
        #expect(cta.isEnabled)
        #expect(try text("summary", in: library).contains("Summary not started"))
        #expect(cta.sendAction(cta.action, to: cta.target))
        let sheet = try #require(app.panel.attachedSheet)
        #expect(!cta.isEnabled)
        #expect(cta.sendAction(cta.action, to: cta.target))
        #expect(app.panel.attachedSheet === sheet)
        #expect(app.panel.sheets.count == 1)
        #expect(ProcessingOperations.shared.snapshot().allSatisfy { $0.session != dir.resolvingSymlinksInPath() })
        let cancel = try #require(sheet.contentView?.allDescendants.compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\u{1b}" })
        #expect(cancel.sendAction(cancel.action, to: cancel.target))
        for _ in 0..<100 where app.panel.attachedSheet != nil { try await Task.sleep(for: .milliseconds(10)) }
        library.refresh(); await library.settled()
        #expect(cta.isEnabled)
        var diarization = DiarizationState(request: .init(engine: "nemotron", threshold: 0.6), status: .pending)
        diarization.beginInference(fingerprint: "fixture"); diarization.failInference("synthetic error")
        try diarization.write(to: dir)
        library.refresh(); await library.settled()
        #expect(!cta.isEnabled)
        #expect(try text("summary", in: library).contains("retry or skip"))
        diarization.status = .skipped; try diarization.write(to: dir)
        try SessionState.amend(dir, with: [SessionState.Key.summaryStatus: "synthetic summary failure"])
        library.refresh(); await library.settled()
        #expect(cta.isEnabled)
        #expect(try text("summary", in: library).contains("Summary creation failed"))
    }

    @Test("Existing and archived materials survive a pending version and meeting switches")
    func versionsKeepTheirMaterials() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("meeting"), other = try recordings.session("other")
        try SessionFixture.transcript.write(to: dir)
        try Data("Archived summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        _ = try TranscriptVersions.archiveCurrent(dir)
        try Transcript(engine: "test", model: "new", created_at: "2026-11-13T10:00:00Z", segments: SessionFixture.meeting).write(to: dir)
        try Data("Current summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try TranscriptVersions.Request(engine: "whisper", diarization: nil).write(to: dir)
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: recordings.root, hostWindow: app.panel)
        defer { _ = library.stopForTermination(); app.hide() }
        app.libraryProvider = { library }; app.show()
        try #require(await library.reveal(dir))
        let picker = try #require(library.contentView.allDescendants.first { $0.identifier?.rawValue == "transcript-versions" } as? NSPopUpButton)
        #expect(try text("summary", in: library).contains("Current summary"))
        picker.selectItem(at: 0); #expect(picker.sendAction(picker.action, to: picker.target))
        #expect(try text("summary", in: library).contains("Archived summary"))
        picker.selectItem(at: 2); #expect(picker.sendAction(picker.action, to: picker.target))
        #expect(try text("summary", in: library).contains("Summary waits for transcription"))
        #expect(try text("transcript", in: library).contains("Transcription queued"))
        #expect(!library.currentActions.transcriptReady)
        try #require(await library.reveal(other))
        #expect(!(try text("summary", in: library)).contains("Archived summary"))
        #expect(!(try text("transcript", in: library)).contains("queued"))
        try #require(await library.reveal(dir))
        #expect(try text("summary", in: library).contains("Current summary"))
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "Current summary")
    }
}
