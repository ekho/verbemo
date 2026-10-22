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
        var body = new StackPanel { Margin = new Thickness(0, 8, 0, 18) };
        body.Children.Add(Ui.Heading(T("CALENDAR", "КАЛЕНДАРЬ")));
        body.Children.Add(calendar.EventUrl is { } url ? Ui.Link(calendar.Title, url.AbsoluteUri) : Ui.Heading(calendar.Title));
        if(calendar.CalendarTitle is { } name) body.Children.Add(Ui.Detail(name));
        if (calendar.Agenda is { Length: > 0 } agenda)
        {
            var preview = agenda.Length <= 100 ? agenda : agenda[..100];
            if (agenda.Length > 100 && preview.LastIndexOf(' ') is > 0 and var boundary) preview = preview[..boundary];
            var text = Ui.Detail(preview + (agenda.Length > 100 ? "…" : ""));
            body.Children.Add(text);
            if (agenda.Length > 100)
            {
                var expanded = false;
                Button? more = null;
                more = Ui.Button(T("Show in full", "Показать полностью"), () =>
                {
                    expanded = !expanded; text.Text = expanded ? agenda : preview + "…";
                    more!.Content = expanded ? T("Collapse", "Свернуть") : T("Show in full", "Показать полностью");
                });
                body.Children.Add(more);
            }
        }
        var people = Ui.Detail(T("Invited: ", "Приглашены: ") + string.Join(", ", calendar.Participants.Take(4).Select(p => p.Name)));
        body.Children.Add(people);
        if (calendar.Participants.Count > 4)
        {
            var expanded = false;
            Button? more = null;
            more = Ui.Button(T("Show all", "Показать всех"), () =>
            {
                expanded = !expanded;
                people.Text = T("Invited: ", "Приглашены: ") + string.Join(", ", calendar.Participants.Take(expanded ? calendar.Participants.Count : 4).Select(p => p.Name));
                more!.Content = expanded ? T("Collapse", "Свернуть") : T("Show all", "Показать всех");
            });
            body.Children.Add(more);
        }
        return body;
    }
}
