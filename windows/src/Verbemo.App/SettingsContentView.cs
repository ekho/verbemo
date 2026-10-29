using System.Windows;
using System.Windows.Controls;
using Verbemo.Core.Configuration;
using Verbemo.App.MCP;
using System.IO;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App;

internal sealed class SettingsContentView
{
    private readonly SetupForm form;
    private readonly ModelFilesView models;
    private readonly List<AdvancedSettings> advanced = [];
    private readonly List<TextBlock> problemLabels = [];
    private readonly VerbemoRuntime runtime;
    private readonly McpSettingsView mcp;
    public Dictionary<ApplicationDestination, FrameworkElement> Pages { get; } = [];
    public static IReadOnlySet<string> PrimaryPaths => SettingsSchema.Sections.SelectMany(s => s.Entries)
        .Where(e => e.AskedInSetup).Select(e => e.Path).Concat(new[] { "summary.backend", "summary.openai_model", "summary.openai_base_url",
            "summary.ollama_model", "summary.ollama_base_url", "mcp.enabled", "mcp.port" }).ToHashSet(StringComparer.Ordinal);
    public static IReadOnlyDictionary<ApplicationDestination, string[]> EditorPaths => SettingsSchema.Sections.SelectMany(s => s.Entries)
        .GroupBy(e => Destination(e.Path)).ToDictionary(g => g.Key, g => g.Select(e => e.Path).ToArray());

    public SettingsContentView(VerbemoRuntime runtime)
    {
        this.runtime = runtime;
        form = new SetupForm(runtime, showsConfigProblems: false);
        models = new ModelFilesView(runtime);
        mcp = new McpSettingsView(() => new(runtime.Settings.Mcp.Enabled, runtime.Settings.Mcp.Port,
            !runtime.ConfigUnreadable, runtime.Mcp.Status, runtime.Mcp.ActiveEndpoint),
            runtime.SetMcpEnabled, port => runtime.Update(settings => settings.Mcp.Port = port),
            runtime.Mcp.ReadToken, runtime.Mcp.RotateAsync, Path.Combine(AppContext.BaseDirectory, "Verbemo.exe"));
        var primary = form.ExtractSettingsPages();
        foreach (var destination in EditorPaths.Keys)
        {
            var content = primary[destination];
            if (destination == ApplicationDestination.Mcp)
            {
                content.Children.Add(mcp.View);
                Pages[destination] = Ui.Scroll(content);
                continue;
            }
            if(destination == ApplicationDestination.Storage) content.Children.Add(models.View);
            var entries = SettingsSchema.Sections.SelectMany(s => s.Entries)
                .Where(e => Destination(e.Path) == destination && !PrimaryPaths.Contains(e.Path)).ToArray();
            var editor = new AdvancedSettings(runtime, entries);
            advanced.Add(editor);
            editor.View.Margin = new Thickness(0);
            if (destination == ApplicationDestination.General) content.Children.Insert(0, editor.View);
            else content.Children.Add(new Expander { Header = T("More options", "Дополнительные параметры"), Content = editor.View, Margin = new Thickness(0, 12, 0, 16) });
            var problems = Ui.Status("", Ui.Caution);
            problemLabels.Add(problems);
            content.Children.Insert(0, problems);
            Pages[destination] = Ui.Scroll(content);
        }
        runtime.SettingsChanged += Changed;
        runtime.Mcp.Changed += Changed;
        RefreshProblems();
    }

    private void Changed(object? sender,EventArgs e) => form.View.Dispatcher.InvokeAsync(RefreshProblems);
    private void RefreshProblems() { mcp.Refresh(); foreach(var label in problemLabels) label.Text = string.Join(Environment.NewLine,runtime.ConfigProblems.Select(p => p.Explanation)); }
    public void Detach() { runtime.SettingsChanged -= Changed; runtime.Mcp.Changed -= Changed; form.Detach(); models.Detach(); foreach (var editor in advanced) editor.Detach(); }
    private static ApplicationDestination Destination(string path) => path switch
    {
        "mcp.enabled" or "mcp.port" => ApplicationDestination.Mcp,
        "recordings_dir" or "keep_audio" => ApplicationDestination.Storage,
        "system_audio" => ApplicationDestination.Recording,
        _ when path.StartsWith("auto_record.", StringComparison.Ordinal) => ApplicationDestination.Recording,
        _ when path.StartsWith("transcription.", StringComparison.Ordinal) || path.StartsWith("live_transcription.", StringComparison.Ordinal)
            || path == "transcript_echo_filter" => ApplicationDestination.Transcription,
        _ when path.StartsWith("summary.", StringComparison.Ordinal) || path.StartsWith("speaker_names.", StringComparison.Ordinal) => ApplicationDestination.Summary,
        _ => ApplicationDestination.General,
    };
}
