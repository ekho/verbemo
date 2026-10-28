using System.Text.Json.Nodes;
using Verbemo.Core.Configuration;
using static Verbemo.Core.MCP.McpContract;

namespace Verbemo.Core.MCP;

/// <summary>Projection of a known-good config and captured runtime values; never accesses credentials.</summary>
public sealed class McpSettings(JsonObject raw, IReadOnlyDictionary<string, JsonNode?> effective,
    IReadOnlyDictionary<string, JsonNode?> applied, IReadOnlyDictionary<string, bool> secretConfigured, string homeDirectory)
{
    private static readonly HashSet<string> Exported =
    [
        "auto_record.enabled", "auto_record.mic_activity", "auto_record.start_delay_seconds", "auto_record.stop_delay_seconds",
        "auto_record.min_duration_seconds", "auto_record.silence_stop_minutes", "auto_record.max_duration_minutes", "auto_record.apps",
        "auto_record.ignore_apps", "system_audio", "keep_audio", "recordings_dir",
        "transcription.enabled", "live_transcription.enabled", "transcription.engine", "transcription.cloud",
        "transcription.local_engine", "transcription.language", "transcript_echo_filter", "transcription.assemblyai.speech_model",
        "transcription.openai.model", "summary.enabled", "summary.backend", "summary.model",
        "summary.openai_model", "summary.openai_base_url", "summary.openai_compatible", "summary.ollama_model",
        "summary.ollama_base_url", "summary.language", "summary.template", "speaker_names.enabled",
        "user_name", "user_email", "speaker_names.backend", "speaker_names.model",
        "interface_theme", "interface_language", "start_at_login", "tray_icon",
        "taskbar_icon", "on_stop", "mcp.enabled", "mcp.port",
    ];
    private static readonly HashSet<string> Secrets = ["transcription.openai.api_key", "transcription.assemblyai.api_key", "transcription.elevenlabs.api_key", "summary.api_key", "summary.openai_api_key", "summary.openai_compatible_api_key", "mcp.token"];
    public JsonObject Project(string[]? keys = null)
    {
        var entries = SettingsSchema.Entries.Where(x => Exported.Contains(x.Path)).ToDictionary(x => x.Path); var available = entries.Keys.Concat(Secrets).ToHashSet(); var selected = keys?.ToHashSet() ?? available; if (!selected.IsSubsetOf(available)) throw new McpFailure("invalid_params"); var items = new JsonArray();
        foreach (var key in selected.Order(StringComparer.Ordinal))
        {
            entries.TryGetValue(key, out var entry); var saved = SettingsDocument.Get(raw, key); var configuredInFile = HasRaw(key); var fields = new JsonObject { ["key"] = key, ["needs_restart"] = entry?.NeedsRestart ?? false }; var redacted = Secrets.Contains(key) || key == "on_stop" || key.EndsWith("api_key_path", StringComparison.Ordinal);
            if (redacted) { fields["configured"] = secretConfigured.TryGetValue(key, out var configured) ? configured : saved is not null && Text(saved) != ""; fields["redacted"] = true; }
            else if (entry is not null)
            {
                var fallback = SettingsSchema.DefaultFor(key, homeDirectory); var value = effective.GetValueOrDefault(key) ?? saved ?? fallback; fields["value"] = Safe(value, key); fields["source"] = configuredInFile ? "configured" : effective.ContainsKey(key) && !JsonNode.DeepEquals(value, fallback) ? "runtime" : "default";
                if (entry.NeedsRestart) { fields["saved_value"] = Safe(saved ?? value, key); fields["applied_value"] = Safe(applied.GetValueOrDefault(key), key); fields["pending_apply"] = applied.ContainsKey(key) ? JsonValue.Create(!JsonNode.DeepEquals(applied[key], saved ?? value)) : null; } else fields["pending_apply"] = false;
            }
            items.Add(fields);
        }
        return new() { ["platform"] = "windows", ["configuration_status"] = "readable", ["items"] = items };
    }
    private bool HasRaw(string key)
    {
        JsonNode? node = raw;
        foreach (var part in key.Split('.')) { if (node is not JsonObject obj || !obj.TryGetPropertyValue(part, out node)) return false; }
        return true;
    }
    private static JsonNode? Safe(JsonNode? value, string key)
    {
        if (value is JsonObject || value is JsonArray arr && arr.Any(x => Text(x) is null)) return null;
        if (!key.EndsWith("_url", StringComparison.Ordinal) || Text(value) is not { } text) return value?.DeepClone();
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || string.IsNullOrEmpty(uri.Host)) return null;
        return JsonValue.Create(new UriBuilder(uri) { UserName = "", Password = "", Query = "", Fragment = "" }.Uri.AbsoluteUri);
    }
}
