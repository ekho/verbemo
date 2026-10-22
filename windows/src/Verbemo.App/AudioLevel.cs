using System.Buffers.Binary;
using System.Diagnostics;
using NAudio.Wave;

namespace Verbemo.App;

internal sealed class AudioLevel
{
    private readonly object gate = new();
    private double peak;
    private long updated;

    internal void Update(ReadOnlySpan<byte> data, WaveFormat format, bool silent)
    {
        var value = Peak(data, format, silent);
        lock (gate) { peak = value; updated = Stopwatch.GetTimestamp(); }
    }
    internal double? Decibels
    {
        get
        {
            lock (gate) return updated == 0 || Stopwatch.GetElapsedTime(updated).TotalSeconds > 0.5
                ? null : Math.Clamp(20 * Math.Log10(Math.Max(peak, 0.001)), -60, 0);
        }
    }
    internal void Reset() { lock (gate) { peak = 0; updated = 0; } }

    internal static double Peak(ReadOnlySpan<byte> data, WaveFormat format, bool silent)
    {
        if (silent) return 0;
        var floating = format.Encoding == WaveFormatEncoding.IeeeFloat || format is WaveFormatExtensible ext
            && ext.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
        var bytes = format.BitsPerSample / 8;
        if (bytes is < 1 or > 4 || floating && bytes != 4 || format.BlockAlign <= 0) return 0;
        double maximum = 0;
        for (var frame = 0; frame + format.BlockAlign <= data.Length; frame += format.BlockAlign)
            for (var channel = 0; channel < format.Channels; channel++)
            {
                var sample = data.Slice(frame + channel * bytes, bytes);
                var value = floating ? BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(sample)) : bytes switch
                {
                    1 => (sample[0] - 128) / 128d,
                    2 => BinaryPrimitives.ReadInt16LittleEndian(sample) / 32768d,
                    3 => ((sample[0] | sample[1] << 8 | sample[2] << 16) << 8 >> 8) / 8388608d,
                    _ => BinaryPrimitives.ReadInt32LittleEndian(sample) / 2147483648d,
                };
                if (double.IsFinite(value)) maximum = Math.Max(maximum, Math.Min(1, Math.Abs(value)));
            }
        return maximum;
    }
}
