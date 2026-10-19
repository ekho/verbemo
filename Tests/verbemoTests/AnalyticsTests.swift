import Foundation
import Testing

@testable import verbemo

@Suite("Analytics v2 catalogue")
struct AnalyticsV2CatalogueTests {
    @Test("STT model names are useful without allowing arbitrary text onto the wire")
    func transcriptionModelsAreNormalised() {
        let cases: [(String, String, String)] = [
            ("parakeet", "parakeet-tdt-0.6b-v3-coreml (ru+en)", "parakeet-v3"),
            ("parakeet", "parakeet-tdt-0.6b-v2-coreml", "parakeet-v2"),
            ("openai", "gpt-4o-transcribe-diarize", "gpt-4o-transcribe-diarize"),
            ("openai", "ft:private:customer-name", "custom"),
            ("assemblyai", "universal · auto-detect", "universal"),
            ("assemblyai", "private-model · ru+en", "custom"),
            ("other", "anything", "unknown"),
        ]
        for (engine, provenance, expected) in cases {
            #expect(
                AnalyticsCatalogue.transcriptionModel(engine: engine, provenance: provenance)
                    == expected,
                "\(engine): \(provenance)")
        }
    }

    @Test("LLM model names are allow-listed per backend")
    func summaryModelsAreNormalised() {
        let cases: [(String, String?, String)] = [
            ("claude-cli", nil, "default"),
            ("anthropic-api", "claude-opus-5", "claude-opus-5"),
            ("anthropic-api", "private/model", "custom"),
            ("codex-cli", "gpt-5", "gpt-5"),
            ("openai-api", "gpt-5", "gpt-5"),
            ("openai-api", "ft:customer:name", "custom"),
            ("ollama", "qwen3:8b", "qwen3:8b"),
            ("ollama", "samat/private-model", "custom-local"),
            ("other", "whatever", "unknown"),
        ]
        for (backend, model, expected) in cases {
            #expect(AnalyticsCatalogue.summaryModel(backend: backend, model: model) == expected)
        }
    }

    @Test("Recording start failures expose only the failed capture component")
    func recordingStartFailureComponents() {
        let underlying = NSError(domain: "private error text", code: 7)
        let system = RecordingSession.StartFailure.systemAudio(underlying)
        let microphone = RecordingSession.StartFailure.microphone(underlying)
        #expect(system.analyticsComponent == "system_audio")
        #expect(microphone.analyticsComponent == "microphone")
        #expect(system.description.contains("private error text"), "the local log keeps detail")
    }

    @Test("Errors collapse to a closed reason without carrying their text")
    func failureReasonsAreSafe() {
        #expect(Analytics.reason(for: URLError(.notConnectedToInternet)) == .noNetwork)
        #expect(Analytics.reason(for: URLError(.timedOut)) == .timedOut)
        #expect(Analytics.reason(for: LLMError.http(429, "private quota detail")) == .usageLimit)
        #expect(Analytics.reason(for: LLMError.http(503, "private server detail")) == .httpError)
        #expect(Analytics.reason(for: LLMError.http(401, "private key detail")) == .refused)
        #expect(Analytics.reason(for: LLMError.emptyResponse("private backend")) == .unknown)
    }
}

/// Which settings may be reported at all. The rule is toggles and fixed
/// choices; everything here is a way of asking whether the rule holds rather
/// than whether somebody remembered to apply it.
@Suite("Reportable settings")
struct AnalyticsCatalogueSettingsTests {
    @Test("Every toggle and choice is reportable, and nothing else is")
    func onlyTogglesAndChoices() {
        let reportable = AnalyticsCatalogue.reportableSettings
        for entry in SettingsSchema.sections.flatMap(\.entries) {
            let key = entry.path.joined(separator: ".")
            if AnalyticsCatalogue.neverReported.contains(key) {
                #expect(reportable[key] == nil, "\(key) is on the never-reported list")
                continue
            }
            switch entry.kind {
            case .toggle, .choice:
                #expect(reportable[key] != nil, "\(key) is a toggle or a choice but not reportable")
            case .text, .multilineText, .number, .list:
                #expect(reportable[key] == nil, "\(key) is free-form and must not be reportable")
            }
        }
    }

    /// The failure this guards against is the expensive one: a path, a name or
    /// a key file leaving the machine inside a `setting_changed`.
    @Test("Free-text settings produce no event whatever they are given")
    func freeTextNeverTravels() {
        let freeForm: [([String], Any)] = [
            (["recordings_dir"], "/Users/someone/Meetings with the board"),
            (["user_name"], "Someone Real"),
            (["on_stop"], "/usr/local/bin/leak.sh"),
            (["transcription", "assemblyai", "api_key_path"], "~/.config/verbemo/keys/assemblyai"),
            (["summary", "api_key_path"], "~/.config/verbemo/keys/anthropic"),
            (["transcription", "language"], "lv"),
            (["auto_record", "apps"], ["us.zoom.xos"]),
            (["auto_record", "start_delay_seconds"], 12),
        ]
        for (path, value) in freeForm {
            #expect(
                Analytics.reportableChange(path: path, value: value) == nil,
                "\(path.joined(separator: ".")) must not be reportable")
        }
    }

    @Test("The analytics switch never reports itself")
    func theSwitchIsSilent() {
        #expect(Analytics.reportableChange(path: ["analytics"], value: false) == nil)
        #expect(Analytics.reportableChange(path: ["analytics"], value: nil) == nil)
    }

    @Test("A toggle and a choice report their value, and a cleared key reports the default")
    func togglesAndChoicesReport() throws {
        let toggled = try #require(
            Analytics.reportableChange(path: ["auto_record", "enabled"], value: false))
        #expect(toggled.key == "auto_record.enabled")
        #expect(toggled.value == .flag(false))

        let cleared = try #require(
            Analytics.reportableChange(path: ["auto_record", "enabled"], value: nil))
        #expect(cleared.value == .text("default"))

        // A value the schema does not offer is not reported at all, which
        // keeps a hand-edited config file from putting free text on the wire
        // through a key that happens to be a choice.
        #expect(
            Analytics.reportableChange(
                path: ["transcription", "cloud"], value: "/etc/passwd") == nil)
    }

    @Test("Durations are buckets, and the boundaries are where they say they are")
    func durationBuckets() {
        #expect(Analytics.durationBucket(seconds: 0) == .text("under_5m"))
        #expect(Analytics.durationBucket(seconds: 299) == .text("under_5m"))
        #expect(Analytics.durationBucket(seconds: 300) == .text("5_15m"))
        #expect(Analytics.durationBucket(seconds: 1799) == .text("15_30m"))
        #expect(Analytics.durationBucket(seconds: 3600) == .text("1_2h"))
        #expect(Analytics.durationBucket(seconds: 90_000) == .text("over_2h"))
    }
}
