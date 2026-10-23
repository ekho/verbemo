import AppKit
import Foundation
import Testing
@testable import verbemo

@MainActor
struct MeetingProcessingCancellationTests {
    @Test("Journal targets only app-owned runs of the canonical selected meeting")
    func targetsAndWaitingCancellation() async throws {
        let operations = ProcessingOperations()
        let a = URL(fileURLWithPath: "/synthetic/a")
        let first = try operations.register(session: a, kind: .transcription)
        _ = try operations.register(session: a, kind: .summary)
        let second = try operations.register(session: URL(fileURLWithPath: "/synthetic/b"), kind: .summary)
        let sweep = try operations.register(session: nil, kind: .sweep)
        let journal = MeetingProcessingCancellation(operations: operations)
        journal.select(a.appendingPathComponent("../a"))
        #expect(journal.canCancel)
        let stop = try #require(journal.cancel())
        #expect(journal.isCancelling)
        #expect(journal.cancel() == nil)
        await stop.value
        #expect(journal.outcome == .cancelled)
        #expect(!journal.canCancel && !journal.isCancelling)
        #expect(Set(operations.snapshot().map(\.id)) == [second.id, sweep.id])
        do { try await first.run {}; Issue.record("Cancelled waiting task started") }
        catch is CancellationError {}
        await operations.cancelAllAndWait()
    }

    @Test("Switching meetings and a new generation cannot receive an old completion")
    func selectionAndNewRun() async throws {
        let operations = ProcessingOperations(), entered = Gate(), release = Gate(), cancelled = Gate()
        let a = URL(fileURLWithPath: "/synthetic/a"), b = URL(fileURLWithPath: "/synthetic/b")
        let first = try operations.register(session: a, kind: .diarization)
        let task = Task {
            try await first.run {
                await withTaskCancellationHandler {
                    entered.open(); await release.pass()
                } onCancel: { cancelled.open() }
                throw CancellationError()
            }
        }
        await entered.pass()
        let journal = MeetingProcessingCancellation(operations: operations)
        journal.select(a)
        let stop = try #require(journal.cancel())
        await cancelled.pass()
        journal.select(b)
        #expect(!journal.isCancelling && !journal.canCancel)
        journal.select(a)
        #expect(journal.isCancelling)
        let next = try operations.register(session: a, kind: .summary)
        journal.select(a)
        release.open(); await stop.value
        _ = try? await task.value
        #expect(journal.outcome == nil)
        #expect(journal.canCancel)
        #expect(operations.snapshot().map(\.id) == [next.id])
        await operations.cancelAllAndWait()
    }

    @Test("A newer run that finishes between polls suppresses an old cancellation callback")
    func completedNewGeneration() async throws {
        let operations = ProcessingOperations(), session = URL(fileURLWithPath: "/synthetic/a")
        _ = try operations.register(session: session, kind: .transcription)
        let journal = MeetingProcessingCancellation(operations: operations)
        journal.select(session)
        var registeredNewer = false
        journal.onChange = {
            guard !registeredNewer else { return }
            registeredNewer = true
            do {
                let newer = try operations.register(session: session, kind: .summary)
                operations.cancel(newer.id)
            } catch { Issue.record("Could not register the later generation: \(error)") }
        }
        let stop = try #require(journal.cancel())
        await stop.value
        #expect(registeredNewer)
        #expect(operations.snapshot().isEmpty)
        #expect(journal.outcome == nil, "An old result must not replace a later generation between polls")
    }

    @Test("A displayed cancellation result expires after a fast successful retry")
    func displayedOutcomeExpires() async throws {
        let operations = ProcessingOperations(), session = URL(fileURLWithPath: "/synthetic/a")
        _ = try operations.register(session: session, kind: .summary)
        let journal = MeetingProcessingCancellation(operations: operations)
        journal.select(session)
        let stop = try #require(journal.cancel())
        await stop.value
        #expect(journal.outcome == .cancelled)

        let independent = try operations.register(session: URL(fileURLWithPath: "/synthetic/b"), kind: .summary)
        try await independent.run {}
        journal.select(session)
        #expect(journal.outcome == .cancelled)

        let retry = try operations.register(session: session, kind: .summary)
        try await retry.run {}
        #expect(operations.snapshot().isEmpty)
        #expect(journal.outcome == nil, "A displayed outcome must expire even if a retry completes between polls")
        journal.select(session)
        #expect(journal.outcome == nil)
    }

    @Test("A sweep child can be cancelled while its parent and another meeting keep running")
    func sweepChild() async throws {
        let operations = ProcessingOperations(), entered = Gate(), release = Gate(), cancelled = Gate()
        let a = URL(fileURLWithPath: "/synthetic/a"), b = URL(fileURLWithPath: "/synthetic/b")
        let parent = try operations.register(session: nil, kind: .sweep)
        let other = try operations.register(session: b, kind: .summary)
        let task = Task {
            try await parent.run {
                try? await operations.run(session: a, kind: .postProcessing) {
                    await withTaskCancellationHandler {
                        entered.open(); await release.pass()
                    } onCancel: { cancelled.open() }
                    throw CancellationError()
                }
            }
        }
        await entered.pass()
        let journal = MeetingProcessingCancellation(operations: operations)
        journal.select(a)
        let stop = try #require(journal.cancel())
        await cancelled.pass()
        #expect(journal.isCancelling)
        #expect(operations.snapshot().first { $0.id == parent.id }?.state == .running)
        #expect(operations.snapshot().first { $0.id == other.id }?.state == .waiting)
        release.open(); await stop.value; try await task.value
        #expect(journal.outcome == .cancelled)
        #expect(operations.snapshot().map(\.id) == [other.id])
        #expect(operations.isAccepting)
        await operations.cancelAllAndWait()
    }
    @Test("A swallowed automatic-summary failure is not reported as completed")
    func automaticSummaryFailure() async throws {
        let entered = Gate(), release = Gate()
        let backend = LLMBackend(name: "codex-cli", model: "synthetic") { _, _ in
            entered.open(); await release.pass()
            throw LLMError.emptyResponse("synthetic")
        }
        let home = Home.sandbox(languageModels: { _ in [backend] })
        let dir = try SessionFixture.make()
        defer {
            release.open()
            for folder in [dir, home.url] { try? FileManager.default.removeItem(at: folder) }
        }
        try home.writeConfig(["summary": ["backend": "codex-cli"], "speaker_names": ["enabled": false]])
        try await Home.$scoped.withValue(home) {
            let task = Task { await PostProcessor.finish(dir, policy: .init(names: false, summary: true)) }
            await entered.pass()
            let snapshot = try #require(ProcessingOperations.shared.snapshot().first {
                $0.session == dir.standardizedFileURL.resolvingSymlinksInPath()
            })
            release.open(); _ = await task.value
            let outcome = await ProcessingOperations.shared.cancelAndWait(snapshot)
            if case .failed(let reason) = outcome { #expect(!reason.isEmpty) }
            else { Issue.record("Automatic summary failure reported as \(outcome)") }
            #expect(!SessionClaim.isHeld(dir))
        }
    }

    private actor FailedEngine: TranscriptionEngine {
        nonisolated let name = "parakeet", model = "synthetic", input = TranscriptionInput.perTrack
        nonisolated let entered = Gate(), releaseInference = Gate()
        func prepare() async throws {}
        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            entered.open(); await releaseInference.pass()
            throw CocoaError(.fileReadCorruptFile)
        }
        func release() async {}
    }

    @Test("A swallowed queued transcription failure remains a failure", .freshHome(config:
        #"{"offline_echo_cancellation":false,"transcription":{"local_diarization":false},"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
    func queuedTranscriptionFailure() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("failure")
        let operations = ProcessingOperations(), engine = FailedEngine()
        let coordinator = TranscriptionCoordinator(engine: engine, operations: operations, onStop: { nil })
        await coordinator.enqueue(dir)
        await engine.entered.pass()
        let snapshot = try #require(operations.snapshot().first { $0.session == dir.resolvingSymlinksInPath() })
        engine.releaseInference.open()
        await coordinator.waitUntilIdle()
        if case .failed = await operations.cancelAndWait(snapshot) {}
        else { Issue.record("Queued transcription failure was reported as completed") }
        #expect(!SessionClaim.isHeld(dir))
    }

}

@Suite(.serialized, .freshHome)
@MainActor
struct JournalProcessingCancellationTests {
    @Test("Journal ignores foreign claims and general work, but cancels its waiting meeting")
    func waitingActionAvailability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("2026-10-23-120000-a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["title": "Synthetic meeting"])
            .write(to: a.appendingPathComponent("meta.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let operations = ProcessingOperations()
        _ = try operations.register(session: nil, kind: .importMedia)
        try SessionClaim.acquire(a, stage: .finish)
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, operations: operations, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        let cancel = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "meeting.cancel-processing" })
        #expect(cancel.isHidden)
        #expect(!cancel.isEnabled)
        SessionClaim.release(a)
        let ticket = try operations.register(session: a, kind: .transcription)
        library.refresh()
        await library.settled()
        #expect(!cancel.isHidden && cancel.isEnabled)
        #expect(cancel.sendAction(cancel.action, to: cancel.target))
        #expect(operations.snapshot().allSatisfy { $0.id != ticket.id })
        #expect(operations.snapshot().first?.kind == .importMedia)
        #expect(operations.isAccepting)
        await operations.cancelAllAndWait()
        for task in library.stopForTermination() { await task.value }
        withExtendedLifetime(app) {}
    }

    @Test("Journal shows cancelling until claim cleanup, even after the window closes")
    func cleanupAndClosedWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("2026-10-23-120000-a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["title": "Synthetic meeting"])
            .write(to: a.appendingPathComponent("meta.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let operations = ProcessingOperations(), entered = Gate(), cancelled = Gate(), release = Gate(), finished = Gate()
        let ticket = try operations.register(session: a, kind: .summary)
        let task = Task {
            try await ticket.run {
                try SessionClaim.acquire(a, stage: .finish)
                defer { SessionClaim.release(a) }
                await withTaskCancellationHandler {
                    entered.open(); await release.pass()
                } onCancel: { cancelled.open() }
                try Task.checkCancellation()
            }
        }
        defer { release.open() }
        await entered.pass()
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, operations: operations, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        library.onActivityChange = { if operations.snapshot().isEmpty { finished.open() } }
        let cancel = try #require(library.contentView.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "meeting.cancel-processing" })
        let status = try #require(library.contentView.allDescendants.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "meeting.processing-status" })
        #expect(cancel.sendAction(cancel.action, to: cancel.target))
        await cancelled.pass()
        #expect(!cancel.isEnabled)
        #expect(status.stringValue == "Cancelling…")
        #expect(SessionClaim.isHeld(a))
        app.panel.orderOut(nil)
        release.open(); await finished.pass()
        _ = try? await task.value
        #expect(!SessionClaim.isHeld(a))
        #expect(status.stringValue.contains("cancelled"))
        #expect(operations.isAccepting)
        for task in library.stopForTermination() { await task.value }
        withExtendedLifetime(app) {}
    }
}
