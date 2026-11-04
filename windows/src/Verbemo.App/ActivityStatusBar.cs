using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using ShapePath = System.Windows.Shapes.Path;
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
                "Microphone permission is allowed. Permission does not prove that audio is being captured; check the meters while recording.",
                "Микрофон разрешён. Разрешение не подтверждает захват звука: проверьте индикаторы во время записи."), false),
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
    private ActivityAccess readiness = ActivityAccess.From(false, MicrophoneAccess.State.Unknown);
    private readonly Button recording;
    private readonly Button work;
    private readonly Button warning;
    private readonly ContextMenu warningSettings = new();
    private readonly TextBlock workDetail = Label();
    private readonly Button system;
    private readonly List<(ProgressBar Bar, Button Source, bool Microphone)> meters = [];
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
        foreach (var width in new[] { GridLength.Auto, GridLength.Auto, GridLength.Auto,
                     new GridLength(1, GridUnitType.Star), GridLength.Auto })
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        var hitArea = new FrameworkElementFactory(typeof(Grid));
        hitArea.SetValue(Panel.BackgroundProperty, Brushes.Transparent);
        hitArea.AppendChild(presenter);
        auto.Template = new ControlTemplate(typeof(ClickCheckBox)) { VisualTree = hitArea };
        auto.Width = 32;
        auto.Height = 32;
        auto.Cursor = System.Windows.Input.Cursors.Hand;
        var settingsMenu = new ContextMenu();
        var settingsItem = new MenuItem { Header = T("Recording settings", "Настройки записи") };
        settingsItem.Click += (_, _) => navigate(ApplicationDestination.Recording);
        settingsMenu.Items.Add(settingsItem);
        auto.ContextMenu = settingsMenu;
        auto.VerticalAlignment = VerticalAlignment.Center;
        auto.Margin = new Thickness(0, 0, 6, 0);
        AutomationProperties.SetAutomationId(auto, "activity.auto");
        AutomationProperties.SetName(auto, T("Automatic recording", "Автоматическая запись"));
        auto.Click += (_, _) =>
        {
            Ui.TryUpdate(Window.GetWindow(this), () => runtime.SetAutoRecord(auto.IsChecked == true));
            Refresh();
        };
        access = ActionButton("activity.microphone-access", () => navigate(runtime.RecordingWarningFor(microphone: true) is not null
            ? ApplicationDestination.Live : ApplicationDestination.General));
        system = ActionButton("activity.system-audio", () => navigate(ApplicationDestination.Live));
        recording = ActionButton("activity.recording", () => navigate(ApplicationDestination.Live));
        work = ActionButton("activity.work", () => navigate(ApplicationDestination.Processing));
        var workText = new DockPanel();
        workText.Children.Add(Glyph("M3 5H15 M3 9H13 M3 13H11", Ui.Secondary));
        workText.Children.Add(workDetail);
        work.Content = workText;
        warning = ActionButton("activity.warning", () => navigate(warningDestination));
        warning.SetResourceReference(Control.ForegroundProperty, Ui.Caution);
        var generalSettings = new MenuItem { Header = T("General settings", "Общие настройки") };
        generalSettings.Click += (_, _) => navigate(ApplicationDestination.General);
        warningSettings.Items.Add(generalSettings);
        var levels = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var microphone in new[] { true, false })
        {
            var name = microphone ? T("Microphone", "Микрофон") : T("System audio", "Звук системы");
            var source = microphone ? access : system;
            var meter = new ProgressBar { Minimum = -60, Maximum = 0, Value = -60, Height = 5, Width = 28,
                VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) };
            meter.SetResourceReference(Control.ForegroundProperty, Ui.Good);
            AutomationProperties.SetName(meter, name);
            AutomationProperties.SetAutomationId(meter, microphone ? "activity.microphone" : "activity.system");
            levels.Children.Add(source);
            levels.Children.Add(meter);
            meters.Add((meter, source, microphone));
        }
        var cells = new FrameworkElement[] { auto, recording, levels, work, warning };
        for (var i = 0; i < cells.Length; i++) { Grid.SetColumn(cells[i], i); grid.Children.Add(cells[i]); }
        Child = grid;
        Refresh();
    }

    internal void Refresh()
    {
        var settings = runtime.Settings;
        var unreadable = runtime.ConfigUnreadable;
        var microphone = MicrophoneAccess.Read();
        readiness = ActivityAccess.From(false, microphone);
        var configDetail = unreadable ? ActivityAccess.From(true, microphone).Detail : "";
        var policy = runtime.AutoRecord;
        var blocked = readiness.Blocked || !settings.AutoRecord.MicrophoneActivity
            || runtime.AutoRecordWarning is not null
            || policy.Phase is AutoRecordPhase.BackingOff or AutoRecordPhase.StandingDown;
        auto.IsChecked = settings.AutoRecord.Enabled;
        auto.IsEnabled = !unreadable;
        var autoState = !settings.AutoRecord.Enabled ? T("off", "выключена") : blocked ? T("blocked", "блокирована")
            : unreadable ? T("on · check settings", "вкл. · настройки?") : T("on", "включена");
        var autoDetail = unreadable ? configDetail : readiness.Blocked ? readiness.Detail : runtime.AutoRecordWarning ?? (!settings.AutoRecord.MicrophoneActivity
            ? T("Microphone activity detection is off. Enable it in recording settings.", "Определение активности микрофона выключено. Включите его в настройках записи.") : policy.LastDecision);
        var autoUnavailable = settings.AutoRecord.Enabled && (blocked || unreadable);
        var autoStateKey = (settings.AutoRecord.Enabled, autoUnavailable);
        if (!Equals(auto.Tag, autoStateKey))
        {
            auto.Content = AutoGlyph(settings.AutoRecord.Enabled, autoUnavailable);
            auto.Tag = autoStateKey;
        }
        Describe(auto, T("Automatic recording: ", "Автоматическая запись: ") + autoState + ". " + autoDetail);
        AutomationProperties.SetName(auto, T("Automatic recording: ", "Автоматическая запись: ") + autoState);
        var state = runtime.State;
        var display = RecordingDisplay.From(state, state.StartedAt is { } started ? DateTimeOffset.Now - started : TimeSpan.Zero);
        SetIconText(recording,
            state.IsPaused ? "M6 4H8V14H6Z M10 4H12V14H10Z" : "M9 2A7 7 0 1 1 8.99 2Z",
            display.Elapsed,
            state.IsRecording ? display.Heading + " " + display.Elapsed : T("Not recording", "Нет записи"),
            state.IsRecording ? T("Open current recording", "Открыть текущую запись") : T("Open live transcript", "Открыть расшифровку на лету"),
            state.IsPaused ? Ui.Caution : state.IsRecording ? Ui.Critical : Ui.Secondary, state.IsRecording);
        var activity = runtime.ProcessingActivity;
        var counts = T($"Running {activity.Running.Count} · waiting {activity.Waiting}", $"Работает {activity.Running.Count} · ждёт {activity.Waiting}");
        var current = activity.Running.FirstOrDefault();
        var stage = current is { SessionDirectory: { } directory }
            ? "   " + current.Message + " · " + (titleFor(directory) ?? Path.GetFileName(directory)) : "";
        workDetail.Text = $"{activity.Running.Count} · {activity.Waiting}" + stage;
        Describe(work, counts + ". " + string.Join(Environment.NewLine, activity.Running.Select(job =>
            job.Message + " · " + (job.SessionDirectory is { } path ? titleFor(path) ?? Path.GetFileName(path) : ""))));
        workDetail.SetResourceReference(TextBlock.ForegroundProperty,
            activity.Running.Count > 0 ? "SystemFillColorAttentionBrush" : Ui.Secondary);
        var count = attentionCount();
        warningDestination = count > 0 ? ApplicationDestination.Attention : ApplicationDestination.General;
        warning.ContextMenu = unreadable && count > 0 ? warningSettings : null;
        warning.Visibility = unreadable || count > 0 ? Visibility.Visible : Visibility.Collapsed;
        SetIconText(warning, "M9 2L17 16H1Z M9 6V11 M9 13V14",
            (count + (unreadable ? 1 : 0)).ToString(), T("Warnings", "Предупреждения"),
            (unreadable ? configDetail + Environment.NewLine : "") +
            (count > 0 ? T($"{count} meetings need attention.", $"Встречи требуют внимания: {count}.") : ""),
            Ui.Caution);
        RefreshMeters();
    }

    internal void RefreshMeters()
    {
        foreach (var (bar, source, microphone) in meters)
        {
            var value = microphone ? runtime.MicrophoneDecibels : runtime.SystemDecibels;
            var sourceWarning = runtime.RecordingWarningFor(microphone);
            var trackLost = sourceWarning is not null;
            var denied = microphone && readiness.Blocked;
            var state = !runtime.State.IsRecording ? T("Not recording", "Нет записи")
                : runtime.State.IsPaused ? T("Paused", "Пауза") : value is null ? T("No reading", "Нет данных")
                : value <= -60 ? T("Silence", "Тишина") : $"{value:0} dBFS";
            bar.Value = denied || trackLost ? -60 : value ?? -60;
            bar.IsEnabled = !denied && !trackLost && value is not null;
            bar.ToolTip = state;
            AutomationProperties.SetHelpText(bar, state);
            var name = microphone ? T("Microphone", "Микрофон") : T("System audio", "Звук системы");
            var accessDetail = microphone ? readiness.Label + ". " + readiness.Detail
                : T("Windows needs no separate permission for call audio.", "Для звука звонка Windows не требует отдельного разрешения.");
            var detail = (trackLost ? sourceWarning + " " : "") + accessDetail + " " + state;
            var symbol = microphone ? "M7 4A2 2 0 0 1 11 4V8A2 2 0 0 1 7 8Z M5 8A4 4 0 0 0 13 8 M9 12V16"
                : "M2 7H5L9 3V15L5 11H2Z M12 6Q16 9 12 12 M14 4Q20 9 14 14";
            if (denied || trackLost) symbol += " M2 2L16 16";
            SetIconText(source, symbol, "", name, detail,
                denied || trackLost ? Ui.Caution : value > -60 ? Ui.Good : Ui.Secondary);
        }
    }

    private static ShapePath Glyph(string path, string tone, bool filled = false)
    {
        var icon = new ShapePath { Data = Geometry.Parse(path), Width = 16, Height = 16, Stretch = Stretch.Uniform,
            StrokeThickness = 1.3, VerticalAlignment = VerticalAlignment.Center };
        icon.SetResourceReference(filled ? System.Windows.Shapes.Shape.FillProperty : System.Windows.Shapes.Shape.StrokeProperty, tone);
        return icon;
    }

    private static ShapePath AutoGlyph(bool enabled, bool blocked)
    {
        var circle = new EllipseGeometry(new Point(9, 9), 7.5, 7.5);
        var letter = Geometry.Parse("M4.8 13L8.2 5H9.8L13.2 13H11.5L10.7 11H7.3L6.5 13Z M7.9 9.6H10.1L9 6.9Z");
        var disk = Geometry.Combine(circle, letter, GeometryCombineMode.Exclude, null);
        if (blocked)
        {
            var cut = Geometry.Parse("M1 2.4L2.4 1L17 15.6L15.6 17Z");
            disk = Geometry.Combine(disk, cut, GeometryCombineMode.Exclude, null);
            disk = Geometry.Combine(disk, Geometry.Parse("M0.8 4L1.8 3L15 16.2L14 17.2Z"), GeometryCombineMode.Union, null);
        }
        var icon = Glyph("M0 0", blocked ? Ui.Caution : enabled ? Ui.Good : Ui.Secondary, filled: true);
        icon.Data = disk;
        return icon;
    }

    private static void SetIconText(Button button, string path, string text, string name, string detail, string tone, bool filled = false)
    {
        var style = (path, text, tone, filled);
        if (!Equals(button.Tag, style))
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(Glyph(path, tone, filled));
            if (text.Length > 0)
            {
                var label = Label(text);
                label.Margin = new Thickness(4, 0, 0, 0);
                label.SetResourceReference(TextBlock.ForegroundProperty, tone);
                content.Children.Add(label);
            }
            button.Content = content;
            button.Tag = style;
        }
        var tooltip = name + ". " + detail;
        if (!Equals(button.ToolTip, tooltip)) Describe(button, tooltip);
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

    private static void Describe(FrameworkElement control, string detail)
    {
        control.ToolTip = detail;
        AutomationProperties.SetHelpText(control, detail);
        if (control is Button) AutomationProperties.SetName(control, detail);
        ToolTipService.SetShowOnDisabled(control, true);
    }
}
