using Verbemo.App;
using Verbemo.Core.Processing;

namespace Verbemo.Core.Tests;

public sealed class ModelManagerTests
{
    [Fact]
    public void Removing_in_use_model_is_refused_and_unused_files_can_be_removed()
    {
        using var temp = new TemporaryDirectory();
        using var client = new HttpClient(new RejectDownloads());
        var manager = new ModelManager(temp.Path, client);
        Directory.CreateDirectory(manager.ModelDirectory);
        File.WriteAllBytes(manager.ModelPath("parakeet"), [1]);
        Assert.Throws<InvalidOperationException>(() => manager.Delete("parakeet", inUse: true));
        Assert.True(File.Exists(manager.ModelPath("parakeet")));
        manager.Delete("parakeet", inUse: false);
        Assert.False(File.Exists(manager.ModelPath("parakeet")));
        Assert.Throws<InvalidOperationException>(() => manager.Delete("../../other", false));
    }

    [Fact]
    public async Task Download_can_be_cancelled_and_cannot_be_deleted_while_running()
    {
        using var temp = new TemporaryDirectory();
        var handler = new WaitingDownload();
        using var client = new HttpClient(handler);
        Directory.CreateDirectory(Path.Combine(temp.Path,"local-runtime"));
        File.WriteAllBytes(Path.Combine(temp.Path,"local-runtime","transcribe-cli.exe"),[1]);
        var manager = new ModelManager(temp.Path,client,temp.Path);
        var downloading = manager.EnsureReadyAsync("parakeet");
        await handler.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(manager.IsDownloading("parakeet"));
        Assert.Throws<InvalidOperationException>(() => manager.Delete("parakeet",false));
        manager.CancelDownload("parakeet");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => downloading);
        Assert.False(manager.IsDownloading("parakeet"));
        Assert.False(File.Exists(manager.ModelPath("parakeet")));
    }

    private sealed class WaitingDownload : HttpMessageHandler
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellationToken)
        {
            Started.TrySetResult();
            await Task.Delay(Timeout.Infinite,cancellationToken);
            throw new InvalidOperationException("Unreachable");
        }
    }
    [Fact]
    public async Task Missing_cli_reports_unavailable_runtime_without_downloading_native_library()
    {
        using var temp = new TemporaryDirectory();
        using var client = new HttpClient(new RejectDownloads());
        var manager = new ModelManager(temp.Path, client);

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => manager.EnsureReadyAsync("parakeet"));

        Assert.Contains("runtime", error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.False(manager.IsReady("parakeet"));
    }

    [Fact]
    public void Bundled_cli_and_existing_model_are_ready_without_legacy_runtime_cache()
    {
        using var temp = new TemporaryDirectory();
        using var client = new HttpClient(new RejectDownloads());
        var appDirectory = Path.Combine(temp.Path, "app");
        var cliDirectory = Path.Combine(appDirectory, "local-runtime");
        Directory.CreateDirectory(cliDirectory);
        File.WriteAllBytes(Path.Combine(cliDirectory, "transcribe-cli.exe"), [1]);
        var models = Path.Combine(temp.Path, "data", "models");
        Directory.CreateDirectory(models);
        File.WriteAllBytes(Path.Combine(models, ModelCatalog.Models["parakeet"].FileName), [1]);

        var manager = new ModelManager(Path.Combine(temp.Path, "data"), client, appDirectory);

        Assert.True(manager.IsReady("parakeet"));
        Assert.Equal(Path.Combine(cliDirectory, "transcribe-cli.exe"), manager.CliPath);
    }

    private sealed class RejectDownloads : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new HttpRequestException("Unexpected download: " + request.RequestUri);
    }
}
