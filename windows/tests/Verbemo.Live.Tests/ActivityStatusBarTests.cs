using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using Verbemo.App;
using Verbemo.Core.Localization;
using Verbemo.Core.Configuration;
using Verbemo.Core.Recording;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class ActivityStatusBarTests
{
    [Theory]
    [InlineData(false, MicrophoneAccess.State.Allowed, false, "Access: allowed")]
    [InlineData(false, MicrophoneAccess.State.Unknown, false, "Access: unknown")]
    [InlineData(false, MicrophoneAccess.State.DeniedForDesktopApps, true, "Access: blocked")]
    [InlineData(false, MicrophoneAccess.State.DeniedForEveryone, true, "Access: blocked")]
    [InlineData(true, MicrophoneAccess.State.Allowed, false, "Access: unknown")]
    public void Readiness_does_not_promote_unknown_or_unreadable_settings(bool unreadable, MicrophoneAccess.State microphone, bool blocked, string label)
    {
        using var language = Localized.Use(InterfaceLanguage.English);
        var access = ActivityAccess.From(unreadable, microphone);
        Assert.Equal(blocked, access.Blocked);
        Assert.Equal(label, access.Label);
        if (label == "Access: allowed") Assert.Contains("does not prove", access.Detail);
    }

    [Fact]
    public async Task Direct_work_and_waiting_queue_are_counted_once_and_release_without_stale_job()
    {
        await using var fixture = await SummaryRegenerationTests.Fixture.Create();
        fixture.Wait = true;
        using var cancellation = new CancellationTokenSource();
        var task = fixture.Processor.RegenerateSummaryAsync(fixture.Directory, cancellation.Token);
        await fixture.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        fixture.Processor.Enqueue(fixture.Directory); // Already reserved by direct work.
        var waiting = Path.Combine(fixture.Directory, "waiting");
        fixture.Processor.Enqueue(waiting);
        fixture.Processor.Enqueue(waiting);
        var reserved = Path.Combine(fixture.Directory, "other-direct");
        using (fixture.Processor.TryReserveIdleSession(reserved))
        {
            var snapshot = fixture.Processor.Activity;
            Assert.Equal(2, snapshot.Running.Count);
            Assert.Equal(1, snapshot.Waiting);
            Assert.Contains(snapshot.Running, status => status.SessionDirectory == fixture.Directory && status.Stage == "summary");
            Assert.Equal("summary", fixture.Processor.StatusFor(fixture.Directory)?.Stage);
        }
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        Assert.Empty(fixture.Processor.Activity.Running);
        Assert.Equal(1, fixture.Processor.Activity.Waiting);
        using var next = fixture.Processor.TryReserveIdleSession(fixture.Directory);
        Assert.Equal("preparing", Assert.Single(fixture.Processor.Activity.Running).Stage);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Direct_completion_or_failure_does_not_hide_other_owned_work(bool fail)
    {
        await using var fixture = await SummaryRegenerationTests.Fixture.Create();
        fixture.Fail = fail;
        using var other = fixture.Processor.TryReserveIdleSession(Path.Combine(fixture.Directory, "other"));
        if (fail) await Assert.ThrowsAnyAsync<Exception>(() => fixture.Processor.RegenerateSummaryAsync(fixture.Directory));
        else await fixture.Processor.RegenerateSummaryAsync(fixture.Directory);
        var remaining = Assert.Single(fixture.Processor.Activity.Running);
        Assert.EndsWith("other", remaining.SessionDirectory);
        Assert.Equal("preparing", remaining.Stage);
        Assert.Equal(0, fixture.Processor.Activity.Waiting);
    }

    [Theory]
    [InlineData(InterfaceLanguage.English)]
    [InlineData(InterfaceLanguage.Russian)]
    public void Minimum_width_keeps_controls_and_full_long_job_name(InterfaceLanguage language) => ApplicationWindowTests.OnSta(() =>
    {
        using var scope = Localized.Use(language);
        RecordingActionsTests.WithWindow((recordings, root) =>
        {
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(recordings, "runtime");
            var processor = RecordingActionsTests.Field<ProcessingCoordinator>(runtime, "processing");
            using var operation = processor.TryReserveIdleSession(root);
            var title = string.Concat(Enumerable.Repeat("Очень длинное название встречи ", 20));
            var destination = ApplicationDestination.AllMeetings;
            var bar = new ActivityStatusBar(runtime, value => destination = value, () => 2, _ => title);
            bar.Measure(new Size(788, 52));
            bar.Arrange(new Rect(0, 0, 788, 52));
            bar.UpdateLayout();
            var grid = Assert.IsType<Grid>(bar.Child);
            var controls = grid.Children.OfType<FrameworkElement>().ToArray();
            for (var i = 0; i < controls.Length; i++)
            {
                var start = controls[i].TranslatePoint(new Point(0, 0), bar).X;
                Assert.True(controls[i].ActualWidth > 20);
                Assert.InRange(start, 0, 788);
                Assert.True(start + controls[i].ActualWidth <= 788);
                if (i + 1 < controls.Length)
                    Assert.True(start + controls[i].ActualWidth <= controls[i + 1].TranslatePoint(new Point(0, 0), bar).X);
            }
            var work = Find<Button>(bar, "activity.work");
            Assert.Contains(title, AutomationProperties.GetName(work));
            Assert.Contains(title, Assert.IsType<string>(work.ToolTip));
            foreach (var (id, expected) in new[] { ("activity.work", ApplicationDestination.Processing),
                         ("activity.recording", ApplicationDestination.Live), ("activity.access", ApplicationDestination.General),
                         ("activity.warning", ApplicationDestination.Attention) })
            {
                Find<Button>(bar, id).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Assert.Equal(expected, destination);
            }
            var toggle = Find<ClickCheckBox>(bar, "activity.auto");
            Assert.False(runtime.Settings.AutoRecord.Enabled);
            var peer = UIElementAutomationPeer.CreatePeerForElement(toggle)!;
            ((IToggleProvider)peer.GetPattern(PatternInterface.Toggle)!).Toggle();
            Assert.True(runtime.Settings.AutoRecord.Enabled);
            Assert.True(toggle.IsChecked);
            ((IToggleProvider)peer.GetPattern(PatternInterface.Toggle)!).Toggle();
            Assert.False(runtime.Settings.AutoRecord.Enabled);
        });
    });

    [Fact]
    public void Recording_pause_silence_and_lost_track_have_distinct_status() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((recordings, root) =>
        {
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(recordings, "runtime");
            var coordinator = RecordingActionsTests.Field<RecordingCoordinator>(runtime, "coordinator");
            var capture = RecordingActionsTests.Field<WindowsAudioCapture>(runtime, "capture");
            var state = new RecordingState(true, false, DateTimeOffset.Now.AddSeconds(-65), root, null, null);
            typeof(RecordingCoordinator).GetProperty("State")!.SetValue(coordinator, state);
            var destination = ApplicationDestination.General;
            var bar = new ActivityStatusBar(runtime, page => destination = page, () => 0, _ => null);
            Assert.Contains("1:", AutomationProperties.GetName(Find<Button>(bar, "activity.recording")));
            capture.MicrophoneLevel.Update(new byte[4], new NAudio.Wave.WaveFormat(16000, 16, 1), silent: true);
            bar.RefreshMeters();
            var microphone = Find<ProgressBar>(bar, "activity.microphone");
            Assert.Equal(-60, microphone.Value);
            Assert.Equal(Localized.T("Silence", "Тишина"), AutomationProperties.GetHelpText(microphone));
            Assert.Null(runtime.RecordingWarning);
            Assert.Equal(Localized.T("No reading", "Нет данных"), AutomationProperties.GetHelpText(Find<ProgressBar>(bar, "activity.system")));
            typeof(RecordingCoordinator).GetProperty("State")!.SetValue(coordinator, state with { IsPaused = true });
            bar.Refresh();
            Assert.Contains(Localized.T("paused", "пауза"), AutomationProperties.GetName(Find<Button>(bar, "activity.recording")));
            Assert.Equal(Localized.T("Paused", "Пауза"), AutomationProperties.GetHelpText(microphone));
            ((EventHandler<string>)typeof(WindowsAudioCapture).GetField("TrackLost", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(capture)!).Invoke(capture, "mic");
            bar.Refresh();
            Find<Button>(bar, "activity.warning").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Assert.Equal(ApplicationDestination.Live, destination);
            typeof(RecordingCoordinator).GetMethod("Publish", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(coordinator, [RecordingState.Ready]);
            Assert.Null(runtime.RecordingWarning);
        }));

    [Fact]
    public void Pending_deletion_reservation_is_not_presented_as_processing() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((recordings, _) =>
        {
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(recordings, "runtime");
            var directory = Path.Combine(runtime.Settings.RecordingsDirectory, "pending-deletion");
            Directory.CreateDirectory(directory);
            runtime.ScheduleDeletion(directory);
            try { Assert.Empty(runtime.ProcessingActivity.Running); }
            finally { runtime.Deletions.Undo(directory); runtime.Deletions.WhenIdle.GetAwaiter().GetResult(); }
            Assert.True(Directory.Exists(directory));
        }));

    [Theory]
    [InlineData("success")]
    [InlineData("cancel")]
    [InlineData("missing")]
    public async Task Import_is_owned_before_copy_and_releases_on_every_exit(string outcome)
    {
        await using var fixture = await SummaryRegenerationTests.Fixture.Create();
        fixture.Settings.RecordingsDirectory = Path.Combine(fixture.Directory, "imports");
        var source = Path.Combine(fixture.Directory, "incoming.wav");
        if (outcome != "missing")
            using (var audio = new NAudio.Wave.WaveFileWriter(source, new NAudio.Wave.WaveFormat(16000, 16, 1)))
                audio.Write(new byte[32000], 0, 32000);
        ProcessingActivity? duringImport = null;
        var events = new List<(ProcessingStatus Status, bool Owned)>();
        fixture.Processor.StatusChanged += (_, status) =>
        {
            events.Add((status, fixture.Processor.StatusFor(status.SessionDirectory!)?.IsBusy == true));
            if (status.Stage == "importing") duringImport = fixture.Processor.Activity;
        };
        using var cancellation = new CancellationTokenSource();
        if (outcome == "cancel") cancellation.Cancel();
        if (outcome == "missing") await Assert.ThrowsAsync<FileNotFoundException>(() => fixture.Processor.ImportAsync(source));
        else if (outcome == "cancel") await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Processor.ImportAsync(source, cancellation.Token));
        else await fixture.Processor.ImportAsync(source);
        Assert.NotNull(duringImport);
        Assert.Equal("importing", Assert.Single(duringImport.Running).Stage);
        Assert.Equal(0, duringImport.Waiting);
        Assert.Empty(fixture.Processor.Activity.Running);
        Assert.Equal(outcome == "success" ? 1 : 0, fixture.Processor.Activity.Waiting);
        if (outcome != "success")
        {
            var terminal = events.Last();
            Assert.False(terminal.Status.IsBusy);
            Assert.False(terminal.Owned);
            Assert.Equal(outcome == "cancel" ? "idle" : "failed", terminal.Status.Stage);
        }
        if (outcome != "missing") Assert.True(File.Exists(source));
    }

    [Fact]
    public async Task Import_reservation_refusal_uses_the_UI_error_contract_without_clearing_its_owner()
    {
        await using var fixture = await SummaryRegenerationTests.Fixture.Create();
        fixture.Settings.RecordingsDirectory = Path.Combine(fixture.Directory, "imports");
        var source = Path.Combine(fixture.Directory, "incoming.wav");
        using (var audio = new NAudio.Wave.WaveFileWriter(source, new NAudio.Wave.WaveFormat(16000, 16, 1)))
            audio.Write(new byte[32000], 0, 32000);
        Exception? refusal = null;
        ProcessingStatus? ownerAfterRefusal = null;
        var events = new List<ProcessingStatus>();
        fixture.Processor.StatusChanged += (_, status) =>
        {
            events.Add(status);
            if (status.Stage != "importing") return;
            refusal = Record.ExceptionAsync(() => fixture.Processor.ImportAsync(source)).GetAwaiter().GetResult();
            ownerAfterRefusal = fixture.Processor.StatusFor(status.SessionDirectory!);
        };
        await fixture.Processor.ImportAsync(source);
        Assert.IsAssignableFrom<IOException>(refusal);
        Assert.Equal("importing", ownerAfterRefusal?.Stage);
        Assert.True(ownerAfterRefusal?.IsBusy);
        Assert.DoesNotContain(events, status => !status.IsBusy);
    }

    [Fact]
    public void Unreadable_settings_preserve_auto_value_and_disable_saving() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((recordings, _) =>
        {
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(recordings, "runtime");
            runtime.SetAutoRecord(true);
            var config = File.ReadAllText(runtime.ConfigPath);
            typeof(VerbemoRuntime).GetField("problems", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(runtime,
                new[] { ConfigProblem.UnreadableFile("fixture") });
            var bar = new ActivityStatusBar(runtime, _ => { }, () => 0, _ => null);
            var toggle = Find<ClickCheckBox>(bar, "activity.auto");
            Assert.True(toggle.IsChecked);
            Assert.False(toggle.IsEnabled);
            Assert.Contains(Localized.T("Access: unknown", "Доступ: ?"), AutomationProperties.GetName(Find<Button>(bar, "activity.access")));
            var peer = UIElementAutomationPeer.CreatePeerForElement(toggle)!;
            Assert.Throws<ElementNotEnabledException>(() => ((IToggleProvider)peer.GetPattern(PatternInterface.Toggle)!).Toggle());
            Assert.Equal(config, File.ReadAllText(runtime.ConfigPath));
        }));

    [Fact]
    public void Application_keeps_bar_on_every_page_and_stops_timers_when_closed() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((recordings, _) =>
        {
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(recordings, "runtime");
            var status = new StatusWindow(runtime, embedded: true);
            var window = new ApplicationWindow(runtime, status);
            try
            {
                var bar = RecordingActionsTests.Field<ActivityStatusBar>(window, "activityBar");
                foreach (var page in Enum.GetValues<ApplicationDestination>())
                {
                    window.ShowDestination(page);
                    Assert.Equal(Visibility.Visible, bar.Visibility);
                    Assert.Equal(2, Grid.GetRow(bar));
                }
                Find<Button>(bar, "activity.access").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Assert.Equal(ApplicationDestination.General, window.Navigation.Destination);
                Assert.Contains(Descendants((DependencyObject)RecordingActionsTests.Field<ContentControl>(window, "host").Content),
                    child => child is Button button && Equals(button.Content, Localized.T("Open settings", "Открыть параметры")));
            }
            finally { window.AllowClose(); window.Close(); status.AllowClose(); status.Close(); }
            Assert.False(RecordingActionsTests.Field<System.Windows.Threading.DispatcherTimer>(window, "timer").IsEnabled);
            Assert.False(RecordingActionsTests.Field<System.Windows.Threading.DispatcherTimer>(window, "meterTimer").IsEnabled);
        }));

    private static T Find<T>(DependencyObject root, string id) where T : FrameworkElement =>
        Descendants(root).OfType<T>().Single(control => AutomationProperties.GetAutomationId(control) == id);

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            foreach (var descendant in Descendants(child)) yield return descendant;
    }
}
