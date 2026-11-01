import Foundation
import Testing
@testable import verbemo

@Suite(.freshHome) struct MeetingLibrarySearchTests {
    @Test func findsCurrentTranscriptAndVisibleSummaryButNotArchives() throws {
        let dir = Home.current.url.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Transcript(engine: "test", model: "test", created_at: "test", segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "🎙️ Кварцевый компас и PLAN"),
        ]).write(to: dir)
        try Data("# Решения\nСапфи**ровый** маяк".utf8).write(to: dir.appendingPathComponent("summary.md"))
        let archive = dir.appendingPathComponent("transcripts/old")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("Только архив".utf8).write(to: archive.appendingPathComponent("summary.md"))
        let input = MeetingLibrarySearch.Input(dir: dir, title: "Planning", metadata: ["2026-11-01", "Борис"])
        let tx = try MeetingLibrarySearch.search([input], query: "  КВАРЦЕВЫЙ компас\n")
        let hit = try #require(tx.hits[dir])
        #expect(hit.source == .transcript)
        #expect(hit.segment == 0)
        #expect(hit.excerpt.contains("🎙️ Кварцевый компас"))
        #expect(hit.revision != nil)
        #expect(tx.unreadable == 0)
        #expect(try MeetingLibrarySearch.search([input], query: "сапфировый маяк").hits[dir]?.source == .summary)
        #expect(try MeetingLibrarySearch.search([input], query: "Только архив").hits.isEmpty)
        #expect(try MeetingLibrarySearch.search([input], query: "борис").hits[dir]?.source == .metadata)
        #expect(try MeetingLibrarySearch.search([input], query: "planning").hits[dir]?.source == .title)
    }

    @Test func legacyMarkdownMissingAndMalformedMaterialAreDistinct() throws {
        let dir = Home.current.url.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = MeetingLibrarySearch.Input(dir: dir, title: "Meeting", metadata: [])
        #expect(try MeetingLibrarySearch.search([input], query: "needle").unreadable == 0)
        try Data("**Needle** in text".utf8).write(to: dir.appendingPathComponent("transcript.md"))
        #expect(try MeetingLibrarySearch.search([input], query: "needle").hits[dir]?.source == .transcript)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        let broken = try MeetingLibrarySearch.search([input], query: "needle")
        #expect(broken.hits.isEmpty, "A stale Markdown fallback cannot hide corrupt canonical JSON")
        #expect(broken.unreadable == 1)
        try Data("Needle in summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        let partial = try MeetingLibrarySearch.search([input], query: "needle")
        #expect(partial.hits[dir]?.source == .summary)
        #expect(partial.unreadable == 1)
    }

    @Test func readOnlySearchRejectsLinksAndOversizedArtifacts() throws {
        let dir = Home.current.url.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outside = Home.current.url.appendingPathComponent("outside.md")
        try Data("needle private".utf8).write(to: outside)
        let summary = dir.appendingPathComponent("summary.md")
        try FileManager.default.createSymbolicLink(at: summary, withDestinationURL: outside)
        let input = MeetingLibrarySearch.Input(dir: dir, title: "Meeting", metadata: [])
        let linked = try MeetingLibrarySearch.search([input], query: "needle")
        #expect(linked.hits.isEmpty)
        #expect(linked.unreadable == 1)
        try FileManager.default.removeItem(at: summary)
        #expect(FileManager.default.createFile(atPath: summary.path, contents: nil))
        let file = try FileHandle(forWritingTo: summary)
        try file.truncate(atOffset: 33 * 1024 * 1024)
        try file.close()
        #expect(try MeetingLibrarySearch.search([input], query: "needle").unreadable == 1)
        #expect(try Data(contentsOf: outside) == Data("needle private".utf8))
    }

    @Test func queryIsLiteralTrimmedAndCancellable() async throws {
        let dir = Home.current.url.appendingPathComponent("literal")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((String(repeating: "Длинный текст ", count: 200) + "a.b 🎙️ fin").utf8).write(to: dir.appendingPathComponent("summary.md"))
        let input = MeetingLibrarySearch.Input(dir: dir, title: "Meeting", metadata: [])
        let hit = try #require(MeetingLibrarySearch.search([input], query: "a.b").hits[dir])
        #expect(hit.excerpt.contains("a.b 🎙️ fin"))
        #expect(hit.excerpt.count <= 162)
        #expect(try MeetingLibrarySearch.search([input], query: "aXb").hits.isEmpty)
        #expect(try MeetingLibrarySearch.search([input], query: " \n").hits.isEmpty)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try MeetingLibrarySearch.search([input], query: "a.b")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func excludesPreviousGenerationSummaryAndReportsUnreadableMetadata() throws {
        let dir = try SessionFixture.make()
        try Data("Previous beacon".utf8).write(to: dir.appendingPathComponent("summary.md"))
        let input = MeetingLibrarySearch.Input(dir: dir, title: "Meeting", metadata: [])
        let hit = try #require(MeetingLibrarySearch.search([input], query: "beacon").hits[dir])
        try TranscriptVersions.commit(.init(engine: "whisper", model: "test", created_at: "2026-11-01T10:00:00Z", segments: []), to: dir)
        #expect(!PostProcessor.hasCurrentSummary(dir))
        #expect(try MeetingLibrarySearch.search([input], query: "beacon").hits.isEmpty)
        #expect(!MeetingLibrarySearch.isCurrent(hit, in: dir))
        try Data("{".utf8).write(to: dir.appendingPathComponent("meta.json"))
        let invalid = try MeetingLibrarySearch.search([input], query: "beacon")
        #expect(invalid.hits.isEmpty)
        #expect(invalid.unreadable == 1)
    }
}
