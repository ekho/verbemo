import AppKit
import Foundation
import Testing
@testable import verbemo

@Suite(.serialized)
@MainActor
struct SummaryProviderSheetTests {
    @Test("A background summary leaves summary, transcription and calendar actions available for other meetings")
    func summaryDoesNotBlockOtherMeetings() async throws {
        let entered = Flag(), release = Gate()
        let backend = LLMBackend(name: "codex-cli", model: "synthetic") { _, content in
            if content.contains("First meeting") {
                entered.raise()
                await release.pass()
                return "first summary"
            }
            return "second summary"
        }
        let home = Home.sandbox(languageModels: { _ in [backend] })
        let recordings = try TestRecordings()
        defer { recordings.remove(); try? FileManager.default.removeItem(at: home.url) }
        let first = try recordings.session("2026-10-28-120000-first", state: ["title": "First meeting"])
        let second = try recordings.session("2026-10-28-130000-second")
        let audio = try recordings.session("2026-10-28-140000-audio")
        let calendar = try recordings.session("2026-10-28-150000-calendar")
        for dir in [first, second, audio] { try SessionFixture.transcript.write(to: dir) }
        try home.writeConfig(["summary": ["backend": "codex-cli"], "transcription": ["enabled": true, "diarization": ["enabled": false]]])

        try await Home.$scoped.withValue(home) {
            let app = ApplicationWindow()
            let library = MeetingLibraryController(root: recordings.root, hostWindow: app.panel)
            app.libraryProvider = { library }
            app.navigate(.allMeetings)
            app.show()
            var queued: [URL] = []
            library.onRetranscribe = { queued.append($0) }
            defer {
                release.open()
                _ = library.stopForTermination()
                if let attached = app.panel.attachedSheet { app.panel.endSheet(attached) }
                app.panel.orderOut(nil)
            }
            @MainActor func submitSummary() async throws {
                let generate = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }
                    .first { $0.identifier?.rawValue == "meeting.generate-summary" })
                try #require(generate.isEnabled)
                #expect(generate.sendAction(generate.action, to: generate.target))
                for _ in 0..<200 where app.panel.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
                let create = try #require(app.panel.attachedSheet?.contentView?.allDescendants.compactMap { $0 as? NSButton }
                    .first { $0.identifier?.rawValue == "summary.create" })
                #expect(create.sendAction(create.action, to: create.target))
                #expect(app.panel.attachedSheet == nil)
            }
            try #require(await library.reveal(first))
            try await submitSummary()
            for _ in 0..<200 where !entered.isRaised { try await Task.sleep(for: .milliseconds(10)) }
            try #require(entered.isRaised)
            #expect(library.currentActions.reason(for: .regenerateSummary) != nil)

            try #require(await library.reveal(second))
            if library.currentActions.reason(for: .regenerateSummary) == nil { try await submitSummary() }
            else { Issue.record("A running summary disabled summary generation for another meeting") }

            try #require(await library.reveal(audio))
            let transcribe = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "meeting.retranscribe" })
            #expect(transcribe.isEnabled)
            if transcribe.isEnabled {
                #expect(transcribe.sendAction(transcribe.action, to: transcribe.target))
                for _ in 0..<200 where app.panel.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
                let confirm = try #require(app.panel.attachedSheet?.contentView?.allDescendants.compactMap { $0 as? NSButton }
                    .first { $0.title == localised("Transcribe again", "Расшифровать заново") })
                for _ in 0..<200 where !confirm.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
                try #require(confirm.isEnabled)
                #expect(confirm.sendAction(confirm.action, to: confirm.target))
                for _ in 0..<200 where queued.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            }
            #expect(queued.map { $0.resolvingSymlinksInPath() } == [audio.resolvingSymlinksInPath()])
            #expect(TranscriptVersions.isRequested(audio))

            try #require(await library.reveal(calendar))
            let picker = library.calendarPicker
            #expect(picker.button.isEnabled)
            let start = Date()
            if picker.button.isEnabled {
                picker.choose(.init(id: "event", title: "Calendar event", start: start, end: start.addingTimeInterval(3600),
                    attendees: [], link: nil, looksLikeCall: false))
                await picker.settled()
            }
            #expect(MeetingCalendarMetadata.read(from: calendar)?.eventID == "event")
            #expect(SessionClaim.isHeld(first))
            #expect(library.isProcessing)

            release.open()
            for _ in 0..<200 where library.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!library.isProcessing)
            #expect(try String(contentsOf: first.appendingPathComponent("summary.md"), encoding: .utf8) == "first summary\n")
            #expect(try String(contentsOf: second.appendingPathComponent("summary.md"), encoding: .utf8) == "second summary\n")
        }
    }

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
            #expect(app.panel.attachedSheet == nil)
            app.panel.orderFront(nil)
            try app.activityBar.openServiceMessagesForTest()
            let message = try #require(app.activityBar.serviceDescendants.compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue == "meeting.operation-error"
            })
            #expect(!message.isHiddenOrHasHiddenAncestor)
            #expect(message.stringValue.contains("previous summary"))
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "old summary")
            try home.writeConfig(["summary": ["backend": "claude-cli", "openai_base_url": "http://localhost:8181/v1"]])
            #expect(generate.isEnabled)
            #expect(generate.sendAction(generate.action, to: generate.target))
            #expect(message.isHidden)
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
