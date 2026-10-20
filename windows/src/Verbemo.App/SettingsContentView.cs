using System.Windows;
using System.Windows.Controls;
using Verbemo.Core.Configuration;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App;

internal sealed class SettingsContentView
{
    private readonly SetupForm form;
    private readonly List<AdvancedSettings> advanced = [];
    public Dictionary<ApplicationDestination, FrameworkElement> Pages { get; } = [];
    public static IReadOnlySet<string> PrimaryPaths => SettingsSchema.Sections.SelectMany(s => s.Entries)
        .Where(e => e.AskedInSetup).Select(e => e.Path).Concat(new[] { "summary.backend", "summary.openai_model", "summary.openai_base_url",
            "summary.ollama_model", "summary.ollama_base_url" }).ToHashSet(StringComparer.Ordinal);
    public static IReadOnlyDictionary<ApplicationDestination, string[]> EditorPaths => SettingsSchema.Sections.SelectMany(s => s.Entries)
        .GroupBy(e => Destination(e.Path)).ToDictionary(g => g.Key, g => g.Select(e => e.Path).ToArray());

    public SettingsContentView(VerbemoRuntime runtime)
    {
        form = new SetupForm(runtime, showsConfigProblems: false);
        var primary = form.ExtractSettingsPages();
        foreach (var destination in EditorPaths.Keys)
        {
            var content = primary[destination];
            var entries = SettingsSchema.Sections.SelectMany(s => s.Entries)
                .Where(e => Destination(e.Path) == destination && !PrimaryPaths.Contains(e.Path)).ToArray();
            var editor = new AdvancedSettings(runtime, entries);
            advanced.Add(editor);
            editor.View.Margin = new Thickness(0);
            if (destination == ApplicationDestination.General) content.Children.Insert(0, editor.View);
            else content.Children.Add(new Expander { Header = T("More options", "Дополнительные параметры"), Content = editor.View, Margin = new Thickness(0, 12, 0, 16) });
            var problems = Ui.Status("", Ui.Caution);
            void RefreshProblems() => problems.Text = string.Join(Environment.NewLine, runtime.ConfigProblems.Select(p => p.Explanation));
            RefreshProblems();
            content.Children.Insert(0, problems);
            Pages[destination] = Ui.Scroll(content);
        }
    }

    public void Detach() { form.Detach(); foreach (var editor in advanced) editor.Detach(); }
    private static ApplicationDestination Destination(string path) => path switch
    {
        "recordings_dir" or "keep_audio" => ApplicationDestination.Storage,
        "system_audio" => ApplicationDestination.Recording,
        _ when path.StartsWith("auto_record.", StringComparison.Ordinal) => ApplicationDestination.Recording,
        _ when path.StartsWith("transcription.", StringComparison.Ordinal) || path.StartsWith("live_transcription.", StringComparison.Ordinal)
            || path == "transcript_echo_filter" => ApplicationDestination.Transcription,
        _ when path.StartsWith("summary.", StringComparison.Ordinal) || path.StartsWith("speaker_names.", StringComparison.Ordinal) => ApplicationDestination.Summary,
        _ => ApplicationDestination.General,
    };
}
