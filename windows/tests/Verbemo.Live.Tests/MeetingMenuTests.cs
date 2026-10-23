using System.Windows.Controls;
using Verbemo.App;
using Verbemo.Core.Processing;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class MeetingMenuTests
{
    [Fact]
    public void Detail_has_summary_first_and_no_summary_action_for_unfinished_transcript() => ApplicationWindowTests.OnSta(() =>
        RecordingActionsTests.WithWindow((window,root) =>
        {
            var tabs = RecordingActionsTests.Field<TabControl>(window,"tabs");
            Assert.Equal(new[] { Verbemo.Core.Localization.Localized.T("Summary", "Сводка"), Verbemo.Core.Localization.Localized.T("Transcript", "Расшифровка"),
                Verbemo.Core.Localization.Localized.T("Participants", "Участники") },tabs.Items.Cast<TabItem>().Select(tab => tab.Header));
            RecordingActionsTests.Select(window,new(root,"Pending",DateTimeOffset.Now,1,"manual","whisper",ProcessingStep.Pending,
                ProcessingStep.Pending,ProcessingStep.Pending,0,true),null);
            Assert.False(RecordingActionsTests.Field<Button>(window,"regenerate").IsEnabled);
        }));

    [Fact]
    public void Playback_includes_system_only_track_and_ignores_unrelated_executables()
    {
        var root = Path.Combine(Path.GetTempPath(),"verbemo-playback",Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllBytes(Path.Combine(root,"system.wav"),[1]);
            File.WriteAllBytes(Path.Combine(root,"source.exe"),[1]);
            Assert.Equal(new[] { Path.Combine(root,"system.wav") },RecordingsWindow.AudioFiles(root));
        }
        finally { Directory.Delete(root,true); }
    }
    [Fact]
    public void One_factory_orders_both_menus_and_disables_summary_until_ready() => ApplicationWindowTests.OnSta(() =>
    {
        var state = new MeetingActionState(false, false, true, false, false, true, true, true);
        var menu = MeetingActionsMenu.Create(state, _ => { });
        var items = menu.Items.OfType<MenuItem>().ToArray();
        Assert.Equal(Enum.GetValues<MeetingAction>(), items.Select(i => (MeetingAction)i.Tag));
        Assert.False(items.Single(i => (MeetingAction)i.Tag == MeetingAction.RegenerateSummary).IsEnabled);
        Assert.False(items.Single(i => (MeetingAction)i.Tag == MeetingAction.CopySummary).IsEnabled);
        Assert.IsType<Separator>(menu.Items[menu.Items.Count - 2]);
    });
}
