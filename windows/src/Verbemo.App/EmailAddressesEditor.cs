using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using Verbemo.Core.Configuration;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App;

internal sealed class EmailAddressesEditor : StackPanel
{
    private readonly StackPanel list = new();
    private readonly TextBox input;
    private readonly TextBlock message = Ui.Detail("");
    private List<string> addresses = [];
    public Func<List<string>, bool>? Save { get; set; }

    public EmailAddressesEditor()
    {
        MaxWidth = 520;
        Children.Add(list);
        var (field, box) = Ui.Field(T("Add email", "Добавить email"));
        input = box;
        AutomationProperties.SetAutomationId(input, "user_email.input");
        AutomationProperties.SetName(input, T("Add email", "Добавить email"));
        var row = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(field);
        var add = new Button { Content = T("Add", "Добавить"), Margin = new Thickness(8, 0, 0, 0) };
        AutomationProperties.SetAutomationId(add, "user_email.add");
        Grid.SetColumn(add, 1);
        row.Children.Add(add);
        add.Click += (_, _) => Add();
        input.KeyDown += (_, args) => { if (args.Key == Key.Enter) { Add(); args.Handled = true; } };
        Children.Add(row);
        message.Visibility = Visibility.Collapsed;
        message.Margin = new Thickness(0, 6, 0, 0);
        Children.Add(message);
    }

    public void Show(IEnumerable<string> emails)
    {
        var updated = EmailAddresses.Normalize(emails);
        if (addresses.SequenceEqual(updated)) return;
        addresses = updated;
        list.Children.Clear();
        foreach (var address in addresses)
        {
            var row = new Grid { Margin = new Thickness(0, 0, 0, 6) };
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = address, TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center, ToolTip = address });
            var remove = new Button { Content = "×", ToolTip = T("Remove ", "Удалить ") + address,
                Margin = new Thickness(8, 0, 0, 0), MinWidth = 28 };
            AutomationProperties.SetName(remove, T("Remove ", "Удалить ") + address);
            AutomationProperties.SetAutomationId(remove, "user_email.remove");
            Grid.SetColumn(remove, 1);
            remove.Click += (_, _) => { if (Commit(addresses.Where(value => value != address).ToList())) input.Focus(); };
            row.Children.Add(remove);
            list.Children.Add(row);
        }
    }

    private void Add()
    {
        var added = EmailAddresses.Parse(input.Text);
        if (added is null || added.Count == 0)
        {
            message.Text = T("Enter an email address, such as name@example.com.", "Введите email, например name@example.com.");
            message.Visibility = Visibility.Visible;
            return;
        }
        if (Commit(EmailAddresses.Normalize(addresses.Concat(added)))) { input.Clear(); input.Focus(); }
    }

    private bool Commit(List<string> updated)
    {
        if (Save?.Invoke(updated) != true) return false;
        Show(updated);
        message.Visibility = Visibility.Collapsed;
        return true;
    }
}
