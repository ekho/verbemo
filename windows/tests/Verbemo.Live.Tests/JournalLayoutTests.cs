using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Verbemo.App;
using Verbemo.Core.Processing;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class JournalLayoutTests
{
    [Fact]
    public void Opening_workspace_loads_existing_meetings() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((recordings, root) =>
        {
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(recordings, "runtime");
            var meeting = Path.Combine(runtime.Settings.RecordingsDirectory, "meeting");
            Directory.CreateDirectory(meeting);
            File.WriteAllText(Path.Combine(meeting, "meta.json"), "{\"title\":\"Journal fixture\",\"duration_seconds\":12}");
            using (var wav = new NAudio.Wave.WaveFileWriter(Path.Combine(meeting, "mic.wav"), new NAudio.Wave.WaveFormat(16000, 16, 1)))
                wav.Write(new byte[32000], 0, 32000);
            Assert.Single(runtime.LoadSessionsAsync().GetAwaiter().GetResult());
            var status = new StatusWindow(runtime, embedded: true);
            var window = new ApplicationWindow(runtime, status);
            var library = RecordingActionsTests.Field<RecordingsWindow>(window, "recordings");
            try
            {
                window.ShowDestination(ApplicationDestination.General);
                window.Show();
                ApplicationWindowTests.Until(() => !RecordingActionsTests.Field<bool>(library, "loading")
                    && RecordingActionsTests.Field<ListBox>(library, "grid").Items.Count == 1);
                Assert.Single(RecordingActionsTests.Field<ListBox>(library, "grid").Items.Cast<object>());
                var player = RecordingActionsTests.Field<MeetingPlayer>(library, "player");
                var clock = RecordingActionsTests.Field<System.Windows.Media.Animation.ClockGroup>(player, "clock");
                typeof(RecordingsWindow).GetMethod("ApplyFilter", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(library, null);
                Assert.Same(clock, RecordingActionsTests.Field<System.Windows.Media.Animation.ClockGroup>(player, "clock"));
            }
            finally
            {
                window.AllowClose(); window.Close(); status.AllowClose(); status.Close();
                ApplicationWindowTests.Until(() => !RecordingActionsTests.Field<bool>(library, "loading"));
                typeof(RecordingsWindow).GetMethod("ReloadAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(library, null);
                Assert.Null(RecordingActionsTests.Field<System.Windows.Media.Animation.ClockGroup?>(
                    RecordingActionsTests.Field<MeetingPlayer>(library, "player"), "clock"));
            }
        }));

    [Fact]
    public void Meeting_list_remains_visible_on_settings_and_live_pages() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((recordings, _) =>
        {
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(recordings, "runtime");
            var status = new StatusWindow(runtime, embedded: true);
            var window = new ApplicationWindow(runtime, status);
            try
            {
                window.ShowDestination(ApplicationDestination.Attention);
                var filters = RecordingActionsTests.Field<ComboBox>(window, "filters");
                Assert.Equal(ApplicationDestination.Attention, ((ComboBoxItem)filters.SelectedItem).Tag);
                window.ShowAllMeetings();
                Assert.Equal(ApplicationDestination.AllMeetings, ((ComboBoxItem)filters.SelectedItem).Tag);
                foreach (var destination in new[] { ApplicationDestination.General, ApplicationDestination.Live, ApplicationDestination.About })
                {
                    window.ShowDestination(destination);
                    Assert.Contains(Descendants((DependencyObject)window.Content), child => child is ListBox);
                }
            }
            finally { window.AllowClose(); window.Close(); status.AllowClose(); status.Close(); }
        }));

    [Fact]
    public void Participants_have_their_own_tab_and_list_survives_narrow_layout() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window, root) =>
        {
            RecordingActionsTests.Select(window, new(root, "Meeting", DateTimeOffset.Now, 120, "manual", "whisper",
                ProcessingStep.Done, ProcessingStep.Done, ProcessingStep.Done, 0, false), null);
            var content = (FrameworkElement)window.Content;
            content.Measure(new Size(850, 600));
            content.Arrange(new Rect(0, 0, 850, 600));
            content.UpdateLayout();
            var tabs = RecordingActionsTests.Field<TabControl>(window, "tabs");
            Assert.Equal(3, tabs.Items.Count);
            Assert.Contains(RecordingActionsTests.Field<StackPanel>(window, "speakers"),
                Descendants((DependencyObject)((TabItem)tabs.Items[2]).Content));
            Assert.DoesNotContain(RecordingActionsTests.Field<StackPanel>(window, "speakers"),
                Descendants(RecordingActionsTests.Field<Border>(window, "inspector")));
            Assert.Equal(Visibility.Visible, RecordingActionsTests.Field<DockPanel>(window, "listPanel").Visibility);
            Assert.Equal(Visibility.Visible, RecordingActionsTests.Field<Grid>(window, "detail").Visibility);
            Assert.Contains(RecordingActionsTests.Field<StackPanel>(window, "speakers"), Descendants(content));
        }));

    [Fact]
    public void Participant_name_can_be_typed_without_calendar_or_a_separate_edit_click() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window, root) =>
        {
            File.WriteAllText(Path.Combine(root, "meta.json"), "{\"title\":\"Test\"}");
            TranscriptWriter.WriteAsync(root, "Test", new("whisper", "tiny", DateTimeOffset.UtcNow,
                [new(2000, 3000, "Sample", "A"), new(4000, 5000, "Later", "A"), new(6000, 7000, "Unknown", "?")])).GetAwaiter().GetResult();
            var show = (Task)typeof(RecordingsWindow).GetMethod("ShowSpeakersAsync", BindingFlags.Instance | BindingFlags.NonPublic)!
                .Invoke(window, [root, "Test", RecordingActionsTests.Field<int>(window, "transcriptShown")])!;
            ApplicationWindowTests.Until(() => show.IsCompleted);
            show.GetAwaiter().GetResult();
            var combo = Assert.Single(Descendants(RecordingActionsTests.Field<StackPanel>(window, "speakers")).OfType<ComboBox>());
            Assert.True(combo.IsEditable);
            combo.Text = "Manual Name";
            combo.RaiseEvent(new System.Windows.Input.KeyboardFocusChangedEventArgs(System.Windows.Input.Keyboard.PrimaryDevice,
                Environment.TickCount, combo, null) { RoutedEvent = UIElement.LostKeyboardFocusEvent });
            ApplicationWindowTests.Until(() => File.ReadAllText(Path.Combine(root, "transcript.md")).Contains("Manual Name"));
            Assert.Equal("Manual Name", SpeakerFile.ReadAsync(root, default).GetAwaiter().GetResult().Names["A"]);
        }));

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            foreach (var descendant in Descendants(child)) yield return descendant;
    }

}
