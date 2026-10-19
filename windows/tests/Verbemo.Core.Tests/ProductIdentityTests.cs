using Verbemo.App;
using Verbemo.Core.Configuration;
using Verbemo.Core.Processing;
using Verbemo.Core.Sessions;

namespace Verbemo.Core.Tests;

public sealed class ProductIdentityTests
{
    [Fact]
    public void AmanuDataRemainsUntouched()
    {
        using var temporary = new TemporaryDirectory();
        var home = Path.Combine(temporary.Path, "home");
        var localData = Path.Combine(temporary.Path, "local");
        var legacyFiles = new Dictionary<string, string>();
        foreach (var directory in new[] { "Amanu", "Amanu Data" })
        {
            var folder = Path.Combine(localData, directory);
            Directory.CreateDirectory(Path.Combine(folder, "models"));
            legacyFiles[Path.Combine(folder, "config.json")] = "{\"keep_audio\":true}";
            legacyFiles[Path.Combine(folder, "setup.json")] = "legacy setup";
            legacyFiles[Path.Combine(folder, "models", ModelCatalog.Models["parakeet"].FileName)] = "legacy model";
        }
        var oldRecording = Path.Combine(home, "Amanu Recordings", "meeting", "transcript.txt");
        Directory.CreateDirectory(Path.GetDirectoryName(oldRecording)!);
        legacyFiles[oldRecording] = "original recording";
        foreach (var (path, content) in legacyFiles) File.WriteAllText(path, content);

        var store = new AppSettingsStore(Path.Combine(ProductIdentity.DataDirectory(localData), "config.json"), home);
        var settings = store.Load().Settings;
        Assert.False(settings.KeepAudio);
        Assert.Equal(Path.Combine(home, "Verbemo Recordings"), settings.RecordingsDirectory);
        store.Save(settings);
        using var http = new HttpClient();
        var manager = new ModelManager(ProductIdentity.DataDirectory(localData), http);
        Assert.Equal(Path.Combine(localData, "Verbemo Data", "models"), manager.ModelDirectory);
        Assert.Null(manager.DownloadedBytes("parakeet"));
        foreach (var (path, content) in legacyFiles) Assert.Equal(content, File.ReadAllText(path));
    }

    [Fact]
    public void UsesIndependentCredentialAndStartupNames()
    {
        Assert.Equal("Verbemo/", ProductIdentity.CredentialPrefix);
        Assert.Equal("Verbemo", ProductIdentity.StartupEntryName);
        Assert.Equal("Local\\Verbemo.Desktop.SingleInstance", ProductIdentity.InstanceName);
        Assert.Equal("Local\\Verbemo.Desktop.ShowWindow", ProductIdentity.DoorbellName);
        Assert.Equal("VERBEMO_TEST_DATA", ProductIdentity.TestDataEnvironmentVariable);
        Assert.NotEqual("Amanu/", ProductIdentity.CredentialPrefix);
        Assert.NotEqual("Amanu", ProductIdentity.StartupEntryName);
        Assert.NotEqual("Local\\Amanu.Desktop.SingleInstance", ProductIdentity.InstanceName);
        Assert.NotEqual("Local\\Amanu.Desktop.ShowWindow", ProductIdentity.DoorbellName);
    }

    [Fact]
    public void ExplicitRecordingDirectoryStillWorks()
    {
        using var temporary = new TemporaryDirectory();
        var recordings = Path.Combine(temporary.Path, "Amanu Recordings");
        var meeting = Path.Combine(recordings, "old meeting");
        Directory.CreateDirectory(meeting);
        File.WriteAllText(Path.Combine(meeting, "transcript.txt"), "existing transcript");
        var store = new AppSettingsStore(Path.Combine(temporary.Path, "Verbemo Data", "config.json"), temporary.Path);
        var settings = store.Defaults;
        settings.RecordingsDirectory = recordings;
        store.Save(settings);

        var chosen = store.Load().Settings.RecordingsDirectory;
        Assert.Equal(recordings, chosen);
        Assert.Equal("existing transcript", File.ReadAllText(Path.Combine(chosen, "old meeting", "transcript.txt")));
        var session = new SessionStore(chosen, Environment.ProcessId).Start(
            DateTimeOffset.UtcNow, "new meeting", SessionTrigger.Manual, null);
        Assert.Equal(chosen, Path.GetDirectoryName(session.Directory));
        Assert.Equal("existing transcript", File.ReadAllText(Path.Combine(meeting, "transcript.txt")));
    }
}
