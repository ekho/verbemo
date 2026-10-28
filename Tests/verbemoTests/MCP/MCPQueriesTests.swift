import Foundation
import Testing
import CryptoKit
import Darwin
@testable import verbemo

@Suite(.freshHome) struct MCPQueriesTests {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: Home.current.url.path.replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored)).appendingPathComponent("mcp-library")
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try put(dir, "meta.json", #"{"title":"Planning","started":"2026-10-28T11:00:00+03:00","duration_seconds":12,"summary_stale":true,"summary_status":"failed: SECRET","files":{"source":"source.m4a"},"calendar":{"title":"Planning","agenda":"Agenda","event_url":"https://secret.example/?pass=SECRET","participants":[{"id":"p1","name":"Alex","email":"a@example.test"},{"id":"p2","name":"Alex","email":"b@example.test"}]}}"#)
        try put(dir, "transcript.json", #"{"engine":"local","model":"test","created_at":"2026-10-28T08:01:00Z","segments":[{"speaker":"them A","start_ms":0,"end_ms":1000,"text":"  Hello world!\n"},{"speaker":"them B","start_ms":1000,"end_ms":2000,"text":"Another hello."}]}"#)
        try put(dir, "speakers.json", #"{"created_at":"2026-10-28T08:01:00Z","speakers":{"them A":{"name":"Alex","source":"manual","participantID":"p1","quote":"SECRET"},"them B":{"name":"Alex","source":"manual","participantID":"p2"}}}"#)
        try put(dir, "summary.md", "# Hello summary\n")
        try put(dir, "source.m4a", "synthetic audio")
        return root
    }
    private func put(_ dir: URL, _ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
    }
    private func call(_ tool: String, _ root: URL, _ args: [String: MCPJSON] = [:]) throws -> MCPJSON {
        try MCPQueries.call(tool, arguments: args, runtime: .init(root: root))
    }
    private func id(_ root: URL) throws -> String {
        try #require(call("list_meetings", root)["items"]?.array?.first?["meeting_id"]?.string)
    }
    private func tree(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for case let file as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[file.path] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
    @Test func eightOperationsAreReadOnlyAndExact() throws {
        let root = try fixture(), before = try tree(root), meeting = try id(root)
        let card = try call("get_meeting", root, ["meeting_id": .string(meeting)])
        #expect(card["has_summary"] == .bool(true))
        #expect(card["summary_stale"] == .bool(true))
        #expect(card["participant_assignment"] == .string("complete"))
        #expect(card["participants"]?.array?.count == 2)
        #expect(card["calendar"]?["agenda"] == .string("Agenda"))
        #expect(card["processing"]?["summary"] == .string("failed"))
        #expect(!String(decoding: try card.encoded(), as: UTF8.self).contains("SECRET"))
        let versions = try call("list_transcript_versions", root, ["meeting_id": .string(meeting)])
        #expect(versions["items"]?.array?.count == 1)
        let transcript = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "start_ms": .number(500), "end_ms": .number(1001)])
        #expect(transcript["segments"]?.array?.count == 2)
        #expect(transcript["segments"]?.array?.first?["text"] == .string("  Hello world!\n"))
        #expect(transcript["segments"]?.array?.first?["speaker_id"] == .string("them A"))
        let summary = try call("get_meeting_summary", root, ["meeting_id": .string(meeting)])
        #expect(summary["markdown"] == .string("# Hello summary\n"))
        #expect(summary["source_version_id"] == .null)
        let search = try call("search_meetings", root, ["query": .string("HELLO"), "limit": .number(1)])
        #expect(search["items"]?.array?.count == 1)
        let cursor = try #require(search["next_cursor"]?.string)
        #expect(try call("search_meetings", root, ["query": .string("HELLO"), "limit": .number(1), "cursor": .string(cursor)])["items"]?.array?.count == 1)
        let audio = try call("get_meeting_audio", root, ["meeting_id": .string(meeting)])
        #expect(audio["items"]?.array?.first?["filename"] == .string("source.m4a"))
        let settings = MCPSettings(raw: ["on_stop": .string("SECRET"), "summary": .object(["openai_base_url": .string("https://u:SECRET@example.test/api?q=SECRET#SECRET")])], effective: [:], applied: [:], secretConfigured: ["mcp.token": true])
        let exported = try MCPQueries.call("get_settings", arguments: [:], runtime: .init(root: root), settings: settings)
        #expect(!String(decoding: try exported.encoded(), as: UTF8.self).contains("SECRET"))
        #expect(try tree(root) == before)
    }
    @Test func filtersUseOffsetsExclusiveEndAndSavedBindings() throws {
        let root = try fixture()
        #expect(try call("list_meetings", root, ["started_from": .string("2026-10-28T08:00:00Z")])["items"]?.array?.count == 1)
        #expect(try call("list_meetings", root, ["started_before": .string("2026-10-28T11:00:00+03:00")])["items"]?.array?.isEmpty == true)
        #expect(try call("list_meetings", root, ["participants": .array([.string("Alex"), .string("A@EXAMPLE.TEST")]), "participant_match": .string("all"), "participant_scope": .string("speaking")])["items"]?.array?.count == 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("meeting/speakers.json"))
        #expect(try call("list_meetings", root, ["participants": .array([.string("Alex")]), "participant_scope": .string("speaking")])["items"]?.array?.isEmpty == true)
    }
    @Test func malformedAndMissingArtifactsAreDifferentAndErrorsDoNotWrite() throws {
        let root = try fixture(), meeting = try id(root), dir = root.appendingPathComponent("meeting")
        try put(dir, "transcript.json", "broken")
        let before = try tree(root)
        let card = try call("get_meeting", root, ["meeting_id": .string(meeting)])
        #expect(card["has_transcript"] == .null)
        #expect(card["partial"] == .bool(true))
        #expect(try call("list_meetings", root, ["has_transcript": .bool(false)])["items"]?.array?.isEmpty == true)
        #expect(throws: MCPFailure.self) { try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)]) }
        #expect(try tree(root) == before)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.json"))
        #expect(try call("get_meeting", root, ["meeting_id": .string(meeting)])["has_transcript"] == .bool(false))
        try put(dir, ".transcript-commit", "unfinished")
        #expect(throws: MCPFailure.self) { try call("get_meeting", root, ["meeting_id": .string(meeting)]) }
    }
    @Test func cursorsAndPageBounds() throws {
        let root = try fixture(), meeting = try id(root), dir = root.appendingPathComponent("meeting")
        let first = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "limit": .number(1)])
        let cursor = try #require(first["next_cursor"]?.string)
        #expect(try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "limit": .number(1), "cursor": .string(cursor)])["segments"]?.array?.first?["segment_index"] == .number(1))
        #expect(throws: MCPFailure.self) { try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "limit": .number(2), "cursor": .string(cursor)]) }
        try put(dir, "speakers.json", #"{"created_at":"now","speakers":{}}"#)
        #expect(throws: MCPFailure.self) { try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "limit": .number(1), "cursor": .string(cursor)]) }
        let huge = Transcript(engine: "test", model: "x", created_at: "2026-10-28T00:00:00Z", segments: [.init(speaker: "me", start_ms: 0, end_ms: 1, text: String(repeating: "x", count: 70_000))])
        try JSONEncoder().encode(huge).write(to: dir.appendingPathComponent("transcript.json"))
        #expect(try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])["segments"]?.array?.first?["text"]?.string?.count == 70_000)
        try put(dir, "summary.md", String(repeating: "💡", count: 40_000))
        let summary = try call("get_meeting_summary", root, ["meeting_id": .string(meeting)])
        #expect((summary["markdown"]?.string?.utf8.count ?? 0) <= 65536)
        #expect(summary["next_cursor"]?.string != nil)
        try put(dir, "meta.json", "{\"title\":\"" + String(repeating: "x", count: 1_048_576) + "\"}")
        #expect(throws: MCPFailure.self) { try call("get_meeting", root, ["meeting_id": .string(meeting)]) }
    }
    @Test func securePathsAndPinnedAudio() throws {
        let root = try fixture(), meeting = try id(root), dir = root.appendingPathComponent("meeting")
        let items = try call("get_meeting_audio", root, ["meeting_id": .string(meeting)])
        let audioID = try #require(items["items"]?.array?.first?["audio_id"]?.string)
        let handle = try MCPLibrary.openAudio(meetingID: meeting, audioID: audioID, runtime: .init(root: root))
        try put(dir, "source.m4a", "replacement")
        #expect(throws: MCPFailure.self) { try MCPLibrary.openAudio(meetingID: meeting, audioID: audioID, runtime: .init(root: root)) }
        #expect(throws: MCPFailure.self) { try handle.read(offset: 0, count: 20) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.json"))
        try put(root, "outside-synthetic.txt", "synthetic outside data")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("transcript.json").path, withDestinationPath: root.appendingPathComponent("outside-synthetic.txt").path)
        #expect(throws: MCPFailure.self) { try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)]) }
        #expect(throws: MCPFailure.self) { try call("list_meetings", root.appendingPathComponent("absent")) }
        let pending = MCPLibrary.Runtime(root: root, pendingDeletion: { $0 == "meeting" })
        #expect(try MCPQueries.call("list_meetings", arguments: [:], runtime: pending)["items"]?.array?.isEmpty == true)
    }
    @Test func sharedContractCases() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/MCP/contract.json")
        let fixture = try JSONDecoder().decode(MCPJSON.self, from: Data(contentsOf: url))
        let root = try self.fixture()
        for test in fixture["parameter_errors"]?.array ?? [] {
            #expect(throws: MCPFailure.self) { try call(test["tool"]!.string!, root, test["arguments"]!.object!) }
        }
        for test in fixture["assignment_cases"]?.array ?? [] {
            try put(root.appendingPathComponent("meeting"), "transcript.json", String(decoding: try test["transcript"]!.encoded(), as: UTF8.self))
            #expect(try call("get_meeting", root, ["meeting_id": .string(id(root))])["participant_assignment"] == test["expected"])
        }
    }
    private func contract() throws -> MCPJSON {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/MCP/contract.json")
        return try MCPJSON.parse(Data(contentsOf: url))
    }
    @Test func sharedObservableResponses() throws {
        let root = try fixture(), meeting = try id(root)
        for (tool, expected) in try contract()["observable"]!.object! {
            let actual = try call(tool, root, ["meeting_id": .string(meeting)])
            for (key, value) in expected.object! { #expect(actual[key] == value) }
        }
    }
    @Test func semanticIDsSurviveJSONAndNamesAndSeparateGenerations() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        for vector in try contract()["semantic_ids"]!.array! {
            let bytes = try vector["transcript"]!.encoded()
            try bytes.write(to: dir.appendingPathComponent("transcript.json"))
            let generation = vector["generation"]!.string!
            if generation.isEmpty { try? FileManager.default.removeItem(at: dir.appendingPathComponent("diarization.json")) }
            else {
                let timeline = MCPJSON.object(["schemaVersion": .number(1), "transcriptSHA256": .string(MCPContract.hash(bytes)), "generationFingerprint": .string(generation)])
                try timeline.encoded().write(to: dir.appendingPathComponent("diarization.json"))
            }
            let response = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
            #expect(response["version_id"] == vector["expected"])
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("diarization.json"))
        let before = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: dir.appendingPathComponent("transcript.json"))
        try put(dir, "speakers.json", #"{"created_at":"now","speakers":{"them A":{"name":"Renamed","source":"manual"}}}"#)
        let after = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
        #expect(before["version_id"] == after["version_id"])
        #expect(before["revision"] != after["revision"])
        let archive = dir.appendingPathComponent("transcripts/legacy-folder-name")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir.appendingPathComponent("transcript.json"), to: archive.appendingPathComponent("transcript.json"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.json"))
        let versions = try call("list_transcript_versions", root, ["meeting_id": .string(meeting)])
        #expect(versions["items"]?.array?.count == 1)
        #expect(versions["items"]?.array?.first?["version_id"] == before["version_id"])
        #expect(versions["items"]?.array?.first?["is_current"] == .bool(false))
        let archived = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "version_id": before["version_id"]!])
        #expect(archived["segments"]?.array?.count == 2)
    }
    @Test func partialBrokenMeetingsAndUnreadableRoot() throws {
        let root = try fixture()
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try put(broken, "meta.json", "broken")
        let hidden = root.appendingPathComponent(".import-hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try put(hidden, "meta.json", "{}")
        let before = try tree(root)
        let result = try call("list_meetings", root)
        #expect(result["partial"] == .bool(true))
        #expect(result["items"]?.array?.count == 1)
        #expect(result["warnings"]?.array?.count == 1)
        #expect(try tree(root) == before)
        chmod(root.path, 0)
        defer { chmod(root.path, 0o700) }
        #expect(throws: MCPFailure.self) { try call("list_meetings", root) }
    }
    @Test func runtimeEvidenceCancellationAndActiveRecording() throws {
        let root = try fixture(), meeting = try id(root)
        let runtime = MCPLibrary.Runtime(root: root, recording: ["meeting": "paused"], processing: ["meeting": ["summary": "cancelled", "diarization": "running"]])
        let result = try MCPQueries.call("get_meeting", arguments: ["meeting_id": .string(meeting)], runtime: runtime)
        #expect(result["recording_state"] == .string("paused"))
        #expect(result["processing"]?["summary"] == .string("cancelled"))
        #expect(result["processing"]?["diarization"] == .string("running"))
        #expect(result["has_audio"] == .null)
        #expect(throws: MCPFailure(.artifactNotReady)) { try MCPQueries.call("get_meeting_audio", arguments: ["meeting_id": .string(meeting)], runtime: runtime) }
        #expect(throws: MCPFailure(.serverStopping)) { try MCPQueries.call("list_meetings", arguments: [:], runtime: .init(root: root, cancelled: { true })) }
        try put(root.appendingPathComponent("meeting"), "meta.json", #"{"diarization":{"status":"running"},"summary_status":"running"}"#)
        let unknown = try call("get_meeting", root, ["meeting_id": .string(meeting)])
        #expect(unknown["processing"]?["diarization"] == .string("unknown"))
        #expect(unknown["started_at"] == .null)
        #expect(try call("list_meetings", root, ["started_from": .string("2026-01-01T00:00:00Z")])["items"]?.array?.isEmpty == true)
    }
    @Test func audioOpenReleasesLockAndRejectsTraversalAndDirectoryFiles() throws {
        let root = try fixture(), meeting = try id(root), dir = root.appendingPathComponent("meeting")
        let audio = try call("get_meeting_audio", root, ["meeting_id": .string(meeting)])
        let handle = try MCPLibrary.openAudio(meetingID: meeting, audioID: audio["items"]!.array!.first!["audio_id"]!.string!, runtime: .init(root: root))
        let fd = open(dir.path, O_RDONLY)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        flock(fd, LOCK_UN)
        #expect(try handle.read(offset: 0, count: 32) == Data("synthetic audio".utf8))
        try put(dir, "meta.json", #"{"files":{"source":"../secret.m4a"}}"#)
        #expect(throws: MCPFailure(.dataUnreadable)) { try call("get_meeting_audio", root, ["meeting_id": .string(meeting)]) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("source.m4a"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("source.m4a"), withIntermediateDirectories: true)
        try put(dir, "meta.json", #"{"files":{"source":"source.m4a"}}"#)
        #expect(throws: MCPFailure(.dataUnreadable)) { try call("get_meeting_audio", root, ["meeting_id": .string(meeting)]) }
    }
    @Test func fileAndDirectoryReplacementDuringReadFailClosed() throws {
        let root = try fixture(), dir = try MCPFiles.Directory.root(root.appendingPathComponent("meeting"))
        let before = try tree(root)
        let mutation = MCPTestOnce()
        let pinned = try #require(try dir.file("transcript.json"))
        #expect(throws: MCPFailure(.contentChanged)) {
            try MCPTextArtifacts.Transcript(file: pinned, check: {
                if !mutation.changed { mutation.changed = true; try put(root.appendingPathComponent("meeting"), "transcript.json", "replacement") }
            })
        }
        #expect(try tree(root) != before)
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: root.appendingPathComponent("meeting"), to: moved)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("meeting"), withDestinationURL: moved)
        #expect(throws: MCPFailure.self) { try call("get_meeting", root, ["meeting_id": .string(MCPContract.meetingID(root: root, relative: "meeting"))]) }
        #expect(throws: MCPFailure.self) { try MCPFiles.Directory.root(root.appendingPathComponent("meeting")) }
    }
    @Test func settingsNeverExportSecretsOrHooksAndCaptureAppliedStartupValues() throws {
        let settings = MCPSettings(raw: ["calendar": .bool(false), "unknown": .string("SECRET"), "on_stop": .array([.string("SECRET")]), "transcription": .object(["assemblyai": .object(["api_key": .string("SECRET")]), "openai": .object(["api_key_path": .string("SECRET")])]), "summary": .object(["openai_base_url": .string("https://user:SECRET@example.test/v1?key=SECRET#SECRET")])], effective: ["user_name": .string("Runtime name")], applied: ["calendar": .bool(true)], secretConfigured: ["mcp.token": true])
        let result = try settings.project(keys: nil), bytes = try result.encoded()
        #expect(!String(decoding: bytes, as: UTF8.self).contains("SECRET"))
        let items = result["items"]!.array!
        let token = try #require(items.first { $0["key"]?.string == "mcp.token" })
        #expect(token["configured"] == .bool(true))
        #expect(token["value"] == nil)
        let calendar = try #require(items.first { $0["key"]?.string == "calendar" })
        #expect(calendar["saved_value"] == .bool(false))
        #expect(calendar["applied_value"] == .bool(true))
        #expect(calendar["pending_apply"] == .bool(true))
        let endpoint = try #require(items.first { $0["key"]?.string == "summary.openai_base_url" })
        #expect(endpoint["value"] == .string("https://example.test/v1"))
        #expect(throws: MCPFailure(.invalidParams)) { try settings.project(keys: ["unknown"]) }
        #expect(throws: MCPFailure(.dataUnreadable)) { try MCPQueries.call("get_settings", arguments: [:], runtime: .init(root: Home.current.url)) }
    }

    @Test func metadataScanDoesNotRetainAudioDescriptors() throws {
        let root = try fixture()
        for index in 0..<30 {
            try FileManager.default.copyItem(at: root.appendingPathComponent("meeting"), to: root.appendingPathComponent("copy-\(index)"))
        }
        func descriptors() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
        let before = descriptors()
        let snapshot = try MCPLibrary.scan(.init(root: root))
        #expect(snapshot.meetings.count == 31)
        #expect(descriptors() <= before + 2)
    }
    @Test func completePaginationPreservesUTF8AndTextBoundaries() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        let text = String(repeating: "💡éa\n", count: 25_000)
        try put(dir, "summary.md", text)
        var combined = "", arguments: [String: MCPJSON] = ["meeting_id": .string(meeting)]
        repeat {
            let response = try call("get_meeting_summary", root, arguments)
            combined += response["markdown"]!.string!
            arguments["cursor"] = response["next_cursor"]?.string.map(MCPJSON.string)
        } while arguments["cursor"] != nil
        #expect(combined == text)
        let transcript = Transcript(engine: "test", model: "test", created_at: "2026-10-28T00:00:00Z", segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1, text: String(repeating: "x", count: 65536)),
            .init(speaker: "me", start_ms: 1, end_ms: 2, text: "y")])
        try JSONEncoder().encode(transcript).write(to: dir.appendingPathComponent("transcript.json"))
        let page = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
        #expect(page["segments"]?.array?.count == 1)
        #expect(page["next_cursor"]?.string != nil)
        let huge = Transcript(engine: "test", model: "test", created_at: "2026-10-28T00:00:00Z", segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1, text: String(repeating: "x", count: 1_048_576))])
        try JSONEncoder().encode(huge).write(to: dir.appendingPathComponent("transcript.json"))
        #expect(throws: MCPFailure(.responseTooLarge)) { try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)]) }
    }
    @Test func strictReadLockIsBoundedAndNeverFallsBackUnlocked() throws {
        let root = try fixture(), fd = open(root.appendingPathComponent("meeting").path, O_RDONLY)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN) }
        let second = open(root.appendingPathComponent("meeting").path, O_RDONLY)
        defer { close(second) }
        let started = Date()
        #expect(throws: MCPFailure(.artifactNotReady)) {
            try SessionLock.withReadLock(descriptor: second, deadline: Date().addingTimeInterval(0.03), check: {}) { Issue.record("Must not run unlocked") }
        }
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(throws: MCPFailure(.dataUnreadable)) { try SessionLock.withReadLock(descriptor: -1, deadline: Date(), check: {}) {} }
    }

    @Test func exactSharedResponseKeysAndErrorCodes() throws {
        let root = try fixture(), meeting = try id(root), fixture = try contract()
        let settings = MCPSettings(raw: [:], effective: [:], applied: [:], secretConfigured: [:])
        for tool in MCPContract.tools {
            var args: [String: MCPJSON] = [:]
            if tool != "list_meetings", tool != "search_meetings", tool != "get_settings" { args["meeting_id"] = .string(meeting) }
            if tool == "search_meetings" { args["query"] = .string("hello") }
            let response = try MCPQueries.call(tool, arguments: args, runtime: .init(root: root), settings: settings)
            let keys = Set(response.object!.keys)
            let expected = Set(fixture["response_keys"]![tool]!.array!.compactMap(\.string))
            #expect(keys == expected)
        }
        for test in fixture["parameter_errors"]!.array! {
            do {
                _ = try call(test["tool"]!.string!, root, test["arguments"]!.object!)
                Issue.record("Expected parameter/cursor/ID failure")
            } catch let error as MCPFailure { #expect(error.code.rawValue == test["code"]?.string) }
        }
    }
    @Test func malformedMetadataCannotInventKnownFields() throws {
        let root = try fixture(), meeting = try id(root), dir = root.appendingPathComponent("meeting")
        for value in [#"{"summary_stale":"false"}"#, #"{"title":42}"#, #"{"calendar":{"participants":[{"id":false,"name":"Alex"}]}}"#] {
            try put(dir, "meta.json", value)
            #expect(throws: MCPFailure(.dataUnreadable)) { try call("get_meeting", root, ["meeting_id": .string(meeting)]) }
        }
    }

    @Test func changingWriterGetsOnlyTwoRetries() throws {
        let root = try fixture(), meeting = try id(root)
        let changes = MCPTestChanges(file: root.appendingPathComponent("meeting/meta.json"))
        let runtime = MCPLibrary.Runtime(root: root, cancelled: { changes.change(); return false })
        #expect(throws: MCPFailure(.contentChanged)) { try MCPQueries.call("get_meeting", arguments: ["meeting_id": .string(meeting)], runtime: runtime) }
        #expect(changes.count < 40)
    }
    @Test func corruptSummaryAndAudioAreUnknownAndArchivesArePartial() throws {
        let root = try fixture(), meeting = try id(root), dir = root.appendingPathComponent("meeting")
        try Data([0xff, 0xfe]).write(to: dir.appendingPathComponent("summary.md"))
        chmod(dir.appendingPathComponent("source.m4a").path, 0)
        defer { chmod(dir.appendingPathComponent("source.m4a").path, 0o600) }
        let response = try call("get_meeting", root, ["meeting_id": .string(meeting)])
        #expect(response["has_summary"] == .null)
        #expect(response["has_audio"] == .null)
        for flag in [true, false] {
            #expect(try call("list_meetings", root, ["has_summary": .bool(flag)])["items"]?.array?.isEmpty == true)
            #expect(try call("list_meetings", root, ["has_audio": .bool(flag)])["items"]?.array?.isEmpty == true)
        }
        #expect(throws: MCPFailure(.dataUnreadable)) { try call("get_meeting_summary", root, ["meeting_id": .string(meeting)]) }
        let archive = dir.appendingPathComponent("transcripts/broken")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try put(archive, "transcript.json", "broken")
        let versions = try call("list_transcript_versions", root, ["meeting_id": .string(meeting)])
        #expect(versions["partial"] == .bool(true))
        #expect(versions["items"]?.array?.count == 1)
    }
    @Test func speakingScopeNeedsSavedParticipantIDAndAnyAllStayDistinct() throws {
        let root = try fixture(), meeting = try id(root), dir = root.appendingPathComponent("meeting")
        #expect(try call("list_meetings", root, ["participants": .array([.string("Alex"), .string("Nobody")]), "participant_match": .string("any")])["items"]?.array?.count == 1)
        #expect(try call("list_meetings", root, ["participants": .array([.string("Alex"), .string("Nobody")]), "participant_match": .string("all")])["items"]?.array?.isEmpty == true)
        try Home.current.writeConfig(["user_name": "Owner", "user_email": "a@example.test"])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("speakers.json"))
        try put(dir, "transcript.json", #"{"engine":"test","model":"test","created_at":"2026-10-28T00:00:00Z","segments":[{"speaker":"me","start_ms":0,"end_ms":1,"text":"hello"}]}"#)
        let transcript = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
        #expect(transcript["segments"]?.array?.first?["speaker_name"] == .null)
        #expect(transcript["segments"]?.array?.first?["participant_id"] == .null)
        #expect(try call("list_meetings", root, ["participants": .array([.string("Alex")]), "participant_scope": .string("listed")])["items"]?.array?.count == 1)
        #expect(try call("list_meetings", root, ["participants": .array([.string("Alex")]), "participant_scope": .string("speaking")])["items"]?.array?.isEmpty == true)
    }

    @Test func pageableArtifactsOver64MiBRemainReadable() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        let url = dir.appendingPathComponent("transcript.json")
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: Data(#"{"engine":"test","model":"bounded","created_at":"2026-10-28T00:00:00Z","segments":["#.utf8))
        let segment = #"{"speaker":"them A","start_ms":0,"end_ms":1000,"text":""# + String(repeating: "x", count: 30_000) + #""}"#
        for index in 0..<2300 {
            if index > 0 { try file.write(contentsOf: Data(",".utf8)) }
            try file.write(contentsOf: Data(segment.utf8))
        }
        try file.write(contentsOf: Data("]}".utf8)); try file.close()
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize! > 64 * 1024 * 1024)
        let runtime = MCPLibrary.Runtime(root: root, deadline: Date().addingTimeInterval(180))
        let result = try MCPQueries.call("get_meeting_transcript", arguments: ["meeting_id": .string(meeting), "limit": .number(1)], runtime: runtime)
        #expect(result["segments"]?.array?.count == 1)
        #expect(result["segments"]?.array?.first?["text"]?.string?.count == 30_000)
        try FileManager.default.removeItem(at: url)
        let summaryURL = dir.appendingPathComponent("summary.md")
        try Data().write(to: summaryURL)
        let summaryFile = try FileHandle(forWritingTo: summaryURL)
        let chunk = Data(String(repeating: "abc\n", count: 16_384).utf8)
        for _ in 0..<1025 { try summaryFile.write(contentsOf: chunk) }
        try summaryFile.write(contentsOf: Data("needle at end".utf8)); try summaryFile.close()
        #expect(try summaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize! > 64 * 1024 * 1024)
        let summary = try MCPQueries.call("get_meeting_summary", arguments: ["meeting_id": .string(meeting)], runtime: runtime)
        #expect(summary["markdown"]?.string?.utf8.count == 65536)
        let search = try MCPQueries.call("search_meetings", arguments: ["query": .string("needle at end"), "scope": .string("summary")], runtime: runtime)
        #expect(search["items"]?.array?.count == 1)
    }

    @Test func streamingJSONPreservesEscapesAndMetadataAfterSegments() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        let text = String(repeating: "x", count: 200_000)
        let escaped = String(repeating: #"\u0078"#, count: 200_000)
        let prefix = #"{"segments":[{"text":""#, suffix = #"","end_ms":1,"start_ms":0,"speaker":null}],"created_at":"2026-10-28T00:00:00Z","model":"test","engine":"test"}"#
        try put(dir, "transcript.json", prefix + escaped + suffix)
        let first = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
        #expect(first["segments"]?.array?.first?["text"] == .string(text))
        try put(dir, "transcript.json", prefix + text + suffix)
        let second = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
        #expect(first["version_id"] == second["version_id"])
        let pad = String(repeating: "a", count: 65535 - prefix.utf8.count)
        try put(dir, "transcript.json", prefix + pad + "💡é" + suffix)
        let unicode = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
        #expect(unicode["segments"]?.array?.first?["text"] == .string(pad + "💡é"))
        try put(dir, "transcript.json", prefix + pad + #"\uD83D\uDCA1\u00e9"# + suffix)
        #expect(try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])["version_id"] == unicode["version_id"])
    }
    @Test func streamingParserRejectsMalformedDataWithoutWriting() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        let prefix = #"{"engine":"test","model":"test","created_at":"2026-10-28T00:00:00Z","segments":[{"speaker":"me","start_ms":0,"end_ms":1,"text":""#
        for bad in [prefix + #"\uD800"}] }"#, prefix + "\n\"}]}", prefix + #"ok"}]} trailing"#, prefix + #"ok","text":"duplicate"}]}"#] {
            try put(dir, "transcript.json", bad)
            let before = try tree(root)
            #expect(throws: MCPFailure(.dataUnreadable)) { try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)]) }
            #expect(try tree(root) == before)
        }
    }
    @Test func streamingSummarySearchKeepsChunkBoundaryMatchesAndContinuation() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting")
        let text = String(repeating: "x", count: 65534) + "Needle" + String(repeating: "x", count: 65530) + "NEEDLE"
        try put(dir, "summary.md", text)
        let first = try call("search_meetings", root, ["query": .string("needle"), "scope": .string("summary"), "limit": .number(1)])
        #expect(first["items"]?.array?.first?["match_offset"] == .number(65534))
        #expect(first["items"]?.array?.first?["snippet"]?.string?.contains("Needle") == true)
        let cursor = try #require(first["next_cursor"]?.string)
        let second = try call("search_meetings", root, ["query": .string("needle"), "scope": .string("summary"), "limit": .number(1), "cursor": .string(cursor)])
        #expect(second["items"]?.array?.first?["match_offset"] == .number(131070))
        #expect(second["next_cursor"] == .null)
    }
    @Test func largePrivateMetadataFieldsAreSkippedAndArchivedSourcesAreReleased() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        let url = dir.appendingPathComponent("meta.json")
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 0)
        try file.write(contentsOf: Data(#"{"title":"small","private":""#.utf8))
        let chunk = Data(String(repeating: "x", count: 65536).utf8)
        for _ in 0..<1025 { try file.write(contentsOf: chunk) }
        try file.write(contentsOf: Data(#""}"#.utf8)); try file.close()
        let result = try call("get_meeting", root, ["meeting_id": .string(meeting)])
        #expect(result["title"] == .string("small"))
        #expect(result["has_transcript"] == .bool(true))
        #expect(result["partial"] == .bool(false))
        let archives = dir.appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        for index in 0..<30 {
            let archive = archives.appendingPathComponent("\(index)")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try put(archive, "transcript.json", #"{"engine":"test","model":""# + "\(index)" + #"","created_at":"2026-10-28T00:00:00Z","segments":[]}"#)
            try put(archive, "summary.md", "short")
        }
        func descriptors() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
        let before = descriptors()
        let snapshot = try MCPLibrary.meeting(meeting, runtime: .init(root: root))
        #expect(snapshot.versions.count == 31)
        #expect(descriptors() <= before + 4)
    }

    @Test func responseLimitUsesCompleteEnvelopeAndNoArbitraryMargin() throws {
        let fits = MCPJSON.object(["text": .string(String(repeating: "x", count: 520_000))])
        #expect(try MCPContract.resultEnvelope(fits).encoded().count <= MCPContract.hardResponseBytes)
        #expect(try MCPContract.checkSize(fits) == fits)
        let oversized = MCPJSON.object(["text": .string(String(repeating: "x", count: 525_000))])
        #expect(try MCPContract.resultEnvelope(oversized).encoded().count > MCPContract.hardResponseBytes)
        #expect(throws: MCPFailure(.responseTooLarge)) { try MCPContract.checkSize(oversized) }
    }
    @Test func unrelatedRootFilesAreSkippedAndNonUTF8NamesFailClosed() throws {
        let root = try fixture()
        try put(root, "readme.txt", "ordinary library note")
        #expect(try call("list_meetings", root)["partial"] == .bool(false))
        let directory = try MCPFiles.Directory.root(root)
        let raw: [CChar] = [-1, 0]
        let made = raw.withUnsafeBufferPointer { mkdirat(directory.fd, $0.baseAddress!, 0o700) }
        if made != 0 {
            #expect(errno == EILSEQ || errno == EINVAL, "The filesystem itself rejects non-UTF8 names")
            return
        }
        defer { _ = raw.withUnsafeBufferPointer { unlinkat(directory.fd, $0.baseAddress!, AT_REMOVEDIR) } }
        #expect(throws: MCPFailure(.dataUnreadable)) { try directory.entries() }
    }

    @Test func transcriptPageDoesNotLoadUnreturnedSpeakerTablesOrCalendarText() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        let huge = String(repeating: "x", count: 1_100_000)
        let meta = MCPJSON.object(["title": .string(huge), "calendar": .object(["agenda": .string(huge), "participants": .array([.object(["id": .string("p1"), "name": .string(huge)])])])])
        try meta.encoded().write(to: dir.appendingPathComponent("meta.json"))
        let transcript = try FileHandle(forWritingTo: dir.appendingPathComponent("transcript.json"))
        try transcript.truncate(atOffset: 0)
        try transcript.write(contentsOf: Data(#"{"engine":"test","model":"test","created_at":"2026-10-28T00:00:00Z","segments":["#.utf8))
        let names = try FileHandle(forWritingTo: dir.appendingPathComponent("speakers.json"))
        try names.truncate(atOffset: 0)
        try names.write(contentsOf: Data(#"{"created_at":"now","speakers":{"#.utf8))
        for index in 0..<20_000 {
            if index > 0 { try transcript.write(contentsOf: Data(",".utf8)); try names.write(contentsOf: Data(",".utf8)) }
            let segment = MCPJSON.object(["speaker": .string("them \(index)"), "start_ms": .number(Double(index)), "end_ms": .number(Double(index + 1)), "text": .string("hello")])
            try transcript.write(contentsOf: segment.encoded())
            let entry = "\"them \(index)\":{\"name\":\"Person \(index)\",\"source\":\"manual\",\"participantID\":\"p1\"}"
            try names.write(contentsOf: Data(entry.utf8))
        }
        try transcript.write(contentsOf: Data("]}".utf8)); try transcript.close()
        try names.write(contentsOf: Data("}}".utf8)); try names.close()
        let result = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "limit": .number(1)])
        #expect(result["segments"]?.array?.count == 1)
        #expect(result["segments"]?.array?.first?["speaker_name"] == .string("Person 0"))
        #expect(result["segments"]?.array?.first?["participant_id"] == .string("p1"))
        #expect(throws: MCPFailure(.responseTooLarge)) { try call("get_meeting", root, ["meeting_id": .string(meeting)]) }
    }

    @Test func bindingMetadataCanReducePageWithoutLosingContinuation() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        var segments: [Transcript.Segment] = [], names: [String: SpeakerNames.Entry] = [:]
        for index in 0..<6 {
            let speaker = "them \(index)"
            segments.append(.init(speaker: speaker, start_ms: index, end_ms: index + 1, text: "hello"))
            names[speaker] = .init(name: String(repeating: "N", count: 100_000), source: .manual, participantID: "p1")
        }
        try JSONEncoder().encode(Transcript(engine: "test", model: "test", created_at: "2026-10-28T00:00:00Z", segments: segments)).write(to: dir.appendingPathComponent("transcript.json"))
        try JSONEncoder().encode(SpeakerNames(speakers: names)).write(to: dir.appendingPathComponent("speakers.json"))
        var args: [String: MCPJSON] = ["meeting_id": .string(meeting)], indices: [MCPJSON] = []
        repeat {
            let result = try call("get_meeting_transcript", root, args)
            indices += result["segments"]!.array!.compactMap { $0["segment_index"] }
            args["cursor"] = result["next_cursor"]?.string.map(MCPJSON.string)
        } while args["cursor"] != nil
        #expect(indices == (0..<6).map { .number(Double($0)) })
    }
    @Test func archivedTranscriptCursorBindsCurrentParticipantRoster() throws {
        let root = try fixture(), meeting = try id(root), dir = root.appendingPathComponent("meeting")
        let original = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
        let version = original["version_id"]!
        let archive = dir.appendingPathComponent("transcripts/old")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for name in ["transcript.json", "speakers.json"] { try FileManager.default.copyItem(at: dir.appendingPathComponent(name), to: archive.appendingPathComponent(name)) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.json"))
        let first = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "version_id": version, "limit": .number(1)])
        let cursor = try #require(first["next_cursor"]?.string)
        try put(dir, "meta.json", #"{"calendar":{"participants":[]}}"#)
        #expect(throws: MCPFailure(.contentChanged)) { try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "version_id": version, "limit": .number(1), "cursor": .string(cursor)]) }
    }

    @Test func speakerStatisticsBudgetNeverErasesValidTranscriptAvailability() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        func write(_ count: Int) throws {
            let segments = (0..<count).map { Transcript.Segment(speaker: "voice\($0)", start_ms: $0, end_ms: $0 + 1, text: "x") }
            try JSONEncoder().encode(Transcript(engine: "test", model: "test", created_at: "2026-10-28T00:00:00Z", segments: segments)).write(to: dir.appendingPathComponent("transcript.json"))
        }
        try write(5000)
        let card = try call("get_meeting", root, ["meeting_id": .string(meeting)])
        #expect(card["has_transcript"] == .bool(true))
        #expect(card["speakers"]?.array?.count == 5000)
        try write(40_000)
        let listing = try call("list_meetings", root)
        #expect(listing["items"]?.array?.first?["has_transcript"] == .bool(true))
        #expect(listing["partial"] == .bool(true))
        #expect(throws: MCPFailure(.responseTooLarge)) { try call("get_meeting", root, ["meeting_id": .string(meeting)]) }
        #expect(throws: MCPFailure(.responseTooLarge)) { try call("list_transcript_versions", root, ["meeting_id": .string(meeting)]) }
        #expect(try call("get_meeting_transcript", root, ["meeting_id": .string(meeting), "limit": .number(1)])["segments"]?.array?.count == 1)
    }

    @Test func originalIntegerTimestampsAreNotRoundedThroughDouble() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting"), meeting = try id(root)
        let start = 9_007_199_254_740_993, end = 9_007_199_254_740_995
        let transcript = Transcript(engine: "test", model: "test", created_at: "2026-10-28T00:00:00Z", segments: [.init(speaker: "me", start_ms: start, end_ms: end, text: "exact")])
        try JSONEncoder().encode(transcript).write(to: dir.appendingPathComponent("transcript.json"))
        let result = try call("get_meeting_transcript", root, ["meeting_id": .string(meeting)])
        let json = String(decoding: try result.encoded(), as: UTF8.self)
        #expect(json.contains("\"start_ms\":9007199254740993"))
        #expect(json.contains("\"end_ms\":9007199254740995"))
    }

    @Test func reviewRoundOneNativeFailureReasonStaysPrivate() throws {
        let root = try fixture(), meeting = try id(root), dir = root.appendingPathComponent("meeting")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.json"))
        for sample in try contract()["native_processing_failures"]!.array! {
            try sample["metadata"]!.encoded().write(to: dir.appendingPathComponent("meta.json"))
            let before = try tree(root)
            let card = try call("get_meeting", root, ["meeting_id": .string(meeting)])
            #expect(card["processing"]?["transcription"] == sample["expected_state"])
            #expect(card["has_transcript"] == .bool(false))
            let listing = try call("list_meetings", root, ["processing_stage": .string("transcription"), "processing_state": .string("failed")])
            #expect(listing["items"]?.array?.count == 1)
            #expect(listing["partial"] == .bool(false))
            for result in [card, listing] {
                #expect(!String(decoding: try result.encoded(), as: UTF8.self).contains(sample["must_not_expose"]!.string!))
            }
            #expect(try tree(root) == before)
        }
    }
    @Test func reviewRoundOneLongGraphemeSearchRetainsOnlyBoundedContext() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting")
        try put(dir, "summary.md", "a" + String(repeating: "\u{0301}", count: 131_072) + "needle")
        let before = try tree(root)
        let result = try call("search_meetings", root, ["query": .string("needle"), "scope": .string("summary")])
        let item = try #require(result["items"]?.array?.first)
        let snippet = try #require(item["snippet"]?.string)
        #expect(item["match_offset"] == .int(262_145))
        #expect(snippet.hasSuffix("needle"))
        // Four full chunks have passed: only the overlap/lookbehind can precede this match.
        #expect(snippet.utf8.count <= 8192)
        #expect(try tree(root) == before)
    }
    @Test func reviewRoundOneLimitBeforeSplitEmojiReturnsPageAndContinuation() throws {
        let root = try fixture(), dir = root.appendingPathComponent("meeting")
        let begin = "needle needle "
        let text = begin + String(repeating: "x", count: 65534 - begin.utf8.count) + "💡 tail"
        let json = #"{"engine":"test","model":"test","created_at":"2026-10-28T00:00:00Z","segments":[{"speaker":"me","start_ms":0,"end_ms":1,"text":""# + text + #""}]}"#
        try put(dir, "transcript.json", json)
        try put(dir, "summary.md", text)
        let before = try tree(root)
        for scope in ["transcript", "summary"] {
            let first = try call("search_meetings", root, ["query": .string("needle"), "scope": .string(scope), "limit": .int(1)])
            #expect(first["items"]?.array?.count == 1)
            #expect(first["items"]?.array?.first?["match_offset"] == .int(0))
            let cursor = try #require(first["next_cursor"]?.string)
            let next = try call("search_meetings", root, ["query": .string("needle"), "scope": .string(scope), "limit": .int(1), "cursor": .string(cursor)])
            #expect(next["items"]?.array?.count == 1)
            #expect(next["items"]?.array?.first?["match_offset"] == .int(7))
            #expect(next["next_cursor"] == .null)
        }
        #expect(try tree(root) == before)
    }

}


private final class MCPTestChanges: @unchecked Sendable {
    let file: URL
    private let lock = NSLock()
    private var mutations = 0
    var count: Int { lock.withLock { mutations } }
    init(file: URL) { self.file = file }
    func change() {
        let next = lock.withLock { mutations += 1; return mutations }
        if next >= 5 { try? Data("{\"title\":\"mutation-\(next)\"}".utf8).write(to: file, options: .atomic) }
    }
}

private final class MCPTestOnce { var changed = false }
