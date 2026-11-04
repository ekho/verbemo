import Foundation
import AppKit
import Testing

@testable import verbemo

struct MediaImportUITests {
    @Test("An import result keeps a compact height in an empty library", .freshHome)
    @MainActor
    func finishedMessageDoesNotStretchWorkspace() throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.show()
        app.finishImport(.init())
        app.panel.contentView?.layoutSubtreeIfNeeded()
        let bar = app.activityBar
        let progress = try #require(bar.serviceRows.first { $0 is MediaImportStatusView })
        #expect(!bar.allDescendants.contains { $0 === progress })
        let messages = try #require(bar.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "activity.messages" })
        #expect(messages.toolTip?.contains("Imported 0") == true)
        #expect(bar.frame.height == 36)
        app.panel.setContentSize(.init(width: 760, height: 600))
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(bar.frame.height == 36)
        #expect(messages.convert(messages.bounds, to: bar).maxX <= bar.bounds.width)
    }

    @Test("A finished import message stays inside a narrow row and has no progress bar", .freshHome)
    @MainActor
    func finishedMessageFitsNarrowRow() throws {
        let view = MediaImportStatusView(frame: .init(x: 0, y: 0, width: 350, height: 50))
        var result = MediaImportCoordinator.Result()
        result.failures = [.init(source: URL(fileURLWithPath: "/tmp/long-meeting-name.wav"),
                                 message: String(repeating: "Could not open this audio file.\n", count: 8))]
        view.finish(result)
        view.layoutSubtreeIfNeeded()
        let label = try #require(view.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        let bar = try #require(view.arrangedSubviews.compactMap { $0 as? NSProgressIndicator }.first)
        #expect(label.frame.height <= 22)
        #expect(label.frame.minX >= 0 && label.frame.maxX <= view.bounds.width)
        #expect(!label.stringValue.contains("\n"))
        #expect(label.toolTip?.contains(result.failures[0].message) == true)
        #expect(bar.isHidden)
    }
    @Test("The header and status menu use the same Import command", .freshHome)
    @MainActor
    func importEntryPoints() throws {
        let app = ApplicationWindow()
        let menu = MenuBarController(visible: false)
        var requests = 0
        app.onChooseImport = { requests += 1 }
        menu.onImport = app.onChooseImport
        let button = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "journal.import" })
        #expect(button.isBordered)
        button.performClick(nil)
        #expect(menu.performOfferedItem(titled: "Import recording…"))
        #expect(requests == 2)
    }

    @Test("Live import progress finishes in the status row with a dismiss action", .freshHome)
    @MainActor
    func importProgressCompletesInPlace() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        app.update(state: .recording, elapsed: "00:10")
        app.showActiveRecording()
        let panel = app.panel
        app.updateImport(.init(source: URL(fileURLWithPath: "/tmp/interview.mov"),
            index: 1, total: 1, stage: .checking, fraction: nil))
        let progress = try #require(app.activityBar.serviceRows.first { $0 is MediaImportStatusView })
        let cancel = try #require(progress.allDescendants.compactMap { $0 as? NSButton }.first)
        #expect(!progress.isHidden)
        #expect(!cancel.isHidden)
        var requests = 0
        app.onCancelImport = { requests += 1 }
        #expect(NSApp.sendAction(try #require(cancel.action), to: cancel.target, from: cancel))
        #expect(requests == 1)
        #expect(!cancel.isEnabled)
        app.updateImport(.init(source: URL(fileURLWithPath: "/tmp/interview.mov"),
            index: 1, total: 1, stage: .normalizing, fraction: 0.5))
        #expect(progress.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Cancelling import…" })
        app.finishImport(.init())
        #expect(cancel.isEnabled)
        #expect(!cancel.isHidden && cancel.image != nil && cancel.title.isEmpty)
        #expect(progress.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Imported 0" })
        #expect(progress.window == nil, "The result stays in the closed message popover")
        #expect(!panel.isVisible, "Progress must not reopen the window")
        #expect(NSApp.sendAction(try #require(cancel.action), to: cancel.target, from: cancel))
        #expect(progress.isHidden)
        #expect(requests == 1, "Dismissal must not cancel another import")
    }

    @Test("Import progress names the file and its place in a multi-file queue")
    func progressCopy() {
        let source = URL(fileURLWithPath: "/tmp/interview.mov")
        let update = MediaImportCoordinator.Update(
            source: source, index: 2, total: 4, stage: .normalizing, fraction: 0.375)

        let copy = MediaImportPresentation.progress(update)
        #expect(copy.label.contains("2 of 4"))
        #expect(copy.label.contains("interview.mov"))
        #expect(copy.fraction == 0.375)
        #expect(copy.progressLabel.hasSuffix("37%"))
    }

    @Test("Import completion distinguishes successes, duplicates and failures")
    func completionCopy() {
        var result = MediaImportCoordinator.Result()
        result.imported = [.init(source: URL(fileURLWithPath: "/tmp/a.mp3"),
                                 session: URL(fileURLWithPath: "/tmp/session"))]
        result.duplicates = [.init(source: URL(fileURLWithPath: "/tmp/a-copy.mp3"),
                                   existingSession: URL(fileURLWithPath: "/tmp/session"))]
        result.failures = [.init(source: URL(fileURLWithPath: "/tmp/silent.mov"),
                                 message: "no audio")]

        let copy = MediaImportPresentation.finished(result)
        #expect(copy.label.contains("Imported 1"))
        #expect(copy.label.contains("1 already here"))
        #expect(copy.label.contains("1 failed"))
        #expect(copy.label.contains("silent.mov: no audio"))
        #expect(copy.fraction == 1)
    }


}
