using Verbemo.Core.Configuration;
using Verbemo.Core.MCP;
using System.Text.Json.Nodes;
using Verbemo.Core.Localization;

namespace Verbemo.Core.Tests;

public sealed class McpConfigurationTests
{
    [Theory]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{\"mcp\":null}")]
    public void Invalid_root_preserves_last_good_and_cannot_be_overwritten(string text)
    {
        using var dir = new TemporaryDirectory(); var path = Path.Combine(dir.Path, "config.json");
        File.WriteAllText(path, text); var store = new AppSettingsStore(path, dir.Path);
        var previous = store.Defaults; previous.KeepAudio = true;
        var load = store.Load(previous);
        Assert.True(load.IsUnreadable); Assert.True(load.Settings.KeepAudio);
        Assert.Throws<ConfigUnreadableException>(() => store.Save(previous)); Assert.Equal(text, File.ReadAllText(path));
    }

    [Fact]
    public void Denied_config_path_is_not_missing()
    {
        using var dir = new TemporaryDirectory(); var store = new AppSettingsStore(dir.Path, dir.Path);
        Assert.True(store.Load().IsUnreadable);
    }

    [Fact]
    public void Mcp_defaults_are_off_and_projection_reports_configured_and_default_values()
    {
        using var dir = new TemporaryDirectory(); var store = new AppSettingsStore(Path.Combine(dir.Path, "config.json"), dir.Path);
        var defaults = SettingsDocument.ToNode(store.Load().Settings);
        Assert.Equal(false, SettingsDocument.Get(defaults, "mcp.enabled")?.GetValue<bool>());
        Assert.Equal(52763, SettingsDocument.Get(defaults, "mcp.port")?.GetValue<int>());
        File.WriteAllText(store.ConfigPath, """{"mcp":{"enabled":true,"port":54321},"interface_language":"ru"}""");
        var load = store.Load(); var effective = SettingsSchema.Entries.ToDictionary(e => e.Path, e => SettingsDocument.Get(SettingsDocument.ToNode(load.Settings), e.Path));
        var projection = new McpSettings(JsonNode.Parse(File.ReadAllText(store.ConfigPath))!.AsObject(), effective,
            new Dictionary<string, JsonNode?> { ["interface_language"] = JsonValue.Create("en") }, new Dictionary<string,bool>(), dir.Path);
        var items = projection.Project(["mcp.enabled", "mcp.port", "interface_language"])["items"]!.AsArray();
        Assert.Equal(54321, items.Single(x => x!["key"]!.GetValue<string>() == "mcp.port")!["value"]!.GetValue<int>());
        Assert.All(items, x => Assert.Equal("configured", x!["source"]!.GetValue<string>()));
        Assert.True(items.Single(x => x!["key"]!.GetValue<string>() == "interface_language")!["pending_apply"]!.GetValue<bool>());
    }


    [Theory]
    [InlineData(InterfaceLanguage.English)]
    [InlineData(InterfaceLanguage.Russian)]
    public void Instructions_have_independent_localized_blocks_and_follow_selected_values(InterfaceLanguage language)
    {
        using var locale = Localized.Use(language);
        foreach (var client in McpConnectionInstructions.Clients)
        {
            var content = McpConnectionInstructions.Create(client, 54321, @"C:\Private Apps\O'Brien\Verbemo.exe");
            Assert.Equal("http://127.0.0.1:54321/mcp", content.Endpoint);
            Assert.Contains("O''Brien", content.ConsoleCommand);
            Assert.DoesNotContain("--port", content.ConsoleCommand);
            Assert.Contains(content.Endpoint, content.AgentPrompt);
            Assert.Contains("mcp", content.AgentPrompt); Assert.Contains("get_settings", content.AgentPrompt);
            Assert.Contains(language == InterfaceLanguage.Russian ? "настрой" : "configur", content.AgentPrompt.ToLowerInvariant());
            Assert.NotEmpty(content.ManualSteps); Assert.Null(content.Error);
            var changed = McpConnectionInstructions.Create(client, 54322, @"D:\Other\Verbemo.exe");
            Assert.DoesNotContain("54321", changed.AgentPrompt); Assert.DoesNotContain("O'Brien", changed.AgentPrompt);
            foreach(var invalid in new[]{0,1023,65536}) { var blocked=McpConnectionInstructions.Create(client,invalid,@"C:\Verbemo.exe"); Assert.NotNull(blocked.Error); Assert.Empty(blocked.Endpoint); Assert.Empty(blocked.ConsoleCommand); Assert.Empty(blocked.AgentPrompt); }
            Assert.NotNull(McpConnectionInstructions.Create(client,54321,@"C:\Verbemo.exe",readable:false).Error);
        }
        Assert.Equal(5, McpConnectionInstructions.Clients.Length);
        var desktop=McpConnectionInstructions.Create("Claude Desktop",54321,@"C:\Verbemo.exe");
        Assert.StartsWith("& ",desktop.ConsoleCommand); Assert.Contains("mcpServers",desktop.AgentPrompt);
        var opencode=McpConnectionInstructions.Create("OpenCode",54321,@"C:\Verbemo.exe");
        Assert.Contains("servers",opencode.AgentPrompt);
    }
}
