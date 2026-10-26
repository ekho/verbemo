using System.Text.Json;
using Verbemo.Core.Configuration;

namespace Verbemo.Core.Tests;

public sealed class EmailAddressesTests
{
    [Theory]
    [InlineData("\" Legacy@Example.test \"", "legacy@example.test")]
    [InlineData("[\"Work@example.test\",\"work@example.test\",\"personal@example.test\"]", "work@example.test,personal@example.test")]
    [InlineData("null", "")]
    public void Reads_legacy_and_list_values_and_saves_as_a_list(string json, string expected)
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-emails", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var path = Path.Combine(root, "config.json");
            File.WriteAllText(path, "{\"user_email\":" + json + "}");
            var store = new AppSettingsStore(path, root);
            var loaded = store.Load();
            Assert.Empty(loaded.Problems);
            Assert.Equal(expected, string.Join(",", loaded.Settings.UserEmails));
            store.Save(loaded.Settings);
            Assert.Equal(loaded.Settings.UserEmails, store.Load().Settings.UserEmails);
            using var document = JsonDocument.Parse(JsonSerializer.Serialize(loaded.Settings, AppSettings.JsonOptions));
            Assert.Equal(JsonValueKind.Array, document.RootElement.GetProperty("user_email").ValueKind);
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void Parses_pasted_lists_and_rejects_invalid_input_as_a_whole()
    {
        Assert.Equal(new[] { "work@example.test", "personal+tag@example.test" },
            EmailAddresses.Parse(" Work@Example.test ; personal+tag@example.test\nwork@example.test "));
        Assert.Null(EmailAddresses.Parse("good@example.test, not an address"));
        Assert.Null(EmailAddresses.Parse("Name <me@example.test>"));
    }
}
