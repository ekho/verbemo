using System.Windows.Controls;
using Verbemo.App;
using Verbemo.Core.Processing;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class MeetingMenuTests
{
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
