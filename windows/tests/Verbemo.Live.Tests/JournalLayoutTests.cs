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
            Assert.Single(runtime.LoadSessionsAsync().GetAwaiter().GetResult());
            var status = new StatusWindow(runtime, embedded: true);
            var window = new ApplicationWindow(runtime, status);
            try
            {
                window.ShowDestination(ApplicationDestination.General);
                window.Show();
                var frame = new System.Windows.Threading.DispatcherFrame();
                var tick = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
                tick.Tick += (_, _) => { tick.Stop(); frame.Continue = false; };
                tick.Start();
                System.Windows.Threading.Dispatcher.PushFrame(frame);
                var library = RecordingActionsTests.Field<RecordingsWindow>(window, "recordings");
                Assert.Single(RecordingActionsTests.Field<ListBox>(library, "grid").Items.Cast<object>());
            }
            finally { window.AllowClose(); window.Close(); status.AllowClose(); status.Close(); }
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
    public void Participants_are_in_inspector_and_list_survives_narrow_layout() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window, root) =>
        {
            RecordingActionsTests.Select(window, new(root, "Meeting", DateTimeOffset.Now, 120, "manual", "whisper",
                ProcessingStep.Done, ProcessingStep.Done, ProcessingStep.Done, 0, false), null);
            var content = (FrameworkElement)window.Content;
            content.Measure(new Size(850, 600));
            content.Arrange(new Rect(0, 0, 850, 600));
            content.UpdateLayout();
            Assert.Equal(2, RecordingActionsTests.Field<TabControl>(window, "tabs").Items.Count);
            Assert.Equal(Visibility.Visible, RecordingActionsTests.Field<DockPanel>(window, "listPanel").Visibility);
            Assert.Equal(Visibility.Visible, RecordingActionsTests.Field<Grid>(window, "detail").Visibility);
            Assert.Contains(RecordingActionsTests.Field<StackPanel>(window, "speakers"), Descendants(content));
        }));

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            foreach (var descendant in Descendants(child)) yield return descendant;
    }
}
