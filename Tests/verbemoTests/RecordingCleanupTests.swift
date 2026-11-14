import AppKit
import Foundation
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct RecordingCleanupTests {
    private let instant = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!
    private func root() throws -> URL {
        let root = Home.current.url.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func fixture(_ name: String, in root: URL, started: String = "2026-11-13T12:00:00Z",
                         files: [String: String] = ["mic": "mic.caf"]) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["started": started, "title": name, "files": files])
            .write(to: dir.appendingPathComponent("meta.json"))
        for name in files.values where !name.contains("/") {
            try Data("synthetic audio".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }
    private func config(_ mode: String = "audio") -> [String: Any] { ["cleanup": ["mode": mode, "days": 1]] }
    private func recycle(_ source: URL, completion: @MainActor @Sendable (URL?, Error?) -> Void) {
        do {
            let trash = Home.current.url.appendingPathComponent("fixture-trash/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            completion(destination, nil)
        } catch { completion(nil, error) }
    }

    @Test(.freshHome) func policyRequiresExplicitModeAndPositiveWholeDays() async throws {
        #expect(try RecordingCleanup.policy(in: [:]) == nil)
        #expect(try RecordingCleanup.policy(in: ["cleanup": ["days": 30]]) == nil)
        for mode in ["audio", "recording"] {
            #expect(try RecordingCleanup.policy(in: config(mode))?.mode.rawValue == mode)
            for bad: Any in [0, -1, 1.5, true, "30", Int.max] {
                #expect(throws: (any Error).self) { try RecordingCleanup.policy(in: ["cleanup": ["mode": mode, "days": bad]]) }
            }
        }
        #expect(throws: (any Error).self) { try RecordingCleanup.policy(in: ["cleanup": ["mode": "recording"]]) }
        let root = try root(), dir = try fixture("untouched", in: root)
        let controller = RecordingCleanupController(root: { root }, config: { [:] }, recycle: { _, done in Issue.record("Disabled cleanup moved data"); done(nil, CocoaError(.fileWriteUnknown)) })
        await controller.request()?.value
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(!FileManager.default.fileExists(atPath: controller.reportURL.path))
    }

    @Test(.freshHome) func exactAgeBoundaryUsesStartAndSkipsUnknownDates() async throws {
        let root = try root()
        let boundary = try fixture("boundary", in: root)
        let younger = try fixture("younger", in: root, started: "2026-11-13T12:00:00.001Z")
        let corrupt = try fixture("corrupt", in: root, started: "yesterday")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: younger.path)
        let controller = RecordingCleanupController(root: { root }, config: { config() }, now: { instant }, recycle: recycle)
        await controller.request()?.value
        #expect(SessionInventory.item(for: boundary)?.hasAudio == false)
        #expect(SessionInventory.item(for: younger)?.hasAudio == true)
        #expect(SessionInventory.item(for: corrupt)?.hasAudio == true)
        #expect(try String(contentsOf: controller.reportURL, encoding: .utf8).contains("corrupt"))
    }

    @Test(.freshHome) func busyQueueClaimsRecordingAndOpenSelectionArePreserved() async throws {
        let root = try root(), operations = ProcessingOperations()
        let queued = try fixture("queued", in: root), claimed = try fixture("claimed", in: root)
        let recording = try fixture("recording", in: root), selected = try fixture("selected", in: root)
        let hidden = try fixture(".import-fixture", in: root)
        let ticket = try operations.register(session: queued, kind: .transcription)
        try SessionClaim.acquire(claimed, stage: .finish)
        try Data().write(to: recording.appendingPathComponent(".recording.json"))
        let controller = RecordingCleanupController(root: { root }, operations: operations, config: { config("recording") },
            busy: { $0.path == selected.standardizedFileURL.resolvingSymlinksInPath().path }, now: { instant }, recycle: { url, done in
                Issue.record("Busy data moved: \(url.path)")
                done(nil, CocoaError(.fileWriteUnknown))
            })
        await controller.request()?.value
        for dir in [queued, claimed, recording, selected, hidden] { #expect(FileManager.default.fileExists(atPath: dir.path)) }
        SessionClaim.release(claimed)
        await operations.cancelAndWait(ticket.id)
    }

    @Test(.freshHome) func allAudioIsRemovedWhileEveryDocumentAndVersionSurvives() async throws {
        let root = try root()
        let dir = try fixture("multi-track", in: root, files: ["mic": "mic.m4a", "system": "system.m4a", "call_one": "call_one.m4a", "source": "source.m4a"])
        let call = CallAudioMetadata(integrationID: "ktalk", callID: "synthetic", periods: [], tracks: [
            .init(fileKey: "call_one", sourceID: "synthetic", speakerID: "call_one", participantID: "fixture",
                  name: "Participant", isLocal: false, generation: 1, sampleRate: 16_000)])
        try SessionState.amend(dir, with: ["archived_from": ["mic": "mic.caf", "call_one": "call_one.caf"],
            "start_offset_ms": ["call_one": 0], "call_audio": try call.jsonValue()])
        for name in ["mic.caf", "call_one.caf", "mixed.m4a", "mixed.tmp.m4a", "multichannel.m4a", "audio.tmp.m4a", "diarization-source-call_one.caf", ".archive-fixture.m4a"] {
            try Data("cached audio".utf8).write(to: dir.appendingPathComponent(name))
        }
        let documents = ["meta.json", "transcript.json", "transcript.md", "summary.md", "speakers.json", "notes.md", "transcripts/v1/transcript.json", "transcripts/v1/summary.md", "transcripts/index.json", "processing.json", "diarization.json"]
        var expected: [String: Data] = [:]
        for name in documents {
            let url = dir.appendingPathComponent(name)
            if name != "meta.json" {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(("preserve " + name).utf8).write(to: url)
            }
            expected[name] = try Data(contentsOf: url)
        }
        let controller = RecordingCleanupController(root: { root }, config: { config() }, now: { instant }, recycle: recycle)
        await controller.request()?.value
        for (name, data) in expected { #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == data) }
        #expect(try RecordingCleanup.audioFiles(in: dir, meta: SessionState.read(dir) ?? [:]).isEmpty)
        #expect(SessionInventory.item(for: dir)?.hasAudio == false)
        #expect(MeetingPlaybackView.sources(in: dir).isEmpty)
        #expect(PostProcessor.obstacleToTranscribing(dir) != nil)
        let report = try String(contentsOf: controller.reportURL, encoding: .utf8)
        #expect(report.contains("call_one.m4a") && report.contains("fixture-trash"))
    }

    @Test(.freshHome) func partialFailureRetryAndAudioRecoveryUseActualRemainingFiles() async throws {
        let root = try root(), dir = try fixture("partial", in: root, files: ["mic": "mic.caf", "system": "system.caf"])
        let allowRetry = Flag()
        var restored: [(URL, URL)] = []
        let controller = RecordingCleanupController(root: { root }, config: { config() }, now: { instant }, recycle: { source, done in
            if !allowRetry.isRaised && source.lastPathComponent == "system.caf" { done(nil, CocoaError(.fileWriteNoPermission)); return }
            recycle(source) { destination, error in
                if let destination { restored.append((source, destination)) }
                done(destination, error)
            }
        })
        await controller.request()?.value
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        #expect(SessionInventory.item(for: dir)?.hasAudio == true)
        #expect(!SessionClaim.isHeld(dir))
        #expect(controller.status.contains("1"))
        allowRetry.raise()
        await controller.request()?.value
        #expect(restored.count == 2)
        #expect(SessionInventory.item(for: dir)?.hasAudio == false)
        await controller.request()?.value
        #expect(restored.count == 2)
        await controller.stopForTermination().value
        for (original, trash) in restored { try FileManager.default.moveItem(at: trash, to: original) }
        #expect(SessionInventory.item(for: dir)?.hasAudio == true)
        #expect(MeetingPlaybackView.sources(in: dir).count == 2)
    }

    @Test(.freshHome) func entireRecordingCanBeRestoredWithoutStaleClaim() async throws {
        let root = try root(), dir = try fixture("whole", in: root)
        let original = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        var destination: URL?
        let controller = RecordingCleanupController(root: { root }, config: { config("recording") }, now: { instant }, recycle: { source, done in
            recycle(source) { url, error in destination = url; done(url, error) }
        })
        await controller.request()?.value
        let trash = try #require(destination)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(!SessionClaim.isHeld(trash))
        await controller.request()?.value
        await controller.stopForTermination().value
        try FileManager.default.moveItem(at: trash, to: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("meta.json")) == original)
        #expect(SessionInventory.item(for: dir)?.hasAudio == true)
    }

    @Test(.freshHome) func unsafePathsAndSymlinksCannotDeleteOutsideDataOrDocuments() async throws {
        let root = try root(), outside = Home.current.url.appendingPathComponent("outside.caf")
        try Data("keep outside".utf8).write(to: outside)
        let linked = try fixture("linked", in: root)
        try FileManager.default.removeItem(at: linked.appendingPathComponent("mic.caf"))
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("mic.caf"), withDestinationURL: outside)
        _ = try fixture("traversal", in: root, files: ["mic": "../../outside.caf"])
        let document = try fixture("document", in: root, files: ["mic": "transcript.md"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder"), withDestinationURL: document)
        let controller = RecordingCleanupController(root: { root }, config: { config() }, now: { instant }, recycle: { _, done in Issue.record("Unsafe item moved"); done(nil, CocoaError(.fileWriteUnknown)) })
        await controller.request()?.value
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep outside")
        #expect(FileManager.default.fileExists(atPath: document.appendingPathComponent("transcript.md").path))
    }

    @Test(.freshHome) func reportWriteFailurePreventsDeletion() async throws {
        let root = try root(), dir = try fixture("kept", in: root)
        let controller = RecordingCleanupController(root: { root }, config: { config() }, reportURL: dir,
            now: { instant }, recycle: { _, done in Issue.record("No recovery report"); done(nil, CocoaError(.fileWriteUnknown)) })
        await controller.request()?.value
        #expect(SessionInventory.item(for: dir)?.hasAudio == true)
        #expect(!controller.status.isEmpty)
    }

    @Test(.freshHome) func disablingPolicyBetweenMovesKeepsRemainingTracks() async throws {
        let root = try root(), dir = try fixture("disable", in: root, files: ["mic": "mic.caf", "system": "system.caf"])
        var settings = config(), count = 0
        let controller = RecordingCleanupController(root: { root }, config: { settings }, now: { instant }, recycle: { source, done in
            count += 1
            settings = [:]
            recycle(source, completion: done)
        })
        await controller.request()?.value
        #expect(count == 1)
        #expect(SessionInventory.item(for: dir)?.hasAudio == true)
        #expect(!SessionClaim.isHeld(dir))
        await controller.request()?.value
        #expect(count == 1)
    }

    @Test(.freshHome) func launchDailyNoDuplicatesAndStopAwaitsInFlightMove() async throws {
        let root = try root(), dir = try fixture("scheduled", in: root)
        var count = 0, completion: (@MainActor @Sendable (URL?, Error?) -> Void)?
        let controller = RecordingCleanupController(root: { root }, config: { config() }, now: { instant }, interval: 0.01,
            recycle: { _, done in count += 1; completion = done })
        controller.start(); controller.start()
        for _ in 0..<100 where count == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(count == 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(count == 1)
        completion?(nil, CocoaError(.fileWriteNoPermission))
        for _ in 0..<100 where count < 2 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(count == 2)
        let stopped = controller.stopForTermination(), finished = Flag()
        let waiter = Task { await stopped.value; finished.raise() }
        for _ in 0..<10 { await Task.yield() }
        #expect(!finished.isRaised)
        completion?(nil, CocoaError(.fileWriteNoPermission))
        await waiter.value
        #expect(!SessionClaim.isHeld(dir))
        controller.start(); controller.request()
        try await Task.sleep(for: .milliseconds(30))
        #expect(count == 2)
    }

    @Test(.freshHome) func changingRootBetweenMovesStopsTheOldCheck() async throws {
        let first = try root(), second = first.deletingLastPathComponent().appendingPathComponent("other-recordings")
        let old = try fixture("old", in: first, files: ["mic": "mic.caf", "system": "system.caf"])
        let other = try fixture("other", in: second)
        var current = first, count = 0
        let controller = RecordingCleanupController(root: { current }, config: { config() }, now: { instant }, recycle: { source, done in
            count += 1
            current = second
            recycle(source, completion: done)
        })
        await controller.request()?.value
        #expect(count == 1)
        #expect(SessionInventory.item(for: old)?.hasAudio == true)
        #expect(SessionInventory.item(for: other)?.hasAudio == true)
        await controller.request()?.value
        #expect(count == 2)
        #expect(SessionInventory.item(for: other)?.hasAudio == false)
    }

    @Test(.freshHome, .speaking(.english)) func libraryProtectsSelectionAndAnnouncesMissingAudio() async throws {
        let root = try root(), dir = try fixture("selected", in: root)
        let controller = RecordingCleanupController(root: { root }, config: { config() }, now: { instant }, recycle: recycle)
        await controller.request()?.value
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.show(); app.navigate(.allMeetings)
        defer { _ = library.stopForTermination(); _ = app.stopForTermination(); app.hide() }
        await library.settled()
        #expect(library.protectsFromCleanup(dir))
        let enumerated = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(library.protectsFromCleanup(enumerated))
        #expect(library.contentView.allDescendants.contains {
            $0.accessibilityRole() == .image && $0.accessibilityLabel() == "Audio not retained"
                && $0.toolTip == "Audio not retained"
        })
    }

    @Test(.freshHome, .speaking(.russian)) func storageControlsRequireAgeAndExposeBothModes() throws {
        let app = ApplicationWindow()
        defer { _ = app.stopForTermination(); app.hide() }
        app.show(); app.navigate(.storage)
        let fields = app.settings.renderedControls
        let days = try #require(fields.first { $0.identifier?.rawValue == "cleanup.days" } as? NSTextField)
        let mode = try #require(fields.first { $0.identifier?.rawValue == "cleanup.mode" } as? NSPopUpButton)
        #expect(days.stringValue.isEmpty)
        #expect(mode.titleOfSelectedItem == "Выключена")
        #expect(days.accessibilityLabel() == "Возраст в днях")
        mode.selectItem(at: 1); mode.sendAction(mode.action, to: mode.target)
        #expect(try RecordingCleanup.policy(in: Config.raw()) == nil)
        days.stringValue = "0"; days.sendAction(days.action, to: days.target)
        #expect(try RecordingCleanup.policy(in: Config.raw()) == nil)
        days.stringValue = "30"; days.sendAction(days.action, to: days.target)
        for selection in [1, 2] {
            mode.selectItem(at: selection); mode.sendAction(mode.action, to: mode.target)
            #expect(try RecordingCleanup.policy(in: Config.raw())?.days == 30)
            #expect(try RecordingCleanup.policy(in: Config.raw())?.mode == (selection == 1 ? .audio : .recording))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.panel.appearance = NSAppearance(named: appearance)
            app.panel.setContentSize(.init(width: 760, height: 600))
            app.panel.contentView?.layoutSubtreeIfNeeded()
            #expect(abs(app.panel.contentLayoutRect.width - 760) < 2)
            #expect(days.frame.width >= 100)
        }
    }
}
