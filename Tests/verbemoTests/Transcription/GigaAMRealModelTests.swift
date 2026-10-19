import Foundation
import Testing
@testable import verbemo

struct GigaAMRealModelTests {
    /// Opt-in ABI/model smoke test. It catches a framework that compiles but
    /// cannot load the exact GGUF we publish in setup.
    @Test(
        "The published GigaAM GGUF transcribes real Russian audio",
        .enabled(if:
            ProcessInfo.processInfo.environment["VERBEMO_GIGAAM_GGUF"] != nil
                && ProcessInfo.processInfo.environment["VERBEMO_GIGAAM_AUDIO"] != nil))
    func publishedModelSmokeTest() async throws {
        let modelPath = ProcessInfo.processInfo.environment["VERBEMO_GIGAAM_GGUF"]!
        let audioPath = ProcessInfo.processInfo.environment["VERBEMO_GIGAAM_AUDIO"]!
        let manifest = GigaAMModelStore.defaultManifest
        let model = URL(fileURLWithPath: modelPath)
        let store = GigaAMModelStore(
            directory: model.deletingLastPathComponent(),
            manifest: .init(
                id: manifest.id,
                fileName: model.lastPathComponent,
                revision: manifest.revision,
                downloadURL: manifest.downloadURL,
                expectedBytes: manifest.expectedBytes,
                sha256: manifest.sha256)) { _, _, _ in
                    Issue.record("the supplied real model must not download")
                }
        let engine = GigaAMEngine(modelStore: store)
        try await engine.prepare()

        let segments = try await engine.transcribe(URL(fileURLWithPath: audioPath))

        #expect(!segments.isEmpty)
        #expect(segments.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        await engine.release()
    }
}
