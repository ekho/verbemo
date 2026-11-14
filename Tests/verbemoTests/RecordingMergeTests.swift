import AppKit
import AVFoundation
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome)
struct RecordingMergeTests {
    private var root: URL { Home.current.url.appendingPathComponent("meetings", isDirectory: true) }

    @Test func joinsRawArchiveAndImportedAudioInStableOrderWithInternalSilence() throws {
        let first = try ordinary("a", started: "2026-11-13T10:00:00Z", duration: 1.5)
        try TestAudio.writeTone(to: first.appendingPathComponent("system.caf"), seconds: 0.5, frequency: 660, sampleRate: 44_100)
        try SessionState.amend(first, with: ["files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 500]])
        let second = try ordinary("b", started: "2026-11-13T10:00:00Z", duration: 1)
        try TestAudio.write(to: second.appendingPathComponent("audio.m4a"), seconds: 1, channels: 2,
            settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]) { channel, frame in
                channel == 0 ? 0 : 0.4 * Float(sin(2 * .pi * 880 * Double(frame) / 48_000))
            }
        try SessionState.amend(second, with: ["files": ["mic": "audio.m4a", "system": "audio.m4a"],
            "start_offset_ms": ["mic": 0, "system": 0], "audio_channels": ["mic": 0, "system": 1]])
        let third = try ordinary("c", started: "2026-11-13T12:00:00Z", duration: 1)
        try SessionState.amend(third, with: ["files": ["source": "mic.caf"]])
        let originals = try snapshots([first, second, third])
        let result = try RecordingMerge.create([third, second, first], in: root)
        #expect(try snapshots([first, second, third]) == originals)
        let meta = try #require(SessionState.read(result))
        let origins = try #require(meta["merge"] as? [[String: Any]])
        #expect(origins.compactMap { $0["session"] as? String } == ["a", "b", "c"])
        #expect(origins.compactMap { $0["offset_ms"] as? Int } == [0, 1500, 2500])
        #expect(meta["duration_seconds"] as? Int == 3)
        #expect(SessionInventory.scan(root: root).first { $0.dir.lastPathComponent == result.lastPathComponent }?.duration == 3)
        #expect(try RecordingMerge.inspect([result, first]).parts.first { $0.dir.lastPathComponent == result.lastPathComponent }?.durationMs == 3500)
        #expect(meta["calendar"] == nil)
        let samples = try samples(result.appendingPathComponent("source.m4a"))
        #expect(samples.count >= 168_000)
        #expect(energy(samples, from: 0.1, to: 0.4) > 0.01)
        #expect(energy(samples, from: 0.65, to: 0.9) > 0.01)
        #expect(energy(samples, from: 1.1, to: 1.4) < 0.0001)
        #expect(energy(samples, from: 1.7, to: 2.2) > 0.001, "The right channel of the shared archive must survive")
        #expect(energy(samples, from: 2.7, to: 3.2) > 0.01)
        #expect(!FileManager.default.fileExists(atPath: result.appendingPathComponent("transcript.json").path))
        #expect(!FileManager.default.fileExists(atPath: result.appendingPathComponent("summary.md").path))
        #expect(!FileManager.default.fileExists(atPath: result.appendingPathComponent("transcripts").path))
    }

    @Test @MainActor func hybridTracksKeepProvenanceAndUseExistingPlaybackAndProcessing() async throws {
        let first = try participant("first", participantID: "person-a", started: "2026-11-13T10:00:00Z")
        let second = try participant("second", participantID: "person-b", started: "2026-11-13T10:00:00.500Z")
        let calendar: [String: Any] = ["event_id": "event", "association": "confirmed", "title": "Synthetic meeting",
            "scheduled_start": "2026-11-13T10:00:00Z", "attendees": ["Synthetic"]]
        for dir in [first, second] { try SessionState.amend(dir, with: ["calendar": calendar]) }
        let before = try snapshots([first, second])
        let result = try RecordingMerge.create([second, first], in: root)
        let meta = try SessionMeta.read(from: result)
        let known = try #require(meta.callAudio)
        #expect(known.tracks.count == 2)
        #expect(Set(known.tracks.map(\.speakerID)).count == 2)
        #expect(known.tracks.map(\.participantID) == ["person-a", "person-b"])
        #expect(known.tracks.map(\.sourceID) == ["original-track", "original-track"])
        #expect(meta.tracks.filter { $0.participant != nil }.map(\.offsetMs) == [100, 1100])
        #expect(meta.tracks.contains { $0.speaker == "speaker" })
        #expect(MeetingCalendarMetadata.read(from: result)?.eventID == "event")
        #expect(try Data(contentsOf: result.appendingPathComponent(known.tracks[0].fileKey + ".caf"))
            == Data(contentsOf: first.appendingPathComponent("call_voice.caf")))
        for input in [TranscriptionInput.perTrack, .mixed, .multichannel] {
            let engine = FakeEngine("test", input: input)
            let segments = try await TranscriptionInputs(session: result, audio: result, meta: meta, engine: engine).segments()
            #expect(engine.counts.heard.count == 3)
            #expect(segments.contains { $0.speaker == known.tracks[1].speakerID && $0.start_ms == 1100 })
        }
        try TrackCompressor.compressParticipantTracks(sessionDir: result)
        #expect(try SessionMeta.read(from: result).tracks.allSatisfy { $0.file.hasSuffix(".m4a") })
        let item = try await MeetingPlaybackView.makeItem(MeetingPlaybackView.sources(in: result), isMerged: true)
        #expect(abs(try await item.asset.load(.duration).seconds - 2) < 0.05)
        try Home.current.writeConfig(["offline_echo_cancellation": false, "transcription": ["local_diarization": false],
            "summary": ["enabled": false], "speaker_names": ["enabled": false]])
        try await TranscriptionCoordinator(engine: FakeEngine("whisper"), onStop: { nil }).transcribeNow(result)
        let transcript = try #require(PostProcessor.readTranscript(result))
        #expect(transcript.segments.count == 3)
        #expect(TranscriptVersions.read(result).count == 1)
        #expect(SpeakerNames.read(from: result)?.speakers[known.tracks[0].speakerID]?.participantID == "person-a")
        #expect(try snapshots([first, second]) == before)
    }

    @Test @MainActor func directOnlyPlaybackKeepsTailSilenceAndDoesNotAttenuateSequentialParts() async throws {
        let first = try participant("first", participantID: "a", started: "2026-11-13T10:00:00Z")
        let second = try participant("second", participantID: "b", started: "2026-11-13T10:01:00Z")
        for dir in [first, second] {
            try SessionState.amend(dir, with: ["files": ["call_voice": "call_voice.caf"], "start_offset_ms": ["call_voice": 100]])
        }
        let result = try RecordingMerge.create([second, first], in: root)
        let sources = MeetingPlaybackView.sources(in: result)
        #expect(sources.count == 2)
        #expect(try SessionMeta.read(from: result).tracks.allSatisfy { $0.participant != nil })
        let item = try await MeetingPlaybackView.makeItem(sources, isMerged: true)
        let duration = try await item.asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.01)
        for parameters in try #require(item.audioMix?.inputParameters) {
            var start: Float = 0, end: Float = 0, range = CMTimeRange.zero
            #expect(parameters.getVolumeRamp(for: CMTime(seconds: 1.2, preferredTimescale: 1000),
                startVolume: &start, endVolume: &end, timeRange: &range))
            #expect(start == 1 && end == 1)
        }
    }

    @Test func calendarIsDroppedForAConflictOrAMissingAssociation() throws {
        let first = try ordinary("first"), second = try ordinary("second")
        try SessionState.amend(first, with: ["calendar": ["event_id": "one", "title": "Same title"]])
        for calendar: [String: String]? in [nil, ["event_id": "two", "title": "Same title"]] {
            try SessionState.amend(second, with: ["calendar": calendar])
            let result = try RecordingMerge.create([first, second], in: root)
            #expect(SessionState.read(result)?["calendar"] == nil)
        }
    }

    @Test func writeFailureAndCancellationDoNotPublishOrChangeSourcesAndRetryWorks() async throws {
        let first = try ordinary("first"), second = try ordinary("second")
        let before = try snapshots([first, second])
        #expect(throws: CocoaError.self) {
            try RecordingMerge.create([first, second], in: root) { file, buffer in
                try file.write(from: buffer)
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        #expect(try snapshots([first, second]) == before)
        let destination = root
        let cancelled = Task {
            try RecordingMerge.create([first, second], in: destination) { file, buffer in
                try file.write(from: buffer)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled merge was published") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(try snapshots([first, second]) == before)
        #expect(SessionInventory.sessionFolders(in: root).count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".merge-") })
        _ = try RecordingMerge.create([first, second], in: root)
        #expect(SessionInventory.sessionFolders(in: root).count == 3)
    }

    @Test func refusesBusyMissingChangedAndEscapingSources() throws {
        let first = try ordinary("first"), second = try ordinary("second")
        try SessionClaim.acquire(second, stage: .transcribe)
        #expect(throws: SessionClaim.Busy.self) { try RecordingMerge.create([first, second], in: root) }
        #expect(!SessionClaim.isHeld(first))
        SessionClaim.release(second)
        let plan = try RecordingMerge.inspect([first, second])
        try SessionState.amend(second, with: ["title": "Changed during confirmation"])
        #expect(throws: RecordingMerge.Unavailable.self) { try RecordingMerge.create([first, second], in: root, expected: plan) }
        let operations = ProcessingOperations()
        _ = try operations.register(session: second, kind: .transcription)
        #expect(throws: RecordingMerge.Unavailable.self) { try RecordingMerge.create([first, second], in: root, operations: operations) }
        try SessionState.amend(second, with: ["files": ["source": "../first/mic.caf"]])
        #expect(throws: (any Error).self) { try RecordingMerge.create([first, second], in: root) }
        try SessionState.amend(second, with: ["files": ["mic": "missing.caf"]])
        #expect(throws: (any Error).self) { try RecordingMerge.create([first, second], in: root) }
        #expect(SessionInventory.sessionFolders(in: root).count == 2)
        #expect(!SessionClaim.isHeld(first) && !SessionClaim.isHeld(second))
    }

    @Test func interruptedStagingStaysHiddenAndARepeatRunRemovesOnlyDeadOwners() throws {
        let first = try ordinary("first"), second = try ordinary("second")
        let abandoned = root.appendingPathComponent(".merge-2147483647-test")
        let live = root.appendingPathComponent(".merge-\(ProcessInfo.processInfo.processIdentifier)-test")
        for dir in [abandoned, live] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        }
        #expect(SessionInventory.sessionFolders(in: root).count == 2)
        _ = try RecordingMerge.create([first, second], in: root)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(SessionInventory.sessionFolders(in: root).count == 3)
    }

    @Test(.speaking(.russian)) @MainActor
    func nativeMergeConfirmationPreservesLanguageAndTerminationClosesTheSheet() async throws {
        _ = try ordinary("first"); _ = try ordinary("second")
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        defer { _ = library.stopForTermination(); app.hide() }
        app.show()
        let table = try #require(library.listContentView.allDescendants.compactMap { $0 as? MeetingTableView }.first)
        func beginMerge() throws {
            table.selectAll(nil)
            let menu = try #require(table.menu)
            library.menuWillOpen(menu)
            let merge = try #require(menu.items.first { $0.action == NSSelectorFromString("mergeClicked") })
            #expect(merge.isEnabled)
            #expect(NSApp.sendAction(try #require(merge.action), to: merge.target, from: merge))
        }
        try beginMerge()
        for _ in 0..<100 where app.panel.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
        let sheet = try #require(app.panel.attachedSheet)
        app.panel.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        for _ in 0..<200 where library.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!library.isProcessing)
        let result = try #require(SessionInventory.scan(root: root).first { $0.name.contains("Merged-") })
        #expect(result.title?.hasPrefix("Объединено · ") == true)
        #expect(library.selectedMeetings.map { $0.dir.lastPathComponent } == [result.name])
        try beginMerge()
        for _ in 0..<100 where app.panel.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(app.panel.attachedSheet != nil)
        for task in library.stopForTermination() { await task.value }
        #expect(app.panel.attachedSheet == nil)
        #expect(SessionInventory.scan(root: root).count == 3)
    }

    private func ordinary(_ name: String, started: String = "2026-11-13T10:00:00Z", duration: Double = 1) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TestAudio.writeTone(to: dir.appendingPathComponent("mic.caf"), seconds: 1, frequency: 220, sampleRate: 16_000)
        try JSONSerialization.data(withJSONObject: ["started": started, "duration_seconds": duration,
            "title": name, "files": ["mic": "mic.caf"], "start_offset_ms": ["mic": 0]])
            .write(to: dir.appendingPathComponent("meta.json"))
        try SessionFixture.transcript.write(to: dir)
        try Data("Manually edited summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try TranscriptVersions.archiveCurrent(dir)
        return dir
    }

    private func participant(_ name: String, participantID: String, started: String) throws -> URL {
        let dir = try ordinary(name, started: started)
        try TestAudio.writeTone(to: dir.appendingPathComponent("call_voice.caf"), seconds: 0.4, frequency: 440, sampleRate: 48_000)
        try TestAudio.writeTone(to: dir.appendingPathComponent("mic.caf"), seconds: 0.5, frequency: 220, sampleRate: 16_000)
        let info = CallAudioMetadata(integrationID: "ktalk", callID: "call-\(name)", periods: [
            .init(mode: .direct, startMs: 0, endMs: 500), .init(mode: .fallback, startMs: 500, endMs: 1000),
        ], tracks: [.init(fileKey: "call_voice", sourceID: "original-track", speakerID: "call_speaker",
            participantID: participantID, name: "Same name", isLocal: false, generation: 1, sampleRate: 48_000)])
        try SessionState.amend(dir, with: ["files": ["mic": "mic.caf", "call_voice": "call_voice.caf"],
            "start_offset_ms": ["mic": 500, "call_voice": 100], "call_audio": try info.jsonValue()])
        return dir
    }

    private func snapshots(_ dirs: [URL]) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for dir in dirs {
            let entries = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let file as URL in entries where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[file.path] = try Data(contentsOf: file)
            }
        }
        return result
    }

    private func samples(_ url: URL) throws -> [Float] {
        let reader = try AudioTrackReader(url: url, rate: 48_000)
        var result: [Float] = []
        while let chunk = try reader.next(16_384) {
            let pointer = try #require(chunk.floatChannelData?[0])
            result += Array(UnsafeBufferPointer(start: pointer, count: Int(chunk.frameLength)))
        }
        return result
    }

    private func energy(_ samples: [Float], from: Double, to: Double) -> Float {
        let values = samples.dropFirst(Int(from * 48_000)).prefix(Int((to - from) * 48_000))
        return values.reduce(0) { $0 + $1 * $1 } / Float(max(1, values.count))
    }
}
