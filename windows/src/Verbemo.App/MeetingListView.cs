using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;
using Verbemo.Core.Processing;
using static Verbemo.Core.Localization.Localized;
using HorizontalAlignment = System.Windows.HorizontalAlignment;

namespace Verbemo.App;

internal static class MeetingListView
{
    public static FrameworkElement Card(SessionListItem item, ProcessingStatus? status)
    {
        var stack = new StackPanel();
        var title = Ui.Heading(item.Title);
        title.Margin = new Thickness(0, 0, 0, 5);
        stack.Children.Add(title);
        stack.Children.Add(Ui.Detail(MeetingPresentation.Date(item) + $" · {Math.Max(1, item.DurationSeconds / 60)} {T("min", "мин")}"));
        var stages = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0,10,0,0) };
        var recording = item.Transcript == ProcessingStep.Recording;
        stages.Children.Add(Stage("\uE720", recording ? T("Recording", "Идёт запись") : T("Recording saved", "Запись сохранена"),
            recording ? ProcessingStep.Recording : ProcessingStep.Done, recording, false));
        stages.Children.Add(Stage("\uE8A5", T("Transcript: ", "Расшифровка: ") + (status?.Stage == "transcribing" ? status.Message : item.Transcript.ToString()),
            item.Transcript, status is { Stage: "transcribing", IsBusy: true }, item.SpeakerCount > 1));
        stages.Children.Add(Stage("\uE9D5", MeetingPresentation.SummaryLabel(item.Summary), item.Summary,
            status is { Stage: "summary", IsBusy: true }, false));
        stack.Children.Add(stages);
        return stack;
    }

    internal static FrameworkElement Stage(string glyph, string label, ProcessingStep state, bool active, bool diarization)
    {
        var panel = new Grid { Width = 25, Height = 23, Margin = new Thickness(0,0,5,0), ToolTip = label };
        var icon = Ui.Symbol(glyph);
        icon.Width = 22;
        icon.FontSize = 14;
        icon.VerticalAlignment = VerticalAlignment.Center;
        panel.Children.Add(icon);
        if (state == ProcessingStep.Off) panel.Opacity = 0.35;
        if (state is ProcessingStep.Failed or ProcessingStep.Deferred)
            panel.Children.Add(new TextBlock { Text = "!", FontSize = 9, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom }.Brush(TextBlock.ForegroundProperty, Ui.Caution));
        else if (state == ProcessingStep.Done)
            panel.Children.Add(new TextBlock { Text = "✓", FontSize = 8, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom }.Brush(TextBlock.ForegroundProperty, Ui.Good));
        if (diarization)
        {
            var people = Ui.Symbol("\uE716");
            people.Width = 10;
            people.FontSize = 8;
            people.HorizontalAlignment = HorizontalAlignment.Left;
            people.VerticalAlignment = VerticalAlignment.Bottom;
            panel.Children.Add(people);
        }
        if (active && SystemParameters.ClientAreaAnimation)
            icon.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1, 0.3, TimeSpan.FromSeconds(0.9)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
        System.Windows.Automation.AutomationProperties.SetName(panel, label);
        return panel;
    }
}
