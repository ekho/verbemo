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
    public void Volume_and_speed_survive_switching_meetings() => ApplicationWindowTests.OnSta(() =>
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
            try
            {
                player.Load(Path.Combine(root, "first"));
                Tick();
                Assert.True(RecordingActionsTests.Field<ClockGroup>(player, "clock").IsPaused);
                var controls = ((DockPanel)((StackPanel)player.Child).Children[0]).Children;
                controls.OfType<Slider>().Single(slider => System.Windows.Automation.AutomationProperties.GetName(slider)
                    == Verbemo.Core.Localization.Localized.T("Playback volume", "Громкость воспроизведения")).Value = 0;
                controls.OfType<ComboBox>().Single().SelectedIndex = 4;
                player.Load(Path.Combine(root, "second"));
                Tick();
                Assert.All(RecordingActionsTests.Field<List<MediaPlayer>>(player, "players"), track => Assert.Equal(0, track.Volume));
                Assert.Equal(2, RecordingActionsTests.Field<ClockGroup>(player, "clock").Controller!.SpeedRatio);
                Assert.True(RecordingActionsTests.Field<ClockGroup>(player, "clock").IsPaused);
                player.Seek(.25, start: false);
                Tick();
                Assert.InRange(RecordingActionsTests.Field<ClockGroup>(player, "clock").CurrentTime!.Value.TotalSeconds, .24, .26);
                Assert.InRange(RecordingActionsTests.Field<Slider>(player, "position").Value, .24, .26);
            }
            finally { window.Close(); }
        }
        finally { Directory.Delete(root, true); }
    });

    private static void Tick()
    {
        var frame = new DispatcherFrame();
        var tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        tick.Tick += (_, _) => { tick.Stop(); frame.Continue = false; };
        tick.Start();
        Dispatcher.PushFrame(frame);
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
