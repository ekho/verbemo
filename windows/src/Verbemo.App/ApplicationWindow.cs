using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Verbemo.Core.Recording;
using static Verbemo.Core.Localization.Localized;
using Button = System.Windows.Controls.Button;
using HorizontalAlignment = System.Windows.HorizontalAlignment;

namespace Verbemo.App;

internal sealed class ApplicationWindow : Window
{
    private readonly VerbemoRuntime runtime;
    private readonly StatusWindow status;
    private readonly RecordingsWindow recordings;
    private readonly SettingsWindow settings;
    private readonly ContentControl host = new();
    private readonly FrameworkElement library;
    private readonly FrameworkElement settingsView;
    private readonly FrameworkElement live;
    private readonly FrameworkElement about;
    private readonly DockPanel toolbar = new() { Margin = new Thickness(18, 10, 18, 10) };
    private readonly Button heading;
    private readonly StackPanel create = new() { Orientation = System.Windows.Controls.Orientation.Horizontal };
    private readonly Border recordingBar = new();
    private readonly Button recordingTitle;
    private readonly Button pause;
    private readonly TextBlock clockText = Ui.Status();
    private readonly Button auto;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool allowClose;

    public ApplicationNavigationState Navigation { get; } = new();

    public ApplicationWindow(VerbemoRuntime runtime, StatusWindow status)
    {
        this.runtime = runtime;
        this.status = status;
        Title = "Verbemo";
        Icon = App.WindowIcon;
        MinWidth = 700;
        MinHeight = 520;
        Ui.FitToWorkArea(this, 1120, 780);
        recordings = new RecordingsWindow(runtime);
        settings = new SettingsWindow(runtime);
        library = TakeContent(recordings);
        settingsView = TakeContent(settings);
        live = TakeContent(status);
        about = AboutWindow.CreateView();
        status.RevealAction = Reveal;

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
        body.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetRow(body, 1);
        root.Children.Add(body);

        var sidebar = new DockPanel { Margin = new Thickness(10), LastChildFill = true };
        var brand = Ui.Heading("Verbemo");
        brand.FontSize = 24;
        brand.Margin = new Thickness(10, 16, 10, 24);
        DockPanel.SetDock(brand, Dock.Top);
        sidebar.Children.Add(brand);
        var meetings = new StackPanel();
        meetings.Children.Add(Ui.Detail(T("MEETINGS", "ВСТРЕЧИ")));
        foreach (var destination in new[] { ApplicationDestination.AllMeetings, ApplicationDestination.Processing, ApplicationDestination.Attention })
            meetings.Children.Add(NavigationButton(destination));
        DockPanel.SetDock(meetings, Dock.Top);
        sidebar.Children.Add(meetings);
        auto = Ui.Button("", () => ShowDestination(ApplicationDestination.Recording));
        auto.Margin = new Thickness(0, 12, 0, 0);
        DockPanel.SetDock(auto, Dock.Bottom);
        sidebar.Children.Add(auto);
        var options = new StackPanel();
        options.Children.Add(Ui.Detail(T("SETTINGS", "НАСТРОЙКИ")));
        foreach (var destination in new[] { ApplicationDestination.General, ApplicationDestination.Recording,
            ApplicationDestination.Transcription, ApplicationDestination.Summary, ApplicationDestination.Storage, ApplicationDestination.About })
            options.Children.Add(NavigationButton(destination));
        var scroll = Ui.Scroll(options);
        scroll.VerticalAlignment = VerticalAlignment.Bottom;
        sidebar.Children.Add(scroll);
        body.Children.Add(new Border { Child = sidebar, BorderThickness = new Thickness(0,0,1,0) }
            .Brush(Border.BackgroundProperty, "LayerFillColorDefaultBrush").Brush(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush"));

        var work = new DockPanel();
        heading = Ui.Button("", ShowAllMeetings);
        heading.FontSize = 22;
        heading.FontWeight = FontWeights.SemiBold;
        heading.Padding = new Thickness(0);
        heading.BorderThickness = new Thickness(0);
        heading.Background = System.Windows.Media.Brushes.Transparent;
        var import = Ui.Button(T("Import", "Импортировать"), () => _ = App.ImportAsync(this));
        create.Children.Add(import);
        var record = Ui.Button(T("New recording", "Новая запись"), async () =>
        {
            if (runtime.State.IsRecording) { ShowDestination(ApplicationDestination.Live); return; }
            await status.ToggleRecordingAsync();
            if (runtime.State.IsRecording) ShowDestination(ApplicationDestination.Live);
        }, accent: true);
        record.Margin = new Thickness(8,0,0,0);
        create.Children.Add(record);
        DockPanel.SetDock(create, Dock.Right);
        toolbar.Children.Add(create);
        toolbar.Children.Add(heading);
        DockPanel.SetDock(toolbar, Dock.Top);
        work.Children.Add(toolbar);
        work.Children.Add(host);
        Grid.SetColumn(work, 1);
        body.Children.Add(work);

        var bar = new DockPanel { Margin = new Thickness(16, 8, 16, 8) };
        var stop = Ui.Button(T("Stop", "Завершить"), async () => await status.ToggleRecordingAsync());
        DockPanel.SetDock(stop, Dock.Right);
        bar.Children.Add(stop);
        pause = Ui.Button(T("Pause", "Пауза"), async () => await status.TogglePauseAsync());
        DockPanel.SetDock(pause, Dock.Right);
        bar.Children.Add(pause);
        DockPanel.SetDock(clockText, Dock.Right);
        clockText.Margin = new Thickness(12,0,12,0);
        bar.Children.Add(clockText);
        recordingTitle = Ui.Button("", () => ShowDestination(ApplicationDestination.Live));
        bar.Children.Add(recordingTitle);
        recordingBar.Child = bar;
        root.Children.Add(recordingBar);
        Content = root;
        timer.Tick += (_, _) => Refresh();
        timer.Start();
        runtime.SettingsChanged += SettingsChanged;
        runtime.StateChanged += RecordingChanged;
        Closed += (_, _) => { timer.Stop(); runtime.SettingsChanged -= SettingsChanged; runtime.StateChanged -= RecordingChanged; recordings.Close(); settings.Close(); };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.OemComma && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { ShowDestination(ApplicationDestination.General); e.Handled = true; } };
        AllowDrop = true;
        Drop += async (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is not string[] files) return;
            try { foreach (var file in files) await runtime.ImportAsync(file); ShowAllMeetings(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Ui.ShowError(this, "Verbemo", error.Message); }
        };
        ShowDestination(ApplicationDestination.AllMeetings);
        Refresh();
    }

    private static FrameworkElement TakeContent(Window window)
    {
        var view = (FrameworkElement)window.Content;
        window.Content = null;
        return view;
    }

    private Button NavigationButton(ApplicationDestination destination)
    {
        var button = Ui.Button(Label(destination), () => ShowDestination(destination));
        button.HorizontalContentAlignment = HorizontalAlignment.Left;
        button.Margin = new Thickness(0, 3, 0, 3);
        button.MinHeight = 34;
        return button;
    }

    public void ShowDestination(ApplicationDestination destination)
    {
        Navigation.Destination = destination;
        toolbar.Visibility = destination == ApplicationDestination.About ? Visibility.Collapsed : Visibility.Visible;
        heading.Content = destination == ApplicationDestination.Live ? Label(ApplicationDestination.AllMeetings) : Label(destination);
        heading.IsEnabled = destination is ApplicationDestination.AllMeetings or ApplicationDestination.Processing or ApplicationDestination.Attention or ApplicationDestination.Live;
        create.Visibility = destination == ApplicationDestination.AllMeetings ? Visibility.Visible : Visibility.Collapsed;
        host.Content = destination switch
        {
            ApplicationDestination.About => about,
            ApplicationDestination.Live => live,
            >= ApplicationDestination.General and <= ApplicationDestination.Storage => settingsView,
            _ => library,
        };
    }

    public void ShowAllMeetings()
    {
        Navigation.Query = "";
        Navigation.SessionDirectory = null;
        ShowDestination(ApplicationDestination.AllMeetings);
    }

    private void SettingsChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(Refresh);
    private void RecordingChanged(object? sender, RecordingState e) => Dispatcher.InvokeAsync(Refresh);
    private void Refresh()
    {
        ShowInTaskbar = runtime.Settings.TaskbarIcon;
        var state = runtime.State;
        recordingBar.Visibility = state.IsRecording ? Visibility.Visible : Visibility.Collapsed;
        var display = RecordingDisplay.From(state, state.StartedAt is { } started ? DateTimeOffset.Now - started : TimeSpan.Zero);
        clockText.Text = display.Heading + " · " + display.Elapsed;
        pause.Content = display.PauseAction;
        recordingTitle.Content = T("Current meeting", "Текущая встреча");
        if (state.SessionDirectory is { } directory)
        {
            try
            {
                using var marker = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, ".recording.json")));
                if (marker.RootElement.TryGetProperty("title", out var value) && value.GetString() is { Length: > 0 } title) recordingTitle.Content = title;
            }
            catch (Exception error) when (error is IOException or JsonException) { }
        }
        auto.Content = T("↻ Auto recording ", "↻ Автозапись ") + (runtime.Settings.AutoRecord.Enabled ? T("on", "включена") : T("off", "выключена"));
    }

    public void Reveal() { Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal; Activate(); }
    public void AllowClose() => allowClose = true;
    protected override void OnClosing(System.ComponentModel.CancelEventArgs e) { if (!allowClose) { e.Cancel = true; Hide(); } base.OnClosing(e); }
    private static string Label(ApplicationDestination destination) => destination switch
    {
        ApplicationDestination.AllMeetings => T("All meetings", "Все встречи"),
        ApplicationDestination.Processing => T("Processing", "В обработке"),
        ApplicationDestination.Attention => T("Needs attention", "Нужны действия"),
        ApplicationDestination.General => T("General", "Общие"),
        ApplicationDestination.Recording => T("Recording", "Запись"),
        ApplicationDestination.Transcription => T("Transcription", "Расшифровка"),
        ApplicationDestination.Summary => T("Summary and participants", "Сводка и участники"),
        ApplicationDestination.Storage => T("Storage and models", "Хранение и модели"),
        ApplicationDestination.About => T("About Verbemo", "О Verbemo"),
        _ => T("Current meeting", "Текущая встреча"),
    };
}
