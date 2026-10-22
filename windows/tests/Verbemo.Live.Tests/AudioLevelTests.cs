using NAudio.Wave;
using Verbemo.App;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class AudioLevelTests
{
    [Fact]
    public void Peak_uses_both_channels_and_rejects_non_finite_samples()
    {
        var format = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);
        var data = new[] { 0f, -.5f, float.NaN, float.PositiveInfinity }.SelectMany(BitConverter.GetBytes).ToArray();
        Assert.Equal(.5, AudioLevel.Peak(data, format, false));
        Assert.Equal(0, AudioLevel.Peak(data, format, true));
        var meter = new AudioLevel();
        Assert.Null(meter.Decibels);
        meter.Update(data, format, false);
        Assert.InRange(meter.Decibels!.Value, -6.03, -6.01);
        meter.Reset();
        Assert.Null(meter.Decibels);
    }

    [Fact]
    public void Pcm_peak_and_silence_use_the_same_scale()
    {
        var format = new WaveFormat(48000, 16, 2);
        Assert.Equal(.5, AudioLevel.Peak(new byte[] { 0, 0, 0, 64 }, format, false));
        var level = new AudioLevel();
        level.Update(new byte[8], format, false);
        Assert.Equal(-60, level.Decibels);
    }
}
