import Foundation
import Testing

@testable import verbemo

/// Engine/config names and model provenance remain consistent.
struct EngineVocabularyTests {
    /// Every engine the program can build, with a key for each cloud one so
    /// that its initializer has nothing to refuse.
    private static func everyEngine() throws -> [any TranscriptionEngine] {
        try withFreshHome { home in
            try FileManager.default.createDirectory(
                at: home.keysDirectory, withIntermediateDirectories: true)
            for service in ["assemblyai", "openai", "elevenlabs"] {
                try Data("test-key".utf8).write(
                    to: home.keysDirectory.appendingPathComponent(service))
            }
            return [
                ParakeetEngine(), WhisperEngine(), GigaAMEngine(), NemotronEngine(),
                try AssemblyAIEngine(), try OpenAITranscriptionEngine(), try ElevenLabsEngine(),
            ]
        }
    }

    @Test("An engine's name is the one the config file uses for it")
    func engineNamesMatchTheConfig() throws {
        let names = Set(try Self.everyEngine().map(\.name))
        #expect(names == Config.localEngines.union(Config.cloudEngines))
    }

    @Test("Every engine's default model is reported by name, not as custom")
    func defaultModelsAreKnown() throws {
        for engine in try Self.everyEngine() {
            let model = AnalyticsCatalogue.transcriptionModel(
                engine: engine.name, provenance: engine.model)
            #expect(model != "custom" && model != "unknown", "\(engine.name): \(engine.model)")
        }
    }
}
