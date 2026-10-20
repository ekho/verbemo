using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Verbemo.App;
using Verbemo.Core.Processing;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class InterfaceRegressionTests
{
    [Fact]
    public void Failed_naming_keeps_manual_finish_reachable() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window, root) =>
        {
            RecordingActionsTests.Select(window, Item(root) with { SpeakerNames = ProcessingStep.Failed }, null);
            var finish = RecordingActionsTests.Field<Button>(window, "finish");
            Assert.True(finish.IsEnabled);
            Assert.Contains(finish, Descendants((DependencyObject)window.Content));
            Assert.Equal(Visibility.Visible, finish.Visibility);
        }));

    [Theory]
    [InlineData(Key.Enter, false)]
    [InlineData(Key.Space, false)]
    [InlineData(Key.Enter, true)]
    public void Keyboard_opens_selected_meeting(Key key, bool active) => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window, root) =>
        {
            RecordingActionsTests.Select(window, Item(root) with { Transcript = active ? ProcessingStep.Recording : ProcessingStep.Done }, null);
            var requested = false;
            window.ActiveMeetingRequested += (_, _) => requested = true;
            var grid = RecordingActionsTests.Field<ListBox>(window, "grid");
            using var source = new HwndSource(new HwndSourceParameters { Width = 640, Height = 500 });
            grid.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, key) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
            if (active) Assert.True(requested);
            else Assert.True(RecordingActionsTests.Field<bool>(window, "detailOpen"));
        }));

    [Fact]
    public void Auto_summary_can_be_selected_after_an_explicit_backend() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window, _) =>
        {
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(window, "runtime");
            runtime.Update(s => { s.Summary.Enabled = true; s.Summary.Backend = "ollama"; });
            var form = new SetupForm(runtime);
            try
            {
                var cards = (Dictionary<string, RadioButton>)typeof(SetupForm).GetField("summaryCards", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(form)!;
                Assert.True(cards.ContainsKey("auto"));
                Assert.Contains(cards["auto"], Descendants(form.View));
                cards["auto"].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Assert.Equal("auto", runtime.Settings.Summary.Backend);
                RunAsync(async () => { await Dispatcher.Yield(DispatcherPriority.ApplicationIdle); Assert.True(cards["auto"].IsChecked); });
            }
            finally { form.Detach(); }
        }));

    [Fact]
    public void Embedded_live_document_has_a_finite_scroll_viewport() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window, _) =>
        {
            var status = new StatusWindow(RecordingActionsTests.Field<VerbemoRuntime>(window, "runtime"), embedded: true);
            try
            {
                var content = (FrameworkElement)status.Content;
                var text = Descendants(content).OfType<RichTextBox>().Single();
                ((FrameworkElement)text.Parent).Visibility = Visibility.Visible;
                for (var i = 0; i < 200; i++) text.Document.Blocks.Add(new Paragraph(new Run(new string('x', 100))));
                content.Measure(new Size(700, 500));
                content.Arrange(new Rect(0, 0, 700, 500));
                content.UpdateLayout();
                Assert.InRange(text.ActualHeight, 80, 500);
                Assert.True(text.ExtentHeight > text.ViewportHeight);
            }
            finally { status.AllowClose(); status.Close(); }
        }));

    [Fact]
    public void Model_failure_is_visible_and_previous_summary_survives() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window, _) => RunAsync(async () =>
        {
            await using var fixture = await SummaryRegenerationTests.Fixture.Create();
            fixture.Fail = true;
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(window, "runtime");
            runtime.Update(s => { s.Summary.Enabled = true; s.Summary.Backend = "ollama"; });
            var processing = typeof(VerbemoRuntime).GetField("processing", BindingFlags.Instance | BindingFlags.NonPublic)!;
            var original = processing.GetValue(runtime);
            processing.SetValue(runtime, fixture.Processor);
            try
            {
                var row = Activator.CreateInstance(typeof(RecordingsWindow).GetNestedType("Row", BindingFlags.NonPublic)!, Item(fixture.Directory), null)!;
                var grid = RecordingActionsTests.Field<ListBox>(window, "grid");
                grid.ItemsSource = new[] { row };
                grid.SelectedItem = row;
                await (Task)typeof(RecordingsWindow).GetMethod("ShowSelectedAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, null)!;
                await (Task)typeof(RecordingsWindow).GetMethod("PerformAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, new object[] { MeetingAction.RegenerateSummary })!;
                Assert.NotEmpty(RecordingActionsTests.Field<TextBlock>(window, "problem").Text);
                Assert.Equal("Old summary", File.ReadAllText(Path.Combine(fixture.Directory, "summary.md")));
                Assert.Equal(1, fixture.Calls);
            }
            finally { processing.SetValue(runtime, original); }
        })));

    private static SessionListItem Item(string root) => new(root, "Test", DateTimeOffset.Now, 1, "manual", "whisper",
        ProcessingStep.Done, ProcessingStep.Done, ProcessingStep.Done, 0, true);

    [Fact]
    public void Undo_stays_outside_compact_panels_and_disappears_after_undo() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window, root) => RunAsync(async () =>
        {
            Assert.IsType<DockPanel>(window.Content);
            var runtime = RecordingActionsTests.Field<VerbemoRuntime>(window, "runtime");
            var directory = Path.Combine(root,"recordings","only-meeting");
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory,"meta.json"),"{\"title\":\"Only meeting\"}");
            RecordingActionsTests.Select(window,Item(directory),null);
            var state = typeof(RecordingsWindow).GetField("detailOpen",BindingFlags.Instance|BindingFlags.NonPublic)!;
            state.SetValue(window,true);
            typeof(RecordingsWindow).GetMethod("ScheduleDeletion",BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(window,new object[] { directory });
            try
            {
                await (Task)typeof(RecordingsWindow).GetMethod("ReloadAsync",BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(window,null)!;
                var notices = RecordingActionsTests.Field<StackPanel>(window,"deletionNotices");
                var button = Assert.Single(notices.Children.OfType<Button>());
                var list = RecordingActionsTests.Field<DockPanel>(window,"listPanel");
                Assert.DoesNotContain(button,Descendants(list));
                Assert.False(RecordingActionsTests.Field<bool>(window,"detailOpen"));
                Assert.Equal(Visibility.Visible,list.Visibility);
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                Assert.Empty(notices.Children);
                Assert.True(Directory.Exists(directory));
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (RecordingActionsTests.Field<bool>(window,"loading") && DateTime.UtcNow < deadline) await Task.Delay(10);
                Assert.False(RecordingActionsTests.Field<bool>(window,"loading"));
            }
            finally { runtime.Deletions.Undo(directory); }
        })));

    internal static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>())
        { yield return child; foreach (var descendant in Descendants(child)) yield return descendant; }
    }

    internal static void RunAsync(Func<Task> action)
    {
        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var frame = new DispatcherFrame();
        Exception? error = null;
        async void Run() { try { await action(); } catch (Exception failure) { error = failure; } finally { frame.Continue = false; } }
        Run();
        if (frame.Continue) Dispatcher.PushFrame(frame);
        SynchronizationContext.SetSynchronizationContext(previous);
        if (error is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error).Throw();
    }
}
