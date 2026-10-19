using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using Verbemo.App;
using Velopack;
using Velopack.Locators;
using Velopack.Sources;
using Xunit;

namespace Verbemo.Live.Tests;

[CollectionDefinition("Updater", DisableParallelization = true)]
public sealed class UpdaterCollection { }

[Collection("Updater")]
public sealed class UpdateServiceTests : IDisposable
{
    private const string BaseUrl = "https://github.com/ekho/verbemo/releases/latest/download/";
    private readonly string directory = Path.Combine(Path.GetTempPath(), "verbemo-updater-" + Guid.NewGuid());
    private static readonly FieldInfo ManagerField = typeof(UpdateService).GetField("manager", BindingFlags.Static | BindingFlags.NonPublic)!;

    public UpdateServiceTests() => Directory.CreateDirectory(directory);

    [Fact]
    public void Primary_admission_prevents_second_launch_from_applying_and_preserves_doorbell()
    {
        var name = "Verbemo.UpdateAdmission." + Guid.NewGuid();
        using var first = Admission(name);
        using var second = Admission(name);
        Assert.True(IsPrimary(first));
        Assert.False(IsPrimary(second));
        Assert.False((bool)first.GetType().GetMethod("SignalExistingInstance")!.Invoke(first, null)!);
        Assert.True((bool)second.GetType().GetMethod("SignalExistingInstance")!.Invoke(second, null)!);
        var doorbell = (EventWaitHandle)first.GetType().GetProperty("Doorbell")!.GetValue(first)!;
        Assert.True(doorbell.WaitOne(0));
    }

    [Fact]
    public void Doorbell_failure_releases_primary_mutex_before_propagating()
    {
        var name = "Verbemo.UpdateAdmission." + Guid.NewGuid();
        // Windows shares the named-kernel-object namespace between mutexes and events.
        using var conflictingDoorbell = new Mutex(false, name + ".Doorbell");
        Assert.Throws<TargetInvocationException>(() => Admission(name));
        using var next = new Mutex(true, name, out var created);
        Assert.True(created);
        next.ReleaseMutex();
    }

    [Fact]
    public async Task Concurrent_launches_admit_only_one_primary_until_it_closes()
    {
        var name = "Verbemo.UpdateAdmission." + Guid.NewGuid();
        using var barrier = new Barrier(2);
        var launches = Enumerable.Range(0, 2).Select(_ => Task.Run(() =>
        {
            using var admission = Admission(name);
            var primary = IsPrimary(admission);
            Assert.True(barrier.SignalAndWait(TimeSpan.FromSeconds(20)));
            return primary;
        })).ToArray();
        Assert.Single(await Task.WhenAll(launches), value => value);
        using var next = Admission(name);
        Assert.True(IsPrimary(next));
    }

    private static IDisposable Admission(string name)
    {
        var type = typeof(UpdateService).Assembly.GetType("Verbemo.App.UpdateStartupAdmission");
        Assert.NotNull(type);
        return (IDisposable)Activator.CreateInstance(type, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
            null, [name, name + ".Doorbell"], null)!;
    }

    private static bool IsPrimary(IDisposable admission) =>
        (bool)admission.GetType().GetProperty("IsPrimary")!.GetValue(admission)!;

    [Fact]
    public void Production_source_is_own_static_stable_feed()
    {
        InstallFixture();
        var manager = (UpdateManager)ManagerField.GetValue(null)!;
        var source = typeof(UpdateManager).GetProperty("Source", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(manager);
        Assert.Equal(BaseUrl, Assert.IsType<SimpleWebSource>(source).BaseUri.AbsoluteUri);
        Assert.Equal("stable", typeof(UpdateManager).GetProperty("Channel", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(manager));
        Assert.Null(typeof(UpdateService).GetMethod("RestartIntoUpdate"));
    }

    [Fact]
    public async Task Static_feed_resolves_and_downloads_full_package_without_applying_or_exiting()
    {
        var fixture = InstallFixture();
        var result = await UpdateService.CheckAsync(() => false, true, CancellationToken.None);
        Assert.Equal(UpdateOutcome.Ready, result.Outcome);
        Assert.Contains("next", result.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("/ekho/verbemo/releases/latest/download/releases.stable.json", new Uri(fixture.Downloader.FeedRequest!).AbsolutePath);
        Assert.Equal(BaseUrl + fixture.Downloader.PackageName, fixture.Downloader.PackageRequest);
        Assert.Equal(fixture.Downloader.Package, File.ReadAllBytes(Path.Combine(directory, fixture.Downloader.PackageName)));
        Assert.Empty(fixture.Process.Starts);
        Assert.Null(fixture.Process.ExitCode);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Recording_or_processing_defers_download_even_for_interactive_check(bool interactive)
    {
        var fixture = InstallFixture();
        var result = await UpdateService.CheckAsync(() => true, interactive, CancellationToken.None);
        Assert.Equal(UpdateOutcome.Busy, result.Outcome);
        Assert.Null(fixture.Downloader.PackageRequest);
        Assert.Empty(fixture.Process.Starts);
        Assert.Null(fixture.Process.ExitCode);
    }

    [Fact]
    public async Task Busy_change_during_feed_check_cannot_apply_or_download()
    {
        var fixture = InstallFixture();
        var busy = false;
        fixture.Downloader.AfterFeed = () => busy = true;
        var result = await UpdateService.CheckAsync(() => busy, true, CancellationToken.None);
        Assert.Equal(UpdateOutcome.Busy, result.Outcome);
        Assert.Null(fixture.Downloader.PackageRequest);
        Assert.Empty(fixture.Process.Starts);
    }

    [Fact]
    public async Task Recording_start_during_download_never_applies_or_exits()
    {
        var fixture = InstallFixture();
        var busy = false;
        fixture.Downloader.BeforePackage = () => busy = true;
        var result = await UpdateService.CheckAsync(() => busy, true, CancellationToken.None);
        Assert.Equal(UpdateOutcome.Ready, result.Outcome);
        Assert.True(busy);
        Assert.Empty(fixture.Process.Starts);
        Assert.Null(fixture.Process.ExitCode);
    }

    [Fact]
    public async Task Missing_feed_is_a_nonfatal_failure()
    {
        var fixture = InstallFixture();
        fixture.Downloader.Missing = true;
        Assert.Equal(UpdateOutcome.Failed, (await UpdateService.CheckAsync(() => false, true, CancellationToken.None)).Outcome);
        Assert.Null(fixture.Downloader.PackageRequest);
        Assert.Empty(fixture.Process.Starts);
    }

    [Fact]
    public async Task Missing_package_is_a_nonfatal_failure_and_can_retry()
    {
        var fixture = InstallFixture();
        fixture.Downloader.MissingPackage = true;
        Assert.Equal(UpdateOutcome.Failed, (await UpdateService.CheckAsync(() => false, true, CancellationToken.None)).Outcome);
        Assert.Empty(fixture.Process.Starts);
        Assert.Null(fixture.Process.ExitCode);
        fixture.Downloader.MissingPackage = false;
        Assert.Equal(UpdateOutcome.Ready, (await UpdateService.CheckAsync(() => false, true, CancellationToken.None)).Outcome);
    }

    [Fact]
    public async Task Cancellation_during_uncancellable_feed_is_observed_before_up_to_date_result()
    {
        var fixture = InstallFixture();
        using var cancellation = new CancellationTokenSource();
        fixture.Downloader.NoUpdate = true;
        fixture.Downloader.AfterFeed = cancellation.Cancel;
        Assert.Equal(UpdateOutcome.Failed, (await UpdateService.CheckAsync(() => false, true, cancellation.Token)).Outcome);
        Assert.Null(fixture.Downloader.PackageRequest);
    }

    [Fact]
    public async Task Cancellation_during_package_download_does_not_apply()
    {
        var fixture = InstallFixture();
        using var cancellation = new CancellationTokenSource();
        fixture.Downloader.BeforePackage = cancellation.Cancel;
        Assert.Equal(UpdateOutcome.Failed, (await UpdateService.CheckAsync(() => false, true, cancellation.Token)).Outcome);
        Assert.False(File.Exists(Path.Combine(directory, fixture.Downloader.PackageName)));
        Assert.Empty(fixture.Process.Starts);
        Assert.Null(fixture.Process.ExitCode);
    }

    private (FixtureDownloader Downloader, ProcessSpy Process) InstallFixture()
    {
        var downloader = new FixtureDownloader();
        var process = new ProcessSpy();
        var locator = new FixtureLocator(directory, process);
        ManagerField.SetValue(null, UpdateService.CreateManager(downloader, locator));
        return (downloader, process);
    }

    public void Dispose()
    {
        ManagerField.SetValue(null, null);
        Directory.Delete(directory, true);
    }

    private sealed class FixtureLocator(string directory, IProcessImpl process) : TestVelopackLocator(
        "Verbemo", "0.1.0", directory, directory, directory, Path.Combine(directory, "Update.exe"), "stable")
    {
        public override IProcessImpl Process => process;
    }

    private sealed class ProcessSpy : IProcessImpl
    {
        public List<string> Starts { get; } = [];
        public int? ExitCode { get; private set; }
        public string GetCurrentProcessPath() => "Verbemo.exe";
        public uint GetCurrentProcessId() => 1;
        public void StartProcess(string exePath, IEnumerable<string> args, string workDir, bool showWindow) => Starts.Add(exePath);
        public void Exit(int exitCode) => ExitCode = exitCode;
    }

    private sealed class FixtureDownloader : IFileDownloader
    {
        public string PackageName => "Verbemo-0.2.0-stable-full.nupkg";
        public byte[] Package { get; }
        public string? FeedRequest { get; private set; }
        public string? PackageRequest { get; private set; }
        public bool Missing { get; set; }
        public bool MissingPackage { get; set; }
        public bool NoUpdate { get; set; }
        public Action? AfterFeed { get; set; }
        public Action? BeforePackage { get; set; }
        public FixtureDownloader()
        {
            using var memory = new MemoryStream();
            using (var zip = new ZipArchive(memory, ZipArchiveMode.Create, true))
            {
                using (var manifest = new StreamWriter(zip.CreateEntry("Verbemo.nuspec").Open()))
                    manifest.Write("<package><metadata><id>Verbemo</id><version>0.2.0</version><authors>Verbemo</authors><description>local fixture</description></metadata></package>");
                using var updater = zip.CreateEntry("lib/app/Squirrel.exe").Open();
                updater.Write([1, 2, 3]);
            }
            Package = memory.ToArray();
        }
        public Task<string> DownloadString(string url, IDictionary<string, string>? headers = null, double timeout = 30)
        {
            FeedRequest = url;
            if (Missing) throw new HttpRequestException("Local fixture 404", null, System.Net.HttpStatusCode.NotFound);
            AfterFeed?.Invoke();
            return Task.FromResult(JsonSerializer.Serialize(new { Assets = NoUpdate ? [] : new[] {
                new { PackageId = "Verbemo", Version = "0.2.0", Type = "Full", FileName = PackageName,
                      SHA256 = Convert.ToHexString(SHA256.HashData(Package)), Size = Package.Length } } }));
        }
        public Task<byte[]> DownloadBytes(string url, IDictionary<string, string>? headers = null, double timeout = 30) =>
            throw new InvalidOperationException("Unexpected fixture request");
        public async Task DownloadFile(string url, string targetFile, Action<int> progress,
            IDictionary<string, string>? headers = null, double timeout = 30, CancellationToken cancelToken = default)
        {
            PackageRequest = url;
            if (MissingPackage) throw new HttpRequestException("Local fixture package 404", null, System.Net.HttpStatusCode.NotFound);
            BeforePackage?.Invoke();
            await File.WriteAllBytesAsync(targetFile, Package, cancelToken);
            progress(100);
        }
    }
}
