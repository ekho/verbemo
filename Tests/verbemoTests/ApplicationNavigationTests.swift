import Foundation
import AppKit
import Testing
@testable import verbemo

struct ApplicationNavigationTests {
    @Test func settingsPreserveMeetingContextAndExplicitAllClearsSearch() {
        var state = ApplicationNavigationState()
        state.selectedSession = URL(fileURLWithPath: "/fixture/meeting")
        state.versionKey = "v1"
        state.resultTab = "transcript"
        state.query = "Анна"
        state.navigate(.transcription)
        state.navigate(.allMeetings)
        #expect(state.selectedSession != nil)
        #expect(state.versionKey == "v1")
        #expect(state.resultTab == "transcript")
        #expect(state.query == "Анна")
        state.showAllMeetings()
        #expect(state.query.isEmpty)
        #expect(!state.showsDetail)
    }
}

@Suite(.serialized)
@MainActor
struct ApplicationWindowTests {
    @Test(.freshHome, .speaking(.russian)) func changingPagesKeepsNarrowWindowSize() async {
        let app = ApplicationWindow()
        defer { app.hide() }
        app.panel.setContentSize(NSSize(width: 760, height: 680))
        app.show()
        for page in [ApplicationNavigationState.Destination.general, .recording, .transcription, .summary, .storage, .about] {
            app.navigate(page)
            app.panel.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
            #expect(app.panel.contentLayoutRect.width <= 762, "\(page)")
        }
    }
    @Test(.freshHome) func workspaceFillsAvailableWidthAfterLayout() throws {
        let app = ApplicationWindow()
        let library = RecordingsWindow(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let available = try #require(app.panel.contentView).bounds.width - 190
        #expect(library.contentView.bounds.width >= available - 2)
        let split = try #require(library.contentView.allDescendants.compactMap { $0 as? NSSplitView }.first)
        #expect(split.bounds.width >= available - 32)
        let heading = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 22 && !$0.isHiddenOrHasHiddenAncestor })
        #expect(heading.bounds.width >= heading.fittingSize.width)
    }
    @Test(.freshHome) func reopeningRefreshesMeetingsChangedWhileHidden() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = ApplicationWindow()
        let library = RecordingsWindow(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        let table = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTableView }.first)
        app.hide()
        let meeting = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try Data("{\"title\":\"New meeting\"}".utf8).write(to: meeting.appendingPathComponent("meta.json"))
        library.sessionsChanged()
        app.show()
        await library.settled()
        #expect(table.numberOfRows == 1)
        app.hide()
        try FileManager.default.removeItem(at: meeting)
        library.sessionsChanged()
        app.bringToFront()
        await library.settled()
        #expect(table.numberOfRows == 0)
        app.hide()
    }
    @Test(.freshHome) func importProgressDoesNotChangePageOrRevealHiddenWindow() {
        let app = ApplicationWindow()
        app.navigate(.general)
        app.hide()
        app.updateImport(.init(source: URL(fileURLWithPath: "/fixture.wav"), index: 1, total: 1, stage: .normalizing, fraction: 0.5))
        #expect(app.navigation.destination == .general)
        #expect(!app.panel.isVisible)
    }
    @Test(.freshHome) func currentRecordingCanReturnThroughTheMainHeading() throws {
        let app = ApplicationWindow()
        app.update(state: .recording, elapsed: "01:00")
        app.showActiveRecording()
        let heading = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }.first { $0.font?.pointSize == 22 })
        #expect(heading.isEnabled)
    }
    @Test(.freshHome) func destinationsShareOneWindowAndAboutHasNoToolbar() {
        let app = ApplicationWindow()
        let panel = app.panel
        for destination in ApplicationNavigationState.Destination.allCases {
            app.navigate(destination)
            #expect(app.panel === panel)
            #expect(app.toolbarIsHidden == (destination == .about))
            #expect(app.primaryActionsAreVisible == (destination == .allMeetings))
        }
        app.update(state: .recording, elapsed: "04:32")
        app.navigate(.general)
        #expect(app.recordingBarIsVisible)
        app.update(state: .idle, elapsed: nil)
        #expect(!app.recordingBarIsVisible)
    }
}
