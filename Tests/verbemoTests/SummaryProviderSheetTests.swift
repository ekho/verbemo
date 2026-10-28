import AppKit
import Foundation
import Testing
@testable import verbemo

@Suite(.serialized)
@MainActor
struct SummaryProviderSheetTests {
    @Test("A background error appears in Journal and reopening preserves the explicit choice")
    func backgroundErrorCanBeRetriedFromJournal() async throws {
        let chosen = FakeModel("openai-api") { call, _, _ in
            if call == 0 { throw LLMError.exit(1, "Not logged in") }
            return "retried"
        }
        let other = FakeModel("claude-cli", answer: "wrong provider")
        let home = Home.withModels([other, chosen])
        let recordings = try TestRecordings()
        let dir = try recordings.session("2026-10-28-120000-summary")
        defer { recordings.remove(); try? FileManager.default.removeItem(at: home.url) }
        try SessionFixture.transcript.write(to: dir)
        try Data("old summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try home.writeConfig(["summary": ["backend": "claude-cli"]])
        try await Home.$scoped.withValue(home) {
            let app = ApplicationWindow()
            let library = MeetingLibraryController(root: recordings.root, hostWindow: app.panel)
            app.libraryProvider = { library }
            app.navigate(.allMeetings)
            defer {
                _ = library.stopForTermination()
                if let attached = app.panel.attachedSheet { app.panel.endSheet(attached) }
                app.panel.orderOut(nil)
            }
            let generate = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "meeting.generate-summary" })
            #expect(generate.isEnabled)
            #expect(generate.sendAction(generate.action, to: generate.target))
            let window = try #require(app.panel.attachedSheet)
            let picker = try #require(window.contentView?.allDescendants.compactMap { $0 as? NSPopUpButton }.first)
            picker.selectItem(at: 3)
            #expect(picker.sendAction(picker.action, to: picker.target))
            let create = try #require(window.contentView?.allDescendants.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "summary.create" })
            #expect(create.sendAction(create.action, to: create.target))
            #expect(app.panel.attachedSheet == nil)
            for _ in 0..<200 where library.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!library.isProcessing)
            await library.settled()
            let errorWindow = try #require(app.panel.attachedSheet)
            #expect(errorWindow !== window)
            #expect(errorWindow.contentView?.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
                .contains { $0.contains("previous summary") } == true)
            app.panel.endSheet(errorWindow)
            errorWindow.orderOut(nil)
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "old summary")
            try home.writeConfig(["summary": ["backend": "claude-cli", "openai_base_url": "http://localhost:8181/v1"]])
            #expect(generate.isEnabled)
            #expect(generate.sendAction(generate.action, to: generate.target))
            #expect(app.panel.attachedSheet === window)
            #expect(picker.indexOfSelectedItem == 3)
            let destination = try #require(window.contentView?.allDescendants.compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "summary.destination" })
            #expect(destination.stringValue.contains("localhost:8181"))
            #expect(create.isEnabled)
            #expect(create.sendAction(create.action, to: create.target))
            for _ in 0..<200 where library.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!library.isProcessing)
            await library.settled()
            #expect(app.panel.attachedSheet == nil)
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "retried\n")
            #expect(other.callCount == 0)
            for task in library.stopForTermination() { await task.value }
            withExtendedLifetime(app) {}
        }
    }

    @Test("Starting a summary dismisses the sheet while the operation continues")
    func generationContinuesAfterDismissal() async throws {
        let entered = Gate(), release = Gate()
        let backend = LLMBackend(name: "codex-cli", model: "synthetic") { _, _ in
            entered.open()
            await release.pass()
            return "new summary"
        }
        let home = Home.sandbox(languageModels: { _ in [backend] })
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try home.writeConfig(["summary": ["backend": "codex-cli"]])
        try Data("old summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try await Home.$scoped.withValue(home) {
            _ = NSApplication.shared
            let parent = NSWindow()
            parent.isReleasedWhenClosed = false
            var completions = 0
            let sheet = SummaryRegenerationSheet(run: { request in
                defer { entered.open() }
                try await PostProcessor.regenerateSummary(dir, request: request)
            }, onFailure: { error in Issue.record("Unexpected failure: \(error)") }, completion: { completions += 1 })
            parent.beginSheet(sheet.window, completionHandler: nil)
            defer {
                release.open()
                if let attached = parent.attachedSheet { parent.endSheet(attached) }
                parent.orderOut(nil)
            }
            sheet.start()
            let task = try #require(sheet.task)
            #expect(parent.attachedSheet == nil)
            #expect(!sheet.window.isVisible)
            await entered.pass()
            #expect(completions == 0)
            #expect(SessionClaim.isHeld(dir))
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "old summary")
            release.open()
            await task.value
            #expect(completions == 1)
            #expect(!SessionClaim.isHeld(dir))
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "new summary\n")
        }
    }

    @Test func pickerKeepsSelectionForExplicitRetry() async throws {
        let chosen = FakeModel("codex-cli") { call, _, _ in
            if call == 0 { throw LLMError.exit(1, "Not logged in") }
            return "retried"
        }
        let other = FakeModel("claude-cli", answer: "wrong provider")
        let home = Home.withModels([other, chosen])
        let dir = try SessionFixture.make()
        defer { for url in [home.url, dir] { try? FileManager.default.removeItem(at: url) } }
        try home.writeConfig(["summary": ["backend": "claude-cli"]])
        try Data("old".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try await Home.$scoped.withValue(home) {
            let sheet = SummaryRegenerationSheet(run: { request in
                try await PostProcessor.regenerateSummary(dir, request: request)
            }, onFailure: { _ in }, completion: {})
            sheet.picker.selectItem(at: 1)
            sheet.selectionChanged()
            #expect(sheet.disclosure.stringValue.contains("Codex"))
            sheet.start()
            await sheet.task?.value
            #expect(sheet.picker.indexOfSelectedItem == 1)
            #expect(sheet.create.isEnabled)
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "old")
            try home.writeConfig(["summary": ["backend": "claude-cli", "enabled": false]])
            sheet.start()
            await sheet.task?.value
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "retried\n")
            #expect(other.callCount == 0)
        }
    }

    @Test func oneRunChoiceIsAvailableWithAutomaticSummaryDisabled() {
        let state = MeetingActionState(transcriptReady: true, summaryReady: false, hasAudio: false,
            isRecording: false, isBusy: false, configReadable: true, transcriptionEnabled: false, summaryEnabled: false)
        #expect(state.reason(for: .regenerateSummary) == nil)
    }
}
