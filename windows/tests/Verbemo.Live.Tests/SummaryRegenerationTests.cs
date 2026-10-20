using Verbemo.App;
using Verbemo.Core.Configuration;
using Verbemo.Core.Processing;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class SummaryRegenerationTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Regeneration_only_replaces_summary_after_success(bool fail)
    {
        await using var fixture = await Fixture.Create();
        fixture.Fail = fail;
        var original = File.ReadAllBytes(Path.Combine(fixture.Directory, "transcript.json"));
        var speakers = File.ReadAllBytes(Path.Combine(fixture.Directory, "speakers.json"));
        if (fail) await Assert.ThrowsAnyAsync<Exception>(() => fixture.Processor.RegenerateSummaryAsync(fixture.Directory));
        else await fixture.Processor.RegenerateSummaryAsync(fixture.Directory);
        Assert.Equal(1, fixture.Calls);
        Assert.Equal(fail ? "Old summary" : "New summary" + Environment.NewLine, File.ReadAllText(Path.Combine(fixture.Directory, "summary.md")));
        Assert.Equal(original, File.ReadAllBytes(Path.Combine(fixture.Directory, "transcript.json")));
        Assert.Equal(speakers, File.ReadAllBytes(Path.Combine(fixture.Directory, "speakers.json")));
        Assert.False(File.Exists(Path.Combine(fixture.Directory, "processing.json")));
    }

    [Theory]
    [InlineData("transcribe.requested")]
    [InlineData(".recording.json")]
    [InlineData("missing")]
    [InlineData("unreadable")]
    [InlineData("off")]
    public async Task Invalid_state_never_reaches_model(string state)
    {
        await using var fixture = await Fixture.Create();
        if (state == "missing") File.Delete(Path.Combine(fixture.Directory, "transcript.json"));
        else if (state == "unreadable") fixture.Readable = false;
        else if (state == "off") fixture.Settings.Summary.Enabled = false;
        else File.WriteAllText(Path.Combine(fixture.Directory, state), "pending");
        await Assert.ThrowsAsync<InvalidOperationException>(() => fixture.Processor.RegenerateSummaryAsync(fixture.Directory));
        Assert.Equal(0, fixture.Calls);
        Assert.Equal("Old summary", File.ReadAllText(Path.Combine(fixture.Directory, "summary.md")));
    }

    [Fact]
    public async Task Concurrent_request_is_rejected_and_cancellation_keeps_old_summary()
    {
        await using var fixture = await Fixture.Create();
        fixture.Wait = true;
        using var cancellation = new CancellationTokenSource();
        var first = fixture.Processor.RegenerateSummaryAsync(fixture.Directory, cancellation.Token);
        await fixture.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(fixture.Processor.IsBusy);
        await Assert.ThrowsAsync<InvalidOperationException>(() => fixture.Processor.RegenerateSummaryAsync(fixture.Directory));
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
        Assert.Equal(1, fixture.Calls);
        Assert.False(fixture.Processor.IsBusy);
        Assert.Equal("Old summary", File.ReadAllText(Path.Combine(fixture.Directory, "summary.md")));
    }

    [Fact]
    public async Task Archive_uses_root_reservation_and_changes_only_selected_version()
    {
        await using var fixture = await Fixture.Create();
        await TranscriptVersions.ArchiveCurrentAsync(fixture.Directory);
        var archive = System.IO.Directory.GetDirectories(Path.Combine(fixture.Directory, "transcripts")).Single();
        fixture.Wait = true;
        var task = fixture.Processor.RegenerateSummaryAsync(archive);
        await fixture.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Assert.ThrowsAsync<InvalidOperationException>(() => fixture.Processor.RegenerateSummaryAsync(fixture.Directory));
        fixture.Release.TrySetResult();
        await task;
        Assert.Equal("Old summary", File.ReadAllText(Path.Combine(fixture.Directory, "summary.md")));
        Assert.Equal("New summary" + Environment.NewLine, File.ReadAllText(Path.Combine(archive, "summary.md")));
    }

    private sealed class Fixture : IAsyncDisposable
    {
        public required string Directory { get; init; }
        public required AppSettings Settings { get; init; }
        public required ProcessingCoordinator Processor { get; set; }
        public required AnalyticsService Analytics { get; init; }
        public required HttpClient Http { get; init; }
        public bool Readable = true, Fail, Wait;
        public int Calls;
        public TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public static async Task<Fixture> Create()
        {
            var root = Path.Combine(Path.GetTempPath(), "verbemo-summary-tests", Guid.NewGuid().ToString("N"));
            System.IO.Directory.CreateDirectory(root);
            var settings = AppSettings.CreateConservative(root);
            settings.Summary.Enabled = true;
            settings.Summary.Backend = "ollama";
            var http = new HttpClient();
            var analytics = new AnalyticsService(root, () => settings, () => false, http);
            var fixture = new Fixture { Directory = root, Settings = settings, Http = http, Analytics = analytics, Processor = null! };
            fixture.Processor = new ProcessingCoordinator(() => settings, () => fixture.Readable, new SecretStore(),
                new ModelManager(root, http, root), http, analytics,
                (_, _) => throw new Exception("ASR must not run"),
                purpose => [new("ollama", "fake", false, async (_, _, token) =>
                {
                    Assert.Equal(EgressPurpose.Summary, purpose);
                    Interlocked.Increment(ref fixture.Calls);
                    fixture.Started.TrySetResult();
                    if (fixture.Wait) await fixture.Release.Task.WaitAsync(token);
                    if (fixture.Fail) throw new ProcessingFailure(FailureKind.Environmental, "Unavailable");
                    return "New summary";
                })]);
            await File.WriteAllTextAsync(Path.Combine(root, "meta.json"), "{\"title\":\"Test\"}");
            await TranscriptWriter.WriteAsync(root, "Test", new("whisper", "tiny", DateTimeOffset.UtcNow, [new(0, 1000, "Words", "A")]));
            await SpeakerFile.WriteAsync(root, new Dictionary<string,string> { ["A"] = "Alice" }, new Dictionary<string,string> { ["A"] = "manual" }, default);
            await File.WriteAllTextAsync(Path.Combine(root, "summary.md"), "Old summary");
            return fixture;
        }

        public async ValueTask DisposeAsync()
        {
            Release.TrySetResult();
            await Processor.DisposeAsync();
            await Analytics.DisposeAsync();
            Http.Dispose();
            System.IO.Directory.Delete(Directory, true);
        }
    }
}
