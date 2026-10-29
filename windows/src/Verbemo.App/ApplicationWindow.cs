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
    private readonly SettingsContentView settings;
    private readonly ContentControl host = new();
    private readonly FrameworkElement library;
    private readonly FrameworkElement live;
    private readonly FrameworkElement about;
    private readonly DockPanel toolbar = new() { Margin = new Thickness(18, 10, 18, 10) };
    private readonly Button heading;
    private readonly StackPanel create = new();
    private readonly StackPanel settingsTabs = new() { Orientation = System.Windows.Controls.Orientation.Horizontal };
    private readonly ComboBox settingsMenu = new();
    private readonly ComboBox filters = new() { Margin = new Thickness(0, 12, 0, 8) };
    private ApplicationDestination meetingDestination = ApplicationDestination.AllMeetings;
    private readonly Border setupNotice = new();
    private string? appliedTheme;
    private readonly DispatcherTimer meterTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private readonly ActivityStatusBar activityBar;
    private readonly Border recordingBar = new();
    private readonly Button recordingTitle;
    private readonly Button pause;
    private readonly TextBlock clockText = Ui.Status();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dictionary<ApplicationDestination,Button> navigationButtons = [];
    private bool allowClose;
    private Window? recordingPrompt;

    public ApplicationNavigationState Navigation { get; } = new();

    public ApplicationWindow(VerbemoRuntime runtime, StatusWindow status)
    {
        this.runtime = runtime;
        this.status = status;
        Title = "Verbemo";
        Icon = App.WindowIcon;
        MinWidth = 820;
        MinHeight = 520;
        Ui.FitToWorkArea(this, 1280, 820);
        recordings = new RecordingsWindow(runtime);
        recordings.Navigation = Navigation;
        recordings.MeetingRequested += (_, _) => ShowDestination(meetingDestination);
        recordings.SettingsRequested += (_, _) => ShowDestination(ApplicationDestination.Transcription);
        recordings.ActiveMeetingRequested += (_, _) => ShowDestination(ApplicationDestination.Live);
        settings = new SettingsContentView(runtime);
        library = TakeContent(recordings);
        live = TakeContent(status);
        about = AboutWindow.CreateView();
        status.RevealAction = Reveal;
        status.HostWindow = this;
        status.StartRecordingAction = NewRecordingAsync;

        var root = new Grid().Brush(Panel.BackgroundProperty, "JournalPaper");
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(268) });
        body.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetRow(body, 1);
        root.Children.Add(body);

        var sidebar = new DockPanel { Margin = new Thickness(14, 12, 14, 12), LastChildFill = true };
        var brand = Ui.Heading("Verbemo");
        brand.FontSize = 24;
        brand.Margin = new Thickness(10, 16, 10, 24);
        DockPanel.SetDock(brand, Dock.Top);
        sidebar.Children.Add(brand);
        foreach (var destination in new[] { ApplicationDestination.AllMeetings, ApplicationDestination.Processing, ApplicationDestination.Attention })
            filters.Items.Add(new ComboBoxItem { Content = Label(destination), Tag = destination });
        filters.SelectedIndex = 0;
        System.Windows.Automation.AutomationProperties.SetName(filters, T("Meeting filter", "Фильтр встреч"));
        filters.SelectionChanged += (_, _) => { if (filters.SelectedItem is ComboBoxItem { Tag: ApplicationDestination page } && Navigation.Destination != page) ShowDestination(page); };
        var bottom = new StackPanel();
        bottom.Children.Add(Ui.Button(T("⚙ Settings", "⚙ Настройки"), () => ShowDestination(ApplicationDestination.General)));
        bottom.Children.Add(NavigationButton(ApplicationDestination.About));
        DockPanel.SetDock(bottom, Dock.Bottom);
        sidebar.Children.Add(bottom);
        create.Margin = new Thickness(0, 0, 0, 8);
        DockPanel.SetDock(create, Dock.Top);
        sidebar.Children.Add(create);
        DockPanel.SetDock(filters, Dock.Top);
        sidebar.Children.Add(filters);
        sidebar.Children.Add(recordings.ExtractSidebar());
        body.Children.Add(new Border { Child = sidebar, BorderThickness = new Thickness(0, 0, 1, 0) }
            .Brush(Border.BackgroundProperty, "JournalSidebar").Brush(Border.BorderBrushProperty, "JournalLine"));

        var work = new DockPanel();
        heading = Ui.Button("", ShowAllMeetings);
        heading.FontSize = 14;
        heading.FontWeight = FontWeights.SemiBold;
        heading.Padding = new Thickness(0);
        heading.BorderThickness = new Thickness(0);
        heading.Background = System.Windows.Media.Brushes.Transparent;
        var record = Ui.Button(T("● New recording", "● Новая запись"), () => _ = NewRecordingAsync(), accent: true);
        record.MinHeight = 40;
        record.HorizontalAlignment = HorizontalAlignment.Stretch;
        create.Children.Add(record);
        var import = Ui.Button(T("↓ Import", "↓ Импортировать"), () => _ = App.ImportAsync(this));
        import.MinHeight = 40;
        import.Margin = new Thickness(0, 8, 0, 0);
        import.HorizontalAlignment = HorizontalAlignment.Stretch;
        create.Children.Add(import);
        var inspector = JournalStyle.IconButton("\uE8A0", T("Meeting details", "Детали встречи"), () =>
        {
            ShowDestination(ApplicationDestination.AllMeetings);
            recordings.ToggleInspector();
        });
        DockPanel.SetDock(inspector, Dock.Right);
        toolbar.Children.Add(inspector);
        toolbar.Children.Add(heading);
        DockPanel.SetDock(toolbar, Dock.Top);
        work.Children.Add(toolbar);
        foreach (var destination in new[] { ApplicationDestination.General, ApplicationDestination.Recording,
            ApplicationDestination.Transcription, ApplicationDestination.Summary, ApplicationDestination.Mcp, ApplicationDestination.Storage })
        {
            var button = NavigationButton(destination);
            button.Margin = new Thickness(0, 0, 12, 0);
            button.FontSize = 12;
            settingsTabs.Children.Add(button);
            settingsMenu.Items.Add(new ComboBoxItem { Content = Label(destination), Tag = destination });
        }
        settingsTabs.Margin = new Thickness(24, 4, 24, 16);
        settingsMenu.Margin = settingsTabs.Margin;
        System.Windows.Automation.AutomationProperties.SetName(settingsMenu, T("Settings section", "Раздел настроек"));
        settingsMenu.SelectionChanged += (_, _) =>
        {
            if (settingsMenu.SelectedItem is ComboBoxItem { Tag: ApplicationDestination page } && Navigation.Destination != page)
                ShowDestination(page);
        };
        DockPanel.SetDock(settingsTabs, Dock.Top);
        DockPanel.SetDock(settingsMenu, Dock.Top);
        work.Children.Add(settingsTabs);
        work.Children.Add(settingsMenu);
        var welcome = new StackPanel { Margin = new Thickness(24, 8, 24, 16) };
        welcome.Children.Add(Ui.Heading(T("Welcome to Verbemo", "Добро пожаловать в Verbemo")));
        welcome.Children.Add(Ui.Detail(T("Choose how to record and process meetings in the sections above.", "Настройте запись и обработку встреч в разделах выше.")));
        welcome.Children.Add(Ui.Button(T("Done", "Готово"), async () =>
        {
            try { await runtime.CompleteSetupAsync(); setupNotice.Visibility = Visibility.Collapsed; ShowAllMeetings(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Ui.ShowError(this, "Verbemo", error.Message); }
        }));
        setupNotice.Child = welcome;
        setupNotice.Visibility = Visibility.Collapsed;
        DockPanel.SetDock(setupNotice, Dock.Top);
        work.Children.Add(setupNotice);
        work.Children.Add(host);
        SizeChanged += (_, _) => UpdateSettingsNavigation();
        Grid.SetColumn(work, 1);
        body.Children.Add(work);

        var bar = new DockPanel { Margin = new Thickness(16, 8, 16, 8) };
        var stop = Ui.Button(T("Stop", "Завершить"), async () => { if(runtime.State.IsRecording) await status.ToggleRecordingAsync(); });
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
        recordingBar.SetResourceReference(Border.BackgroundProperty, "JournalInset");
        root.Children.Add(recordingBar);
        activityBar = new ActivityStatusBar(runtime, destination =>
        {
            if (destination is ApplicationDestination.Processing or ApplicationDestination.Attention) recordings.ShowList();
            ShowDestination(destination);
        }, () => recordings.AttentionCount, recordings.TitleFor);
        Grid.SetRow(activityBar, 2);
        root.Children.Add(activityBar);
        Content = root;
        timer.Tick += (_, _) => Refresh();
        timer.Start();
        meterTimer.Tick += (_, _) => activityBar.RefreshMeters();
        meterTimer.Start();
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += SystemThemeChanged;
        runtime.SettingsChanged += SettingsChanged;
        runtime.StateChanged += RecordingChanged;
        Closed += (_, _) => { timer.Stop(); meterTimer.Stop(); Microsoft.Win32.SystemEvents.UserPreferenceChanged -= SystemThemeChanged; status.StartRecordingAction = null; runtime.SettingsChanged -= SettingsChanged; runtime.StateChanged -= RecordingChanged; recordings.Close(); settings.Detach(); };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.F && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { recordings.FocusSearch(); e.Handled = true; } else if (e.Key == Key.OemComma && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { ShowDestination(ApplicationDestination.General); e.Handled = true; } };
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
        navigationButtons[destination] = button;
        return button;
    }

    public void ShowDestination(ApplicationDestination destination)
    {
        Navigation.Destination = destination;
        foreach(var (page,button) in navigationButtons)
        {
            button.FontWeight = page == destination ? FontWeights.SemiBold : FontWeights.Normal;
            button.SetResourceReference(Control.BackgroundProperty,page == destination ? "ControlFillColorSecondaryBrush" : "ControlFillColorDefaultBrush");
        }
        if (destination <= ApplicationDestination.Attention)
        {
            meetingDestination = destination;
            filters.SelectedItem = filters.Items.Cast<ComboBoxItem>().First(item => Equals(item.Tag, destination));
            recordings.SetFilter(destination switch
            { ApplicationDestination.Processing => Verbemo.Core.Processing.MeetingFilter.Processing, ApplicationDestination.Attention => Verbemo.Core.Processing.MeetingFilter.Attention, _ => Verbemo.Core.Processing.MeetingFilter.All });
        }
        toolbar.Visibility = Visibility.Visible;
        heading.Content = destination is >= ApplicationDestination.General and <= ApplicationDestination.Storage
            ? T("Settings", "Настройки") + "  /  " + Label(destination) : T("Meetings", "Встречи");
        heading.IsEnabled = destination is ApplicationDestination.AllMeetings or ApplicationDestination.Processing or ApplicationDestination.Attention or ApplicationDestination.Live;
        UpdateSettingsNavigation();
        setupNotice.Visibility = !runtime.IsSetupComplete && destination is >= ApplicationDestination.General and <= ApplicationDestination.Storage ? Visibility.Visible : Visibility.Collapsed;
        host.Content = destination switch
        {
            ApplicationDestination.About => about,
            ApplicationDestination.Live => live,
            >= ApplicationDestination.General and <= ApplicationDestination.Storage => settings.Pages[destination],
            _ => library,
        };
    }

    public void ShowAllMeetings()
    {
        Navigation.Query = "";
        Navigation.SessionDirectory = null;
        recordings.ShowList();
        ShowDestination(ApplicationDestination.AllMeetings);
    }

    private void SettingsChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(() => { appliedTheme = null; Refresh(); });
    private void SystemThemeChanged(object sender, Microsoft.Win32.UserPreferenceChangedEventArgs e) => Dispatcher.InvokeAsync(() => { appliedTheme = null; Refresh(); });
    private void RecordingChanged(object? sender, RecordingState e) => Dispatcher.InvokeAsync(() =>
    {
        if (e.IsRecording && recordingPrompt is { } prompt) prompt.DialogResult = false;
        Refresh();
    });
    private void Refresh()
    {
        var themeKey = runtime.Settings.InterfaceTheme + ":" + SystemParameters.HighContrast;
        if (appliedTheme != themeKey)
        {
#pragma warning disable WPF0001
            if (System.Windows.Application.Current is { } app) app.ThemeMode = runtime.Settings.InterfaceTheme switch
            { "light" => ThemeMode.Light, "dark" => ThemeMode.Dark, _ => ThemeMode.System };
#pragma warning restore WPF0001
            JournalStyle.Apply(this, runtime.Settings.InterfaceTheme);
            appliedTheme = themeKey;
        }
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
        activityBar.Refresh();
    }

    private void UpdateSettingsNavigation()
    {
        var visible = Navigation.Destination is >= ApplicationDestination.General and <= ApplicationDestination.Storage;
        settingsTabs.Visibility = visible && ActualWidth >= 1180 ? Visibility.Visible : Visibility.Collapsed;
        settingsMenu.Visibility = visible && ActualWidth < 1180 ? Visibility.Visible : Visibility.Collapsed;
        settingsMenu.SelectedItem = settingsMenu.Items.Cast<ComboBoxItem>().FirstOrDefault(item => Equals(item.Tag, Navigation.Destination));
    }

    internal async Task NewRecordingAsync()
    {
        if (runtime.State.IsRecording) { ShowDestination(ApplicationDestination.Live); return; }
        if (recordingPrompt is { } existing) { existing.Activate(); return; }
        Reveal();
        var title = new TextBox { Text = T("Recording ", "Запись ") + DateTime.Now.ToString("dd.MM.yyyy HH:mm"), Margin = new Thickness(0, 0, 0, 20) };
        System.Windows.Automation.AutomationProperties.SetName(title, T("Meeting title", "Название встречи"));
        var content = new StackPanel { Margin = new Thickness(24) };
        content.Children.Add(Ui.Heading(T("New recording", "Новая запись")));
        content.Children.Add(title);
        var prompt = new Window { Title = T("New recording", "Новая запись"), Owner = this, Width = 500,
            SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize, Content = content };
        JournalStyle.Apply(prompt, runtime.Settings.InterfaceTheme);
        prompt.SetResourceReference(BackgroundProperty, "JournalPaper");
        var buttons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var start = Ui.Button(T("● Start", "● Начать"), () => prompt.DialogResult = true, accent: true);
        start.IsDefault = true;
        var cancel = Ui.Button(T("Cancel", "Отмена"), () => prompt.DialogResult = false);
        cancel.IsCancel = true;
        cancel.Margin = new Thickness(8, 0, 8, 0);
        buttons.Children.Add(start);
        buttons.Children.Add(cancel);
        buttons.Children.Add(JournalStyle.IconButton("\uE713", T("Recording settings", "Настройки записи"), () => { prompt.DialogResult = false; ShowDestination(ApplicationDestination.Recording); }));
        content.Children.Add(buttons);
        prompt.Loaded += (_, _) => { title.SelectAll(); title.Focus(); };
        bool accepted;
        recordingPrompt = prompt;
        try { accepted = prompt.ShowDialog() == true; }
        finally { recordingPrompt = null; }
        if (!accepted || runtime.State.IsRecording) return;
        await status.ToggleRecordingAsync(prompt: false);
        if (runtime.State.IsRecording)
        {
            try { await runtime.RenameRecordingAsync(title.Text); }
            catch (Exception error) when (error is IOException or InvalidOperationException or UnauthorizedAccessException) { Ui.ShowError(this, "Verbemo", error.Message); }
            ShowDestination(ApplicationDestination.Live);
        }
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
        ApplicationDestination.Mcp => "MCP",
        ApplicationDestination.Storage => T("Storage and models", "Хранение и модели"),
        ApplicationDestination.About => T("About Verbemo", "О Verbemo"),
        _ => T("Current meeting", "Текущая встреча"),
    };
}
