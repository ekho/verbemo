using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Verbemo.Core.Configuration;
using Verbemo.Core.Processing;
using Verbemo.Core.Sessions;
using static Verbemo.Core.Localization.Localized;
using ContextMenu = System.Windows.Controls.ContextMenu;
using DataGrid = System.Windows.Controls.DataGrid;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using MenuItem = System.Windows.Controls.MenuItem;
using Orientation = System.Windows.Controls.Orientation;
using TextBox = System.Windows.Controls.TextBox;

namespace Verbemo.App;

/// <summary>
/// Every meeting in the recordings folder, what has been done with it, and the
/// few things worth doing to one by hand: finish what gave up, transcribe again,
/// put a name to a voice, listen, open, delete.
/// </summary>
internal sealed class RecordingsWindow : Window
{
    private readonly VerbemoRuntime runtime;
    private readonly System.Windows.Controls.ListBox grid = new() { BorderThickness = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly Grid layout = new();
    private readonly DockPanel listPanel = new();
    private readonly StackPanel deletionNotices = new();
    private readonly Dictionary<string, System.Windows.Controls.Button> undoButtons = new(StringComparer.OrdinalIgnoreCase);
    private readonly TextBox search;
    private readonly System.Windows.Controls.Button regenerate;
    private readonly System.Windows.Controls.Button textCopy;
    private readonly System.Windows.Controls.Button markdownCopy;
    private MeetingFilter filter;
    private List<Row> allRows = [];
    private bool detailOpen;
    private bool sidebarExtracted;
    private bool inspectorOpen;
    private readonly Border inspector = new();
    private readonly TextBlock metadata = Ui.Detail("");
    private readonly TextBlock processingSettings = Ui.Detail("");
    private readonly MeetingPlayer player = new();
    public event EventHandler? MeetingRequested;
    public event EventHandler? SettingsRequested;
    private ApplicationNavigationState? navigation;
    public event EventHandler? ActiveMeetingRequested;
    public ApplicationNavigationState? Navigation { set => navigation = value; }
    private readonly TextBlock title = Ui.Title("");
    private readonly TextBlock problem = Ui.Status("", Ui.Caution);
    private readonly MarkdownPreview summary = new();
    private readonly MarkdownPreview transcript = new();
    private readonly ContentControl transcriptContent = new();
    private readonly StackPanel calendarPanel = new();
    private readonly TabControl engineTabs = new() { Margin = new Thickness(0, 8, 0, 0), Visibility = Visibility.Collapsed };
    private readonly TextBlock processingStatus = Ui.Status("");
    private readonly StackPanel speakers = new() { Margin = new Thickness(12) };
    private readonly TextBlock empty = Ui.Detail("");
    private readonly System.Windows.Controls.Button finish;
    private readonly System.Windows.Controls.Button retranscribe;
    private readonly System.Windows.Controls.Button listen;
    private readonly System.Windows.Controls.Button folder;
    private readonly System.Windows.Controls.Button delete;
    private readonly Grid detail = new();
    private readonly TabControl tabs = new() { Margin = new Thickness(0, 8, 0, 0) };
    private bool loading;
    private bool replacingRows;
    private bool reloadRequested;
    private bool updatingChoices;
    private string? selectedTranscriptKey;
    private string? selectedTranscriptSession;
    private int transcriptShown;

    public RecordingsWindow(VerbemoRuntime runtime)
    {
        this.runtime = runtime;
        Title = T("Recordings", "Записи");
        MinWidth = 760;
        MinHeight = 520;
        Ui.FitToWorkArea(this, 1040, 760);
        Icon = App.WindowIcon;
        var searchField = Ui.Field(T("Find a meeting", "Найти встречу"));
        search = searchField.Box;
        grid.Background = System.Windows.Media.Brushes.Transparent;
        ScrollViewer.SetHorizontalScrollBarVisibility(grid, ScrollBarVisibility.Disabled);

        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetBinding(ContentPresenter.ContentProperty, new System.Windows.Data.Binding(nameof(Row.View)));
        grid.ItemTemplate = new DataTemplate { VisualTree = presenter };
        grid.SetResourceReference(ItemsControl.ItemContainerStyleProperty, "MeetingCard");
        grid.SelectionChanged += async (_, _) =>
        {
            if (replacingRows) return;
            if (navigation is not null) navigation.SessionDirectory = Selected?.Item.Directory;
            await ShowSelectedAsync();
        };
        grid.PreviewMouseRightButtonDown += (_, e) =>
        {
            var hit = ItemsControl.ContainerFromElement(grid, e.OriginalSource as DependencyObject) as System.Windows.Controls.ListBoxItem;
            if (hit is not null) hit.IsSelected = true;
        };
        grid.ContextMenuOpening += (_, e) => { e.Handled = true; OpenMeetingMenu(grid); };
        grid.ContextMenu = new ContextMenu();
        void OpenSelected()
        {
            if (Selected?.Item.Transcript == ProcessingStep.Recording) { ActiveMeetingRequested?.Invoke(this, EventArgs.Empty); return; }
            detailOpen = Selected is not null;
            MeetingRequested?.Invoke(this, EventArgs.Empty);
            UpdateLayoutMode();
        }
        grid.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.F10 && Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { OpenMeetingMenu(grid); e.Handled = true; }
            else if (e.Key is Key.Enter or Key.Space) { OpenSelected(); e.Handled = true; }
        };
        grid.PreviewMouseLeftButtonUp += (_, _) => OpenSelected();
        finish = Ui.Button(T("Finish", "Доделать"), () => { if (Selected is { } row) runtime.FinishProcessing(row.Item.Directory); });
        finish.ToolTip = T("Try again whatever gave up or is waiting, keeping the transcript and every name typed by hand.",
            "Ещё раз попробовать то, что не получилось или ждёт, — расшифровка и имена, введённые вручную, остаются.");
        retranscribe = Ui.Button(T("Transcribe again ▾", "Расшифровать заново ▾"), OpenRetranscribeMenu);
        listen = Ui.Button(T("Listen", "Слушать"), () => { if (Selected is { } row) Listen(row); });
        folder = Ui.Button(T("Open folder", "Открыть папку"), () => { if (Selected is { } row) OpenFolder(row); });
        delete = Ui.Button(T("Delete", "Удалить"), () => { if (Selected is { } row) Delete(row); });

        regenerate = Ui.Button(T("Regenerate summary", "Перегенерировать сводку"), () => _ = PerformAsync(MeetingAction.RegenerateSummary));
        textCopy = Ui.Button(T("Text", "Текст"), () => _ = CopyAsync(markdown: false));
        markdownCopy = Ui.Button("Markdown", () => _ = CopyAsync(markdown: true));
        tabs.SelectionChanged += (_, e) => { if (e.Source == tabs) { if (navigation is not null) navigation.Tab = tabs.SelectedIndex; UpdateContentActions(); } };
        transcriptContent.Content = transcript;
        tabs.Items.Add(new TabItem { Header = T("Summary", "Сводка"), Content = summary });
        tabs.Items.Add(new TabItem { Header = T("Transcript", "Расшифровка"), Content = transcriptContent });

        engineTabs.SelectionChanged += async (_, args) =>
        {
            if (!updatingChoices && args.Source == engineTabs) await ShowTranscriptAsync();
        };
        var transcriptPanel = new Grid();
        transcriptPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        transcriptPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        transcriptPanel.Children.Add(engineTabs);
        Grid.SetRow(tabs, 1);
        transcriptPanel.Children.Add(tabs);

        var actions = new WrapPanel { Margin = new Thickness(0, 8, 0, 12) };
        foreach (var button in new[] { textCopy, markdownCopy })
        {
            ToolTipService.SetShowOnDisabled(button, true);
            button.Margin = new Thickness(0, 0, 8, 0);
            actions.Children.Add(button);
        }
        detail.Margin = new Thickness(28, 18, 28, 20);
        for (var index = 0; index < 5; index++) detail.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        detail.RowDefinitions.Add(new RowDefinition());
        detail.Children.Add(metadata);
        title.FontSize = 30;
        title.FontWeight = FontWeights.Bold;
        title.Margin = new Thickness(0, 10, 0, 16);
        var titleRow = new DockPanel();
        var more = JournalStyle.IconButton("\uE712", T("Meeting actions", "Действия со встречей"), () => OpenMeetingMenu(title));
        DockPanel.SetDock(more, Dock.Right);
        titleRow.Children.Add(more);
        var rename = Ui.Button("", () => _ = PerformAsync(MeetingAction.Rename));
        rename.Content = title;
        rename.Background = System.Windows.Media.Brushes.Transparent;
        rename.BorderThickness = new Thickness(0);
        rename.Padding = new Thickness(0);
        rename.HorizontalContentAlignment = HorizontalAlignment.Left;
        System.Windows.Automation.AutomationProperties.SetName(rename, T("Rename meeting", "Переименовать встречу"));
        titleRow.Children.Add(rename);
        Grid.SetRow(titleRow, 1);
        detail.Children.Add(titleRow);
        Grid.SetRow(player, 2);
        detail.Children.Add(player);
        Grid.SetRow(problem, 3);
        detail.Children.Add(problem);
        Grid.SetRow(actions, 4);
        detail.Children.Add(actions);
        Grid.SetRow(transcriptPanel, 5);
        detail.Children.Add(transcriptPanel);

        var information = new StackPanel { Margin = new Thickness(18, 24, 18, 18) };
        information.Children.Add(Ui.Heading(T("MEETING DETAILS", "ДЕТАЛИ ВСТРЕЧИ")));
        information.Children.Add(Ui.Heading(T("PARTICIPANTS", "УЧАСТНИКИ")));
        speakers.Margin = new Thickness(0, 8, 0, 16);
        information.Children.Add(speakers);
        information.Children.Add(calendarPanel);
        information.Children.Add(Ui.Heading(T("PROCESSING", "ОБРАБОТКА")));
        information.Children.Add(processingStatus);
        information.Children.Add(finish);
        foreach (var (button, text) in new[] { (retranscribe, T("Transcript", "Расшифровка")), (regenerate, T("Summary", "Сводка")) })
        {
            var label = button.Content?.ToString() ?? text;
            var symbol = Ui.Symbol("\uE72C"); symbol.Width = 20;
            button.Content = symbol;
            button.MinWidth = 32;
            button.Padding = new Thickness(5);
            System.Windows.Automation.AutomationProperties.SetName(button, label);
            ToolTipService.SetShowOnDisabled(button, true);
            information.Children.Add(Ui.Row(null, Ui.Title(text), null, button));
        }
        information.Children.Add(Ui.Heading(T("PROCESSING SETTINGS", "НАСТРОЙКИ ОБРАБОТКИ")));
        information.Children.Add(processingSettings);
        var settingsLink = Ui.Button(T("Settings →", "Настройки →"), () => SettingsRequested?.Invoke(this, EventArgs.Empty));
        settingsLink.Margin = new Thickness(0, 12, 0, 0);
        information.Children.Add(settingsLink);
        inspector.Child = Ui.Scroll(information);
        inspector.BorderThickness = new Thickness(1, 0, 0, 0);
        inspector.SetResourceReference(Border.BackgroundProperty, "JournalInset");
        inspector.SetResourceReference(Border.BorderBrushProperty, "JournalLine");

        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(290) });
        layout.ColumnDefinitions.Add(new ColumnDefinition());
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(280) });
        searchField.View.Margin = new Thickness(12,8,12,10);
        System.Windows.Automation.AutomationProperties.SetName(search, T("Find a meeting", "Найти встречу"));
        search.TextChanged += (_, _) => { if (navigation is not null) navigation.Query = search.Text; ApplyFilter(); };
        DockPanel.SetDock(searchField.View, Dock.Top);
        listPanel.Children.Add(searchField.View);
        var listContent = new Grid();
        listContent.Children.Add(grid);
        listContent.Children.Add(empty);
        listPanel.Children.Add(listContent);
        layout.Children.Add(listPanel);
        Grid.SetColumn(detail, 1);
        layout.Children.Add(detail);
        Grid.SetColumn(inspector, 2);
        layout.Children.Add(inspector);
        var content = new DockPanel();
        DockPanel.SetDock(deletionNotices, Dock.Bottom);
        content.Children.Add(deletionNotices);
        content.Children.Add(layout);
        Content = content;
        EventHandler deletionChanged = (_, _) => Dispatcher.InvokeAsync(() =>
        {
            foreach (var (directory, button) in undoButtons.ToArray())
                if (!runtime.Deletions.IsPending(directory)) { deletionNotices.Children.Remove(button); undoButtons.Remove(directory); }
        });
        runtime.Deletions.Changed += deletionChanged;
        Closed += (_, _) => runtime.Deletions.Changed -= deletionChanged;
        layout.SizeChanged += (_, _) => UpdateLayoutMode();
        EventHandler changed = (_, _) => Dispatcher.InvokeAsync(ReloadAsync);
        runtime.SessionsChanged += changed;
        Closed += (_, _) => { runtime.SessionsChanged -= changed; player.Dispose(); };
        System.ComponentModel.PropertyChangedEventHandler motionChanged = (_, e) =>
        {
            if(e.PropertyName == nameof(SystemParameters.ClientAreaAnimation)) Dispatcher.InvokeAsync(ReloadAsync);
        };
        SystemParameters.StaticPropertyChanged += motionChanged;
        Closed += (_, _) => SystemParameters.StaticPropertyChanged -= motionChanged;
        listPanel.Loaded += async (_, _) => await ReloadAsync();
        runtime.TrackArtifact("recordings_window");
    }

    private Row? Selected => grid.SelectedItem as Row;

    private string? ArtifactDirectory => engineTabs.SelectedItem is TabItem { Tag: TranscriptChoice choice } && choice.Version.State == ProcessingStep.Done
        ? choice.Version.Directory : Selected?.Item.Directory;
    private MeetingActionState ActionState()
    {
        var item = Selected?.Item;
        var directory = ArtifactDirectory;
        var ready = engineTabs.SelectedItem is TabItem { Tag: TranscriptChoice { Version.State: ProcessingStep.Done } }
            || item?.Transcript == ProcessingStep.Done;
        return new(ready && File.Exists(Path.Combine(directory ?? "", "transcript.json")),
            ready && File.Exists(Path.Combine(directory ?? "", "summary.md")), item?.HasAudio == true,
            item?.Transcript == ProcessingStep.Recording, item is not null && runtime.ProcessingStatusFor(item.Directory)?.IsBusy == true,
            !runtime.ConfigUnreadable, runtime.Settings.Transcription.Enabled,
            MeetingEgress.Route(EgressPurpose.Summary, runtime.Settings) is not null,
            item is not null && File.Exists(Path.Combine(item.Directory, TranscriptVersions.RequestFile)));
    }

    private void UpdateContentActions()
    {
        if (regenerate is null) return;
        var state = ActionState();
        var summaryTab = tabs.SelectedIndex == 0;
        regenerate.Visibility = retranscribe.Visibility = Visibility.Visible;
        regenerate.IsEnabled = state.Reason(MeetingAction.RegenerateSummary) is null;
        regenerate.ToolTip = state.Reason(MeetingAction.RegenerateSummary);
        textCopy.Visibility = markdownCopy.Visibility = Selected is null ? Visibility.Collapsed : Visibility.Visible;
        textCopy.IsEnabled = markdownCopy.IsEnabled = state.Reason(summaryTab ? MeetingAction.CopySummary : MeetingAction.CopyTranscript) is null;
        var settings = runtime.Settings;
        processingSettings.Text = T("Transcription: ", "Расшифровка: ") + (settings.Transcription.Enabled ? EngineResolver.DisplayName(settings.Transcription.Engine) : T("Disabled", "Выключена"))
            + "\n" + T("Diarization: ", "Диаризация: ") + (settings.Transcription.Enabled && TranscriptionSettings.CloudEngines.Contains(settings.Transcription.Engine)
                ? T("Cloud provider", "Облачный провайдер") : T("Not available locally", "Локально недоступна"))
            + "\n" + T("Summary: ", "Сводка: ") + (settings.Summary.Enabled ? settings.Summary.Backend : T("Disabled", "Выключена"));
    }

    private void OpenMeetingMenu(FrameworkElement anchor)
    {
        if (Selected is null) return;
        var menu = MeetingActionsMenu.Create(ActionState(), action => _ = PerformAsync(action));
        menu.FontSize = SystemFonts.MessageFontSize;
        menu.FontWeight = FontWeights.Normal;
        foreach (var item in menu.Items.OfType<MenuItem>().Where(item => item.Tag is MeetingAction.CopyTranscript or MeetingAction.CopySummary or MeetingAction.RegenerateSummary or MeetingAction.Retranscribe).ToArray()) menu.Items.Remove(item);
        menu.PlacementTarget = anchor;
        menu.IsOpen = true;
    }

    private async Task PerformAsync(MeetingAction action)
    {
        if (Selected is not { } row) return;
        if (ActionState().Reason(action) is { } reason) { Ui.ShowError(Ui.OwnerOf(layout), "Verbemo", reason); return; }
        try
        {
            switch (action)
            {
                case MeetingAction.CopyTranscript: await CopyArtifactAsync(ArtifactDirectory!, "transcript.md", false); break;
                case MeetingAction.CopySummary: await CopyArtifactAsync(ArtifactDirectory!, "summary.md", false); break;
                case MeetingAction.RegenerateSummary: await runtime.RegenerateSummaryAsync(ArtifactDirectory!); break;
                case MeetingAction.Retranscribe: OpenRetranscribeMenu(); break;
                case MeetingAction.OpenFolder: OpenFolder(row); break;
                case MeetingAction.Delete: Delete(row); break;
                case MeetingAction.Rename:
                    var field = new TextBox { Text = row.Item.Title, Margin = new Thickness(16), MinWidth = 300 };
                    var prompt = new Window { Title = T("Rename meeting", "Переименовать встречу"), Owner = Ui.OwnerOf(layout),
                        SizeToContent = SizeToContent.WidthAndHeight, WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize };
                    var content = new StackPanel();
                    content.Children.Add(field);
                    var save = Ui.Button(T("Save", "Сохранить"), () => prompt.DialogResult = true);
                    save.IsDefault = true;
                    save.Margin = new Thickness(16,0,16,16);
                    content.Children.Add(save);
                    prompt.Content = content;
                    prompt.Loaded += (_, _) => { field.SelectAll(); field.Focus(); };
                    if (prompt.ShowDialog() == true) await runtime.RenameSessionAsync(row.Item.Directory, field.Text);
                    break;
            }
            await ReloadAsync();
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or UnauthorizedAccessException or JsonException or ProcessingFailure)
        {
            await ReloadAsync();
            problem.Text = error.Message;
            problem.Visibility = Visibility.Visible;
        }
        catch (OperationCanceledException) { await ReloadAsync(); }
    }

    private async Task CopyAsync(bool markdown)
    {
        var action = tabs.SelectedIndex == 0 ? MeetingAction.CopySummary : MeetingAction.CopyTranscript;
        if (ActionState().Reason(action) is not null || ArtifactDirectory is not { } directory) return;
        try { await CopyArtifactAsync(directory, action == MeetingAction.CopySummary ? "summary.md" : "transcript.md", markdown); }
        catch (Exception error) when (error is IOException or System.Runtime.InteropServices.ExternalException) { Ui.ShowError(Ui.OwnerOf(layout), "Verbemo", error.Message); }
    }
    private static async Task CopyArtifactAsync(string directory, string artifact, bool markdown)
    {
        var content = await File.ReadAllTextAsync(Path.Combine(directory, artifact));
        if (!markdown)
        {
            var preview = new MarkdownPreview();
            preview.ShowMarkdown(content);
            content = new System.Windows.Documents.TextRange(preview.Document.ContentStart, preview.Document.ContentEnd).Text;
        }
        System.Windows.Clipboard.SetText(content);
    }

    public void SetFilter(MeetingFilter value) { filter = value; ApplyFilter(); }
    public void ShowList() { search.Text = ""; detailOpen = false; UpdateLayoutMode(); }
    public FrameworkElement ExtractSidebar()
    {
        sidebarExtracted = true;
        layout.Children.Remove(listPanel);
        layout.ColumnDefinitions[0].Width = new GridLength(0);
        return listPanel;
    }
    public void FocusSearch() { search.Focus(); search.SelectAll(); }
    public void ToggleInspector() { inspectorOpen = !inspectorOpen; UpdateLayoutMode(); }
    private void UpdateLayoutMode()
    {
        if (Selected is null) detailOpen = false;
        var available = layout.ActualWidth - (sidebarExtracted ? 0 : 268);
        var compact = available < 760;
        listPanel.Visibility = Visibility.Visible;
        detail.Visibility = Selected is null || compact && inspectorOpen ? Visibility.Collapsed : Visibility.Visible;
        inspector.Visibility = Selected is not null && (!compact || inspectorOpen) ? Visibility.Visible : Visibility.Collapsed;
        layout.ColumnDefinitions[0].Width = new GridLength(sidebarExtracted ? 0 : 268);
        layout.ColumnDefinitions[1].Width = compact && inspectorOpen ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        layout.ColumnDefinitions[2].Width = inspector.Visibility == Visibility.Collapsed ? new GridLength(0)
            : compact ? new GridLength(1, GridUnitType.Star) : new GridLength(280);
    }
    private void ApplyFilter()
    {
        var selected = Selected?.Item.Directory;
        var rows = allRows.Where(row => MeetingPresentation.Matches(row.Item, filter, search.Text, row.Status?.IsBusy == true)).ToList();
        replacingRows = true;
        try { grid.ItemsSource = rows; }
        finally { replacingRows = false; }
        grid.SelectedItem = rows.FirstOrDefault(row => row.Item.Directory == selected) ?? rows.FirstOrDefault();
        if (rows.Count == 0) _ = ShowSelectedAsync();
        empty.Text = search.Text.Length > 0 ? T("No matching meetings.", "Встречи не найдены.") : T("No meetings in this section.", "В этом разделе пока нет встреч.");
        empty.Margin = new Thickness(20);
        empty.IsHitTestVisible = false;
        empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateLayoutMode();
    }

    private async Task ReloadAsync()
    {
        if (loading) { reloadRequested = true; return; }
        loading = true;
        try
        {
            var selected = Selected?.Item.Directory;
            var selectedTab = tabs.SelectedIndex;
            var items = await runtime.LoadSessionsAsync();
            var rows = items.Select(item => new Row(item, runtime.ProcessingStatusFor(item.Directory))
            { IsPaused = runtime.State.SessionDirectory == item.Directory && runtime.State.IsPaused }).ToList();
            allRows = rows;
            ApplyFilter();
            grid.SelectedItem = rows.FirstOrDefault(row => row.Item.Directory == selected && grid.Items.Contains(row)) ?? grid.SelectedItem;
            tabs.SelectedIndex = selectedTab;
            // Setting the selection shows it: the rows are new, so the selection changes.
            UpdateLayoutMode();
        }
        finally
        {
            loading = false;
            if (reloadRequested)
            {
                reloadRequested = false;
                await ReloadAsync();
            }
        }
    }

    private async Task ShowSelectedAsync()
    {
        // Action availability follows the selection immediately, before reading previews.
        ++transcriptShown;
        speakers.Children.Clear();
        if (Selected is not { } row)
        {
            foreach (var button in new[] { finish, retranscribe, listen, folder, delete }) button.IsEnabled = false;
            title.Text = "";
            player.Load(null);
            UpdateContentActions();
            UpdateLayoutMode();
            summary.ShowText("");
            transcript.ShowText("");
            return;
        }
        var item = row.Item;
        calendarPanel.Children.Clear();
        if(MeetingCalendarView.Create(item.Calendar) is { } calendarView) calendarPanel.Children.Add(calendarView);
        var recording = item.Transcript == ProcessingStep.Recording;
        var busy = row.Status?.IsBusy == true;
        var canFinish = item.Transcript is ProcessingStep.Failed or ProcessingStep.Deferred
            || item.SpeakerNames is ProcessingStep.Failed or ProcessingStep.Deferred
            || item.Summary is ProcessingStep.Failed or ProcessingStep.Deferred or ProcessingStep.Stale
            || item.Transcript == ProcessingStep.Pending && item.HasAudio
            || item.Transcript == ProcessingStep.Done && (item.SpeakerNames == ProcessingStep.Pending && runtime.Settings.SpeakerNames.Enabled
                || item.Summary == ProcessingStep.Pending && runtime.Settings.Summary.Enabled);
        finish.IsEnabled = !recording && !busy && canFinish;
        finish.Visibility = canFinish ? Visibility.Visible : Visibility.Collapsed;
        retranscribe.IsEnabled = !recording && item.HasAudio && !busy;
        listen.IsEnabled = item.HasAudio && !recording;
        folder.IsEnabled = true;
        delete.IsEnabled = !recording && !busy;
        var noAudio = T("The audio was not kept for this recording.", "Звук этой записи не сохранён.");
        retranscribe.ToolTip = !item.HasAudio ? noAudio : busy ? row.Status!.Message : null;
        listen.ToolTip = !item.HasAudio ? noAudio : null;
        finish.ToolTip = busy ? row.Status!.Message : !canFinish
            ? T("There is no unfinished processing for this recording.", "Для этой записи нет незавершённой обработки.")
            : T("Try again whatever gave up or is waiting, keeping the transcript and every name typed by hand.",
                "Ещё раз попробовать то, что не получилось или ждёт, — расшифровка и имена, введённые вручную, остаются.");
        title.Text = item.Title;
        metadata.Text = MeetingPresentation.Date(item) + " · " + Math.Max(1, item.DurationSeconds / 60) + T(" min", " мин");
        player.Load(recording ? null : item.Directory);
        UpdateLayoutMode();
        problem.Text = item.Problem ?? "";
        problem.Visibility = item.Problem is null ? Visibility.Collapsed : Visibility.Visible;
        processingStatus.Text = row.Status is { IsBusy: true } status ? status.Message : row.TranscriptText;
        if (!item.HasAudio && !recording) processingStatus.Text += "\n" + noAudio;
        if (selectedTranscriptSession != item.Directory)
        {
            selectedTranscriptSession = item.Directory;
            selectedTranscriptKey = null;
        }
        var entries = item.Transcripts ?? [];
        var choices = entries.Select((entry, index) => new TranscriptChoice(entry,
            entry.EngineName + (entries.Count(other => other.Engine == entry.Engine) > 1 ? $" ({index + 1})" : "")
            + " · " + Row.Step(row.StateFor(entry)))).ToList();
        updatingChoices = true;
        engineTabs.ItemsSource = choices.Select(choice => new TabItem { Header = choice.Label, Tag = choice }).ToList();
        engineTabs.SelectedItem = engineTabs.Items.Cast<TabItem>().FirstOrDefault(tab => ((TranscriptChoice)tab.Tag).Key == selectedTranscriptKey)
            ?? engineTabs.Items.Cast<TabItem>().LastOrDefault();
        engineTabs.Visibility = choices.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        tabs.Margin = new Thickness(0, choices.Count > 1 ? 0 : 8, 0, 0);
        updatingChoices = false;
        await ShowTranscriptAsync();
        UpdateContentActions();
    }

    private async Task ShowTranscriptAsync()
    {
        var version = ++transcriptShown;
        transcriptContent.Content = transcript;
        transcript.ShowText("");
        summary.ShowText("");
        speakers.Children.Clear();
        var item = Selected?.Item;
        if (engineTabs.SelectedItem is not TabItem { Tag: TranscriptChoice choice })
        {
            var emptySummary = item is null ? "" : await ReadAsync(Path.Combine(item.Directory, "summary.md"))
                ?? T("No summary yet.", "Сводки пока нет.");
            if (version != transcriptShown) return;
            transcript.ShowText(T("No transcript yet.", "Расшифровки пока нет."));
            summary.ShowMarkdown(emptySummary);
            speakers.Children.Add(Ui.Detail(T("Speakers appear once there is a transcript.", "Участники появятся, когда будет расшифровка.")));
            return;
        }
        selectedTranscriptKey = choice.Key;
        if (navigation is not null) navigation.VersionKey = choice.Key;
        var directory = choice.Version.Directory;
        if (choice.Version.State != ProcessingStep.Done)
        {
            transcript.ShowText(choice.Label + "\n\n" + (item?.Problem ?? T("Earlier transcripts are available in the tabs above.", "Предыдущие расшифровки доступны во вкладках выше.")));
            summary.ShowText(T("No summary for this transcript yet.", "Сводки этой расшифровки пока нет."));
            speakers.Children.Add(Ui.Detail(T("Speakers appear once this transcript is ready.", "Участники появятся, когда эта расшифровка будет готова.")));
            return;
        }
        var text = await ReadAsync(Path.Combine(directory, "transcript.md")) ?? T("No transcript text available.", "Текст расшифровки недоступен.");
        var summaryText = await ReadAsync(Path.Combine(directory, "summary.md"))
            ?? (item?.Summary == ProcessingStep.Off ? T("Summaries are off.", "Создание сводки выключено.") : T("No summary yet.", "Сводки пока нет."));
        if (File.Exists(Path.Combine(directory, "summary.stale")))
            summaryText = T("This summary refers to the previous transcript.\n\n", "Это сводка предыдущей расшифровки.\n\n") + summaryText;
        if (version != transcriptShown) return;
        transcript.ShowTranscript(text, seconds => player.Seek(seconds));
        summary.ShowMarkdown(summaryText);
        if(item?.Calendar is { IsConfirmed: true, Participants.Count: > 0 } calendar)
            await ShowTranscriptParticipantsAsync(directory,calendar,version);
        await ShowSpeakersAsync(directory, item?.Title ?? "", version);
        UpdateContentActions();
    }

    private sealed record TranscriptChoice(TranscriptVersion Version, string Label)
    {
        public string Key => Version.State == ProcessingStep.Done ? $"{Version.Engine}:{Version.CreatedAt:O}" : "pending";
        public override string ToString() => Label;
    }

    private async Task ShowSpeakersAsync(string directory, string meetingTitle, int version)
    {
        var transcriptPath = Path.Combine(directory, "transcript.json");
        if (!File.Exists(transcriptPath))
        {
            speakers.Children.Add(Ui.Detail(T("Speakers appear once there is a transcript.", "Участники появятся, когда будет расшифровка.")));
            return;
        }
        TranscriptDocument? document;
        try { document = JsonSerializer.Deserialize<TranscriptDocument>(await File.ReadAllTextAsync(transcriptPath)); }
        catch (JsonException) { return; }
        if (document is null) return;
        var file = await SpeakerFile.ReadAsync(directory, CancellationToken.None);
        if (version != transcriptShown) return;
        if(Selected?.Item.Calendar is { IsConfirmed: true } calendar)
        {
            speakers.Children.Add(Ui.Heading(T("Invited from calendar", "Приглашённые из календаря")));
            speakers.Children.Add(Ui.Detail(T("An invitation does not confirm attendance.", "Приглашение не подтверждает присутствие на встрече.")));
            foreach(var person in calendar.Participants) speakers.Children.Add(Ui.Detail(person.Name+(person.Email is { } email ? " · "+email : "")));
            speakers.Children.Add(Ui.Heading(T("Speakers in the recording", "Говорящие в записи")));
        }
        foreach (var group in document.Segments.Where(segment => segment.Speaker is not null).GroupBy(segment => segment.Speaker!))
        {
            var label = group.Key;
            var row = new Grid { Margin = new Thickness(0, 0, 0, 12) };
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.RowDefinitions.Add(new RowDefinition());
            row.RowDefinitions.Add(new RowDefinition());
            row.RowDefinitions.Add(new RowDefinition());
            row.RowDefinitions.Add(new RowDefinition());
            var name = Ui.Title(SpeakerLabels.Display(label));
            name.FontWeight = FontWeights.SemiBold;
            name.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(name);
            var (view, box) = Ui.Field(T("name", "имя"), 210);
            box.Text = file.Names.GetValueOrDefault(label) ?? "";
            Grid.SetRow(view, 1);
            row.Children.Add(view);
            var source = file.Sources.GetValueOrDefault(label) switch
            {
                "manual" => T("by hand · ", "вручную · "),
                "model" => T("model · ", "модель · "),
                "account" => T("your account · ", "ваша учётная запись · "),
                _ => "",
            };
            var count = Ui.Status(source + T($"lines: {group.Count()}", $"реплик: {group.Count()}"));
            count.Margin = new Thickness(0, 4, 0, 4);
            Grid.SetRow(count, 2);
            row.Children.Add(count);
            var first = Ui.Detail(T("first: ", "первая: ") + group.First().Text.Trim());
            first.TextTrimming = TextTrimming.CharacterEllipsis;
            first.TextWrapping = TextWrapping.NoWrap;
            Grid.SetRow(first, 3);
            Grid.SetColumnSpan(first, 3);
            row.Children.Add(first);
            speakers.Children.Add(row);

            var stored = box.Text;
            async Task CommitAsync()
            {
                if (box.Text.Trim() == stored) return;
                stored = box.Text.Trim();
                try { await runtime.SetSpeakerNameAsync(directory, label, stored, title: meetingTitle); }
                catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException)
                {
                    Ui.ShowError(Ui.OwnerOf(layout), T("Couldn’t save the name", "Не удалось сохранить имя"), exception.Message);
                }
            }
            box.LostKeyboardFocus += async (_, _) => await CommitAsync();
            box.KeyDown += async (_, args) => { if (args.Key == Key.Enter) await CommitAsync(); };
        }
    }

    private async Task ShowTranscriptParticipantsAsync(string directory, MeetingCalendarMetadata calendar, int version)
    {
        var json = await ReadAsync(Path.Combine(directory,"transcript.json"));
        if(json is null) return;
        TranscriptDocument? document;
        try { document = JsonSerializer.Deserialize<TranscriptDocument>(json); } catch(JsonException) { return; }
        if(document?.IsDiarized != true) return;
        var names = await SpeakerFile.ReadAsync(directory,default);
        if(version != transcriptShown) return;
        var lines = new StackPanel { Margin = new Thickness(8,12,8,12) };
        lines.Children.Add(Ui.Detail(T("Choose an invited participant for a speaker. The choice applies to all their lines in this version.",
            "Выберите приглашённого участника для говорящего. Выбор применяется ко всем его репликам в этой версии.")));
        foreach(var segment in document.Segments)
        {
            var row = new StackPanel { Margin = new Thickness(0,18,0,8) };
            var timestamp = TimeSpan.FromMilliseconds(Math.Max(0, segment.StartMs));
            var seek = Ui.Button(timestamp.ToString(@"hh\:mm\:ss"), () => player.Seek(timestamp.TotalSeconds));
            seek.HorizontalAlignment = HorizontalAlignment.Left;
            System.Windows.Automation.AutomationProperties.SetName(seek, T("Play from ", "Воспроизвести с ") + timestamp);
            row.Children.Add(seek);
            if(segment.Speaker is { } speaker)
            {
                var combo = new System.Windows.Controls.ComboBox { MinWidth = 220, HorizontalAlignment = HorizontalAlignment.Left };
                combo.Items.Add(new ComboBoxItem { Content = SpeakerLabels.Display(speaker)+T(" · not matched", " · не сопоставлен"), Tag = null });
                foreach(var person in calendar.Participants)
                    combo.Items.Add(new ComboBoxItem { Content = person.Name+(person.Email is { } email ? " · "+email : ""), Tag = person });
                combo.SelectedItem = combo.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (i.Tag as CalendarParticipant)?.Id == names.ParticipantIds.GetValueOrDefault(speaker)) ?? combo.Items[0];
                System.Windows.Automation.AutomationProperties.SetName(combo,T("Who is speaking? ", "Кто говорит? ")+SpeakerLabels.Display(speaker));
                combo.IsEnabled = runtime.ProcessingStatusFor(Selected!.Item.Directory)?.IsBusy != true;
                combo.SelectionChanged += async (_, _) =>
                {
                    try { await runtime.SetSpeakerParticipantAsync(directory,speaker,(combo.SelectedItem as ComboBoxItem)?.Tag as CalendarParticipant); }
                    catch(Exception error) when(error is IOException or InvalidOperationException or UnauthorizedAccessException) { Ui.ShowError(Ui.OwnerOf(layout),"Verbemo",error.Message); }
                };
                row.Children.Add(combo);
            }
            var words = Ui.Title(segment.Text);
            words.Margin = new Thickness(0,8,0,0);
            row.Children.Add(words);
            lines.Children.Add(row);
        }
        transcriptContent.Content = Ui.Scroll(lines);
    }

    private void OpenRetranscribeMenu()
    {
        if (Selected is not { } row) return;
        var settings = runtime.Settings;
        var menu = new ContextMenu { PlacementTarget = retranscribe, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        void Add(string text, string? engine, bool enabled, string? why = null)
        {
            var item = new MenuItem { Header = text, IsEnabled = enabled, ToolTip = why };
            item.Click += async (_, _) =>
            {
                try
                {
                    retranscribe.IsEnabled = false;
                    processingStatus.Text = T("Starting transcription…", "Запускаю расшифровку…");
                    await runtime.RetranscribeAsync(row.Item.Directory, engine);
                    selectedTranscriptKey = "pending";
                    await ReloadAsync();
                }
                catch (Exception exception) when (exception is InvalidOperationException or IOException)
                {
                    Ui.ShowError(Ui.OwnerOf(layout), T("Couldn’t transcribe again", "Не удалось расшифровать заново"), exception.Message);
                    await ReloadAsync();
                }
            };
            menu.Items.Add(item);
        }
        Add(T("With the engine in Settings", "Движком из настроек"), null, true);
        menu.Items.Add(new Separator());
        foreach (var engine in TranscriptionSettings.CloudEngines)
        {
            var hasKey = !string.IsNullOrWhiteSpace(runtime.GetSecret(engine));
            Add(EngineResolver.DisplayName(engine) + T(" — uploads the audio", " — звук уходит в облако"), engine, hasKey,
                hasKey ? null : T("Add a key in Settings first.", "Сначала добавьте ключ в настройках."));
        }
        menu.Items.Add(new Separator());
        foreach (var engine in TranscriptionSettings.LocalEngines)
        {
            var ready = runtime.IsLocalModelReady(engine);
            Add(EngineResolver.DisplayName(engine) + T(" — on this computer", " — на этом компьютере"), engine, ready,
                ready ? null : T("Download the model in Settings first.", "Сначала скачайте модель в настройках."));
        }
        _ = settings;
        menu.IsOpen = true;
    }

    private void Listen(Row row)
    {
        var menu = new ContextMenu { PlacementTarget = listen };
        foreach(var path in AudioFiles(row.Item.Directory))
        {
            var item = new MenuItem { Header = Path.GetFileName(path) };
            item.Click += (_, _) => { runtime.TrackArtifact("audio"); VerbemoRuntime.Open(path); };
            menu.Items.Add(item);
        }
        if(menu.Items.Count > 0) menu.IsOpen = true;
    }

    internal static IReadOnlyList<string> AudioFiles(string directory)
    {
        if(!Directory.Exists(directory)) return [];
        var known = new[] { "audio.m4a", "mic.wav", "system.wav" }.Select(name => Path.Combine(directory,name));
        var imported = Directory.EnumerateFiles(directory,"source.*").Where(path => new[] { ".wav", ".m4a", ".mp3", ".flac", ".ogg", ".aac", ".wma", ".mp4", ".mov", ".mkv", ".webm" }.Contains(Path.GetExtension(path),StringComparer.OrdinalIgnoreCase));
        return known.Concat(imported).Where(File.Exists).Where(path => (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private void OpenFolder(Row row)
    {
        runtime.TrackArtifact("session_folder");
        VerbemoRuntime.Open(row.Item.Directory);
    }

    private void Delete(Row row)
    {
        var answer = System.Windows.MessageBox.Show(Ui.OwnerOf(layout) ?? this,
            T($"Delete “{row.Item.Title}” with its audio, transcript and summary?",
              $"«{row.Item.Title}» уйдёт в корзину вместе со звуком, расшифровкой и сводкой."),
            T("Delete this recording?", "Удалить запись?"), MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer != MessageBoxResult.OK) return;
        try
        {
            ScheduleDeletion(row.Item.Directory);
        }
        catch (Exception exception) when (exception is InvalidOperationException or IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            Ui.ShowError(Ui.OwnerOf(layout), T("Couldn’t delete the recording", "Не удалось удалить запись"), exception.Message);
        }
    }

    internal void ScheduleDeletion(string directory)
    {
        runtime.ScheduleDeletion(directory);
        if (undoButtons.ContainsKey(directory)) return;
        var undo = Ui.Button(T("Undo deletion", "Отменить удаление"), () => runtime.Deletions.Undo(directory));
        undo.Margin = new Thickness(12, 6, 12, 6);
        undoButtons.Add(directory, undo);
        deletionNotices.Children.Add(undo);
    }

    private static async Task<string?> ReadAsync(string path)
    {
        try
        {
            return await File.ReadAllTextAsync(path);
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException or IOException or UnauthorizedAccessException)
        {
            // Gone between the list and the click — a re-transcription clears it.
            return null;
        }
    }

    /// <summary>One line of the list, in words.</summary>
    private sealed class Row(SessionListItem item, ProcessingStatus? status)
    {
        public SessionListItem Item { get; } = item;
        public ProcessingStatus? Status { get; } = status;
        public bool IsPaused { get; init; }

        public string When => MeetingPresentation.Date(Item);
        public FrameworkElement View => MeetingListView.Card(Item, Status, IsPaused);

        public string Meeting => Item.DurationSeconds > 0
            ? $"{Item.Title} · {Math.Max(1, (int)Math.Round(Item.DurationSeconds / 60.0))} {T("min", "мин")}"
            : Item.Title;

        public ProcessingStep StateFor(TranscriptVersion version) => version.State != ProcessingStep.Done ? Status?.Stage switch
        {
            "transcribing" when Status.IsBusy => ProcessingStep.Transcribing,
            "queued" when Status.IsBusy => ProcessingStep.Pending,
            "deferred" => ProcessingStep.Deferred,
            "failed" => ProcessingStep.Failed,
            _ => version.State,
        } : version.State;

        public string TranscriptText => Item.Transcripts is { Count: > 0 } versions
            ? string.Join("\n", versions.Select(version => $"{version.EngineName} — {Step(StateFor(version))}"))
            : Item.Transcript switch
        {
            ProcessingStep.Done => T("done", "готово") + (Item.Engine is { } engine ? $" ({engine})" : ""),
            ProcessingStep.Recording => T("recording", "идёт запись"),
            ProcessingStep.Off => T("off", "выключено"),
            _ => Step(Status is { IsBusy: true, Stage: "transcribing" } ? ProcessingStep.Transcribing : Item.Transcript),
        };

        public string NamesText => Item.SpeakerCount > 0 ? $"{Item.NamedSpeakerCount}/{Item.SpeakerCount}"
            : Item.Transcript == ProcessingStep.Done ? Step(Item.SpeakerNames) : "";

        public string SummaryText => Status is { IsBusy: true, Stage: "summary" } ? Status.Message
            : Item.Summary == ProcessingStep.Pending && Item.Transcript is ProcessingStep.Pending or ProcessingStep.Transcribing
                ? T("after transcription", "после расшифровки") : Item.Summary switch
        {
            ProcessingStep.Stale => T("out of date", "устарело"),
            _ => Step(Item.Summary),
        };

        public static string Step(ProcessingStep step) => step switch
        {
            ProcessingStep.Done => T("done", "готово"),
            ProcessingStep.Off => T("off", "выключено"),
            ProcessingStep.Failed => T("failed", "не удалось"),
            ProcessingStep.Deferred => T("waiting", "ждёт"),
            ProcessingStep.Transcribing => T("transcribing…", "расшифровывается…"),
            _ => T("queued", "в очереди"),
        };
    }
}
