using System.Windows.Controls;
using Verbemo.Core.Processing;
using static Verbemo.Core.Localization.Localized;
using ContextMenu = System.Windows.Controls.ContextMenu;
using MenuItem = System.Windows.Controls.MenuItem;

namespace Verbemo.App;

internal static class MeetingActionsMenu
{
    public static ContextMenu Create(MeetingActionState state, Action<MeetingAction> perform)
    {
        var menu = new ContextMenu();
        foreach (var action in Enum.GetValues<MeetingAction>())
        {
            if (action == MeetingAction.Delete) menu.Items.Add(new Separator());
            var reason = state.Reason(action);
            var item = new MenuItem { Tag = action, Header = Label(action), IsEnabled = reason is null, ToolTip = reason };
            ToolTipService.SetShowOnDisabled(item, true);
            item.Click += (_, _) => perform(action);
            menu.Items.Add(item);
        }
        return menu;
    }
    private static string Label(MeetingAction action) => action switch
    {
        MeetingAction.Rename => T("Rename", "Переименовать"),
        MeetingAction.CopyTranscript => T("Copy transcript", "Копировать расшифровку"),
        MeetingAction.Retranscribe => T("Transcribe again", "Расшифровать повторно"),
        MeetingAction.CopySummary => T("Copy summary", "Копировать сводку"),
        MeetingAction.RegenerateSummary => T("Regenerate summary", "Перегенерировать сводку"),
        MeetingAction.OpenFolder => T("Open folder in Explorer", "Открыть папку в Проводнике"),
        _ => T("Delete", "Удалить"),
    };
}
