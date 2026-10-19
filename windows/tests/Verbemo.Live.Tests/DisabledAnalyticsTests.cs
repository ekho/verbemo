using System.Net;
using Verbemo.App;
using Verbemo.Core.Configuration;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class DisabledAnalyticsTests
{
    [Theory]
    [InlineData("{}")]
    [InlineData("{\"analytics\":true}")]
    [InlineData("{\"analytics\":false}")]
    [InlineData("{\"analytics\":\"yes\"}")]
    [InlineData("{\"analytics\":true")]
    public async Task Lifecycle_ignores_config_and_pending_events_without_network_or_identity(string config)
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-analytics-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var configPath = Path.Combine(root, "config.json");
            File.WriteAllText(configPath, config);
            var load = new AppSettingsStore(configPath, root).Load();
            var queuePath = Path.Combine(root, "analytics-pending.json");
            const string pending = "[{\"QueueId\":\"old\",\"Name\":\"recording_started\",\"Timestamp\":1,\"Data\":{}}]";
            File.WriteAllText(queuePath, pending);
            using var transport = new SpyHandler();
            using var http = new HttpClient(transport);
            await using (var analytics = new AnalyticsService(root, () => load.Settings, () => !load.IsUnreadable, http))
            {
                await analytics.StartAsync();
                await analytics.SetEnabledAsync(true);
                await analytics.RecordAsync("recording_started");
                await analytics.RecordAsync("recording_finished", new Dictionary<string, object?> { ["path"] = "private meeting" });
                await analytics.FlushAsync(CancellationToken.None);
                await analytics.SetEnabledAsync(false);
            }
            Assert.False(load.Settings.Analytics);
            Assert.Equal(0, transport.Calls);
            Assert.False(File.Exists(Path.Combine(root, "analytics.json")));
            Assert.Equal(pending, File.ReadAllText(queuePath));
            Assert.Equal(config, File.ReadAllText(configPath));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Fact]
    public async Task Fresh_lifecycle_does_not_create_a_data_directory_or_read_settings()
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-disabled-" + Guid.NewGuid().ToString("N"));
        using var transport = new SpyHandler();
        using var http = new HttpClient(transport);
        await using (var analytics = new AnalyticsService(root,
            () => throw new InvalidOperationException("must not collect settings"), () => true, http))
        {
            await analytics.StartAsync();
            await analytics.SetEnabledAsync(true);
            await analytics.RecordAsync("installed");
            await analytics.FlushAsync(CancellationToken.None);
        }
        Assert.False(Directory.Exists(root));
        Assert.Equal(0, transport.Calls);
    }

    private sealed class SpyHandler : HttpMessageHandler
    {
        public int Calls { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));
        }
    }
}
