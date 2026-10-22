using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using Verbemo.App;
using Verbemo.Core.Sessions;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class MeetingCalendarViewTests
{
    [Fact]
    public void Html_agenda_renders_text_emphasis_and_links_without_counting_tags() => OnSta(() =>
    {
        var view = Create("<p><b>План</b> &amp; <i>цели</i><br><a href=\"https://example.test/agenda\">Документ</a></p><ul><li>Обсуждение</li></ul>");
        var text = Agenda(view);
        Assert.Contains("План & цели\nДокумент", VisibleText(text));
        Assert.Contains("Обсуждение", VisibleText(text));
        Assert.DoesNotContain("<", VisibleText(text));
        Assert.Empty(view.Children.OfType<Button>());
        Assert.Contains(text.Inlines.OfType<Run>(), run => run.Text == "План" && run.FontWeight == FontWeights.Bold);
        Assert.Equal("https://example.test/agenda", Assert.Single(text.Inlines.OfType<Hyperlink>()).NavigateUri.AbsoluteUri);
    });

    [Fact]
    public void Long_html_expands_and_collapses_without_losing_formatting() => OnSta(() =>
    {
        var notes = string.Join(" ", Enumerable.Repeat("Тема 👩🏽‍💻 встречи", 12));
        var view = Create("<b>" + notes + "</b>");
        var text = Agenda(view);
        var preview = VisibleText(text);
        Assert.DoesNotContain("<", preview);
        var button = Assert.Single(view.Children.OfType<Button>());
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(notes, VisibleText(text));
        Assert.Equal(FontWeights.Bold, Assert.IsType<Run>(text.Inlines.FirstInline).FontWeight);
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(preview, VisibleText(text));
    });

    [Fact]
    public void Plain_text_keeps_literal_characters_and_newlines() => OnSta(() =>
    {
        const string notes = "План: 2 < 3 & 5 > 4\n**буквально** <person@example.test>";
        Assert.Equal(notes, VisibleText(Agenda(Create(notes))));
    });

    [Fact]
    public void Broken_html_keeps_text_without_active_content_or_unsafe_links() => OnSta(() =>
    {
        var text = Agenda(Create("<p>Текст<script>hidden()</script><img src='https://example.test/pixel'><iframe>hidden</iframe><a href='file:///private'>Файл</a><a href='javascript:alert(1)'>Скрипт</a><b>Незакрытый &nbsp; &#128512;"));
        Assert.Contains("Текст", VisibleText(text));
        Assert.Contains("Незакрытый", VisibleText(text));
        Assert.Contains("😀", VisibleText(text));
        Assert.DoesNotContain("hidden", VisibleText(text));
        Assert.Empty(text.Inlines.OfType<Hyperlink>());
        Assert.All(text.Inlines, inline => Assert.IsType<Run>(inline));
    });

    private static string VisibleText(TextBlock field) => new TextRange(field.ContentStart, field.ContentEnd).Text;
    private static StackPanel Create(string agenda) => Assert.IsType<StackPanel>(MeetingCalendarView.Create(
        new MeetingCalendarMetadata("event", "confirmed", "Planning", null, null, agenda, [])));
    private static TextBlock Agenda(StackPanel view) => view.Children.OfType<TextBlock>().ElementAt(2);
    private static void OnSta(Action check)
    {
        Exception? failure = null;
        var thread = new Thread(() => { try { check(); } catch (Exception error) { failure = error; } });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "Calendar UI check did not finish.");
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
