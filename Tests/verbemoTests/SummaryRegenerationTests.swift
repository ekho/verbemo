import Foundation
import Testing
@testable import verbemo

struct SummaryRegenerationTests {
    private func run(_ model: FakeModel, _ body: () async throws -> Void) async throws {
        let home = Home.withModels([model])
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["summary": ["backend": "auto"], "speaker_names": ["enabled": false]])
        try await Home.$scoped.withValue(home) { try await body() }
    }
    @Test func readySummaryCanBeRegeneratedWithoutNaming() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldTranscript = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        try Data("old".utf8).write(to: dir.appendingPathComponent("summary.md"))
        let model = FakeModel("claude-cli", answer: "new summary")
        try await run(model) { try await PostProcessor.regenerateSummary(dir) }
        #expect(model.callCount == 1)
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "new summary\n")
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == oldTranscript)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(SpeakerNames.file).path))
        #expect(!SessionClaim.isHeld(dir))
    }
    @Test func pendingRequestAndBusySessionNeverCallModel() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FakeModel("claude-cli", answer: "must not run")
        try Data("gigaam".utf8).write(to: dir.appendingPathComponent(TranscriptVersions.requestFile))
        try await run(model) {
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(dir) }
            try FileManager.default.removeItem(at: dir.appendingPathComponent(TranscriptVersions.requestFile))
            try SessionClaim.acquire(dir, stage: .transcribe)
            defer { SessionClaim.release(dir) }
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(dir) }
        }
        #expect(model.callCount == 0)
    }
    @Test func backendFailureKeepsOldSummaryAndNames() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("old summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        PostProcessor.rename("them A", to: "Анна", in: dir)
        let oldNames = try Data(contentsOf: dir.appendingPathComponent(SpeakerNames.file))
        let model = FakeModel("claude-cli", failing: URLError(.notConnectedToInternet))
        try await run(model) {
            await #expect(throws: (any Error).self) { try await PostProcessor.regenerateSummary(dir) }
        }
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "old summary")
        #expect(try Data(contentsOf: dir.appendingPathComponent(SpeakerNames.file)) == oldNames)
    }
}
