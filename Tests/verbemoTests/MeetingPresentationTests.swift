import AppKit
import Foundation
import Testing
@testable import verbemo

struct MeetingPresentationTests {
    @Test(.freshHome, .speaking(.russian)) func summaryFailureIsLocalizedInRussian() throws {
        try expectSummaryFailure("Сбой создания сводки")
    }

    @Test(.freshHome, .speaking(.english)) func summaryFailureIsLocalizedInEnglish() throws {
        try expectSummaryFailure("Summary creation failed")
    }

    private func expectSummaryFailure(_ title: String) throws {
        let dir = try SessionFixture.make(meta: [SessionState.Key.summaryStatus: "failed"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(SessionInventory.item(for: dir, policy: .init(names: false, summary: true)))
        let summary = try #require(MeetingPresentation.stages(item).last)
        #expect(summary.state == .failed)
        #expect(summary.title == title)
    }

    @Test(.freshHome) func twoSeparatedVoicesHaveDiarizationBadge() throws {
        let dir = try SessionFixture.make(segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hello"),
            .init(speaker: "them A", start_ms: 1000, end_ms: 2000, text: "Hi"),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(SessionInventory.item(for: dir))
        #expect(MeetingPresentation.stages(item).first { $0.symbol == "doc.text" }?.diarized == true)
    }
    @Test(.freshHome) func singleSourceWithoutSpeakerSeparationHasNoDiarizationBadge() throws {
        let dir = try SessionFixture.make(segments: [
            .init(speaker: "speaker", start_ms: 0, end_ms: 1000, text: "Imported speech.")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(SessionInventory.item(for: dir))
        #expect(MeetingPresentation.stages(item).first { $0.symbol == "doc.text" }?.diarized == false)
    }
    @Test(.freshHome) func audioOnlyOffersExistingFilesInsideMeeting() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        try SessionState.amend(dir, with: ["files": ["mic": "mic.caf", "system": "missing.caf", "outside": "../outside.caf"]])
        #expect(MeetingPresentation.audioFiles(dir).map(\.lastPathComponent) == ["mic.caf"])
    }

    @Test func fullDateIncludesYearAndTime() {
        let date = ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z")!
        #expect(MeetingPresentation.date(date, timeZone: TimeZone(secondsFromGMT: 0)!) == "20.10.2026 10:00")
    }
    @Test(.freshHome, .speaking(.russian)) func readyMeetingAndMissingSummaryAreDistinct() throws {
        let dir = try SessionFixture.make(meta: ["title": "Планирование", "started": "2026-10-20T10:00:00Z"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(SessionInventory.item(for: dir, policy: .init(names: false, summary: false)))
        #expect(MeetingPresentation.matches(item, filter: .allMeetings, query: "план"))
        #expect(!MeetingPresentation.matches(item, filter: .allMeetings, query: "другое"))
        #expect(!MeetingPresentation.matches(item, filter: .attention, query: ""))
        #expect(MeetingPresentation.stages(item).last?.title == "Сводка не создавалась")
    }
}

@Suite(.serialized)
@MainActor
struct MeetingMenuTests {
    @Test(.freshHome) func journalDetailsExposeManualFinishForFailedNaming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try SessionFixture.make()
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.moveItem(at: fixture, to: dir)
        try SessionState.amend(dir, with: [SessionState.Key.speakersStatus: "failed"])
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        await library.settled()
        let button = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.title == "Finish processing" })
        #expect(!button.isHidden)
        #expect(button.isEnabled)
        let item = try #require(SessionInventory.item(for: dir))
        #expect(MeetingLibraryController.decision(for: item, policy: .init(names: true, summary: false)) == .finish)
        withExtendedLifetime(library) {}
    }
    @Test(.speaking(.russian)) func meetingMenuOmitsActionsWithDedicatedControls() {
        let state = MeetingActionState(transcriptReady: false, summaryReady: false,
            hasAudio: true, isRecording: false, isBusy: false,
            configReadable: true, transcriptionEnabled: true, summaryEnabled: true)
        let menu = MeetingActionsMenu.make(state: state, target: NSObject(), action: NSSelectorFromString("run:"))
        #expect(menu.items.map(\.title) == ["Переименовать", "Расшифровать повторно", "Открыть папку в Finder", "Открыть во внешнем редакторе", "", "Удалить"])
        #expect(menu.items[1].isEnabled)
        #expect(!menu.items[3].isEnabled)
        #expect(menu.items[3].toolTip != nil)
    }
    @Test func textAndMarkdownCopyHaveDifferentContents() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let markdown = "## Heading\n\n- First\n  - Nested"
        #expect(MeetingLibraryController.copyContent(markdown, plainText: true, to: pasteboard))
        #expect(pasteboard.string(forType: .string)?.contains("##") == false)
        #expect(MeetingLibraryController.copyContent(markdown, plainText: false, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == markdown)
    }
}

@Suite(.serialized) @MainActor
struct ActiveMeetingPresentationTests {
    @Test(.freshHome) func liveRecordingAndPauseHaveRealStageStatesAndCannotBeDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("active-meeting-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var active = MeetingPresentation.ActiveRecording(dir: root.appendingPathComponent("meeting"), title: "Live meeting", started: Date(), paused: false, liveStatus: .live)
        let stages = MeetingPresentation.stages(active.item, active: active)
        #expect(stages.first { $0.symbol == "mic" }?.state == .active)
        #expect(stages.first { $0.symbol == "doc.text" }?.state == .active)
        active.paused = true
        let paused = MeetingPresentation.stages(active.item, active: active)
        #expect(paused.first { $0.symbol == "mic" }?.state == .paused)
        #expect(paused.first { $0.symbol == "doc.text" }?.state == .paused)
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        library.setActiveRecording(active)
        #expect(library.currentActions.isRecording)
        #expect(library.currentActions.reason(for: .delete) != nil)
        library.setActiveRecording(nil)
        #expect(!library.currentActions.isRecording)
    }
}
