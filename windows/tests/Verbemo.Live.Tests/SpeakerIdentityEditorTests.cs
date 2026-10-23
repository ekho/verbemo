using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Verbemo.App;
using Verbemo.Core.Sessions;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class SpeakerIdentityEditorTests
{
    [Fact]
    public void Long_compact_name_keeps_edit_action_visible_and_unlinked_icon_is_crossed() => ApplicationWindowTests.OnSta(() =>
    {
        var editor = new SpeakerIdentityEditor("A", new string('W', 200), null, [], true, true, () => true,
            (_, name) => Task.FromResult((name ?? "", (string?)null)), error => throw error);
        var host = new Grid { Width = 240 };
        host.Children.Add(editor);
        host.Measure(new Size(240, 100));
        host.Arrange(new Rect(0, 0, 240, 100));
        host.UpdateLayout();
        var row = Assert.IsType<Grid>(editor.Content);
        var button = Assert.Single(row.Children.OfType<Button>());
        Assert.InRange(button.TranslatePoint(new Point(button.ActualWidth, 0), host).X, 1d, 240d);
        Assert.Single(Assert.IsType<Grid>(button.Content).Children.OfType<System.Windows.Shapes.Line>());
    });

    [Fact]
    public void Duplicate_names_select_by_identity_and_focus_loss_does_not_save_a_second_manual_name() => ApplicationWindowTests.OnSta(() =>
    {
        var writes = new List<(CalendarParticipant? Person, string? Name)>();
        var editor = new SpeakerIdentityEditor("A", "Manual", null, [new("a", "Alex"), new("b", "Alex")], false, true,
            () => true, (person, name) => { writes.Add((person, name)); return Task.FromResult((person?.Name ?? name ?? "", person?.Id)); }, error => throw error);
        var combo = Assert.IsType<ComboBox>(editor.Content);
        Assert.NotEqual(combo.Items[1].ToString(), combo.Items[2].ToString());
        combo.SelectedItem = combo.Items[2];
        Leave(combo);
        var saved = Assert.Single(writes);
        Assert.Equal("b", saved.Person?.Id);
        Assert.Null(saved.Name);
    });

    [Fact]
    public void Escape_cancels_free_text_and_stale_editor_cannot_write() => ApplicationWindowTests.OnSta(() =>
    {
        var writes = new List<string?>();
        var current = true;
        var editor = new SpeakerIdentityEditor("A", "Original", null, [], false, true, () => current,
            (_, name) => { writes.Add(name); return Task.FromResult((name ?? "", (string?)null)); }, error => throw error);
        var combo = Assert.IsType<ComboBox>(editor.Content);
        combo.Text = "Cancelled";
        using var source = new System.Windows.Interop.HwndSource(new System.Windows.Interop.HwndSourceParameters { Width = 400, Height = 200 });
        combo.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source,
            Environment.TickCount, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
        Leave(combo);
        Assert.Equal("Original", combo.Text);
        Assert.Empty(writes);
        current = false;
        combo.Text = "Stale";
        Leave(combo);
        Assert.Empty(writes);
    });

    private static void Leave(ComboBox combo) => combo.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice,
        Environment.TickCount, combo, null) { RoutedEvent = UIElement.LostKeyboardFocusEvent });
}
