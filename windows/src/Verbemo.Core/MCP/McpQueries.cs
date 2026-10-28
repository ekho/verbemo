using System.Text.Json.Nodes;
using static Verbemo.Core.MCP.McpContract;

namespace Verbemo.Core.MCP;

public static class McpQueries
{
    private static readonly string[] ListKeys = ["started_from", "started_before", "title_contains", "participants", "participant_scope", "participant_match", "has_transcript", "has_summary", "has_audio", "participant_assignment", "processing_stage", "processing_state", "sort", "limit", "cursor"];
    /// <summary>Synchronous bounded reads. Run off the UI thread, behind the host's admission gate.</summary>
    public static JsonObject Call(string tool, JsonObject arguments, McpLibrary.Runtime runtime, McpSettings? settings = null)
    {
        runtime.Check(); var args = new McpArguments(arguments); JsonObject result;
        if (tool == "get_settings") { args.Keys(["keys"]); result = (settings ?? throw new McpFailure("data_unreadable")).Project(args.Strings("keys")); }
        else if (tool is "list_meetings" or "search_meetings")
        {
            args.Keys(tool == "list_meetings" ? ListKeys : [.. ListKeys, "query", "scope"]); var filter = new Filter(arguments); var query = tool == "search_meetings" ? args.String("query") : null;
            if (tool == "search_meetings" && string.IsNullOrWhiteSpace(query)) throw new McpFailure("invalid_params");
            var scope = args.Choice("scope", ["transcript", "summary", "both"], "both")!; McpCursor.Validate(arguments);
            var snapshot = McpLibrary.Scan(runtime); var meetings = filter.Select(snapshot.Meetings); var offset = McpCursor.Offset(arguments, tool, snapshot.Revision); var limit = (int)args.Integer("limit", 20, 1, 100)!;
            if (query is null) { var page = Page(meetings.Select(x => x.Card).ToArray(), offset, limit); result = Listing(page.Items, page.Next, arguments, tool, snapshot.Revision, snapshot.Warnings); }
            else result = Search(meetings, query, scope, offset, limit, arguments, snapshot, runtime);
        }
        else if (tool is "get_meeting" or "list_transcript_versions" or "get_meeting_transcript" or "get_meeting_summary" or "get_meeting_audio")
        {
            args.Keys(tool switch { "list_transcript_versions" => ["meeting_id", "limit", "cursor"], "get_meeting_transcript" => ["meeting_id", "version_id", "start_ms", "end_ms", "limit", "cursor"], "get_meeting_summary" => ["meeting_id", "version_id", "cursor"], _ => ["meeting_id"] });
            var id = args.String("meeting_id"); if (string.IsNullOrEmpty(id)) throw new McpFailure("invalid_params");
            var start = args.Integer("start_ms", 0)!.Value; var end = args.Integer("end_ms"); if (end <= start) throw new McpFailure("invalid_params");
            var limit = (int)args.Integer("limit", tool == "get_meeting_transcript" ? 100 : 20, 1, tool == "get_meeting_transcript" ? 500 : 100)!;
            var selector = args.String("version_id", "current")!; McpCursor.Validate(arguments);
            using var meeting = McpLibrary.Get(id, runtime, tool is "get_meeting" or "list_transcript_versions" || selector != "current", tool == "get_meeting_transcript", tool == "get_meeting");
            if (tool == "get_meeting") result = Details(meeting);
            else if (tool == "get_meeting_audio") result = Audio(meeting, runtime);
            else if (tool == "list_transcript_versions")
            {
                var offset = McpCursor.Offset(arguments, tool, meeting.Revision); var versions = meeting.Versions.Where(x => x.Transcript is not null).OrderByDescending(x => x.Transcript!.CreatedDate).ThenBy(x => x.Id, StringComparer.Ordinal).ToArray();
                if (offset > versions.Length) throw new McpFailure("invalid_cursor"); var cards = new List<JsonObject>(); var size = 0; long index = offset;
                while (index < versions.Length && cards.Count < limit) { var version = versions[index]; if (version.Transcript!.Labels is null) { if (cards.Count > 0) break; throw new McpFailure("response_too_large"); } var card = VersionCard(version, meeting); var bytes = Encode(card).Length; if (cards.Count > 0 && size + bytes > SoftTextBytes) break; cards.Add(card); size += bytes; index++; }
                result = Listing(cards, index < versions.Length ? index : null, arguments, tool, meeting.Revision, meeting.Warnings);
            }
            else
            {
                var version = selector == "current" ? meeting.Current : meeting.Versions.FirstOrDefault(x => x.Id == selector) ?? throw new McpFailure("version_not_found");
                if (tool == "get_meeting_transcript") result = Transcript(meeting, version, start, end, limit, arguments, runtime);
                else
                {
                    if (version.SummaryError is { } error) throw new McpFailure(error); var summary = version.Summary ?? throw new McpFailure("artifact_not_found"); var offset = McpCursor.Offset(arguments, tool, version.Revision, version.Id); var page = summary.Page(offset);
                    result = new() { ["meeting_id"] = id, ["version_id"] = version.Id, ["revision"] = version.Revision, ["source_version_id"] = null, ["stale"] = version.Stale, ["markdown"] = page.Text, ["next_cursor"] = McpCursor.Next(page.Next, arguments, tool, version.Revision, version.Id) };
                }
            }
            meeting.Validate();
        }
        else throw new McpFailure("unknown_tool");
        runtime.Check(); return CheckSize(result);
    }
    private static (List<JsonObject> Items, long? Next) Page(JsonObject[] values, long offset, int limit)
    {
        if (offset > values.Length) throw new McpFailure("invalid_cursor"); var items = new List<JsonObject>(); var size = 0; long index = offset;
        while (index < values.Length && items.Count < limit) { var bytes = Encode(values[index]).Length; if (items.Count > 0 && size + bytes > SoftTextBytes) break; items.Add(values[index++]); size += bytes; }
        return (items, index < values.Length ? index : null);
    }
    private static JsonObject Listing(IEnumerable<JsonObject> items, long? next, JsonObject args, string tool, string revision, JsonArray warnings) => new() { ["items"] = Array(items), ["next_cursor"] = McpCursor.Next(next, args, tool, revision), ["revision"] = revision, ["partial"] = warnings.Count > 0, ["warnings"] = warnings.DeepClone() };
    private static JsonObject Details(McpLibrary.Meeting meeting)
    {
        if (meeting.Current.Transcript is { Labels: null } || meeting.Current.NamesError == "response_too_large") throw new McpFailure("response_too_large"); var result = meeting.Card; var assignment = meeting.Current.Assignment(meeting.Participants);
        result["current_version_id"] = meeting.Current.Id; result["version_count"] = meeting.Versions.Count(x => x.Transcript is not null); result["linked_speakers"] = assignment.Linked; result["unlinked_speakers"] = assignment.Unlinked; result["unknown_segments"] = assignment.Unknown;
        result["speakers"] = Array((meeting.Current.Transcript?.Labels ?? []).Order(StringComparer.Ordinal).Select(label => { var name = Unknown(label) ? null : meeting.Current.Names.GetValueOrDefault(label); return new JsonObject { ["speaker_id"] = label, ["speaker_name"] = name?.Display, ["participant_id"] = meeting.Participants.Any(x => Text(x?["participant_id"]) == name?.Participant) ? name?.Participant : null }; }));
        if (meeting.Meta["calendar"] is JsonObject calendar) { var info = new JsonObject(); foreach (var key in new[] { "event_id", "association", "title", "calendar_title", "agenda", "scheduled_start", "scheduled_end", "time_zone" }) info[key] = key is "scheduled_start" or "scheduled_end" && Date(Text(calendar[key])) is null ? null : calendar[key]?.DeepClone(); result["calendar"] = info; } else result["calendar"] = null;
        result["partial"] = meeting.Warnings.Count > 0; result["warnings"] = meeting.Warnings.DeepClone(); return result;
    }
    private static JsonObject VersionCard(McpLibrary.Version version, McpLibrary.Meeting meeting) => new() { ["version_id"] = version.Id, ["created_at"] = version.Transcript?.CreatedAt, ["engine"] = version.Transcript?.Engine, ["model"] = version.Transcript?.Model, ["is_current"] = version.Current, ["has_summary"] = version.HasSummary, ["summary_stale"] = version.Stale, ["participant_assignment"] = version.Assignment(meeting.Participants).State, ["speakers"] = Array((version.Transcript?.Labels ?? []).Order(StringComparer.Ordinal).Select(x => JsonValue.Create(x))) };
    private static JsonObject Transcript(McpLibrary.Meeting meeting, McpLibrary.Version version, long start, long? end, int limit, JsonObject arguments, McpLibrary.Runtime runtime)
    {
        if (version.TranscriptError is { } error) throw new McpFailure(error); var transcript = version.Transcript ?? throw new McpFailure("artifact_not_found"); if (version.NamesError is { } namesError) throw new McpFailure(namesError);
        var revision = Hash(Framed([version.Revision, meeting.MetadataRevision])); var offset = McpCursor.Offset(arguments, "get_meeting_transcript", revision, version.Id); var selected = new List<McpTextArtifacts.Segment>(); long position = 0, bytes = 0; var more = false;
        transcript.Each(segment => { if (arguments.ContainsKey("start_ms") && segment.End <= start || end is not null && segment.Start >= end) return true; if (position++ < offset) return true; if (selected.Count == limit || selected.Count > 0 && bytes + segment.Text.Bytes > SoftTextBytes) { more = true; return false; } if (segment.Text.Bytes > HardResponseBytes) throw new McpFailure("response_too_large"); selected.Add(segment); bytes += segment.Text.Bytes; return true; });
        if (offset > position) throw new McpFailure("invalid_cursor");
        while (true)
        {
            try
            {
                var labels = selected.Where(x => !Unknown(x.Speaker)).Select(x => x.Speaker!).ToHashSet(); var names = version.NamesFile is { } namesFile ? McpLibrary.Names(namesFile, labels, runtime.Check) : new Dictionary<string,McpLibrary.Name>();
                var ids = meeting.ExistingParticipants(names.Values.Where(x => x.Participant is not null).Select(x => x.Participant!).ToHashSet());
                var segments = selected.Select(segment => { var name = segment.Speaker is null ? null : names.GetValueOrDefault(segment.Speaker); return new JsonObject { ["segment_index"] = segment.Index, ["start_ms"] = segment.Start, ["end_ms"] = segment.End, ["speaker_id"] = segment.Speaker, ["speaker_name"] = name?.Display, ["participant_id"] = name?.Participant is { } id && ids.Contains(id) ? id : null, ["text"] = transcript.Text(segment) }; });
                return CheckSize(new() { ["meeting_id"] = meeting.Id, ["version_id"] = version.Id, ["revision"] = revision, ["language"] = null, ["engine"] = transcript.Engine, ["model"] = transcript.Model, ["segments"] = Array(segments), ["next_cursor"] = McpCursor.Next(more ? offset + selected.Count : null, arguments, "get_meeting_transcript", revision, version.Id) });
            }
            catch (McpFailure e) when (e.Code == "response_too_large" && selected.Count > 1) { selected.RemoveRange(selected.Count / 2, selected.Count - selected.Count / 2); more = true; }
        }
    }
    private static JsonObject Audio(McpLibrary.Meeting meeting, McpLibrary.Runtime runtime)
    {
        if (meeting.AudioError is { } error) throw new McpFailure(error); if (meeting.Audio.Count == 0) throw new McpFailure("artifact_not_found"); if (runtime.Port is < 1024 or > 65535) throw new McpFailure("invalid_params"); var links = new JsonArray(); var items = new JsonArray();
        foreach (var audio in meeting.Audio) { var uri = $"http://127.0.0.1:{runtime.Port}/audio/{meeting.Id}/{audio.Id}"; links.Add(new JsonObject { ["type"] = "resource_link", ["uri"] = uri, ["name"] = audio.Filename, ["mimeType"] = audio.Mime, ["size"] = audio.Stamp.Size }); items.Add(new JsonObject { ["audio_id"] = audio.Id, ["role"] = string.Join('+', audio.Roles), ["roles"] = Array(audio.Roles.Select(x => JsonValue.Create(x))), ["filename"] = audio.Filename, ["mime_type"] = audio.Mime, ["size_bytes"] = audio.Stamp.Size, ["duration_ms"] = null, ["start_offset_ms"] = audio.Offsets[audio.Roles[0]]?.DeepClone(), ["role_offsets_ms"] = audio.Offsets.DeepClone(), ["preferred"] = audio.Filename == "audio.m4a", ["download_uri"] = uri }); }
        return new() { ["meeting_id"] = meeting.Id, ["items"] = items, ["resources"] = links };
    }
    private static JsonObject Search(List<McpLibrary.Listing> meetings, string query, string scope, long offset, int limit, JsonObject arguments, McpLibrary.Snapshot snapshot, McpLibrary.Runtime runtime)
    {
        long position = 0; var size = 0; var items = new List<JsonObject>(); var more = false;
        bool Emit(string snippet, long at, JsonObject item) { runtime.Check(); if (position++ < offset) return true; if (items.Count == limit || items.Count > 0 && size + Utf8.GetByteCount(snippet) > SoftTextBytes) { more = true; return false; } item["snippet"] = snippet; item["match_offset"] = at; items.Add(item); size += Utf8.GetByteCount(snippet); return true; }
        foreach (var listing in meetings)
        {
            using var meeting = McpLibrary.Get(listing.Id, runtime, archives: false); if (meeting.Revision != listing.Revision) throw new McpFailure("content_changed"); var version = meeting.Current;
            if (scope != "summary" && version.Transcript is { } transcript) transcript.Each(segment => { transcript.Search(segment, query, (snippet, at) => Emit(snippet, at, new() { ["meeting_id"] = meeting.Id, ["version_id"] = version.Id, ["material"] = "transcript", ["segment_index"] = segment.Index, ["start_ms"] = segment.Start, ["end_ms"] = segment.End })); return !more; });
            if (!more && scope != "transcript" && version.Summary is { } summary) summary.Search(query, (snippet, at) => Emit(snippet, at, new() { ["meeting_id"] = meeting.Id, ["version_id"] = version.Id, ["material"] = "summary", ["stale"] = version.Stale, ["source_version_id"] = null }));
            meeting.Validate(); if (more) break;
        }
        if (offset > position) throw new McpFailure("invalid_cursor"); return Listing(items, more ? offset + items.Count : null, arguments, "search_meetings", snapshot.Revision, snapshot.Warnings);
    }
    private sealed class Filter
    {
        private readonly DateTimeOffset? from, before; private readonly string? title, assignment, stage, state; private readonly string[] people;
        private readonly string scope, match, sort; private readonly Dictionary<string,bool> availability = [];
        public Filter(JsonObject values)
        {
            var args = new McpArguments(values);
            DateTimeOffset? ParseDate(string key) { var value = args.String(key); return value is null ? null : Date(value) ?? throw new McpFailure("invalid_params"); }
            from = ParseDate("started_from"); before = ParseDate("started_before"); if (from >= before) throw new McpFailure("invalid_params"); title = args.String("title_contains"); people = args.Strings("participants") ?? []; if (people.Any(string.IsNullOrWhiteSpace)) throw new McpFailure("invalid_params");
            scope = args.Choice("participant_scope", ["listed", "speaking"], "listed")!; match = args.Choice("participant_match", ["any", "all"], "any")!; assignment = args.Choice("participant_assignment", ["complete", "incomplete", "unknown"]); stage = args.Choice("processing_stage", Stages); state = args.Choice("processing_state", States); if ((stage is null) != (state is null)) throw new McpFailure("invalid_params"); sort = args.Choice("sort", ["started_desc", "started_asc"], "started_desc")!; _ = args.Integer("limit", 20, 1, 100);
            foreach (var key in new[] { "has_transcript", "has_summary", "has_audio" }) if (values.ContainsKey(key)) availability[key] = Bool(values[key]) ?? throw new McpFailure("invalid_params");
        }
        public List<McpLibrary.Listing> Select(List<McpLibrary.Listing> meetings)
        {
            bool Matches(McpLibrary.Listing meeting)
            {
                var card = meeting.Card; var started = Date(Text(card["started_at"])); if ((from is not null || before is not null) && (started is null || started < from || started >= before)) return false;
                if (title is not null && !(Text(card["title"]) ?? "").Contains(title, StringComparison.OrdinalIgnoreCase)) return false; if (availability.Any(x => Bool(card[x.Key]) != x.Value)) return false;
                if (assignment is not null && Text(card["participant_assignment"]) != assignment || stage is not null && Text(card["processing"]?[stage]) != state) return false;
                bool Person(string query) => card["participants"]!.AsArray().Where(x => scope == "listed" || meeting.Speaking.Contains(Text(x?["participant_id"]) ?? "")).Any(x => query.Trim().Contains('@') ? string.Equals(Text(x?["email"])?.Trim(), query.Trim(), StringComparison.OrdinalIgnoreCase) : (Text(x?["name"]) ?? "").Contains(query, StringComparison.OrdinalIgnoreCase));
                return people.Length == 0 || (match == "all" ? people.All(Person) : people.Any(Person));
            }
            var values = meetings.Where(Matches).OrderBy(x => Date(Text(x.Card["started_at"])) is null);
            return (sort == "started_desc" ? values.ThenByDescending(x => Date(Text(x.Card["started_at"]))) : values.ThenBy(x => Date(Text(x.Card["started_at"])))).ThenBy(x => x.Id, StringComparer.Ordinal).ToList();
        }
    }
}
