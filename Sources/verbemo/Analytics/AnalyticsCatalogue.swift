import Foundation

/// Which settings may be reported, derived rather than listed.
///
/// A hand-written list of reportable keys is a list that goes stale the first
/// time somebody adds a setting, and it goes stale in the dangerous
/// direction: nobody notices a key that was let in. So the rule is stated
/// once and applied to `SettingsSchema`, which is already the one place every
/// setting exists.
///
/// The rule: toggles and fixed choices, nothing else. That keeps out paths,
/// key files, names, app lists, model names and language codes — not because
/// somebody reviewed each of them, but because none of them can be a toggle
/// or a choice. A setting added next year is covered before it is written.
enum AnalyticsCatalogue {
    enum SettingKind: Equatable {
        case toggle
        case choice([String])
    }

    /// The analytics switch itself is never reported.
    ///
    /// Sending an event *because* somebody just turned reporting off is
    /// indefensible whatever it would teach us about the opt-out rate, and
    /// the symmetric case — reporting that it was turned on — is only less
    /// obviously so. The number is not worth the sentence it would take to
    /// explain.
    static let neverReported: Set<String> = ["analytics"]

    static var reportableSettings: [String: SettingKind] {
        var reportable: [String: SettingKind] = [:]
        for entry in SettingsSchema.sections.flatMap(\.entries) {
            let key = entry.path.joined(separator: ".")
            guard !neverReported.contains(key) else { continue }
            switch entry.kind {
            case .toggle: reportable[key] = .toggle
            case .choice(let allowed): reportable[key] = .choice(allowed)
            case .number, .text, .multilineText, .list: continue
            }
        }
        return reportable
    }

    /// Model provenance is deliberately narrowed before it reaches the wire.
    /// Transcript files keep the full local string; analytics gets only a
    /// public model we know or `custom`, never a private fine-tune identifier,
    /// registry namespace, or language hint embedded in provenance.
    static func transcriptionModel(engine: String, provenance: String) -> String {
        switch engine {
        case "parakeet":
            if provenance.contains("0.6b-v3") { return "parakeet-v3" }
            if provenance.contains("0.6b-v2") { return "parakeet-v2" }
            return "custom"
        case "openai":
            return provenance == "gpt-4o-transcribe-diarize"
                ? "gpt-4o-transcribe-diarize" : "custom"
        case "assemblyai":
            let model = provenance.components(separatedBy: " · ").first ?? provenance
            return model == "universal" ? "universal" : "custom"
        case "elevenlabs":
            return provenance == "scribe_v2" ? "scribe_v2" : "custom"
        case "whisper":
            return provenance == WhisperModelStore.defaultManifest.id
                ? "whisper-large-v3-turbo" : "custom"
        case "nemotron":
            let known = ["latin", "multilingual"].map { "nemotron-3.5-asr-streaming-multilingual-0.6b/\($0)/1120ms" }
            return known.contains(provenance) ? "nemotron-3.5-asr-0.6b" : "custom"
        case "gigaam":
            return provenance == GigaAMModelStore.defaultManifest.id ? "gigaam-v3" : "custom"
        default:
            return "unknown"
        }
    }

    /// Same boundary for LLMs. The backend is sent separately; this value says
    /// which public model family was actually asked, without leaking arbitrary
    /// model strings from config or a local Ollama registry.
    static func summaryModel(backend: String, model: String?) -> String {
        switch backend {
        case "claude-cli":
            return "default"
        case "anthropic-api":
            return model == "claude-opus-5" ? "claude-opus-5" : "custom"
        case "codex-cli", "openai-api":
            return model == "gpt-5" ? "gpt-5" : "custom"
        case "ollama":
            return model == "qwen3:8b" ? "qwen3:8b" : "custom-local"
        default:
            return "unknown"
        }
    }

}
