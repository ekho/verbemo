using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using Verbemo.App;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class EmailAddressesEditorTests
{
    [Fact]
    public void Adds_removes_and_keeps_invalid_or_unsaved_drafts() => ApplicationWindowTests.OnSta(() =>
    {
        List<string> saved = ["old@example.test"];
        var editor = new EmailAddressesEditor { Save = addresses => { saved = addresses; return true; } };
        editor.Show(saved);
        var input = Descendants(editor).OfType<TextBox>().Single();
        var add = Descendants(editor).OfType<Button>().Single(button => AutomationProperties.GetAutomationId(button) == "user_email.add");
        input.Text = "NEW@example.test; old@example.test";
        add.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(new[] { "old@example.test", "new@example.test" }, saved);
        Assert.Empty(input.Text);
        input.Text = "not an email";
        add.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(2, saved.Count);
        Assert.Equal("not an email", input.Text);
        var remove = Descendants(editor).OfType<Button>().First(button => AutomationProperties.GetAutomationId(button) == "user_email.remove");
        remove.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(new[] { "new@example.test" }, saved);
        editor.Save = _ => false;
        input.Text = "unsaved@example.test";
        add.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(new[] { "new@example.test" }, saved);
        Assert.Equal("unsaved@example.test", input.Text);
    });

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
