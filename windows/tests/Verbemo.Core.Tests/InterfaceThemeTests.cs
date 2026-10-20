using System.Text.Json;
using Verbemo.Core.Configuration;

namespace Verbemo.Core.Tests;

public sealed class InterfaceThemeTests
{
    [Fact]
    public void Legacy_config_follows_system_and_explicit_theme_round_trips()
    {
        Assert.Equal("system", JsonSerializer.Deserialize<AppSettings>("{}", AppSettings.JsonOptions)!.InterfaceTheme);
        foreach (var theme in new[] { "system", "light", "dark" })
        {
            var settings = AppSettings.CreateDefault(Path.GetTempPath());
            settings.InterfaceTheme = theme;
            Assert.Equal(theme, JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(settings, AppSettings.JsonOptions), AppSettings.JsonOptions)!.InterfaceTheme);
        }
        Assert.Equal(new[] { "system", "light", "dark" }, SettingsSchema.Sections.SelectMany(s => s.Entries).Single(e => e.Path == "interface_theme").Options);
    }
}
