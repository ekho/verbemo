using System.Text.Json;
using Verbemo.Core.Configuration;

namespace Verbemo.Core.Tests;

public sealed class DisabledAnalyticsSettingsTests
{
    [Theory]
    [InlineData("{}")]
    [InlineData("{\"analytics\":true}")]
    [InlineData("{\"analytics\":false}")]
    public void Legacy_settings_cannot_enable_product_analytics(string json)
    {
        var settings = JsonSerializer.Deserialize<AppSettings>(json)!;
        settings.Analytics = true;
        Assert.False(settings.Analytics);
        Assert.Null(SettingsSchema.Find("analytics"));
    }
}
