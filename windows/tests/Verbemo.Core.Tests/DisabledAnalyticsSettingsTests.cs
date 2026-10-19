using System.Text.Json;
using Verbemo.Core.Configuration;

namespace Verbemo.Core.Tests;

public sealed class DisabledAnalyticsSettingsTests
{
    [Theory]
    [InlineData("{}")]
    [InlineData("{\"analytics\":true}")]
    [InlineData("{\"analytics\":false}")]
    public void Legacy_settings_stay_disabled_and_are_omitted_when_saved(string json)
    {
        var settings = JsonSerializer.Deserialize<AppSettings>(json)!;
        settings.Analytics = true;
        Assert.False(settings.Analytics);
        Assert.Null(SettingsSchema.Find("analytics"));
        Assert.False(SettingsDocument.ToNode(settings).ContainsKey("analytics"));
    }
}
