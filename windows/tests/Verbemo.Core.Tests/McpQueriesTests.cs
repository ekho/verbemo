using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Verbemo.Core.MCP;
using Xunit;

namespace Verbemo.Core.Tests;

public sealed class McpQueriesTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Shared_observable_contract_and_assignment_cases(bool native)
    {
        using var fixture = new Fixture(native); var shared = McpContractTests.Fixture;
        foreach (var tool in new[] { "get_meeting", "get_meeting_transcript", "get_meeting_summary" })
        {
            var actual = fixture.Call(tool); foreach (var (key, expected) in shared["observable"]![tool]!.AsObject()) Assert.True(JsonNode.DeepEquals(expected, actual[key]), tool + ": " + key);
            Assert.Equal(shared["response_keys"]![tool]!.AsArray().Select(x => x!.GetValue<string>()).Order(), actual.Select(x => x.Key).Order());
        }
        foreach (var item in shared["assignment_cases"]!.AsArray()) { fixture.Write("transcript.json", item!["transcript"]!.ToJsonString()); Assert.Equal(item["expected"]!.GetValue<string>(), fixture.Call("get_meeting")["participant_assignment"]!.GetValue<string>()); }
    }

    [Fact]
    public void All_tools_leave_every_library_byte_unchanged()
    {
        using var f = new Fixture(); var before = f.Hashes();
        foreach (var tool in McpContract.Tools) { var args = tool switch { "list_meetings" => new JsonObject(), "search_meetings" => new() { ["query"] = "hello" }, "get_settings" => new() { ["keys"] = new JsonArray("user_name") }, _ => f.Args() }; var result = McpQueries.Call(tool, args, f.Runtime, f.Settings); Assert.NotNull(result); }
        Assert.Equal(before, f.Hashes());
    }

    [Fact]
    public void Semantic_id_survives_names_and_whitespace_but_revision_changes()
    {
        using var f = new Fixture(); var old = f.Call("get_meeting_transcript"); var transcript = JsonNode.Parse(File.ReadAllText(f.PathFor("transcript.json")))!;
        f.Write("transcript.json", transcript.ToJsonString(new() { WriteIndented = true })); f.Write("speakers.json", "{\"names\":{\"them A\":\"New\"},\"participantIds\":{\"them A\":\"p1\"}}");
        var updated = f.Call("get_meeting_transcript"); Assert.Equal(old["version_id"]!.GetValue<string>(), updated["version_id"]!.GetValue<string>()); Assert.NotEqual(old["revision"]!.GetValue<string>(), updated["revision"]!.GetValue<string>());
    }

    [Fact]
    public void Pagination_binds_filters_version_revision_and_keeps_text_exact()
    {
        using var f = new Fixture(); var args = f.Args(); args["limit"] = 1; var first = f.Call("get_meeting_transcript", args); Assert.Equal("  Hello world!\n", first["segments"]![0]!["text"]!.GetValue<string>()); args["cursor"] = first["next_cursor"]!.DeepClone();
        var second = f.Call("get_meeting_transcript", args); Assert.Equal(1, second["segments"]![0]!["segment_index"]!.GetValue<long>()); Assert.Null(second["next_cursor"]);
        args["limit"] = 2; Assert.Equal("invalid_cursor", Assert.Throws<McpFailure>(() => f.Call("get_meeting_transcript", args)).Code); args["limit"] = 1;
        f.Write("speakers.json", "{\"names\":{\"them A\":\"Edited\"}}"); Assert.Equal("content_changed", Assert.Throws<McpFailure>(() => f.Call("get_meeting_transcript", args)).Code);
    }

    [Fact]
    public void Integer_timestamps_above_double_precision_remain_exact()
    {
        using var f = new Fixture(); f.Write("transcript.json", "{\"engine\":\"x\",\"model\":\"x\",\"created_at\":\"2026-10-28T00:00:00Z\",\"segments\":[{\"start_ms\":9007199254740993,\"end_ms\":9007199254740995,\"speaker\":null,\"text\":\" raw \"}]}");
        var response = f.Call("get_meeting_transcript"); Assert.Equal(9007199254740993L, response["segments"]![0]!["start_ms"]!.GetValue<long>());
    }

    [Theory]
    [InlineData("{\"segments\":null}")]
    [InlineData("{\"engine\":\"x\",\"model\":\"x\",\"created_at\":\"2026-10-28T00:00:00Z\",\"segments\":[{\"start_ms\":true,\"end_ms\":1,\"text\":\"a\"}]}")]
    [InlineData("{\"engine\":\"x\",\"model\":\"x\",\"created_at\":\"2026-10-28T00:00:00Z\",\"segments\":[{\"start_ms\":2,\"end_ms\":1,\"text\":\"a\"}]}")]
    public void Corruption_is_unknown_not_absence(string malformed)
    {
        using var f = new Fixture(); f.Write("transcript.json", malformed); Assert.Null(f.Call("get_meeting")["has_transcript"]); Assert.Equal("data_unreadable", Assert.Throws<McpFailure>(() => f.Call("get_meeting_transcript")).Code);
        var list = McpQueries.Call("list_meetings", new() { ["has_transcript"] = false }, f.Runtime); Assert.Empty(list["items"]!.AsArray()); File.Delete(f.PathFor("transcript.json")); Assert.False(f.Call("get_meeting")["has_transcript"]!.GetValue<bool>());
    }

    [Fact]
    public void Native_failure_markers_and_saved_reasons_are_never_exported()
    {
        using var f = new Fixture(); var meta = JsonNode.Parse(File.ReadAllText(f.PathFor("meta.json")))!; meta["transcription_failed"] = "credential=DO_NOT_EXPORT_REASON"; f.Write("meta.json", meta.ToJsonString());
        var result = f.Call("get_meeting"); Assert.Equal("failed", result["processing"]!["transcription"]!.GetValue<string>()); Assert.DoesNotContain("DO_NOT_EXPORT_REASON", result.ToJsonString()); f.Write("summary.failed", "secret-provider-error"); result = f.Call("get_meeting"); Assert.Equal("failed", result["processing"]!["summary"]!.GetValue<string>()); Assert.DoesNotContain("secret-provider-error", result.ToJsonString());
    }

    [Fact]
    public void Pending_deletion_reservations_and_recording_fail_closed()
    {
        using var f = new Fixture(); var pending = new McpLibrary.Runtime(f.Root, pendingDeletion: _ => true); Assert.Empty(McpQueries.Call("list_meetings", new(), pending)["items"]!.AsArray()); Assert.Equal("meeting_not_found", Assert.Throws<McpFailure>(() => McpQueries.Call("get_meeting", f.Args(), pending)).Code);
        var busy = new McpLibrary.Runtime(f.Root, reserveRead: _ => null); Assert.Equal("artifact_not_ready", Assert.Throws<McpFailure>(() => McpQueries.Call("get_meeting", f.Args(), busy)).Code);
        f.Write(".recording.json", "{}"); Assert.Equal("artifact_not_ready", Assert.Throws<McpFailure>(() => f.Call("get_meeting_audio")).Code);
    }

    [Fact]
    public void Download_is_pinned_and_old_audio_id_never_resolves_replacement()
    {
        using var f = new Fixture(); var audio = f.Call("get_meeting_audio"); var id = audio["items"]![0]!["audio_id"]!.GetValue<string>(); using var handle = McpLibrary.OpenAudio(f.Id, id, f.Runtime);
        File.Move(f.PathFor("mic.wav"), f.PathFor("old.wav")); File.Delete(f.PathFor("old.wav")); f.Write("mic.wav", "replacement"); Assert.Equal("audio-fixture", Encoding.UTF8.GetString(handle.Read(0, 64))); Assert.Equal("artifact_not_found", Assert.Throws<McpFailure>(() => McpLibrary.OpenAudio(f.Id, id, f.Runtime)).Code);
    }

    [Fact]
    public void Held_ancestor_handles_prevent_directory_replacement_and_reparse_escape()
    {
        using var f = new Fixture(); using (var root = McpFiles.DirectoryHandle.Root(f.Root)) using (var meeting = root.Directory("meeting")!) Assert.Throws<IOException>(() => Directory.Move(f.Meeting, f.Meeting + "-old"));
        var outside = Path.Combine(Path.GetTempPath(), "verbemo-mcp-outside-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(outside);
        try { var link = Path.Combine(f.Root, "junction"); var process = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{outside}\"") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true })!; process.WaitForExit(); Assert.Equal(0, process.ExitCode); Assert.Equal("data_unreadable", Assert.Throws<McpFailure>(() => McpFiles.DirectoryHandle.Root(link)).Code); Directory.Delete(link); }
        finally { Directory.Delete(outside); }
    }

    [Fact]
    public void Denied_open_is_not_missing_and_leaf_reparse_is_rejected()
    {
        using var f = new Fixture(); using var root = McpFiles.DirectoryHandle.Root(f.Root); using var meeting = root.Directory("meeting")!; Assert.Null(meeting.File("missing.json"));
        using (var denied = new FileStream(f.PathFor("transcript.json"), FileMode.Open, FileAccess.Read, FileShare.None)) Assert.Equal("artifact_not_ready", Assert.Throws<McpFailure>(() => meeting.File("transcript.json")).Code);
        var link = f.PathFor("linked.json"); File.CreateSymbolicLink(link, f.PathFor("meta.json")); Assert.Equal("data_unreadable", Assert.Throws<McpFailure>(() => meeting.File("linked.json")).Code);
    }

    [Fact]
    public void Search_uses_utf8_offsets_and_transcript_before_summary()
    {
        using var f = new Fixture(); f.Write("transcript.json", "{\"engine\":\"x\",\"model\":\"x\",\"created_at\":\"2026-10-28T00:00:00Z\",\"segments\":[{\"start_ms\":0,\"end_ms\":1,\"text\":\"я Hello\"}]}"); var result = McpQueries.Call("search_meetings", new() { ["query"] = "hello" }, f.Runtime);
        Assert.Equal("transcript", result["items"]![0]!["material"]!.GetValue<string>()); Assert.Equal(3, result["items"]![0]!["match_offset"]!.GetValue<long>()); Assert.Equal("summary", result["items"]![1]!["material"]!.GetValue<string>());
    }

    [Fact]
    public void Archive_deduplicates_semantic_versions_and_ignores_pending_staging()
    {
        using var f = new Fixture(); var archive = Path.Combine(f.Meeting, "transcripts", new string('a',64)); Directory.CreateDirectory(archive); File.Copy(f.PathFor("transcript.json"), Path.Combine(archive,"transcript.json")); Directory.CreateDirectory(Path.Combine(f.Meeting,"transcripts",".staging")); f.Write("transcribe.requested", "engine");
        var result = f.Call("list_transcript_versions"); Assert.Single(result["items"]!.AsArray()); Assert.True(result["items"]![0]!["is_current"]!.GetValue<bool>()); Assert.Equal("version_not_found", Assert.Throws<McpFailure>(() => f.Call("get_meeting_transcript", new() { ["meeting_id"] = f.Id, ["version_id"] = "pending" })).Code);
    }

    [Fact]
    public void Large_transcript_and_unreturned_metadata_are_pageable_without_64MiB_cap()
    {
        using var f = new Fixture();
        using (var writer = new StreamWriter(f.PathFor("transcript.json"), false, new UTF8Encoding(false))) { writer.Write("{\"engine\":\"x\",\"model\":\"x\",\"created_at\":\"2026-10-28T00:00:00Z\",\"segments\":["); var text = new string('x', 8192); for (var i = 0; i < 8500; i++) { if (i > 0) writer.Write(','); writer.Write("{\"start_ms\":0,\"end_ms\":1,\"speaker\":\"me\",\"text\":\""); writer.Write(text); writer.Write("\"}"); } writer.Write("]}"); }
        using (var writer = new StreamWriter(f.PathFor("meta.json"), false, new UTF8Encoding(false))) { writer.Write("{\"title\":\""); var chunk = new string('m', 65536); for (var i = 0; i < 1025; i++) writer.Write(chunk); writer.Write("\",\"calendar\":{\"agenda\":\""); for (var i = 0; i < 1025; i++) writer.Write(chunk); writer.Write("\"}}"); }
        Assert.True(new FileInfo(f.PathFor("transcript.json")).Length > 64L * 1024 * 1024); var result = f.Call("get_meeting_transcript", new() { ["meeting_id"] = f.Id, ["limit"] = 1 }); Assert.Single(result["segments"]!.AsArray()); Assert.Equal(8192, result["segments"]![0]!["text"]!.GetValue<string>().Length); Assert.NotNull(result["next_cursor"]);
    }

    [Fact]
    public void Summary_utf8_page_boundary_and_large_sources_are_exact()
    {
        using var f = new Fixture(); f.Write("summary.md", new string('a',65535) + "я" + new string('b', 65536)); var first = f.Call("get_meeting_summary"); Assert.Equal(new string('a',65535), first["markdown"]!.GetValue<string>()); var args = f.Args(); args["cursor"] = first["next_cursor"]!.DeepClone(); var second = f.Call("get_meeting_summary", args); Assert.StartsWith("я", second["markdown"]!.GetValue<string>());
    }

    [Fact]
    public void Settings_hide_secrets_commands_unknown_fields_and_url_credentials()
    {
        using var f = new Fixture(); var raw = JsonNode.Parse("{\"on_stop\":{\"executable\":\"secret\"},\"unknown\":\"secret\",\"interface_language\":\"ru\",\"summary\":{\"openai_base_url\":\"https://user:secret@example.com/api?token=secret#secret\"}}")!.AsObject(); var settings = new McpSettings(raw, new Dictionary<string,JsonNode?>(), new Dictionary<string,JsonNode?> { ["interface_language"] = JsonValue.Create("en") }, new Dictionary<string,bool> { ["mcp.token"] = true }, f.Root);
        var result = settings.Project(["on_stop","summary.openai_base_url","interface_language","mcp.token"]); Assert.DoesNotContain("secret", result.ToJsonString()); Assert.DoesNotContain("user:", result.ToJsonString()); Assert.True(result["items"]!.AsArray().Single(x => x!["key"]!.GetValue<string>() == "interface_language")!["pending_apply"]!.GetValue<bool>()); Assert.Equal("invalid_params", Assert.Throws<McpFailure>(() => settings.Project(["unknown"])).Code);
        Assert.Equal(3, settings.Project(["start_at_login", "tray_icon", "taskbar_icon"])["items"]!.AsArray().Count);
    }

    [Fact]
    public void Cancellation_and_mutation_during_snapshot_are_detected()
    {
        using var f = new Fixture(); using var cts = new CancellationTokenSource(); cts.Cancel(); Assert.Equal("server_stopping", Assert.Throws<McpFailure>(() => McpQueries.Call("get_meeting", f.Args(), new(f.Root, cancellation: cts.Token))).Code);
        using var root = McpFiles.DirectoryHandle.Root(f.Root); using var dir = root.Directory("meeting")!; using var file = dir.File("mic.wav")!; Assert.Throws<IOException>(() => f.Write("mic.wav", "longer-new-content")); file.Validate(); Assert.Equal("audio-fixture", Encoding.UTF8.GetString(file.Read(0, 64)));
    }

    [Fact]
    public void Actual_windows_access_denial_is_distinct_from_missing()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        using var f = new Fixture(); using var identity = System.Security.Principal.WindowsIdentity.GetCurrent(); var sid = identity.User!.Value;
        void Acl(params string[] args) { var start = new ProcessStartInfo("icacls.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }; start.ArgumentList.Add(f.PathFor("transcript.json")); foreach (var arg in args) start.ArgumentList.Add(arg); using var process = Process.Start(start)!; process.WaitForExit(); Assert.Equal(0, process.ExitCode); }
        try { Acl("/deny", "*" + sid + ":(R)"); using var root = McpFiles.DirectoryHandle.Root(f.Root); using var meeting = root.Directory("meeting")!; Assert.Equal("data_unreadable", Assert.Throws<McpFailure>(() => meeting.File("transcript.json")).Code); Assert.Null(meeting.File("missing.json")); }
        finally { Acl("/remove:d", "*" + sid); }
    }

    [Fact]
    public void Many_distinct_voices_and_oversized_unselected_names_still_allow_small_page()
    {
        using var f = new Fixture();
        using (var writer = new StreamWriter(f.PathFor("transcript.json"), false, new UTF8Encoding(false))) { writer.Write("{\"engine\":\"x\",\"model\":\"x\",\"created_at\":\"2026-10-28T00:00:00Z\",\"segments\":["); for (var i = 0; i < 20000; i++) { if (i > 0) writer.Write(','); writer.Write("{\"start_ms\":0,\"end_ms\":1,\"speaker\":\"voice-" + i + "\",\"text\":\"x\"}"); } writer.Write("]}"); }
        using (var writer = new StreamWriter(f.PathFor("speakers.json"), false, new UTF8Encoding(false))) { writer.Write("{\"names\":{\"voice-0\":\"First\",\"unreturned\":\""); var chunk = new string('n',65536); for (var i = 0; i < 1025; i++) writer.Write(chunk); writer.Write("\"},\"participantIds\":{\"voice-0\":\"p1\"}}"); }
        var result = f.Call("get_meeting_transcript", new() { ["meeting_id"] = f.Id, ["limit"] = 1 }); Assert.Equal("First", result["segments"]![0]!["speaker_name"]!.GetValue<string>()); Assert.Equal("p1", result["segments"]![0]!["participant_id"]!.GetValue<string>());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Metadata_change_at_final_validation_never_returns_a_mixed_snapshot(bool keepsChanging)
    {
        using var f = new Fixture(); var checks = 0;
        var runtime = new McpLibrary.Runtime(f.Root, pendingDeletion: _ => { checks++; if (checks == 2 || keepsChanging && checks % 2 == 0) { f.Write(".replacement-meta.json", new JsonObject { ["title"] = "Changed " + checks }.ToJsonString()); File.Move(f.PathFor("meta.json"), f.PathFor(".previous-meta-" + checks + ".json")); File.Move(f.PathFor(".replacement-meta.json"), f.PathFor("meta.json")); } return false; });
        if (keepsChanging) Assert.Equal("content_changed", Assert.Throws<McpFailure>(() => McpQueries.Call("get_meeting", f.Args(), runtime)).Code);
        else { var result = McpQueries.Call("get_meeting", f.Args(), runtime); Assert.Equal("Changed 2", result["title"]!.GetValue<string>()); Assert.Empty(result["participants"]!.AsArray()); }
    }

    [Fact]
    public void Oversized_segment_is_rejected_whole_and_invalid_utf8_is_unknown()
    {
        using var f = new Fixture(); var transcript = McpContractTests.Fixture["semantic_ids"]![0]!["transcript"]!.DeepClone(); transcript["segments"]![0]!["text"] = new string('x', 600000); f.Write("transcript.json", transcript.ToJsonString()); Assert.Equal("response_too_large", Assert.Throws<McpFailure>(() => f.Call("get_meeting_transcript")).Code);
        File.WriteAllBytes(f.PathFor("summary.md"), [0xc3, 0x28]); Assert.Null(f.Call("get_meeting")["has_summary"]); Assert.Equal("data_unreadable", Assert.Throws<McpFailure>(() => f.Call("get_meeting_summary")).Code);
    }

    [Fact]
    public void Native_finalized_audio_is_found_after_raw_files_are_deleted()
    {
        using var f = new Fixture(); File.Delete(f.PathFor("mic.wav")); f.Write("audio.m4a", "finalized-audio"); var meta = JsonNode.Parse(File.ReadAllText(f.PathFor("meta.json")))!; meta["start_offset_ms"] = new JsonObject { ["mic"] = 200 }; f.Write("meta.json", meta.ToJsonString());
        var result = f.Call("get_meeting_audio"); Assert.Single(result["items"]!.AsArray()); Assert.Equal("audio.m4a", result["items"]![0]!["filename"]!.GetValue<string>()); Assert.Equal(0, result["items"]![0]!["start_offset_ms"]!.GetValue<long>());
        f.Write(".audio.m4a", "partial-finalization"); Assert.Equal("artifact_not_ready", Assert.Throws<McpFailure>(() => f.Call("get_meeting_audio")).Code);
    }

    [Fact]
    public void Validated_native_generation_changes_semantic_id_only_for_matching_transcript()
    {
        using var f = new Fixture(); var hash = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(f.PathFor("transcript.json")))); f.Write("diarization.json", new JsonObject { ["schemaVersion"] = 1, ["transcriptSHA256"] = hash, ["generationFingerprint"] = new string('a',64) }.ToJsonString());
        Assert.Equal(McpContractTests.Fixture["semantic_ids"]![1]!["expected"]!.GetValue<string>(), f.Call("get_meeting_transcript")["version_id"]!.GetValue<string>());
        f.Write("transcript.json", JsonNode.Parse(File.ReadAllText(f.PathFor("transcript.json")))!.ToJsonString(new() { WriteIndented = true })); Assert.Equal(McpContractTests.Fixture["semantic_ids"]![0]!["expected"]!.GetValue<string>(), f.Call("get_meeting_transcript")["version_id"]!.GetValue<string>());
    }

    [Fact]
    public void Summary_larger_than_64MiB_remains_pageable()
    {
        using var f = new Fixture(); using (var stream = File.Create(f.PathFor("summary.md"))) { var bytes = Encoding.UTF8.GetBytes(new string('x',65536)); for (var i = 0; i < 1025; i++) stream.Write(bytes); }
        var result = f.Call("get_meeting_summary"); Assert.Equal(65536, result["markdown"]!.GetValue<string>().Length); Assert.NotNull(result["next_cursor"]);
    }

    [Fact]
    public void Metadata_revision_tracks_bytes_when_sync_preserves_file_timestamps()
    {
        using var f = new Fixture(); var before = McpQueries.Call("list_meetings", new(), f.Runtime)["revision"]!.GetValue<string>();
        var path = f.PathFor("meta.json"); var stamp = File.GetLastWriteTimeUtc(path); f.Write("meta.json", File.ReadAllText(path).Replace("Meeting", "Changed")); File.SetLastWriteTimeUtc(path, stamp);
        var after = McpQueries.Call("list_meetings", new(), f.Runtime)["revision"]!.GetValue<string>(); Assert.NotEqual(before, after);
    }

    [Fact]
    public void Held_snapshot_rejects_same_size_restored_mtime_transcript_rewrite()
    {
        using var f = new Fixture(); var path = f.PathFor("transcript.json"); var original = File.ReadAllText(path); var stamp = File.GetLastWriteTimeUtc(path); var checks = 0; IOException? rejected = null;
        var runtime = new McpLibrary.Runtime(f.Root, pendingDeletion: _ =>
        {
            if (++checks == 2)
            {
                try { f.Write("transcript.json", original.Replace("Hello", "Jello")); File.SetLastWriteTimeUtc(path, stamp); }
                catch (IOException error) { rejected = error; }
            }
            return false;
        });
        var result = McpQueries.Call("get_meeting_transcript", f.Args(), runtime);
        Assert.Equal("  Hello world!\n", result["segments"]![0]!["text"]!.GetValue<string>());
        Assert.Equal(McpContractTests.Fixture["semantic_ids"]![0]!["expected"]!.GetValue<string>(), result["version_id"]!.GetValue<string>());
        Assert.NotNull(rejected); Assert.Equal(32, rejected.HResult & 0xffff); Assert.Equal(original, File.ReadAllText(path));
    }

    [Theory]
    [InlineData("\"bad\"")]
    [InlineData("42")]
    [InlineData("null")]
    [InlineData("[]")]
    public void Malformed_selected_legacy_speaker_is_safe_error_and_partial_listing(string entry)
    {
        using var f = new Fixture(); f.Write("speakers.json", "{\"speakers\":{\"them A\":" + entry + "}}");
        Assert.Equal("data_unreadable", Assert.Throws<McpFailure>(() => f.Call("get_meeting_transcript")).Code);
        var list = McpQueries.Call("list_meetings", new(), f.Runtime); Assert.True(list["partial"]!.GetValue<bool>());
        Assert.Equal("unknown", Assert.Single(list["items"]!.AsArray())!["participant_assignment"]!.GetValue<string>());
        Assert.Contains(list["warnings"]!.AsArray(), warning => warning!["code"]!.GetValue<string>() == "data_unreadable" && warning["artifact"]!.GetValue<string>() == "speakers");
    }

    [Fact]
    public void Preexisting_writer_conflict_is_not_ready_and_audio_disposal_releases_write_exclusion()
    {
        using var f = new Fixture();
        using (var writer = new FileStream(f.PathFor("transcript.json"), FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
            Assert.Equal("artifact_not_ready", Assert.Throws<McpFailure>(() => f.Call("get_meeting_transcript")).Code);
        var audioId = f.Call("get_meeting_audio")["items"]![0]!["audio_id"]!.GetValue<string>();
        using var cancellation = new CancellationTokenSource(); var runtime = new McpLibrary.Runtime(f.Root, cancellation: cancellation.Token);
        using (var audio = McpLibrary.OpenAudio(f.Id, audioId, runtime))
        {
            Assert.Throws<IOException>(() => f.Write("mic.wav", "changed-audio"));
            cancellation.Cancel(); Assert.Equal("server_stopping", Assert.Throws<McpFailure>(() => McpLibrary.OpenAudio(f.Id, audioId, runtime)).Code);
            Assert.Equal("audio-fixture", Encoding.UTF8.GetString(audio.Read(0, 64)));
        }
        f.Write("mic.wav", "after-disposal"); Assert.Equal("after-disposal", File.ReadAllText(f.PathFor("mic.wav")));
    }

    internal sealed class Fixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "verbemo-mcp-tests-" + Guid.NewGuid().ToString("N"));
        public string Meeting => Path.Combine(Root,"meeting"); public string Id => McpContract.MeetingId(Root,"meeting"); public McpLibrary.Runtime Runtime => new(Root, deadline: DateTimeOffset.UtcNow.AddMinutes(3));
        public McpSettings Settings => new(new(), new Dictionary<string,JsonNode?>(), new Dictionary<string,JsonNode?>(), new Dictionary<string,bool>(), Root);
        public Fixture(bool native = true) { Directory.CreateDirectory(Meeting); Write("meta.json", "{\"title\":\"Meeting\",\"started\":\"2026-10-28T08:00:00Z\",\"trigger\":\"manual\",\"duration_seconds\":2,\"files\":{\"mic\":\"mic.wav\"},\"calendar\":{\"participants\":[{\"id\":\"p1\",\"name\":\"Alex\",\"email\":\"one@example.com\"},{\"id\":\"p2\",\"name\":\"Alex\",\"email\":\"two@example.com\"}]}}"); Write("transcript.json", McpContractTests.Fixture["semantic_ids"]![0]!["transcript"]!.ToJsonString()); Write("speakers.json", native ? "{\"names\":{\"them A\":\"Alex\",\"them B\":\"Alex\"},\"sources\":{\"them A\":\"manual\"},\"participantIds\":{\"them A\":\"p1\",\"them B\":\"p2\"}}" : "{\"speakers\":{\"them A\":{\"name\":\"Alex\",\"participantID\":\"p1\"},\"them B\":{\"name\":\"Alex\",\"participantID\":\"p2\"}}}"); Write("summary.md", "# Hello summary\n"); Write("summary.stale", ""); Write("mic.wav", "audio-fixture"); }
        public string PathFor(string name) => Path.Combine(Meeting,name); public void Write(string name,string text) => File.WriteAllText(PathFor(name),text,new UTF8Encoding(false)); public JsonObject Args() => new() { ["meeting_id"] = Id };
        public JsonObject Call(string tool, JsonObject? args = null) => McpQueries.Call(tool,args ?? Args(),Runtime,Settings);
        public string[] Hashes() => Directory.GetFiles(Root,"*",SearchOption.AllDirectories).Order().Select(x => Path.GetRelativePath(Root,x) + ":" + Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(x)))).ToArray();
        public void Dispose() => Directory.Delete(Root,true);
    }
}
