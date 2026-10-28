import Foundation

/// Caller supplies a known-good document and captured runtime values; never reads a key store.
struct MCPSettings: Sendable {
    let raw: [String: MCPJSON]
    let effective: [String: MCPJSON]
    let applied: [String: MCPJSON]
    let secretConfigured: [String: Bool]
    init(raw: [String: MCPJSON], effective: [String: MCPJSON], applied: [String: MCPJSON], secretConfigured: [String: Bool]) {
        self.raw = raw; self.effective = effective; self.applied = applied; self.secretConfigured = secretConfigured
    }
    // Export policy is deliberate: new schema entries remain private until reviewed here.
    private static let exportedKeys: Set<String> = [
        "recordings_dir", "transcription.enabled", "transcription.engine",
        "transcription.local_engine", "transcription.cloud", "transcription.openai.model",
        "transcription.model", "transcription.language", "transcription.local_diarization",
        "transcription.diarization_model", "transcription.diarization_threshold", "transcription.assemblyai.speech_model",
        "live_transcription.enabled", "mic_voice_processing",
        "transcript_echo_filter", "offline_echo_cancellation", "user_name",
        "user_email", "speaker_names.enabled", "speaker_names.backend",
        "speaker_names.model", "auto_record.enabled", "auto_record.mic_activity",
        "auto_record.calendar", "auto_record.start_delay_seconds", "auto_record.stop_delay_seconds",
        "auto_record.min_duration_seconds", "auto_record.max_duration_minutes", "auto_record.silence_stop_minutes",
        "auto_record.apps", "auto_record.any_app", "auto_record.ignore_apps",
        "system_audio", "calendar", "calendar_ids",
        "dock_icon", "menu_bar_icon", "window",
        "interface_theme", "interface_language", "keep_audio",
        "summary.enabled", "summary.backend", "summary.language",
        "summary.model", "summary.ollama_model", "summary.openai_model",
        "summary.openai_base_url", "summary.openai_compatible", "summary.ollama_base_url",
        "summary.template", "mcp.enabled", "mcp.port",
        "on_stop", "transcription.openai.api_key_path", "transcription.assemblyai.api_key_path",
        "transcription.elevenlabs.api_key_path", "summary.api_key_path", "summary.openai_api_key_path",
        "summary.openai_compatible_api_key_path",
    ]
    func project(keys: [String]?) throws -> MCPJSON {
        let schema = SettingsSchema.everyEntry
        let entries = Dictionary(uniqueKeysWithValues: schema.map { ($0.path.joined(separator: "."), $0) })
        let secretKeys: Set<String> = ["transcription.assemblyai.api_key", "transcription.elevenlabs.api_key", "mcp.token"]
        let available = Set(entries.keys).intersection(Self.exportedKeys).union(secretKeys)
        let selected = keys.map(Set.init) ?? available
        guard selected.isSubset(of: available), keys?.contains(where: { $0.isEmpty }) != true else { throw MCPFailure(.invalidParams) }
        var items: [MCPJSON] = []
        for key in selected.sorted() {
            let entry = entries[key]
            let saved = lookup(key)
            let redacted = secretKeys.contains(key) || key == "on_stop" || key.hasSuffix("api_key_path")
            var fields: [String: MCPJSON] = ["key": .string(key), "needs_restart": .bool(entry?.needsRestart ?? false)]
            if redacted {
                fields["configured"] = .bool(secretConfigured[key] ?? (saved != nil && saved != .null && saved != .string("")))
                fields["redacted"] = .bool(true)
            } else if let entry {
                let fallback: MCPJSON
                if entry.hasValueDefault {
                    let data = try JSONSerialization.data(withJSONObject: entry.defaultValue, options: [.fragmentsAllowed])
                    fallback = try MCPJSON.parse(data)
                } else { fallback = .null }
                let value = effective[key] ?? saved ?? fallback
                fields["value"] = safe(value, key: key)
                fields["source"] = .string(saved != nil ? "configured" : effective[key] != nil && effective[key] != fallback ? "runtime" : "default")
                if entry.needsRestart {
                    // Absence of a captured startup value is unknown, never the saved value.
                    fields["saved_value"] = safe(saved ?? value, key: key)
                    fields["applied_value"] = safe(applied[key] ?? .null, key: key)
                    fields["pending_apply"] = applied[key].map { .bool($0 != (saved ?? value)) } ?? .null
                } else { fields["pending_apply"] = .bool(false) }
            }
            items.append(.object(fields))
        }
        return .object(["platform": .string("macos"), "configuration_status": .string("readable"), "items": .array(items)])
    }
    private func lookup(_ key: String) -> MCPJSON? {
        var value = MCPJSON.object(raw)
        for part in key.split(separator: ".") {
            guard let next = value[String(part)] else { return nil }
            value = next
        }
        return value
    }
    private func safe(_ value: MCPJSON, key: String) -> MCPJSON {
        // Schema fields may hold only their intended scalar/list values, never arbitrary nested keys.
        guard value.object == nil else { return .null }
        if let array = value.array, array.contains(where: { $0.string == nil }) { return .null }
        guard key.hasSuffix("_url"), let text = value.string else { return value }
        guard var url = URLComponents(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return .null }
        url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
        return .optional(url.string)
    }
}
