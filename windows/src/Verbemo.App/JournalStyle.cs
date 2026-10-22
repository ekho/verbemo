using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace Verbemo.App;

internal static class JournalStyle
{
    internal static void Apply(FrameworkElement root, string theme)
    {
        var dark = theme == "dark" || theme != "light" && Registry.GetValue(
            @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is 0;
        foreach (var (key, light, night) in new[]
        {
            ("JournalPaper", "#FFFEFA", "#242A25"), ("JournalSidebar", "#EEEEE7", "#1D241E"),
            ("JournalInset", "#F5F4EE", "#202620"), ("JournalInk", "#272E27", "#EEEEDE"),
            ("JournalMuted", "#59665C", "#A8B1A3"), ("JournalAccent", "#285846", "#AAD2AD"),
            ("JournalSelection", "#DFE9DF", "#354739"), ("JournalLine", "#DEDFD5", "#414A40")
        })
        {
            var brush = SystemParameters.HighContrast
                ? key is "JournalInk" or "JournalMuted" or "JournalAccent" or "JournalLine" ? SystemColors.WindowTextBrush
                    : SystemColors.WindowBrush
                : new SolidColorBrush((Color)ColorConverter.ConvertFromString(dark ? night : light));
            root.Resources[key] = brush;
        }
        root.Resources[Ui.Primary] = root.Resources["JournalInk"];
        root.Resources[Ui.Secondary] = root.Resources["JournalMuted"];
        root.Resources["CardBackgroundFillColorDefaultBrush"] = root.Resources["JournalPaper"];
        root.Resources["DividerStrokeColorDefaultBrush"] = root.Resources["JournalLine"];
        root.Resources["AccentFillColorDefaultBrush"] = SystemParameters.HighContrast ? SystemColors.HighlightBrush : root.Resources["JournalAccent"];
        root.Resources["TextOnAccentFillColorPrimaryBrush"] = SystemParameters.HighContrast ? SystemColors.HighlightTextBrush
            : new SolidColorBrush((Color)ColorConverter.ConvertFromString(dark ? "#1D241E" : "#FFFFFF"));
    }

    internal static Button IconButton(string glyph, string name, Action action)
    {
        var button = Ui.Button("", action);
        var symbol = Ui.Symbol(glyph);
        symbol.Width = 20;
        button.Content = symbol;
        button.MinWidth = 34;
        button.Padding = new Thickness(6);
        button.ToolTip = name;
        System.Windows.Automation.AutomationProperties.SetName(button, name);
        return button;
    }
}
