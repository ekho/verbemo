using Velopack;
using Velopack.Exceptions;
using Velopack.Locators;
using Velopack.Sources;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App;

public enum UpdateOutcome
{
    NotInstalled,
    UpToDate,
    /// <summary>Downloaded and waiting for the next primary startup, before recording begins.</summary>
    Ready,
    Busy,
    Failed,
}

public sealed record UpdateResult(UpdateOutcome Outcome, string Message);

/// <summary>
/// Checks the stable feed and prepares a package for the next primary startup.
/// This service never arms an updater or exits a running recording/processing session.
/// </summary>
public static class UpdateService
{
    private static UpdateManager? manager;
    private static UpdateManager Manager => manager ??= CreateManager();

    internal static UpdateManager CreateManager(IFileDownloader? downloader = null, IVelopackLocator? locator = null) => new(
        new SimpleWebSource("https://github.com/ekho/verbemo/releases/latest/download/", downloader),
        new UpdateOptions { ExplicitChannel = "stable" }, locator);

    public static async Task<UpdateResult> CheckAsync(Func<bool> busy, bool interactive, CancellationToken cancellationToken)
    {
        try
        {
            if (!Manager.IsInstalled)
                return new(UpdateOutcome.NotInstalled, T("This copy of Verbemo was not installed by its installer, so it doesn't update itself.",
                    "Эта копия Verbemo установлена не установщиком, поэтому сама не обновляется."));
            cancellationToken.ThrowIfCancellationRequested();
            var update = await Manager.CheckForUpdatesAsync();
            // Velopack 1.2's feed request has no cancellation-token parameter.
            cancellationToken.ThrowIfCancellationRequested();
            if (update is null)
                return new(UpdateOutcome.UpToDate, T($"Verbemo {VerbemoRuntime.AppVersion} is the latest version.", $"Verbemo {VerbemoRuntime.AppVersion} — последняя версия."));
            if (busy())
                return new(UpdateOutcome.Busy, T("An update waits until the recording ends.", "Обновление подождёт конца записи."));
            await Manager.DownloadUpdatesAsync(update, progress: null, cancelToken: cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            return new(UpdateOutcome.Ready, T($"Verbemo {update.TargetFullRelease.Version} is downloaded and installs the next time you open Verbemo after closing it.",
                $"Verbemo {update.TargetFullRelease.Version} скачана и установится, когда вы закроете и снова откроете Verbemo."));
        }
        catch (NotInstalledException)
        {
            return new(UpdateOutcome.NotInstalled, T("This copy of Verbemo doesn't update itself.", "Эта копия Verbemo сама не обновляется."));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new(UpdateOutcome.Failed, "");
        }
        catch (Exception exception)
        {
            // Update failures are retried at the next launch and never get in the way of recording.
            return new(UpdateOutcome.Failed, T("Couldn't check for updates: ", "Не удалось проверить обновления: ") + exception.Message);
        }
    }

}
