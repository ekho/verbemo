import Foundation
import AppKit
import Testing

@testable import verbemo

struct MediaImportUITests {
    @Test("The sidebar and status menu use the same Import command", .freshHome)
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
        #expect(menu.performOfferedItem(titled: "Import…"))
        #expect(requests == 2)
    }

    @Test("Live import progress finishes in the main window and hides cancellation", .freshHome)
    @MainActor
    func importProgressCompletesInPlace() throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        app.update(state: .recording, elapsed: "00:10")
        app.showActiveRecording()
        let panel = app.panel
        app.updateImport(.init(source: URL(fileURLWithPath: "/tmp/interview.mov"),
            index: 1, total: 1, stage: .checking, fraction: nil))
        let progress = try #require(panel.contentView?.allDescendants.first { $0 is MediaImportStatusView })
        let cancel = try #require(progress.allDescendants.compactMap { $0 as? NSButton }.first)
        #expect(!progress.isHidden)
        #expect(!cancel.isHidden)
        var requests = 0
        app.onCancelImport = { requests += 1 }
        cancel.performClick(nil)
        #expect(requests == 1)
        app.finishImport(.init())
        #expect(cancel.isHidden)
        #expect(progress.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Imported 0" })
        #expect(progress.window === panel)
        #expect(!panel.isVisible, "Progress must not reopen the window")
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
