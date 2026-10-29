using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Verbemo.Core.MCP;

public sealed class McpFailure(string code) : Exception(code)
{
    public string Code { get; } = code;
    public bool Retryable => Code is "artifact_not_ready" or "content_changed";
    public JsonObject Json => new() { ["code"] = Code, ["message"] = Code, ["retryable"] = Retryable };
}

public static class McpContract
{
    public static readonly string[] Tools = ["list_meetings", "get_meeting", "list_transcript_versions", "get_meeting_transcript", "get_meeting_summary", "search_meetings", "get_meeting_audio", "get_settings"];
    public static readonly string[] Stages = ["transcription", "diarization", "speaker_naming", "summary"];
    public static readonly string[] States = ["pending", "running", "deferred", "failed", "off", "done", "cancelled", "unknown"];
    public const int SoftTextBytes = 65536, HardResponseBytes = 1048576;
    internal static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly JsonSerializerOptions JsonOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    public static byte[] Encode(JsonNode node) => JsonSerializer.SerializeToUtf8Bytes(Sorted(node), JsonOptions);
    private static JsonNode? Sorted(JsonNode? node) => node switch {
        JsonObject obj => new JsonObject(obj.OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => KeyValuePair.Create(x.Key, Sorted(x.Value)))),
        JsonArray arr => new JsonArray(arr.Select(Sorted).ToArray()), _ => node?.DeepClone()
    };
    public static string Hash(string value) => Hash(Utf8.GetBytes(value));
    public static string Hash(byte[] value) => Convert.ToHexStringLower(SHA256.HashData(value));
    internal static string Framed(IEnumerable<string> values) => string.Concat(values.Select(x => Utf8.GetByteCount(x).ToString(CultureInfo.InvariantCulture) + ":" + x));
    public static string MeetingId(string root, string relative) => "m_" + Hash("verbemo-meeting-v1\0" + Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + "\0" + relative);
    public static DateTimeOffset? Date(string? text) => text is not null && Regex.IsMatch(text, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$") && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) ? date : null;
    public static string VersionId(JsonObject transcript, string generation = "")
    {
        var values = new List<string> { Text(transcript["engine"])!, Text(transcript["model"])!, Date(Text(transcript["created_at"]))!.Value.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture) };
        foreach (var segment in transcript["segments"]!.AsArray()) values.AddRange([Text(segment!["speaker"]) ?? "", Integer(segment["start_ms"]).ToString(CultureInfo.InvariantCulture), Integer(segment["end_ms"]).ToString(CultureInfo.InvariantCulture), Text(segment["text"])!]);
        values.Add(generation); return "v_" + Hash(Framed(values));
    }
    public static JsonObject ResultEnvelope(JsonNode value)
    {
        var content = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = Utf8.GetString(Encode(value)) });
        if (value["resources"] is JsonArray resources) foreach (var resource in resources) content.Add(resource?.DeepClone());
        return new() { ["isError"] = false, ["structuredContent"] = value.DeepClone(), ["content"] = content };
    }
    public static JsonObject CheckSize(JsonObject value) { if (Encode(ResultEnvelope(value)).Length > HardResponseBytes) throw new McpFailure("response_too_large"); return value; }
    internal static string? Text(JsonNode? node) => node is JsonValue v && v.TryGetValue<string>(out var text) ? text : null;
    internal static bool? Bool(JsonNode? node) => node is JsonValue v && v.TryGetValue<bool>(out var flag) ? flag : null;
    internal static long Integer(JsonNode? node, string code = "data_unreadable")
    {
        if (node is JsonValue v && v.GetValueKind() == JsonValueKind.Number && decimal.TryParse(v.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && n == decimal.Truncate(n) && n >= long.MinValue && n <= long.MaxValue) return (long)n;
        throw new McpFailure(code);
    }
    internal static JsonArray Array(IEnumerable<JsonNode?> values) => new(values.Select(x => x?.DeepClone()).ToArray());
    internal static bool Unknown(string? label) => string.IsNullOrEmpty(label) || label == "?" || label.EndsWith(" ?", StringComparison.Ordinal);
}

internal sealed class McpArguments(JsonObject values)
{
    public string? String(string key, string? fallback = null) => !values.ContainsKey(key) ? fallback : McpContract.Text(values[key]) ?? throw new McpFailure("invalid_params");
    public long? Integer(string key, long? fallback = null, long min = 0, long max = long.MaxValue) { if (!values.ContainsKey(key)) return fallback; var n = McpContract.Integer(values[key], "invalid_params"); if (n < min || n > max) throw new McpFailure("invalid_params"); return n; }
    public string? Choice(string key, string[] choices, string? fallback = null) { var value = String(key, fallback); if (value is not null && !choices.Contains(value)) throw new McpFailure("invalid_params"); return value; }
    public string[]? Strings(string key) { if (!values.ContainsKey(key)) return null; if (values[key] is not JsonArray arr) throw new McpFailure("invalid_params"); return arr.Select(x => McpContract.Text(x) ?? throw new McpFailure("invalid_params")).ToArray(); }
    public void Keys(IEnumerable<string> allowed) { if (values.Any(x => !allowed.Contains(x.Key))) throw new McpFailure("invalid_params"); }
}

internal static class McpCursor
{
    private static string Digest(JsonObject args, string operation) { var copy = (JsonObject)args.DeepClone(); copy.Remove("cursor"); copy["operation"] = operation; return McpContract.Hash(McpContract.Encode(copy)); }
    public static void Validate(JsonObject args)
    {
        if (!args.TryGetPropertyValue("cursor", out var value)) return;
        var text = McpContract.Text(value);
        if (text is null || text.Length is 0 or > 4096 || !Regex.IsMatch(text, "^[A-Za-z0-9_-]+$")) throw new McpFailure("invalid_cursor");
        try
        {
            var encoded = text.Replace('-', '+').Replace('_', '/');
            var cursor = JsonNode.Parse(Convert.FromBase64String(encoded.PadRight((encoded.Length + 3) / 4 * 4, '=')))!.AsObject();
            if (McpContract.Integer(cursor["format"], "invalid_cursor") != 1 || McpContract.Integer(cursor["offset"], "invalid_cursor") < 0 || McpContract.Text(cursor["digest"]) is null || McpContract.Text(cursor["revision"]) is null || cursor["version"] is not null && McpContract.Text(cursor["version"]) is null) throw new McpFailure("invalid_cursor");
        }
        catch { throw new McpFailure("invalid_cursor"); }
    }
    public static long Offset(JsonObject args, string operation, string revision, string? version = null)
    {
        Validate(args); if (!args.ContainsKey("cursor")) return 0;
        JsonObject cursor;
        try { var text = args["cursor"]!.GetValue<string>().Replace('-', '+').Replace('_', '/'); cursor = JsonNode.Parse(Convert.FromBase64String(text.PadRight((text.Length + 3) / 4 * 4, '=')))!.AsObject(); }
        catch { throw new McpFailure("invalid_cursor"); }
        var offset = McpContract.Integer(cursor["offset"], "invalid_cursor");
        if (McpContract.Integer(cursor["format"], "invalid_cursor") != 1 || offset < 0 || McpContract.Text(cursor["digest"]) != Digest(args, operation)) throw new McpFailure("invalid_cursor");
        if (McpContract.Text(cursor["revision"]) != revision || McpContract.Text(cursor["version"]) != version) throw new McpFailure("content_changed");
        return offset;
    }
    public static string? Next(long? offset, JsonObject args, string operation, string revision, string? version = null) => offset is null ? null : Convert.ToBase64String(McpContract.Encode(new JsonObject { ["format"] = 1, ["digest"] = Digest(args, operation), ["revision"] = revision, ["version"] = version, ["offset"] = offset })).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
