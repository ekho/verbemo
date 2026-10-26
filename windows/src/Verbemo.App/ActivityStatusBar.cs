using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Verbemo.Core.Recording;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App;

internal sealed record ActivityAccess(string Label, string Detail, bool Blocked)
{
    internal static ActivityAccess From(bool configUnreadable, MicrophoneAccess.State microphone) => configUnreadable
        ? new(T("Access: unknown", "Доступ: ?"), T("config.json cannot be read. Recording keeps the last readable settings; changes cannot be saved.", "config.json не читается. Запись использует последние прочитанные настройки; изменения нельзя сохранить."), false)
        : microphone switch
        {
            MicrophoneAccess.State.DeniedForEveryone or MicrophoneAccess.State.DeniedForDesktopApps =>
                new(T("Access: blocked", "Доступ: нет"), T("Allow desktop apps to use the microphone in Windows settings.", "Разрешите классическим приложениям доступ к микрофону в параметрах Windows."), true),
            MicrophoneAccess.State.Allowed => new(T("Access: allowed", "Доступ: есть"), T(
                "Microphone permission is allowed. Windows needs no separate permission for call audio. Permission does not prove that audio is being captured; check the meters while recording.",
                "Микрофон разрешён. Для звука звонка Windows не требует отдельного разрешения. Разрешение не подтверждает захват звука: проверьте индикаторы во время записи."), false),
            _ => new(T("Access: unknown", "Доступ: ?"), T("Windows microphone access could not be verified. Check recording settings.", "Не удалось проверить доступ к микрофону Windows. Проверьте настройки записи."), false),
        };
}

internal sealed class ActivityStatusBar : Border
{
    private readonly VerbemoRuntime runtime;
    private readonly Func<int> attentionCount;
    private readonly Func<string, string?> titleFor;
    private readonly ClickCheckBox auto = new();
    private readonly Button access;
    private readonly Button recording;
    private readonly Button work;
    private readonly Button warning;
    private readonly TextBlock autoState = Label();
    private readonly TextBlock workCount = Label();
    private readonly TextBlock workDetail = Label();
    private readonly List<(ProgressBar Bar, TextBlock Label, bool Microphone)> meters = [];
    private ApplicationDestination warningDestination;

    internal ActivityStatusBar(VerbemoRuntime runtime, Action<ApplicationDestination> navigate,
        Func<int> attentionCount, Func<string, string?> titleFor)
    {
        this.runtime = runtime;
        this.attentionCount = attentionCount;
        this.titleFor = titleFor;
        BorderThickness = new Thickness(0, 1, 0, 0);
        SetResourceReference(BorderBrushProperty, "JournalLine");
        SetResourceReference(BackgroundProperty, "JournalInset");
        var grid = new Grid { Margin = new Thickness(10, 4, 10, 4) };
        foreach (var width in new[] { new GridLength(136), new GridLength(108), new GridLength(108),
                     new GridLength(1, GridUnitType.Star), new GridLength(92), new GridLength(80) })
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var automatic = new StackPanel();
        automatic.Children.Add(Label(T("Auto record", "Автозапись")));
        automatic.Children.Add(autoState);
        auto.Content = automatic;
        auto.VerticalAlignment = VerticalAlignment.Center;
        auto.Margin = new Thickness(0, 0, 6, 0);
        AutomationProperties.SetAutomationId(auto, "activity.auto");
        AutomationProperties.SetName(auto, T("Automatic recording", "Автоматическая запись"));
        auto.Click += (_, _) =>
        {
            Ui.TryUpdate(Window.GetWindow(this), () => runtime.SetAutoRecord(auto.IsChecked == true));
            Refresh();
        };
        access = ActionButton("activity.access", () => navigate(ApplicationDestination.General));
        recording = ActionButton("activity.recording", () => navigate(ApplicationDestination.Live));
        work = ActionButton("activity.work", () => navigate(ApplicationDestination.Processing));
        var workText = new StackPanel();
        workText.Children.Add(workCount);
        workText.Children.Add(workDetail);
        work.Content = workText;
        warning = ActionButton("activity.warning", () => navigate(warningDestination));
        warning.SetResourceReference(Control.ForegroundProperty, Ui.Caution);
        var levels = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 6, 0) };
        foreach (var microphone in new[] { true, false })
        {
            var name = microphone ? T("Microphone", "Микрофон") : T("System audio", "Звук системы");
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(27) });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            var label = Label(microphone ? T("Mic", "Мик") : T("Sys", "Сис"));
            var meter = new ProgressBar { Minimum = -60, Maximum = 0, Value = -60, Height = 4, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(meter, name);
            AutomationProperties.SetAutomationId(meter, microphone ? "activity.microphone" : "activity.system");
            Grid.SetColumn(meter, 1);
            row.Children.Add(label); row.Children.Add(meter); levels.Children.Add(row);
            meters.Add((meter, label, microphone));
        }
        var cells = new FrameworkElement[] { auto, access, recording, work, levels, warning };
        for (var i = 0; i < cells.Length; i++) { Grid.SetColumn(cells[i], i); grid.Children.Add(cells[i]); }
        Child = grid;
        Refresh();
    }

    internal void Refresh()
    {
        var settings = runtime.Settings;
        var unreadable = runtime.ConfigUnreadable;
        var readiness = ActivityAccess.From(unreadable, MicrophoneAccess.Read());
        var policy = runtime.AutoRecord;
        var blocked = readiness.Blocked || !settings.AutoRecord.MicrophoneActivity
            || runtime.AutoRecordWarning is not null
            || policy.Phase is AutoRecordPhase.BackingOff or AutoRecordPhase.StandingDown;
        auto.IsChecked = settings.AutoRecord.Enabled;
        auto.IsEnabled = !unreadable;
        autoState.Text = !settings.AutoRecord.Enabled ? T("off", "выключена") : blocked ? T("blocked", "блокирована")
            : unreadable ? T("on · check settings", "вкл. · настройки?") : T("on", "включена");
        var autoDetail = readiness.Blocked || unreadable ? readiness.Detail : runtime.AutoRecordWarning ?? (!settings.AutoRecord.MicrophoneActivity
            ? T("Microphone activity detection is off. Enable it in recording settings.", "Определение активности микрофона выключено. Включите его в настройках записи.") : policy.LastDecision);
        Describe(auto, T("Automatic recording: ", "Автоматическая запись: ") + autoState.Text + ". " + autoDetail);
        SetText(access, readiness.Label, readiness.Detail);
        var state = runtime.State;
        var display = RecordingDisplay.From(state, state.StartedAt is { } started ? DateTimeOffset.Now - started : TimeSpan.Zero);
        SetText(recording, state.IsRecording ? display.Heading + " " + display.Elapsed : T("Not recording", "Нет записи"),
            state.IsRecording ? T("Open current recording", "Открыть текущую запись") : T("Open live transcript", "Открыть расшифровку на лету"));
        var activity = runtime.ProcessingActivity;
        workCount.Text = T($"Running {activity.Running.Count} · waiting {activity.Waiting}", $"Работает {activity.Running.Count} · ждёт {activity.Waiting}");
        var current = activity.Running.FirstOrDefault();
        workDetail.Text = current is { SessionDirectory: { } directory }
            ? current.Message + " · " + (titleFor(directory) ?? Path.GetFileName(directory))
            : T("No active job", "Нет активной задачи");
        Describe(work, workCount.Text + ". " + string.Join(Environment.NewLine, activity.Running.Select(job =>
            job.Message + " · " + (job.SessionDirectory is { } path ? titleFor(path) ?? Path.GetFileName(path) : ""))));
        var count = attentionCount();
        var needsSettings = unreadable || readiness.Blocked || settings.AutoRecord.Enabled && blocked;
        var captureWarning = runtime.RecordingWarning;
        warningDestination = captureWarning is not null ? ApplicationDestination.Live : count > 0
            ? ApplicationDestination.Attention : readiness.Blocked || unreadable ? ApplicationDestination.General : ApplicationDestination.Recording;
        warning.Visibility = captureWarning is not null || needsSettings || count > 0 ? Visibility.Visible : Visibility.Hidden;
        SetText(warning, "⚠ " + (captureWarning is not null ? T("Audio", "Звук") : count > 0 ? count.ToString() : T("Check", "Доступ")),
            captureWarning ?? (count > 0 ? T($"{count} meetings need attention. Open their details.", $"Встречи требуют внимания: {count}. Открыть подробности.") : autoDetail));
        RefreshMeters();
    }

    internal void RefreshMeters()
    {
        foreach (var (bar, label, microphone) in meters)
        {
            var value = microphone ? runtime.MicrophoneDecibels : runtime.SystemDecibels;
            var state = !runtime.State.IsRecording ? T("Not recording", "Нет записи")
                : runtime.State.IsPaused ? T("Paused", "Пауза") : value is null ? T("No reading", "Нет данных")
                : value <= -60 ? T("Silence", "Тишина") : $"{value:0} dBFS";
            bar.Value = value ?? -60;
            bar.IsEnabled = value is not null;
            label.ToolTip = bar.ToolTip = state;
            AutomationProperties.SetHelpText(bar, state);
        }
    }

    private static TextBlock Label(string text = "") => new TextBlock
    {
        Text = text, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis,
        TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center,
    }.Brush(TextBlock.ForegroundProperty, Ui.Primary);

    private static Button ActionButton(string id, Action action)
    {
        var button = Ui.Button("", action);
        button.Padding = new Thickness(4, 2, 4, 2);
        button.Margin = new Thickness(2, 0, 2, 0);
        button.MinWidth = 0;
        button.MinHeight = 36;
        button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        button.Background = System.Windows.Media.Brushes.Transparent;
        button.BorderThickness = new Thickness(0);
        AutomationProperties.SetAutomationId(button, id);
        return button;
    }

    private static void SetText(Button button, string text, string detail)
    {
        if (button.Content is not TextBlock label) button.Content = label = Label();
        label.Text = text;
        Describe(button, text + ". " + detail);
    }

    private static void Describe(FrameworkElement control, string detail)
    {
        control.ToolTip = detail;
        AutomationProperties.SetHelpText(control, detail);
        if (control is Button) AutomationProperties.SetName(control, detail);
        ToolTipService.SetShowOnDisabled(control, true);
    }
}
