using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using static Verbemo.Core.MCP.McpContract;

namespace Verbemo.Core.MCP;

public static class McpLibrary
{
    public sealed class Runtime
    {
        public string Root { get; } public int Port { get; }
        public IReadOnlyDictionary<string, string> Recording { get; }
        public IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Processing { get; }
        public Func<string, bool> PendingDeletion { get; }
        public Func<string, IDisposable?>? ReserveRead { get; }
        private readonly CancellationToken cancellation; private readonly DateTimeOffset deadline;
        public Runtime(string root, int port = 52763, IReadOnlyDictionary<string, string>? recording = null,
            IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>>? processing = null, Func<string, bool>? pendingDeletion = null,
            Func<string, IDisposable?>? reserveRead = null, CancellationToken cancellation = default, DateTimeOffset? deadline = null)
        { Root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)); Port = port; Recording = recording ?? new Dictionary<string,string>(); Processing = processing ?? new Dictionary<string,IReadOnlyDictionary<string,string>>(); PendingDeletion = pendingDeletion ?? (_ => false); ReserveRead = reserveRead; this.cancellation = cancellation; this.deadline = deadline ?? DateTimeOffset.UtcNow.AddSeconds(30); }
        public void Check() { if (cancellation.IsCancellationRequested || DateTimeOffset.UtcNow >= deadline) throw new McpFailure("server_stopping"); }
    }
    internal sealed record Name(string? Display, string? Participant);
    internal sealed class Version
    {
        public string? Id => Transcript?.Id;
        public bool Current; public McpTextArtifacts.Transcript? Transcript; public string? TranscriptError, NamesError, SummaryError;
        public McpTextArtifacts.Summary? Summary; public McpFiles.AudioHandle? NamesFile;
        public Dictionary<string, Name> Names = []; public bool Stale; public string Revision = "";
        public JsonNode? HasTranscript => TranscriptError is null ? JsonValue.Create(Transcript is not null) : null;
        public JsonNode? HasSummary => SummaryError is null ? JsonValue.Create(Summary is not null) : null;
        public (string State, int? Linked, int? Unlinked, long? Unknown) Assignment(JsonArray participants)
        {
            if (Transcript?.Labels is not { } labels || Transcript.Count == 0 || NamesError is not null || labels.Overlaps(["them", "speaker"])) return ("unknown", null, null, null);
            var ids = participants.Select(x => Text(x?["participant_id"])).ToHashSet(); var known = labels.Where(x => !McpContract.Unknown(x)).ToArray(); var linked = known.Count(x => Names.TryGetValue(x, out var name) && name.Participant is not null && ids.Contains(name.Participant)); var unlinked = known.Length - linked;
            return (Transcript.Unknown == 0 && unlinked == 0 ? "complete" : "incomplete", linked, unlinked, Transcript.Unknown);
        }
    }
    internal sealed record Audio(string Id, string Filename, string[] Roles, JsonObject Offsets, McpFiles.Stamp Stamp)
    {
        public string Mime => Path.GetExtension(Filename).ToLowerInvariant() switch { ".wav" => "audio/wav", ".mp3" => "audio/mpeg", ".flac" => "audio/flac", ".ogg" => "audio/ogg", ".aac" => "audio/aac", ".wma" => "audio/x-ms-wma", ".webm" => "video/webm", ".mkv" => "video/x-matroska", ".mov" => "video/quicktime", ".mp4" => "video/mp4", _ => "audio/mp4" };
    }
    internal sealed class Meeting : IDisposable
    {
        public required string Id, Relative, Revision, MetadataRevision; public required JsonObject Meta, Processing;
        public required JsonArray Participants, Warnings; public required List<Version> Versions; public required List<Audio> Audio;
        public string? RecordingState, AudioError; public required Read Owner; public Version Current => Versions[0];
        public string? Started => Text(Meta["trigger"]) == "import" ? null : Date(Text(Meta["started"] ?? Meta["started_at"])) is not null ? Text(Meta["started"] ?? Meta["started_at"]) : null;
        public JsonObject Card => new() { ["meeting_id"] = Id, ["title"] = (Meta["title"] ?? Meta["calendar"]?["title"])?.DeepClone(), ["started_at"] = Started, ["duration_seconds"] = Meta["duration_seconds"]?.DeepClone(), ["source"] = Meta["trigger"]?.DeepClone(), ["recording_state"] = RecordingState, ["participants"] = Participants.DeepClone(), ["has_transcript"] = Current.HasTranscript, ["has_summary"] = Current.HasSummary, ["summary_stale"] = Current.Stale, ["has_audio"] = AudioError is null ? JsonValue.Create(Audio.Count > 0) : null, ["participant_assignment"] = Current.Assignment(Participants).State, ["processing"] = Processing.DeepClone() };
        public HashSet<string> ExistingParticipants(HashSet<string> requested) => Owner.ParticipantIds(requested);
        public void Validate() => Owner.Validate(); public void Dispose() => Owner.Dispose();
    }
    internal sealed record Listing(string Id, string Relative, JsonObject Card, HashSet<string> Speaking, string Revision);
    internal sealed record Snapshot(List<Listing> Meetings, JsonArray Warnings, string Revision);
    internal static JsonObject Warning(string code, string id, string? artifact = null) { var result = new JsonObject { ["code"] = code, ["meeting_id"] = id }; if (artifact is not null) result["artifact"] = artifact; return result; }
    internal static Snapshot Scan(Runtime runtime)
    {
        runtime.Check(); using var root = McpFiles.DirectoryHandle.Root(runtime.Root); var stamp = root.Stamp; var meetings = new List<Listing>(); var warnings = new JsonArray();
        foreach (var relative in root.Directories().Where(x => !x.StartsWith('.')))
        {
            runtime.Check(); if (runtime.PendingDeletion(relative)) continue; var id = MeetingId(runtime.Root, relative);
            try
            {
                using var directory = root.Directory(relative)!;
                using var meta = directory.File("meta.json"); using var marker = directory.File(".recording.json"); if (meta is null && marker is null && !runtime.Recording.ContainsKey(relative)) continue;
                using var meeting = ReadMeeting(runtime, root, relative, archives: false, transcriptOnly: false, calendarDetails: false);
                var speaking = meeting.Current.Names.Where(x => meeting.Current.Transcript?.Labels?.Contains(x.Key) == true && !Unknown(x.Key) && x.Value.Participant is not null).Select(x => x.Value.Participant!).ToHashSet();
                meetings.Add(new(meeting.Id, relative, meeting.Card, speaking, meeting.Revision)); foreach (var warning in meeting.Warnings) warnings.Add(warning?.DeepClone());
            }
            catch (McpFailure e) { if (e.Code == "server_stopping") throw; warnings.Add(Warning(e.Code, id)); }
        }
        if (root.Stamp != stamp) throw new McpFailure("content_changed");
        return new(meetings, warnings, Hash(Framed(new[] { stamp.Revision }.Concat(meetings.OrderBy(x => x.Id, StringComparer.Ordinal).Select(x => x.Id + ":" + x.Revision)).Append(Hash(Encode(warnings))))));
    }
    internal static Meeting Get(string id, Runtime runtime, bool archives = true, bool transcriptOnly = false, bool calendarDetails = false)
    {
        if (!Regex.IsMatch(id, "^m_[0-9a-fA-F]{64}$")) throw new McpFailure("meeting_not_found"); runtime.Check();
        var root = McpFiles.DirectoryHandle.Root(runtime.Root);
        try { foreach (var relative in root.Directories().Where(x => !x.StartsWith('.'))) if (MeetingId(runtime.Root, relative) == id) return ReadMeeting(runtime, root, relative, archives, transcriptOnly, calendarDetails, ownsRoot: true); }
        catch { root.Dispose(); throw; }
        root.Dispose(); throw new McpFailure("meeting_not_found");
    }
    private static Meeting ReadMeeting(Runtime runtime, McpFiles.DirectoryHandle root, string relative, bool archives, bool transcriptOnly, bool calendarDetails, bool ownsRoot = false)
    {
        for (var attempt = 0; ; attempt++)
        {
            try { var meeting = ReadMeetingOnce(runtime, root, relative, archives, transcriptOnly, calendarDetails); if (ownsRoot) meeting.Owner.Own(root); return meeting; }
            catch (McpFailure error) when (error.Code == "content_changed" && attempt < 2) { runtime.Check(); }
        }
    }
    private static Meeting ReadMeetingOnce(Runtime runtime, McpFiles.DirectoryHandle root, string relative, bool archives, bool transcriptOnly, bool calendarDetails)
    {
        runtime.Check(); if (runtime.PendingDeletion(relative)) throw new McpFailure("meeting_not_found");
        var reservation = runtime.ReserveRead?.Invoke(relative); if (runtime.ReserveRead is not null && reservation is null) throw new McpFailure("artifact_not_ready");
        Read? read = null;
        try
        {
            read = new(root.Directory(relative)!, runtime.Check, reservation); reservation = null;
            if (read.Open(".transcript-commit") is not null) throw new McpFailure("artifact_not_ready");
            var marker = read.Open(".recording.json"); var savedMeta = read.Open("meta.json"); var metadata = savedMeta ?? marker ?? throw new McpFailure("data_unreadable"); read.MetadataFile = metadata;
            var meta = Metadata(metadata, runtime.Check, transcriptOnly, calendarDetails); var metadataHash = read.HashFile(savedMeta is null ? ".recording.json" : "meta.json", metadata); var id = MeetingId(runtime.Root, relative); var warnings = new JsonArray();
            var versions = new List<Version> { read.Version(meta, true, transcriptOnly, calendarDetails) };
            if (archives && read.Directory.Directory("transcripts", true) is { } archiveRoot)
            {
                read.Own(archiveRoot); var before = archiveRoot.Stamp;
                foreach (var name in archiveRoot.Directories().Where(x => !x.StartsWith('.')))
                {
                    runtime.Check();
                    try { var archive = new Read(archiveRoot.Directory(name)!, runtime.Check); read.Own(archive); var version = archive.Version(meta, false, transcriptOnly); archive.Validate(); if (version.Transcript is null) throw new McpFailure(version.TranscriptError ?? "data_unreadable"); if (!versions.Any(x => x.Id == version.Id)) versions.Add(version); }
                    catch (McpFailure e) { if (e.Code is "server_stopping" or "content_changed") throw; warnings.Add(Warning(e.Code, id, "archive")); }
                }
                if (archiveRoot.Stamp != before) throw new McpFailure("content_changed");
            }
            var recording = runtime.Recording.GetValueOrDefault(relative); if (recording is not ("recording" or "paused")) recording = null;
            var supplied = runtime.Processing.GetValueOrDefault(relative) ?? new Dictionary<string,string>(); var audio = new List<Audio>(); string? audioError = null;
            if (marker is not null || recording is not null || supplied.GetValueOrDefault("audio") == "running" || read.Open(".audio.m4a") is not null || read.Open(".archive.wav") is not null) audioError = "artifact_not_ready";
            else if (!transcriptOnly) { try { audio = read.Audio(id, meta); } catch (McpFailure e) { if (e.Code == "server_stopping") throw; audioError = e.Code; } }
            foreach (var version in versions) foreach (var (role, error) in new[] { ("transcript", version.TranscriptError), ("speakers", version.NamesError), ("summary", version.SummaryError) }) if (error is not null) warnings.Add(Warning(error, id, role));
            if (audioError is not null) warnings.Add(Warning(audioError, id, "audio"));
            var current = versions[0]; var processing = new JsonObject(); foreach (var stage in Stages) processing[stage] = "unknown";
            string? Status(string? value) => value == "failed" || value?.StartsWith("failed:") == true ? "failed" : value is "pending" or "deferred" or "off" or "done" or "cancelled" ? value : null;
            processing["transcription"] = meta["transcription_failed"] is JsonValue failure && (Text(failure) is not null || Bool(failure) == true) ? "failed" : Bool(meta["transcription_deferred"]) == true ? "deferred" : current.Transcript is not null ? "done" : "unknown";
            processing["summary"] = Status(Text(meta["summary_status"])) ?? (current.Summary is not null && !current.Stale ? "done" : "unknown");
            processing["speaker_naming"] = Status(Text(meta["speakers_status"])) ?? (current.NamesFile is not null && current.NamesError is null ? "done" : "unknown");
            var diarization = Text(meta["diarization"]?["status"]); processing["diarization"] = diarization == "completed" ? "done" : diarization is "skipped" or "not_applicable" ? "off" : Status(diarization) ?? "unknown";
            foreach (var (stage, markerPrefix) in new[] { ("transcription", "transcribe"), ("speaker_naming", "speakers"), ("summary", "summary") })
                foreach (var state in new[] { "off", "deferred", "failed" }) if (read.Open(markerPrefix + "." + state) is not null) processing[stage] = state;
            if (read.Open("transcribe.requested") is not null && Text(processing["transcription"]) is not ("failed" or "deferred")) processing["transcription"] = "pending";
            foreach (var stage in Stages) if (supplied.TryGetValue(stage, out var state) && States.Contains(state)) processing[stage] = state;
            if (runtime.PendingDeletion(relative)) throw new McpFailure("meeting_not_found"); read.Validate();
            return new Meeting { Id = id, Relative = relative, Meta = meta, Versions = versions, Audio = audio, AudioError = audioError, RecordingState = recording, Processing = processing, Participants = Participants(meta), Warnings = warnings, Owner = read, MetadataRevision = metadataHash, Revision = Hash(Framed(new[] { read.Directory.Stamp.Revision, read.Revision }.Concat(versions.Select(x => x.Revision)).Concat(audio.Select(x => x.Id)).Append(Hash(Encode(processing))).Append(recording ?? ""))) };
        }
        catch { read?.Dispose(); reservation?.Dispose(); throw; }
    }
    internal static JsonArray Participants(JsonObject meta)
    {
        var result = new JsonArray(); if (meta["calendar"] is not JsonObject calendar) return result;
        if (calendar["participants"] is JsonArray participants) foreach (var person in participants)
        {
            if (person is not JsonObject obj || Text(obj["id"]) is not { } id || Text(obj["name"]) is not { } name || (obj["email"] is not null && Text(obj["email"]) is null) || (obj["organizer"] is not null && Bool(obj["organizer"]) is null)) throw new McpFailure("data_unreadable");
            if (id.Length > 0 && !result.Any(x => Text(x?["participant_id"]) == id)) result.Add(new JsonObject { ["participant_id"] = id, ["name"] = name, ["email"] = obj["email"]?.DeepClone(), ["organizer"] = obj["organizer"]?.DeepClone() });
        }
        else if (calendar["attendees"] is JsonArray attendees) for (var i = 0; i < attendees.Count; i++) result.Add(new JsonObject { ["participant_id"] = "legacy-" + i, ["name"] = Text(attendees[i]) ?? throw new McpFailure("data_unreadable"), ["email"] = null, ["organizer"] = null });
        return result;
    }
    private static JsonObject Metadata(McpFiles.AudioHandle file, Action check, bool transcriptOnly, bool details)
    {
        var reader = new McpTextArtifacts.Reader(file, check);
        string[] fields = ["title", "trigger", "started", "started_at", "ended", "duration_seconds", "summary_stale", "summary_status", "speakers_status", "transcription_failed", "transcription_deferred", "files", "start_offset_ms", "diarization", "calendar"];
        var meta = reader.Project(path => {
            if (path.Length == 1) return fields.Contains(path[0]) && !transcriptOnly;
            if (path[0] is "files" or "start_offset_ms") return path.Length == 2 && path[1] is "mic" or "system" or "source";
            if (path[0] == "diarization") return path.Length == 2 && path[1] == "status";
            if (path[0] == "calendar") return path.Length == 2 ? new[] { "title", "event_id", "association", "calendar_title", "agenda", "scheduled_start", "scheduled_end", "time_zone", "participants", "attendees" }.Contains(path[1]) && (details || path[1] is "title" or "participants" or "attendees") : path.Length == 3 && path[1] == "participants" && new[] { "id", "name", "email", "organizer" }.Contains(path[2]);
            return false;
        }) as JsonObject ?? throw new McpFailure("data_unreadable"); reader.End();
        foreach (var key in new[] { "title", "trigger", "started", "started_at", "ended", "summary_status", "speakers_status" }) if (meta[key] is not null && Text(meta[key]) is null) throw new McpFailure("data_unreadable");
        foreach (var key in new[] { "summary_stale", "transcription_deferred" }) if (meta.ContainsKey(key) && Bool(meta[key]) is null) throw new McpFailure("data_unreadable");
        if (meta.ContainsKey("transcription_failed") && Text(meta["transcription_failed"]) is null && Bool(meta["transcription_failed"]) is null) throw new McpFailure("data_unreadable");
        foreach (var key in new[] { "files", "start_offset_ms", "diarization", "calendar" }) if (meta[key] is not null and not JsonObject) throw new McpFailure("data_unreadable");
        if (meta["duration_seconds"] is { } duration && (duration is not JsonValue v || !v.TryGetValue<double>(out var n) || !double.IsFinite(n) || n < 0)) throw new McpFailure("data_unreadable");
        return meta;
    }
    internal sealed class Read : IDisposable
    {
        public McpFiles.DirectoryHandle Directory { get; } public McpFiles.AudioHandle? MetadataFile;
        private readonly Action check; private readonly McpFiles.Stamp before; private readonly Dictionary<string, McpFiles.AudioHandle?> files = [];
        private readonly List<IDisposable> owned = []; private readonly Dictionary<string,string> hashes = [];
        public Read(McpFiles.DirectoryHandle directory, Action check, IDisposable? reservation = null, IDisposable? root = null) { Directory = directory; this.check = check; before = directory.Stamp; if (root is not null) owned.Add(root); if (reservation is not null) owned.Add(reservation); }
        public void Own(IDisposable value) => owned.Add(value);
        public string HashFile(string name, McpFiles.AudioHandle file) => hashes[name] = file.Hash(check);
        public McpFiles.AudioHandle? Open(string name) { check(); if (!files.TryGetValue(name, out var file)) { file = Directory.File(name); files[name] = file; } return file; }
        public string Revision => Hash(Framed(files.OrderBy(x => x.Key, StringComparer.Ordinal).SelectMany(x => new[] { x.Key, hashes.GetValueOrDefault(x.Key) ?? x.Value?.Stamp.Revision ?? "absent" })));
        public void Validate() { check(); foreach (var child in owned.OfType<Read>()) child.Validate(); if (Directory.Stamp != before) throw new McpFailure("content_changed"); foreach (var (name, file) in files) { file?.Validate(); using var current = Directory.File(name); if (current?.Stamp != file?.Stamp) throw new McpFailure("content_changed"); } }
        public Version Version(JsonObject fallback, bool current, bool transcriptOnly, bool displayNames = false)
        {
            var result = new Version { Current = current }; var meta = fallback;
            if (!current && Open("meta.json") is { } archived) { meta = Metadata(archived, check, transcriptOnly, false); HashFile("meta.json", archived); }
            result.Stale = Bool(meta["summary_stale"]) == true || Open("summary.stale") is not null;
            try
            {
                if (Open("transcript.json") is { } transcript)
                {
                    var generation = "";
                    if (Open("diarization.json") is { } timeline)
                    {
                        var reader = new McpTextArtifacts.Reader(timeline, check); var data = reader.Project(path => path.Length == 1 && new[] { "schemaVersion", "transcriptSHA256", "generationFingerprint" }.Contains(path[0])) as JsonObject ?? throw new McpFailure("data_unreadable"); reader.End();
                        if (data["schemaVersion"] is not null && Integer(data["schemaVersion"]) == 1 && Text(data["transcriptSHA256"]) == transcript.Hash(check) && Text(data["generationFingerprint"]) is { } fingerprint && Regex.IsMatch(fingerprint, "^[0-9a-fA-F]{64}$")) generation = fingerprint;
                    }
                    result.Transcript = new(transcript, check, generation, !transcriptOnly); hashes["transcript.json"] = result.Transcript.RawHash;
                }
            }
            catch (McpFailure e) { if (e.Code is "server_stopping" or "content_changed") throw; result.TranscriptError = e.Code; }
            try { result.NamesFile = Open("speakers.json"); if (result.NamesFile is { } names) { result.Names = Names(names, transcriptOnly ? [] : result.Transcript?.Labels ?? [], check, displayNames); hashes["speakers.json"] = names.Hash(check); } }
            catch (McpFailure e) { if (e.Code is "server_stopping" or "content_changed") throw; result.NamesError = e.Code; }
            try { if (!transcriptOnly && Open("summary.md") is { } summary) { result.Summary = new(summary, check); hashes["summary.md"] = result.Summary.Revision; } }
            catch (McpFailure e) { if (e.Code is "server_stopping" or "content_changed") throw; result.SummaryError = e.Code; }
            result.Revision = Revision; return result;
        }
        public HashSet<string> ParticipantIds(HashSet<string> requested)
        {
            if (MetadataFile is null || requested.Count == 0) return []; var reader = new McpTextArtifacts.Reader(MetadataFile, check); HashSet<string>? modern = null; var legacy = new HashSet<string>();
            reader.Object(key => { if (key != "calendar") { reader.Skip(); return; } if (reader.Null()) return; reader.Object(field => {
                if (field == "participants") { modern = []; reader.Array(_ => { string? id = null; bool hasName = false, hasId = false; var keys = new HashSet<string>(); reader.Object(p => { if (p is "id" or "name" or "email" or "organizer" && !keys.Add(p)) throw new McpFailure("data_unreadable"); if (p == "id") { id = reader.String(requested.Max(x => Utf8.GetByteCount(x))).Value; hasId = true; } else if (p == "name") { reader.String(); hasName = true; } else if (p == "email") { if (!reader.Null()) reader.String(); } else if (p == "organizer") { var flag = reader.Scalar(); if (flag is not null && Bool(flag) is null) throw new McpFailure("data_unreadable"); } else reader.Skip(); }); if (!hasName || !hasId) throw new McpFailure("data_unreadable"); if (id is not null && requested.Contains(id)) modern.Add(id); }); }
                else if (field == "attendees") reader.Array(i => { reader.String(); if (requested.Contains("legacy-" + i)) legacy.Add("legacy-" + i); }); else reader.Skip();
            }); }); reader.End(); return modern ?? legacy;
        }
        public List<Audio> Audio(string meetingId, JsonObject meta)
        {
            var roles = new Dictionary<string,List<string>>(StringComparer.Ordinal); string[] sourceExtensions = [".wav", ".m4a", ".mp3", ".flac", ".ogg", ".aac", ".wma", ".mp4", ".mov", ".mkv", ".webm"];
            if (meta["files"] is JsonObject declared) foreach (var (role, value) in declared)
            {
                if (role is not ("mic" or "system" or "source")) continue; var name = Text(value) ?? throw new McpFailure("data_unreadable");
                if (!(role == "mic" && name is "mic.wav" or "audio.m4a") && !(role == "system" && name is "system.wav" or "audio.m4a") && !(role == "source" && name.StartsWith("source.", StringComparison.Ordinal) && sourceExtensions.Contains(Path.GetExtension(name).ToLowerInvariant()) && Path.GetFileName(name) == name)) throw new McpFailure("data_unreadable");
                if (!roles.TryGetValue(name, out var list)) roles[name] = list = []; list.Add(role);
            }
            // Windows finalization replaces raw tracks without rewriting meta.json's files map.
            foreach (var name in Directory.Entries()) if (!roles.ContainsKey(name) && (name is "audio.m4a" or "mic.wav" or "system.wav" || name.StartsWith("source.", StringComparison.Ordinal) && sourceExtensions.Contains(Path.GetExtension(name).ToLowerInvariant()))) roles[name] = name == "audio.m4a" ? ["mic", "system"] : [name.StartsWith("mic.") ? "mic" : name.StartsWith("system.") ? "system" : "source"];
            var result = new List<Audio>(); foreach (var (name, list) in roles.OrderBy(x => x.Key, StringComparer.Ordinal)) if (Open(name) is { } file)
            {
                var sorted = list.Order(StringComparer.Ordinal).ToArray(); var offsets = new JsonObject(); foreach (var role in sorted) offsets[role] = name != "audio.m4a" && meta["start_offset_ms"]?[role] is { } value ? Math.Max(0, Integer(value)) : 0L;
                result.Add(new("a_" + Hash(Framed([meetingId, string.Join(',', sorted), name, file.Stamp.Revision])), name, sorted, offsets, file.Stamp));
            }
            return result.FirstOrDefault(x => x.Filename == "audio.m4a") is { } preferred ? [preferred] : result;
        }
        public void Dispose() { foreach (var file in files.Values) file?.Dispose(); Directory.Dispose(); foreach (var value in owned.AsEnumerable().Reverse()) value.Dispose(); }
    }
    internal static Dictionary<string,Name> Names(McpFiles.AudioHandle file, HashSet<string> labels, Action check, bool displayNames = true)
    {
        var reader = new McpTextArtifacts.Reader(file, check); var data = reader.Project(path => path.Length == 1 ? path[0] is "names" or "participantIds" or "speakers" : path.Length == 2 ? labels.Contains(path[1]) && (displayNames || path[0] != "names") : path.Length == 3 && path[0] == "speakers" && (path[2] is "participantID" or "participant_id" || displayNames && path[2] == "name")) as JsonObject ?? throw new McpFailure("data_unreadable"); reader.End();
        if (data["names"] is not JsonObject && data["speakers"] is not JsonObject) throw new McpFailure("data_unreadable");
        foreach (var key in new[] { "names", "sources", "participantIds", "manualNames", "speakers" }) if (data.ContainsKey(key) && data[key] is not JsonObject) throw new McpFailure("data_unreadable");
        var result = new Dictionary<string,Name>(); foreach (var label in labels.Where(x => !Unknown(x)))
        {
            JsonObject? legacy = null;
            if (data["speakers"] is JsonObject speakers && speakers.TryGetPropertyValue(label, out var entry))
                legacy = entry as JsonObject ?? throw new McpFailure("data_unreadable");
            var display = data["names"]?[label] ?? legacy?["name"]; var participant = data["participantIds"]?[label] ?? (legacy?["participantID"] ?? legacy?["participant_id"]);
            if (display is not null && Text(display) is null || participant is not null && Text(participant) is null) throw new McpFailure("data_unreadable");
            result[label] = new(Text(display), Text(participant));
        }
        return result;
    }
    public static McpFiles.AudioHandle OpenAudio(string meetingId, string audioId, Runtime runtime)
    {
        using var meeting = Get(meetingId, runtime, archives: false); if (meeting.AudioError is { } error) throw new McpFailure(error); var audio = meeting.Audio.FirstOrDefault(x => x.Id == audioId) ?? throw new McpFailure("artifact_not_found");
        var handle = meeting.Owner.Directory.File(audio.Filename) ?? throw new McpFailure("artifact_not_found");
        try { if (handle.Stamp != audio.Stamp) throw new McpFailure("content_changed"); meeting.Validate(); runtime.Check(); if (runtime.PendingDeletion(meeting.Relative)) throw new McpFailure("meeting_not_found"); return handle; } catch { handle.Dispose(); throw; }
    }
}
