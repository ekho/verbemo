import Foundation
import Testing
@testable import verbemo

struct SummaryCLIConfigurationTests {
    @Test func codexRefusesChangedConfigurationBeforeProbeOrTranscript() async throws {
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let folder = home.url.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = folder.appendingPathComponent("config.toml")
        try Data("model = \"original\"".utf8).write(to: config)
        try await Home.$scoped.withValue(home) {
            let backend = LLMBackend.codexCLI(path: "/usr/bin/true", freezeConfiguration: true)
            try await backend.checkAccess()
            try Data("model = \"changed\"".utf8).write(to: config)
            await #expect(throws: PostProcessor.SummaryRegenerationError.self) { try await backend.checkAccess() }
            await #expect(throws: PostProcessor.SummaryRegenerationError.self) { _ = try await backend.call("system", "private transcript") }
        }
    }
}
