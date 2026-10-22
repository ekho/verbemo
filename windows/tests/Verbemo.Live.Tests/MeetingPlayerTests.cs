using Verbemo.App;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class MeetingPlayerTests
{
    [Fact]
    public void Volume_and_speed_survive_switching_meetings() => WithPlayer((player, root) =>
    {
        player.Load(Path.Combine(root, "first"));
        var controls = ((DockPanel)((StackPanel)player.Child).Children[0]).Children;
        controls.OfType<Slider>().Single(slider => System.Windows.Automation.AutomationProperties.GetName(slider)
            == Verbemo.Core.Localization.Localized.T("Playback volume", "Громкость воспроизведения")).Value = 0;
        controls.OfType<ComboBox>().Single().SelectedIndex = 4;
        player.Load(Path.Combine(root, "second"));
        Until(() => RecordingActionsTests.Field<ClockGroup>(player, "clock").IsPaused, player);
        Assert.All(RecordingActionsTests.Field<List<MediaPlayer>>(player, "players"), track => Assert.Equal(0, track.Volume));
        Assert.Equal(2, RecordingActionsTests.Field<ClockGroup>(player, "clock").Controller!.SpeedRatio);
    });

    [AudioPlaybackFact]
    public void Native_seek_waits_for_loading_and_stays_paused_after_unload() => WithPlayer((player, root) =>
    {
        player.Load(Path.Combine(root, "first"));
        Until(() => RecordingActionsTests.Field<List<MediaPlayer>>(player, "players").All(track => track.NaturalDuration.HasTimeSpan)
            && RecordingActionsTests.Field<ClockGroup>(player, "clock").IsPaused, player);
        player.Load(Path.Combine(root, "second"));
        player.Seek(.25);
        player.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.FrameworkElement.UnloadedEvent));
        Until(() => Math.Abs(RecordingActionsTests.Field<Slider>(player, "position").Value - .25) < .01, player);
        Assert.True(RecordingActionsTests.Field<ClockGroup>(player, "clock").IsPaused);
        Assert.InRange(RecordingActionsTests.Field<ClockGroup>(player, "clock").CurrentTime!.Value.TotalSeconds, .24, .26);
        Assert.InRange(RecordingActionsTests.Field<Slider>(player, "position").Value, .24, .26);
    });

    public sealed class AudioPlaybackFactAttribute : FactAttribute
    {
        public AudioPlaybackFactAttribute()
        {
            if (NAudio.Wave.WaveOut.DeviceCount == 0)
                Skip = "Requires a Windows playback device; run this native-media check on a Windows desktop before release.";
        }
    }

    private static void WithPlayer(Action<MeetingPlayer, string> test) => ApplicationWindowTests.OnSta(() =>
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-journal-player", Guid.NewGuid().ToString("N"));
        try
        {
            foreach (var name in new[] { "first", "second" })
            {
                var directory = Path.Combine(root, name);
                Directory.CreateDirectory(directory);
                using var wav = new NAudio.Wave.WaveFileWriter(Path.Combine(directory, "mic.wav"), new NAudio.Wave.WaveFormat(16000, 16, 1));
                wav.Write(new byte[32000], 0, 32000);
            }
            using var player = new MeetingPlayer();
            var window = new System.Windows.Window { Content = player, Width = 400, Height = 150 };
            window.Show();
            try { test(player, root); }
            finally { window.Close(); }
        }
        finally { Directory.Delete(root, true); }
    });

    private static void Until(Func<bool> condition, MeetingPlayer player)
    {
        var frame = new DispatcherFrame();
        var elapsed = System.Diagnostics.Stopwatch.StartNew();
        var tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
        tick.Tick += (_, _) => { if (condition() || elapsed.Elapsed > TimeSpan.FromSeconds(5)) { tick.Stop(); frame.Continue = false; } };
        tick.Start();
        Dispatcher.PushFrame(frame);
        Assert.True(condition(), "Timed out waiting for the native media clock. "
            + RecordingActionsTests.Field<TextBlock>(player, "error").Text
            + "; audio-devices=" + NAudio.Wave.WaveOut.DeviceCount
            + "; paused=" + RecordingActionsTests.Field<ClockGroup>(player, "clock").IsPaused
            + "; durations=" + string.Join(",", RecordingActionsTests.Field<List<MediaPlayer>>(player, "players").Select(track => track.NaturalDuration)));
    }

    [Fact]
    public void Archive_replaces_raw_tracks_and_raw_offsets_stay_on_the_meeting_timeline()
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-journal-player", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            File.WriteAllText(Path.Combine(root, "mic.wav"), "fixture");
            File.WriteAllText(Path.Combine(root, "system.wav"), "fixture");
            File.WriteAllText(Path.Combine(root, "meta.json"), "{\"start_offset_ms\":{\"mic\":250,\"system\":700}}");
            var tracks = MeetingPlayer.Tracks(root);
            Assert.Equal(new[] { 0.25, 0.7 }, tracks.Select(track => track.Offset));
            File.WriteAllText(Path.Combine(root, "audio.m4a"), "fixture");
            var archive = Assert.Single(MeetingPlayer.Tracks(root));
            Assert.Equal("audio.m4a", Path.GetFileName(archive.Path));
            Assert.Equal(0, archive.Offset);
            Assert.Equal("fixture", File.ReadAllText(Path.Combine(root, "mic.wav")));
        }
        finally { Directory.Delete(root, true); }
    }
}
