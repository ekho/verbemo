using System.Reflection;
using System.Runtime.ExceptionServices;
using Verbemo.App;
using Verbemo.Core.Configuration;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class ApplicationWindowTests
{
    [Fact]
    public void Sections_share_host_and_keep_meeting_selection() => OnSta(() =>
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-window-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var settings = AppSettings.CreateConservative(root);
        var path = Path.Combine(root, "config.json");
        File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(settings, AppSettings.JsonOptions));
        var store = new AppSettingsStore(path, root);
        var runtime = (VerbemoRuntime)typeof(VerbemoRuntime).GetConstructors(BindingFlags.NonPublic | BindingFlags.Instance).Single()
            .Invoke([store, store.Load(), root]);
        try
        {
            var status = new StatusWindow(runtime, embedded: true);
            var window = new ApplicationWindow(runtime, status);
            window.Navigation.SessionDirectory = "selected";
            window.Navigation.VersionKey = "archived";
            window.Navigation.Query = "words";
            window.Navigation.Tab = 1;
            var host = window.Content;
            foreach (var destination in Enum.GetValues<ApplicationDestination>()) window.ShowDestination(destination);
            Assert.Same(host, window.Content);
            Assert.Equal("selected", window.Navigation.SessionDirectory);
            Assert.Equal("archived", window.Navigation.VersionKey);
            Assert.Equal("words", window.Navigation.Query);
            Assert.Equal(1, window.Navigation.Tab);
            window.ShowAllMeetings();
            Assert.Equal("", window.Navigation.Query);
            Assert.Null(window.Navigation.SessionDirectory);
            Assert.Equal(ApplicationDestination.AllMeetings, window.Navigation.Destination);
            window.AllowClose();
            window.Close();
            status.AllowClose();
            status.Close();
        }
        finally { runtime.DisposeAsync().AsTask().GetAwaiter().GetResult(); Directory.Delete(root, true); }
    });

    internal static void OnSta(Action test)
    {
        Exception? failure = null;
        var thread = new Thread(() => { try { test(); } catch (Exception error) { failure = error; } });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(20)));
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
