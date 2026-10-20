import AppKit
import Foundation
import AppKit
import Testing
@testable import verbemo

struct MeetingPresentationTests {
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
    @Test(.speaking(.russian)) func oneMenuOrdersCopyAndRegenerationAndDisablesUntilReady() {
        let state = MeetingActionState(transcriptReady: false, summaryReady: false,
            hasAudio: true, isRecording: false, isBusy: false,
            configReadable: true, transcriptionEnabled: true, summaryEnabled: true)
        let menu = MeetingActionsMenu.make(state: state, target: NSObject(), action: NSSelectorFromString("run:"))
        #expect(menu.items.map(\.title) == ["Переименовать", "Копировать транскрипцию", "Расшифровать повторно", "Копировать сводку", "Перегенерировать сводку", "Открыть папку в Finder", "", "Удалить"])
        #expect(!menu.items[1].isEnabled)
        #expect(menu.items[2].isEnabled)
        #expect(!menu.items[3].isEnabled)
        #expect(!menu.items[4].isEnabled)
        #expect(menu.items[4].toolTip != nil)
    }
    @Test func textAndMarkdownCopyHaveDifferentContents() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let markdown = "## Heading\n\n- First\n  - Nested"
        #expect(RecordingsWindow.copyContent(markdown, plainText: true, to: pasteboard))
        #expect(pasteboard.string(forType: .string)?.contains("##") == false)
        #expect(RecordingsWindow.copyContent(markdown, plainText: false, to: pasteboard))
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
        let host = NSWindow()
        let library = RecordingsWindow(root: root, hostWindow: host)
        library.setActiveRecording(active)
        #expect(library.currentActions.isRecording)
        #expect(library.currentActions.reason(for: .delete) != nil)
        library.setActiveRecording(nil)
        #expect(!library.currentActions.isRecording)
    }
}
