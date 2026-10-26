import AppKit
import Foundation
import Testing

@testable import verbemo

/// The settings window's one non-obvious rule, tested without a window: a
/// value equal to the default is cleared rather than written, so the config
/// file keeps reading as a list of decisions and a default that improves later
/// still reaches the user.
struct SettingsSchemaTests {
    private static func entry(
        _ kind: SettingsSchema.Kind, default value: Any
    ) -> SettingsSchema.Entry {
        SettingsSchema.Entry(["x"], "X", "help", kind, default: value)
    }

    private static func stored(
        _ input: SettingsSchema.Input, _ entry: SettingsSchema.Entry
    ) -> Any? {
        switch SettingsSchema.resolve(input, for: entry) {
        case .set(let value): return value
        case .clear: return nil
        case .invalid: return "INVALID"
        }
    }

    @Test("Echo cancellation is opt-in so recording does not change playback")
    func micVoiceProcessingDefaultsOff() throws {
        let audio = try #require(SettingsSchema.sections.first { $0.title == localised("Audio", "Звук") })
        let voice = try #require(audio.entries.first { $0.path == ["mic_voice_processing"] })
        #expect(voice.defaultValue as? Bool == false)
    }

    @Test("An empty config records the raw microphone")
    func emptyConfigUsesRawMic() {
        #expect(!Config.micVoiceProcessing(in: nil))
        #expect(!Config.micVoiceProcessing(in: [:]))
        #expect(Config.micVoiceProcessing(in: ["mic_voice_processing": true]))
        #expect(!Config.micVoiceProcessing(in: ["mic_voice_processing": false]))
    }

    @Test("Setting a toggle to its default clears the key instead of writing it")
    func toggleAtDefaultClears() {
        let onByDefault = Self.entry(.toggle, default: true)
        #expect(Self.stored(.flag(true), onByDefault) == nil)
        #expect(Self.stored(.flag(false), onByDefault) as? Bool == false)

        let offByDefault = Self.entry(.toggle, default: false)
        #expect(Self.stored(.flag(false), offByDefault) == nil)
        #expect(Self.stored(.flag(true), offByDefault) as? Bool == true)
    }

    /// Leaving a field is not deciding anything. Every one of these used to
    /// write the file back byte for byte, moving its timestamp and waking
    /// every open window, because editing ended — not because anybody typed.
    @Test("A row still showing what is stored commits nothing")
    func unchangedRowsCommitNothing() {
        let language = Self.entry(.text, default: "the meeting's language")
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text("ru"), for: language), from: "ru"))

        let onByDefault = Self.entry(.toggle, default: true)
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.flag(false), for: onByDefault), from: false))

        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text("30"), for: delay), from: 30))

        let apps = Self.entry(.list, default: "empty")
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text("zoom, teams"), for: apps), from: ["zoom", "teams"]))
    }

    /// The other half, and the one that would go unnoticed: a guard against
    /// pointless writes must not swallow a real edit.
    @Test("An edited row, and a row falling back to its default, both commit")
    func changedRowsCommit() {
        let language = Self.entry(.text, default: "the meeting's language")
        #expect(SettingsSchema.changes(
            SettingsSchema.resolve(.text("de"), for: language), from: "ru"))
        // Emptied: the key goes away, which is a change when it was there.
        #expect(SettingsSchema.changes(
            SettingsSchema.resolve(.text(""), for: language), from: "ru"))
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text(""), for: language), from: nil))

        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(SettingsSchema.changes(
            SettingsSchema.resolve(.text("45"), for: delay), from: 30))
        // Unusable input changes nothing by definition; the window puts the
        // stored value back instead.
        #expect(!SettingsSchema.changes(
            SettingsSchema.resolve(.text("soon"), for: delay), from: 30))
    }

    @Test("Choosing the default option clears the key")
    func choiceAtDefaultClears() {
        let engine = Self.entry(.choice(["auto", "assemblyai", "parakeet"]), default: "auto")
        #expect(Self.stored(.choice("auto"), engine) == nil)
        #expect(Self.stored(.choice("parakeet"), engine) as? String == "parakeet")
    }

    /// A pop-up can't produce a title it doesn't have, but the rule is what a
    /// future caller would rely on, and silently writing an unknown engine
    /// name is how a config ends up meaning nothing.
    @Test("An option that isn't in the list is refused")
    func unknownChoiceRefused() {
        let engine = Self.entry(.choice(["auto", "parakeet"]), default: "auto")
        #expect(Self.stored(.choice("whisper"), engine) as? String == "INVALID")
    }

    @Test("An emptied field means unset, not empty")
    func emptyFieldClears() {
        let language = Self.entry(.text, default: "the meeting's language")
        #expect(Self.stored(.text(""), language) == nil)
        #expect(Self.stored(.text("   "), language) == nil)
        #expect(Self.stored(.text(" ru "), language) as? String == "ru")

        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(Self.stored(.text(""), delay) == nil)
    }

    @Test("Typing the default value back clears the key")
    func typedDefaultClears() {
        let model = Self.entry(.text, default: "claude-opus-5")
        #expect(Self.stored(.text("claude-opus-5"), model) == nil)
        #expect(Self.stored(.text("claude-sonnet-5"), model) as? String == "claude-sonnet-5")

        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(Self.stored(.text("12"), delay) == nil)
        #expect(Self.stored(.text(" 30 "), delay) as? Int == 30)
    }

    @Test("A custom summary template is read and the built-in template remains the default")
    func summaryTemplateSetting() {
        #expect(Config.summary(in: nil).template == SummaryTemplate.default)
        #expect(Config.summary(in: [
            "summary": ["template": "## My format\nOnly decisions."],
        ]).template == "## My format\nOnly decisions.")
    }

    @Test("Summary API base URLs have safe defaults and accept compatible servers")
    func summaryBaseURLs() {
        let defaults = Config.summary(in: nil)
        #expect(defaults.openAIBaseURL == "https://api.openai.com/v1")
        #expect(defaults.ollamaBaseURL == "http://127.0.0.1:11434")

        let custom = Config.summary(in: ["summary": [
            "openai_base_url": "https://llm.example/v1/",
            "ollama_base_url": "http://studio.local:11434/",
        ]])
        #expect(custom.openAIBaseURL == "https://llm.example/v1/")
        #expect(custom.ollamaBaseURL == "http://studio.local:11434/")
    }

    @Test("The summary template is an editable multi-line Advanced setting")
    func summaryTemplateAppearsInAdvanced() throws {
        let summaries = try #require(
            SettingsSchema.sections.first { $0.title == localised("Summaries", "Сводка") })
        let template = try #require(
            summaries.entries.first { $0.path == ["summary", "template"] })
        guard case .multilineText = template.kind else {
            Issue.record("summary.template should be a multi-line field")
            return
        }
        #expect(template.defaultValue as? String == SummaryTemplate.default)
        #expect(SettingsSchema.advancedSections
            .flatMap(\.entries).contains { $0.path == ["summary", "template"] })
    }

    /// The field would otherwise write 0, or an empty key, and the recorder
    /// would wait zero seconds before deciding a mic blip was a meeting.
    @Test("Letters in a number field change nothing")
    func garbageNumberRefused() {
        let delay = Self.entry(.number(unit: "seconds"), default: 12)
        #expect(Self.stored(.text("soon"), delay) as? String == "INVALID")
        #expect(Self.stored(.text("12s"), delay) as? String == "INVALID")
    }

    @Test("A list comes apart on commas and drops the gaps")
    func listSplitsOnCommas() {
        let apps = Self.entry(.list, default: "the known conferencing apps")
        #expect(Self.stored(.text("us.zoom.xos, com.tinyspeck.slackmacgap"), apps) as? [String]
            == ["us.zoom.xos", "com.tinyspeck.slackmacgap"])
        #expect(Self.stored(.text("us.zoom.xos,,  ,"), apps) as? [String] == ["us.zoom.xos"])
        #expect(Self.stored(.text("  "), apps) == nil)
    }

    /// The schema is the only list of settings there is — the window renders
    /// it and the README is written against it — so a duplicated path means
    /// two controls quietly fighting over one key.
    @Test("Every setting has a distinct path")
    func pathsAreUnique() {
        let keys = SettingsSchema.knownKeys
        #expect(Set(keys).count == keys.count, "duplicate paths in the schema")
        #expect(!keys.isEmpty)
    }

    /// The settings the setup form asks in full, and therefore the ones
    /// the Advanced tab leaves out. Written down rather than derived, because
    /// there is nothing to derive it from: setup asks these through cards,
    /// switches and an open panel, in its own vocabulary, and no signature in
    /// `SetupForm` says which config key a card stands for.
    ///
    /// So this is a canary, and it is worth having as one. Dropping a control
    /// from setup without clearing its flag here does not break a build or
    /// fail a test elsewhere — it removes the setting from the window
    /// altogether, which is the one failure this schema exists to prevent, and
    /// the one nobody notices until somebody goes looking for a setting that
    /// is no longer anywhere.
    @Test("The settings held back from Advanced are the ones setup asks")
    func setupCoversWhatAdvancedOmits() {
        let held = Set(SettingsSchema.sections
            .flatMap(\.entries)
            .filter(\.askedInSetup)
            .map { $0.path.joined(separator: ".") })
        #expect(held == [
            // The switch at the foot of the form.
            "auto_record.enabled",
            // Both transcription switches off.
            "transcription.enabled",
            // The two switches, "In the cloud" and "On this Mac".
            "transcription.engine",
            // The AssemblyAI and OpenAI cards under the cloud switch.
            "transcription.cloud",
            // The local-engine picker beside the local switch.
            "transcription.local_engine",
            // The optional speaker-separation switch in Setup.
            "transcription.local_diarization",
            // The three speaker-model cards directly under that switch.
            "transcription.diarization_model",
            // The live-transcript switch — Apple Silicon only, on both sides.
            "live_transcription.enabled",
            // Files: the switch, and the folder chosen with an open panel.
            "keep_audio",
            "recordings_dir",
            // The switch beside the Summaries heading.
            "summary.enabled",
            // The separate OpenAI / OpenAI-compatible choice in the own-key card.
            "summary.openai_compatible",
            // The two switches under "Where verbemo shows up".
            "menu_bar_icon",
            "dock_icon",
        ])
    }

    @Test("Summary controls represent every backend allowed by the schema", .freshHome)
    @MainActor
    func summaryCardsCoverSchemaBackends() throws {
        let application = ApplicationWindow()
        application.navigate(.summary)
        defer { withExtendedLifetime(application) {} }
        let entry = try #require(SettingsSchema.sections.flatMap(\.entries).first { $0.path == ["summary", "backend"] })
        guard case .choice(let backends) = entry.kind else { Issue.record("Summary backend must be a choice"); return }
        let cards = try #require(application.panel.contentView).allDescendants.compactMap { $0 as? ChoiceCard }
        for backend in backends {
            Config.update(path: ["summary", "backend"], value: backend)
            let expected = ["anthropic-api", "openai-api"].contains(backend) ? "api-key" : backend
            #expect(cards.filter(\.isSelected).map(\.id) == (backend == "none" ? [] : [expected]))
            if backend == "none" {
                let toggle = try #require(application.panel.contentView?.allDescendants
                    .first { $0.identifier?.rawValue == "summary.enabled" } as? NSSwitch)
                #expect(toggle.state == .off)
            }
        }
    }

    /// The list that tells someone a setting is being ignored has to be right
    /// in one direction above all: a key verbemo *does* read must never appear
    /// in it. It did — `transcription.assemblyai.*` and the two summary key
    /// paths had no entry, so a config written straight from the README was
    /// reported as unread.
    ///
    /// This used to be checked against a sample written out by hand as "every
    /// key Config reads", which could not notice a key nobody had added to
    /// the sample. `Config` now reads only through `Config.Key`, so the two
    /// lists are compared whole, in both directions: a key read and not
    /// described, and a key described and never read.
    @Test("Config reads exactly the keys the schema describes")
    func configAndSchemaAgree() {
        let read = Set(Config.Key.allCases.map(\.rawValue))
        let described = Set(SettingsSchema.knownKeys)
            .subtracting(SettingsSchema.deprecatedKeys)
        #expect(read.subtracting(described).isEmpty,
                "read but not in the schema: \(read.subtracting(described).sorted())")
        #expect(described.subtracting(read).isEmpty,
                "in the schema but read by nothing: \(described.subtracting(read).sorted())")
    }

    /// The other half of the drift: the default. The window shows the
    /// schema's as a placeholder, and `Config` used to write its own inline —
    /// two numbers that only agreed because somebody kept them agreeing. The
    /// readers now take theirs from the schema, and this checks the settings
    /// structs the rest of verbemo is handed, not just the readers.
    @Test("An empty config reads as the schema's defaults", .freshHome)
    func emptyConfigIsTheSchemasDefaults() throws {
        for entry in SettingsSchema.everyEntry where entry.hasValueDefault {
            let key = try #require(Config.Key(rawValue: entry.path.joined(separator: ".")))
            switch entry.kind {
            case .toggle:
                #expect(Config.flag(key, in: [:]) == entry.defaultValue as? Bool, "\(key)")
            case .number:
                let expected = (entry.defaultValue as? Double)
                    ?? (entry.defaultValue as? Int).map(Double.init)
                #expect(Config.number(key, in: [:]) == expected,
                        "\(key)")
            default:
                #expect(Config.string(key, in: [:]) == entry.defaultValue as? String, "\(key)")
            }
        }

        func schema(_ key: Config.Key) -> SettingsSchema.ValueDefault? {
            SettingsSchema.valueDefault(for: key)
        }
        let summary = Config.summary()
        #expect(schema(.summaryModel) == .string(summary.model))
        #expect(schema(.summaryOpenAIModel) == .string(summary.openAIModel))
        #expect(schema(.summaryOllamaBaseURL) == .string(summary.ollamaBaseURL))
        #expect(schema(.summaryTemplate) == .string(summary.template))
        let auto = Config.autoRecord()
        #expect(schema(.autoRecordStartDelay) == .number(auto.startDelay))
        #expect(schema(.autoRecordMaxDuration) == .number(auto.maxDuration / 60))
        #expect(schema(.autoRecordCalendar) == .flag(auto.calendar))
        #expect(schema(.offlineEchoCancellation) == .flag(Config.offlineEchoCancellation()))
        #expect(schema(.keepAudio) == .flag(Config.keepAudio()))
        #expect(schema(.transcriptionEngine) == .string(Config.transcriptionEngine()))
        #expect(schema(.systemAudio) == .string(Config.systemAudioScope()))
    }

    /// A setting whose default is described in words has no value to fall
    /// back on, so a reader asking for one is a mistake — and it is caught
    /// where it is written rather than read as `false`.
    @Test("Asking the schema for a default it describes only in words stops the run")
    func describedDefaultsAreNotValues() async {
        #expect(SettingsSchema.valueDefault(for: .userName) == nil)
        await #expect(processExitsWith: .failure) {
            _ = Config.defaultString(.userName)
        }
    }

    @Test("Writing a key nothing reads stops the run")
    func writingAnUnknownKeyStops() async {
        await #expect(processExitsWith: .failure) {
            _ = Config.update(path: ["recordings_directory"], value: "~/Meetings")
        }
    }

    /// `"enabled": "false"` reads as off to a person and as nothing to a JSON
    /// parser, and the default — on — used to apply without a word.
    @Test("A value of the wrong kind is reported, and the default still applies",
          .freshHome(config: #"""
          {
            "transcription": { "enabled": "false", "language": "" },
            "auto_record": { "start_delay_seconds": "12", "apps": "us.zoom.xos" },
            "system_audio": "everything",
            "keep_audio": true,
            "summary": { "model": 5 }
          }
          """#))
    func wrongKindsAreReported() {
        let problems = Config.problems()
        let keys = problems.compactMap { problem -> String? in
            if case .unusable(let key, _, _) = problem { return key }
            return nil
        }
        #expect(Set(keys) == [
            "transcription.enabled", "auto_record.start_delay_seconds", "auto_record.apps",
            "system_audio", "summary.model",
        ])
        #expect(Config.transcriptionEnabled(), "the default no longer applies")
        let enabled = problems.first {
            if case .unusable("transcription.enabled", _, _) = $0 { return true }
            return false
        }
        #expect(enabled?.explanation.contains(#""false""#) == true)
        #expect(enabled?.explanation.contains("true or false") == true)

        guard case .warn = DoctorReport.checkConfig().status else {
            Issue.record("the doctor said nothing about it")
            return
        }
    }

    @Test("A config holding only usable values has nothing to report",
          .freshHome(config: #"""
          {
            "transcription": { "enabled": false, "engine": "assemblyai", "language": "ru" },
            "auto_record": { "start_delay_seconds": 20, "apps": [] },
            "summary": { "template": "## Decisions", "api_key_path": "~/key" }
          }
          """#))
    func usableValuesAreQuiet() {
        #expect(Config.problems().isEmpty, "\(Config.problems())")
    }

    /// The settings window on an Intel Mac renders neither of these — there is
    /// no local model behind them — but the config file may well carry them,
    /// and telling somebody their working setting is ignored is the one
    /// direction this list must never fail in.
    @Test("Settings only shown on Apple Silicon are still known keys")
    func localModelKeysAreNeverStray() {
        let config: [String: Any] = [
            "live_transcription": ["enabled": true],
            "transcription": ["model": "v3"],
        ]
        #expect(SettingsSchema.strayKeys(in: config).isEmpty,
                "reported as unread: \(SettingsSchema.strayKeys(in: config))")
    }

    /// The other direction, which is the point of the list existing.
    @Test("A key nothing reads is named, nested or not")
    func strayKeysAreReported() {
        let config: [String: Any] = [
            "recordings_dir": "~/Verbemo Recordings",
            "recordings_directory": "~/Meetings",
            "transcription": ["enabled": true, "engien": "auto"],
            "summarize": ["enabled": true],
        ]
        #expect(SettingsSchema.strayKeys(in: config)
            == ["recordings_directory", "summarize", "transcription.engien"])
    }

    @Test("Removed audio-format keys stay accepted for old config files")
    func removedAudioKeysAreNotReportedAsTypos() {
        let oldConfig: [String: Any] = [
            "compress_tracks": false,
            "keep_uncompressed": true,
        ]
        #expect(SettingsSchema.strayKeys(in: oldConfig).isEmpty)
    }

    /// An inline API key is the one setting with no control, and the reason is
    /// that a text field would put a secret on screen. It still has to count
    /// as read.
    @Test("The unrendered inline key is known but has no control")
    func unrenderedKeysStayKnown() {
        let rendered = Set(SettingsSchema.sections
            .flatMap(\.entries)
            .map { $0.path.joined(separator: ".") })
        for key in SettingsSchema.unrenderedKeys {
            #expect(!rendered.contains(key), "\(key) has a control after all")
            #expect(SettingsSchema.knownKeys.contains(key))
        }
    }

    /// A default of the wrong type would render as a placeholder saying one
    /// thing and compare as another — the control would never clear, and the
    /// file would collect a key holding the default forever.
    @Test("Toggle and number defaults have the type their control expects")
    func defaultsMatchTheirKind() {
        for section in SettingsSchema.sections {
            for entry in section.entries {
                switch entry.kind {
                case .toggle:
                    #expect(entry.defaultValue is Bool, "\(entry.path) toggle default isn't a Bool")
                case .number:
                    let integer = entry.defaultValue as? Int
                    let real = entry.defaultValue as? Double
                    #expect(integer != nil || real?.isFinite == true,
                            "\(entry.path) number default must be a finite Int or Double")
                case .choice(let options):
                    // A default outside its own option list can't be selected,
                    // so the pop-up would open on something else and the first
                    // change would write a value that was already in effect.
                    let value = entry.defaultValue as? String
                    #expect(value != nil && options.contains(value!),
                            "\(entry.path) default isn't one of its options")
                case .text, .multilineText, .list:
                    #expect(entry.defaultValue is String,
                            "\(entry.path) default should be shown as text")
                }
            }
        }
    }

    @Test("GigaAM is a configurable local transcription engine")
    func gigaAMIsInLocalEngineChoices() throws {
        let entry = try #require(SettingsSchema.sections
            .flatMap(\.entries)
            .first { $0.path == ["transcription", "local_engine"] })
        guard case .choice(let options) = entry.kind else {
            Issue.record("transcription.local_engine must be a choice")
            return
        }
        #expect(options.contains("gigaam"))
    }
}

/// The actual Journal settings pages retain the schema's editors and defaults.
@Suite(.serialized)
@MainActor
struct SettingsControllerTests {
    @Test("Every schema setting not covered by the form gets a control", .freshHome)
    func rendersEverySetting() throws {
        let application = ApplicationWindow()
        let settings = application.settings
        defer { withExtendedLifetime(application) {} }
        let entries = SettingsSchema.sections.flatMap(\.entries).filter {
            !SetupForm.settingsCoveredPaths.contains($0.path.joined(separator: "."))
        }
        #expect(settings.renderedControls.count == entries.count)
        for entry in entries {
            application.navigate(SettingsPage.destination(for: entry.path))
            let control = try #require(settings.renderedControls.first { $0.identifier?.rawValue == entry.path.joined(separator: ".") })
            #expect(control.window === application.panel)
            if entry.path == ["user_email"] {
                #expect(control is EmailAddressesEditor)
                continue
            }
            switch entry.kind {
            case .toggle:
                #expect(control is NSSwitch, "\(entry.path) should be a switch")
            case .choice(let options):
                let popup = try #require(control as? NSPopUpButton)
                let values = popup.itemArray.map { $0.representedObject as? String ?? $0.title }
                #expect(values == options, "\(entry.path) is missing options")
            case .number, .text, .multilineText, .list:
                #expect(control is NSTextField, "\(entry.path) should be a text field")
            }
        }
    }

    @Test("Every schema field shows its own default", .freshHome)
    func fieldsShowDefaults() throws {
        let application = ApplicationWindow()
        let settings = application.settings
        defer { withExtendedLifetime(application) {} }
        for entry in SettingsSchema.sections.flatMap(\.entries) {
            guard let field = settings.renderedControls.first(where: {
                $0.identifier?.rawValue == entry.path.joined(separator: ".")
            }) as? NSTextField else { continue }
            application.navigate(SettingsPage.destination(for: entry.path))
            #expect(field.window === application.panel)
            if case .multilineText = entry.kind {
                #expect(field.stringValue == SettingsSchema.describeDefault(entry),
                        "\(entry.path) doesn't start with its editable default")
                continue
            }
            #expect(field.placeholderString == SettingsSchema.describeDefault(entry),
                    "\(entry.path) doesn't show its default as its placeholder")
            #expect(!(field.placeholderString ?? "").isEmpty, "\(entry.path) has no placeholder")
        }
    }

    @Test("Return inserts a newline in the summary template", .freshHome)
    func multilineReturn() throws {
        let application = ApplicationWindow()
        application.navigate(.summary)
        defer { withExtendedLifetime(application) {} }
        let settings = application.settings
        let field = try #require(settings.renderedControls.first { $0.identifier?.rawValue == "summary.template" } as? NSTextField)
        let editor = NSTextView()
        editor.string = "First line"
        editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)

        #expect(settings.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(editor.string == "First line\n")
    }
}

/// The public configuration reference must remain discoverable from the README
/// and cover every setting that the schema exposes, including provider key paths.
@Suite("Every setting is documented")
struct SettingsDocumentationTests {
    private static let referencePath = "docs/configuration.md"

    /// Find the repository from this file; SwiftPM does not promise a working directory.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // verbemoTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    static var readme: String {
        get throws {
            try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        }
    }

    static var configurationReference: String {
        get throws {
            try String(contentsOf: root.appendingPathComponent(referencePath), encoding: .utf8)
        }
    }

    @Test("The README links to the complete public configuration reference")
    func referenceIsDiscoverable() throws {
        let readme = try Self.readme
        let reference = try Self.configurationReference
        #expect(readme.contains("](\(Self.referencePath))"), "README.md must link to \(Self.referencePath)")
        #expect(!reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Name each setting in full, or name its group and leaf in the reference prose.
    @Test("Every setting in the schema is named in the configuration reference")
    func everySettingIsInTheReference() throws {
        let reference = try Self.configurationReference
        var undocumented: [String] = []

        for entry in SettingsSchema.sections.flatMap({ $0.entries }) {
            let path = entry.path.joined(separator: ".")
            if reference.contains(path) { continue }

            let group = entry.path.dropLast().joined(separator: ".")
            let leaf = entry.path[entry.path.count - 1]
            if !group.isEmpty, reference.contains("`\(group).*`"), reference.contains(leaf) {
                continue
            }
            undocumented.append(path)
        }

        #expect(undocumented.isEmpty, "not in \(Self.referencePath): \(undocumented.joined(separator: ", "))")
    }

    /// Advertised provider paths must be explicit and still be real Config keys.
    @Test("The advertised key-file settings are documented settings verbemo reads")
    func keyPathsAreReal() throws {
        let reference = try Self.configurationReference
        let advertised = [
            "transcription.assemblyai.api_key_path",
            "summary.api_key_path",
            "summary.openai_api_key_path",
            "summary.openai_compatible_api_key_path",
            "transcription.openai.api_key_path",
        ]
        for key in advertised {
            #expect(reference.contains(key), "\(key) must be explicit in \(Self.referencePath)")
            #expect(SettingsSchema.knownKeys.contains(key), "\(key) is not a known setting")
        }
    }
}
