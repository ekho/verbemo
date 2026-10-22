using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using static Verbemo.Core.Localization.Localized;

namespace Verbemo.App;

internal sealed class MeetingPlayer : Border, IDisposable
{
    private readonly Button play;
    private readonly Slider position = new() { Minimum = 0, Maximum = 0, MinWidth = 60, IsEnabled = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock time = Ui.Status("00:00 / 00:00");
    private readonly TextBlock error = Ui.Status("", Ui.Caution);
    private readonly List<MediaPlayer> players = [];
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(200) };
    private ClockGroup? clock;
    private string? directory;
    private bool playing;
    private bool refreshing;
    private bool dragging;
    private double playbackSpeed = 1;
    private double playbackVolume = .5;
    private (double Seconds, bool Start)? pendingSeek;

    public MeetingPlayer()
    {
        CornerRadius = new CornerRadius(8);
        Padding = new Thickness(10);
        Margin = new Thickness(0, 0, 0, 12);
        SetResourceReference(BackgroundProperty, "JournalInset");
        var body = new DockPanel();
        play = JournalStyle.IconButton("\uE768", T("Play or pause meeting", "Слушать или приостановить встречу"), Toggle);
        play.IsEnabled = false;
        Visibility = Visibility.Collapsed;
        DockPanel.SetDock(play, Dock.Left);
        body.Children.Add(play);
        var speed = new ComboBox { Width = 80, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        foreach (var rate in new[] { 0.75, 1, 1.25, 1.5, 2 }) speed.Items.Add(new ComboBoxItem { Content = rate.ToString("0.##") + "×", Tag = rate });
        speed.SelectedIndex = 1;
        System.Windows.Automation.AutomationProperties.SetName(speed, T("Playback speed", "Скорость воспроизведения"));
        speed.SelectionChanged += (_, _) =>
        {
            if (speed.SelectedItem is not ComboBoxItem { Tag: double rate }) return;
            playbackSpeed = rate;
            if (clock?.Controller is { } controller) controller.SpeedRatio = rate;
        };
        DockPanel.SetDock(speed, Dock.Right);
        body.Children.Add(speed);
        var volume = new Slider { Minimum = 0, Maximum = 1, Value = .5, Width = 56, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        System.Windows.Automation.AutomationProperties.SetName(volume, T("Playback volume", "Громкость воспроизведения"));
        volume.ValueChanged += (_, _) => { playbackVolume = volume.Value; foreach (var player in players) player.Volume = playbackVolume; };
        DockPanel.SetDock(volume, Dock.Right);
        body.Children.Add(volume);
        time.Margin = new Thickness(10, 0, 0, 0);
        DockPanel.SetDock(time, Dock.Right);
        body.Children.Add(time);
        position.Margin = new Thickness(8, 0, 0, 0);
        System.Windows.Automation.AutomationProperties.SetName(position, T("Meeting playback position", "Позиция воспроизведения встречи"));
        position.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => dragging = true));
        position.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => { dragging = false; Seek(position.Value, playing); }));
        position.ValueChanged += (_, _) => { if (!refreshing && !dragging) Seek(position.Value, playing); };
        body.Children.Add(position);
        var content = new StackPanel();
        content.Children.Add(body);
        content.Children.Add(error);
        Child = content;
        timer.Tick += (_, _) => Refresh();
        Unloaded += (_, _) => Pause();
    }

    internal static IReadOnlyList<(string Path, double Offset)> Tracks(string directory)
    {
        var paths = RecordingsWindow.AudioFiles(directory);
        var archive = paths.FirstOrDefault(path => Path.GetFileName(path) == "audio.m4a");
        if (archive is not null) return [(archive, 0)];
        var raw = paths.Where(path => Path.GetFileName(path) is "mic.wav" or "system.wav").ToArray();
        if (raw.Length == 0) return paths.Take(1).Select(path => (path, 0d)).ToArray();
        var offsets = new Dictionary<string, double>();
        var metadata = Path.Combine(directory, "meta.json");
        if (File.Exists(metadata))
        {
            using var json = JsonDocument.Parse(File.ReadAllText(metadata));
            if (json.RootElement.TryGetProperty("start_offset_ms", out var values))
                foreach (var key in new[] { "mic", "system" })
                    if (values.ValueKind == JsonValueKind.Object && values.TryGetProperty(key, out var value) && value.TryGetDouble(out var ms) && double.IsFinite(ms))
                        offsets[key] = Math.Max(0, ms / 1000);
        }
        return raw.Select(path => (path, offsets.GetValueOrDefault(Path.GetFileNameWithoutExtension(path)))).ToArray();
    }

    public void Load(string? value)
    {
        if (directory == value) return;
        DisposeMedia();
        directory = value;
        error.Text = "";
        Refresh();
        if (value is null) return;
        try
        {
            var tracks = Tracks(value);
            var timeline = new ParallelTimeline { Duration = Duration.Forever };
            foreach (var track in tracks)
                timeline.Children.Add(new MediaTimeline(new Uri(track.Path)) { BeginTime = TimeSpan.FromSeconds(track.Offset) });
            clock = (ClockGroup)timeline.CreateClock(true);
            clock.CurrentTimeInvalidated += (_, _) => { if (!playing) Refresh(); };
            clock.Controller!.Pause();
            clock.Controller!.SpeedRatio = playbackSpeed;
            for (var index = 0; index < tracks.Count; index++)
            {
                var player = new MediaPlayer { Volume = playbackVolume };
                var offset = tracks[index].Offset;
                player.MediaOpened += (_, _) =>
                {
                    if (!players.Contains(player)) return;
                    if (player.NaturalDuration.HasTimeSpan) position.Maximum = Math.Max(position.Maximum, offset + player.NaturalDuration.TimeSpan.TotalSeconds);
                    if (players.All(track => track.NaturalDuration.HasTimeSpan) && pendingSeek is { } request)
                    {
                        pendingSeek = null;
                        Seek(request.Seconds, request.Start);
                    }
                };
                player.MediaFailed += (_, args) => { if (!players.Contains(player)) return; Pause(); error.Text = T("Cannot play audio: ", "Не удалось воспроизвести звук: ") + args.ErrorException.Message; };
                players.Add(player);
                player.Clock = (MediaClock)clock.Children[index];
            }
            play.IsEnabled = position.IsEnabled = tracks.Count > 0;
            Visibility = tracks.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or ArgumentException)
        {
            DisposeMedia();
            error.Text = exception.Message;
            Visibility = Visibility.Visible;
        }
    }

    private void Toggle()
    {
        if (playing) Pause();
        else Seek(position.Value >= position.Maximum ? 0 : position.Value, true);
    }

    public void Seek(double seconds, bool start = true)
    {
        if (clock?.Controller is not { } controller || players.Count == 0) return;
        seconds = Math.Max(0, double.IsFinite(seconds) ? seconds : 0);
        if (players.Any(player => !player.NaturalDuration.HasTimeSpan)) { pendingSeek = (seconds, start); return; }
        if (clock.CurrentState == ClockState.Stopped) controller.Begin();
        controller.Seek(TimeSpan.FromSeconds(seconds), TimeSeekOrigin.BeginTime);
        if (start) { controller.Resume(); playing = true; timer.Start(); }
        else controller.Pause();
        Refresh();
    }

    private void Pause()
    {
        if (pendingSeek is { } request) pendingSeek = (request.Seconds, false);
        clock?.Controller?.Pause(); playing = false; timer.Stop(); Refresh();
    }
    private void Refresh()
    {
        var elapsed = clock?.CurrentTime?.TotalSeconds ?? 0;
        refreshing = true;
        if (!dragging) position.Value = Math.Min(position.Maximum, elapsed);
        refreshing = false;
        time.Text = Format(elapsed) + " / " + Format(position.Maximum);
        ((TextBlock)play.Content).Text = playing ? "\uE769" : "\uE768";
        if (playing && position.Maximum > 0 && elapsed >= position.Maximum) Pause();
    }
    private static string Format(double seconds) => TimeSpan.FromSeconds(Math.Max(0, seconds)).ToString(seconds >= 3600 ? @"hh\:mm\:ss" : @"mm\:ss");
    private void DisposeMedia()
    {
        timer.Stop(); playing = false; pendingSeek = null;
        clock?.Controller?.Stop(); clock = null;
        foreach (var player in players) { player.Clock = null; player.Close(); }
        players.Clear();
        refreshing = true; position.Maximum = 0; position.Value = 0; refreshing = false;
        play.IsEnabled = position.IsEnabled = false;
    }
    public void Dispose() { DisposeMedia(); directory = null; }
}
