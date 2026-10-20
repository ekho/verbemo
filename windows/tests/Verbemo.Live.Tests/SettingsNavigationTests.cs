using Verbemo.App;
using Verbemo.Core.Configuration;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class SettingsNavigationTests
{
    [Fact]
    public void Every_schema_key_has_one_editor_and_model_choices_stay_in_transcription()
    {
        var all = SettingsSchema.Sections.SelectMany(s => s.Entries).Select(e => e.Path).Order().ToArray();
        var represented = SettingsContentView.EditorPaths.Values.SelectMany(paths => paths).Order().ToArray();
        Assert.Equal(all, represented);
        Assert.Equal(represented.Length, represented.Distinct().Count());
        Assert.Contains("transcription.local_engine", SettingsContentView.EditorPaths[ApplicationDestination.Transcription]);
        Assert.DoesNotContain("transcription.local_engine", SettingsContentView.EditorPaths[ApplicationDestination.Storage]);
        Assert.Contains("interface_theme", SettingsContentView.EditorPaths[ApplicationDestination.General]);
        Assert.Contains("summary.backend", SettingsContentView.PrimaryPaths);
        Assert.Contains("summary.openai_model", SettingsContentView.PrimaryPaths);
    }
}
