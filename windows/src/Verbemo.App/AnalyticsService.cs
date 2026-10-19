using System.Net.Http;
using Verbemo.Core.Configuration;

namespace Verbemo.App;

/// <summary>Compatibility API: product analytics is permanently disabled.</summary>
public sealed class AnalyticsService : IAsyncDisposable
{
    public AnalyticsService(string dataDirectory, Func<AppSettings> settings, Func<bool> permitted, HttpClient httpClient) { }

    public Task StartAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
    public Task SetEnabledAsync(bool enabled, CancellationToken cancellationToken = default) => Task.CompletedTask;
    public Task RecordAsync(string eventName, IReadOnlyDictionary<string, object?>? properties = null,
        CancellationToken cancellationToken = default) => Task.CompletedTask;
    public Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
