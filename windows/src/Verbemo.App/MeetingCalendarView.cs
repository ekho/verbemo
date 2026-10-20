using System.Windows;
using System.Windows.Controls;
using Verbemo.Core.Sessions;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App;

internal static class MeetingCalendarView
{
    public static FrameworkElement? Create(MeetingCalendarMetadata? calendar)
    {
        if(calendar?.IsConfirmed != true) return null;
        var body = new StackPanel { Margin = new Thickness(14) };
        body.Children.Add(Ui.Detail(T("Linked calendar event", "Связано с календарём")));
        body.Children.Add(Ui.Heading(calendar.Title));
        if(calendar.CalendarTitle is { } name) body.Children.Add(Ui.Detail(name));
        if(calendar.EventUrl is { } url) body.Children.Add(Ui.Link(T("Open in calendar", "Открыть в календаре"),url.AbsoluteUri));
        else body.Children.Add(Ui.Detail(T("The saved event has no supported calendar link.", "У сохранённого события нет доступной ссылки на календарь.")));
        if(calendar.Agenda is { } agenda) body.Children.Add(new Expander { Header = T("Meeting agenda", "Повестка встречи"), Content = Ui.Detail(agenda), Margin = new Thickness(0,10,0,0) });
        body.Children.Add(Ui.Detail(T("Invited: ", "Приглашены: ")+string.Join(", ",calendar.Participants.Select(p => p.Name))));
        return Ui.Box(body);
    }
}
