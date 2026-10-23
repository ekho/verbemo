using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Verbemo.Core.Sessions;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App;

internal sealed class SpeakerIdentityEditor : ContentControl
{
    private sealed record Choice(string Text, CalendarParticipant? Participant)
    {
        public override string ToString() => Text;
    }

    public SpeakerIdentityEditor(string speaker, string name, string? participantId, IReadOnlyList<CalendarParticipant> participants,
        bool compact, bool enabled, Func<bool> isCurrent, Func<CalendarParticipant?, string?, Task<(string Name, string? ParticipantId)>> save, Action<Exception> showError)
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        var combo = new ComboBox { IsEditable = true, IsTextSearchEnabled = false, MinWidth = compact ? 0 : 220,
            HorizontalAlignment = compact ? HorizontalAlignment.Stretch : HorizontalAlignment.Left, IsEnabled = enabled };
        var choices = participants.Select(person => new Choice(person.Name + " · "
            + (string.IsNullOrWhiteSpace(person.Email) ? person.Id : person.Email)
            + (!string.IsNullOrWhiteSpace(person.Email) && participants.Count(other => other.Name == person.Name
                && string.Equals(other.Email?.Trim(), person.Email?.Trim(), StringComparison.OrdinalIgnoreCase)) > 1 ? " · " + person.Id : ""), person)).ToArray();
        if (participants.Count > 0 || participantId is not null) combo.Items.Add(new Choice(T("Not linked", "Без связи"), null));
        foreach (var choice in choices) combo.Items.Add(choice);
        combo.SelectedItem = choices.FirstOrDefault(choice => choice.Participant!.Id == participantId);
        combo.Text = name;
        var storedText = name;
        var saving = false;
        var cancelling = false;
        System.Windows.Automation.AutomationProperties.SetName(combo, T("Who is speaking? ", "Кто говорит? ") + speaker);
        combo.ToolTip = T("Choose a participant or type a name. Enter or leaving the field saves; Escape cancels.",
            "Выберите участника или введите имя. Enter или выход из поля сохраняет, Escape отменяет.");

        void ShowCompact()
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var label = Ui.Status(string.IsNullOrEmpty(name) ? speaker : name);
            label.VerticalAlignment = VerticalAlignment.Center;
            label.TextWrapping = TextWrapping.NoWrap;
            label.TextTrimming = TextTrimming.CharacterEllipsis;
            label.ToolTip = label.Text;
            row.Children.Add(label);
            var action = T("Match or rename speaker", "Сопоставить участника или изменить имя");
            var button = JournalStyle.IconButton("\uE71B", action, () =>
            {
                Content = combo;
                combo.Focus();
                combo.IsDropDownOpen = true;
            });
            button.Cursor = Cursors.Hand;
            button.IsEnabled = enabled;
            button.MinWidth = 24;
            button.Padding = new Thickness(2);
            button.Margin = new Thickness(4, 0, 0, 0);
            button.ToolTip = (participantId is null ? T("Not linked. ", "Нет связи. ") : T("Linked to a calendar participant. ", "Связан с участником календаря. ")) + action + ": " + speaker;
            System.Windows.Automation.AutomationProperties.SetName(button, (string)button.ToolTip);
            if (participantId is null && button.Content is TextBlock icon)
            {
                var red = SystemParameters.HighContrast ? SystemColors.WindowTextBrush : System.Windows.Media.Brushes.Firebrick;
                icon.Foreground = red;
                button.Content = null;
                var broken = new Grid { Width = 20, Height = 20 };
                broken.Children.Add(icon);
                broken.Children.Add(new System.Windows.Shapes.Line { X1 = 2, Y1 = 18, X2 = 18, Y2 = 2,
                    Stroke = red, StrokeThickness = 2, IsHitTestVisible = false });
                button.Content = broken;
            }
            Grid.SetColumn(button, 1);
            row.Children.Add(button);
            Content = row;
        }

        async Task CommitAsync(CalendarParticipant? participant, string? manual)
        {
            if (saving || cancelling || !isCurrent()) return;
            if (manual is not null && manual.Trim() == storedText) { if (compact) ShowCompact(); return; }
            saving = true;
            try
            {
                var identity = await save(participant, manual?.Trim());
                participantId = identity.ParticipantId;
                name = identity.Name;
                storedText = manual is null ? (combo.SelectedItem as Choice)?.Text ?? "" : manual.Trim();
                if (compact && isCurrent()) ShowCompact();
            }
            catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException)
            {
                cancelling = true;
                combo.SelectedItem = choices.FirstOrDefault(choice => choice.Participant!.Id == participantId);
                combo.Text = storedText;
                cancelling = false;
                showError(error);
            }
            finally { saving = false; }
        }

        combo.SelectionChanged += async (_, _) =>
        {
            if (combo.SelectedItem is Choice choice) await CommitAsync(choice.Participant, null);
        };
        combo.LostKeyboardFocus += async (_, _) =>
        {
            if (!combo.IsKeyboardFocusWithin && !combo.IsDropDownOpen) await CommitAsync(null, combo.Text);
        };
        combo.PreviewKeyDown += async (_, args) =>
        {
            if (args.Key == Key.Escape)
            {
                cancelling = true;
                combo.Text = storedText;
                combo.IsDropDownOpen = false;
                if (compact) ShowCompact();
                cancelling = false;
                args.Handled = true;
            }
            else if (args.Key == Key.Enter)
            {
                combo.IsDropDownOpen = false;
                await CommitAsync(null, combo.Text);
                args.Handled = true;
            }
        };
        if (compact) ShowCompact();
        else Content = combo;
    }
}
