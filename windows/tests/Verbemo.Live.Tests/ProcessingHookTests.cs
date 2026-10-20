using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Verbemo.App;
using Verbemo.Core.Configuration;
using Xunit;
using Xunit.Abstractions;

namespace Verbemo.Live.Tests;

public sealed class ProcessingHookTests(ITestOutputHelper output)
{
    [Theory]
    [InlineData(0, false)]
    [InlineData(500, true)]
    public async Task An_open_hook_does_not_block_the_next_session_or_run_twice(int startupDelay, bool stopBeforeHookReady)
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-hook-tests", Guid.NewGuid().ToString("N"));
        var sessions = new[] { Path.Combine(root, "first"), Path.Combine(root, "second") };
        foreach (var session in sessions)
        {
            Directory.CreateDirectory(session);
            await File.WriteAllTextAsync(Path.Combine(session, "meta.json"), JsonSerializer.Serialize(new { title = Path.GetFileName(session) }));
        }
        // A viewer stays open until the test releases it, like Notepad opened
        // by on_stop. No network, audio, credentials or user settings are used.
        var script = $"Start-Sleep -Milliseconds {startupDelay}; "
            + "$PID | Set-Content -LiteralPath 'hook.pid.tmp'; Move-Item -LiteralPath 'hook.pid.tmp' -Destination 'hook.pid'; "
            + "Add-Content -LiteralPath 'hook.runs' -Value 'started'; $deadline = [DateTime]::UtcNow.AddSeconds(30); "
            + "while (-not (Test-Path -LiteralPath 'release') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }";
        var settings = AppSettings.CreateDefault(root);
        settings.RecordingsDirectory = root;
        settings.Transcription.Enabled = false;
        settings.Analytics = false;
        settings.OnStop = new CommandHook
        {
            Executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = ["-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script))],
        };
        using var http = new HttpClient();
        await using var analytics = new AnalyticsService(root, () => settings, () => false, http);
        var processor = new ProcessingCoordinator(() => settings, () => true,
            new SecretStore(), new ModelManager(root, http), http, analytics);
        var completed = new ConcurrentDictionary<string, bool>();
        var bothDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var repeated = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        processor.StatusChanged += (_, status) =>
        {
            if (status.Stage != "complete" || status.SessionDirectory is null) return;
            if (!completed.TryAdd(status.SessionDirectory, true)) repeated.TrySetResult();
            if (completed.Count == 2) bothDone.TrySetResult();
        };
        try
        {
            processor.Start();
            await bothDone.Task.WaitAsync(TimeSpan.FromSeconds(20));
            // Exercise teardown before a slow shell has published its identity.
            if (stopBeforeHookReady) throw new OperationCanceledException("Simulated interruption before hook startup");
            foreach (var session in sessions)
            {
                await WaitForFileAsync(Path.Combine(session, "hook.runs"));
                var pid = int.Parse((await File.ReadAllTextAsync(Path.Combine(session, "hook.pid"))).Trim());
                using var hook = Process.GetProcessById(pid);
                Assert.False(hook.HasExited);
                Assert.True(ProcessingCoordinator.Ledger(session).HookRan);
            }
            // Reprocessing a settled session must not launch its hook again.
            processor.Enqueue(sessions[1]);
            await repeated.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Single(await File.ReadAllLinesAsync(Path.Combine(sessions[1], "hook.runs")));
        }
        catch (OperationCanceledException) when (stopBeforeHookReady) { }
        catch (Exception exception)
        {
            output.WriteLine("Hook assertions failed before cleanup: {0}", exception);
            throw;
        }
        finally
        {
            output.WriteLine("Releasing hooks in {0} at {1:O}", root, DateTimeOffset.UtcNow);
            foreach (var session in sessions) await File.WriteAllTextAsync(Path.Combine(session, "release"), "release");
            await processor.DisposeAsync();
            var cleanupErrors = new List<Exception>();
            foreach (var session in sessions)
            {
                try
                {
                    var path = Path.Combine(session, "hook.pid");
                    if (!ProcessingCoordinator.Ledger(session).HookRan) continue;
                    // A launched shell can still be starting when assertions time out.
                    // Keep its release marker and working directory until it registers and exits.
                    await WaitForFileAsync(path);
                    var pid = int.Parse((await File.ReadAllTextAsync(path)).Trim());
                    output.WriteLine("Waiting for hook PID {0} in {1}", pid, session);
                    try
                    {
                        using var hook = Process.GetProcessById(pid);
                        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                        try { await hook.WaitForExitAsync(limit.Token); }
                        catch (OperationCanceledException)
                        {
                            output.WriteLine("Terminating timed-out hook PID {0}", pid);
                            try { hook.Kill(entireProcessTree: true); }
                            catch (InvalidOperationException) when (hook.HasExited) { }
                            using var killLimit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                            await hook.WaitForExitAsync(killLimit.Token);
                            throw new TimeoutException($"Hook PID {pid} did not exit after release");
                        }
                    }
                    catch (ArgumentException) { }
                }
                catch (Exception exception)
                {
                    output.WriteLine("Hook cleanup failed for {0}: {1}", session, exception);
                    cleanupErrors.Add(exception);
                }
            }
            if (cleanupErrors.Count > 0)
                throw new AggregateException("Hook cleanup failed; release markers retained", cleanupErrors);
            // A session directory can remain locked briefly after the hook exits.
            for (var attempt = 0; ; attempt++)
            {
                try { Directory.Delete(root, recursive: true); break; }
                catch (IOException exception) when (attempt < 20)
                {
                    output.WriteLine("Directory release pending at {0:O}: {1}", DateTimeOffset.UtcNow, exception.Message);
                    await Task.Delay(100);
                }
            }
        }
    }

    private static async Task WaitForFileAsync(string path)
    {
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        while (!File.Exists(path)) await Task.Delay(25, limit.Token);
    }
}
