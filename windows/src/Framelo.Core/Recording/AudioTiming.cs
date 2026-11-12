namespace Framelo.Core;

/// <summary>
/// Keeps a captured audio stream on the session clock. WASAPI loopback delivers nothing while the system is
/// silent, so the recorder asks how much silence to insert before each packet to keep sample count == time.
/// </summary>
public sealed class AudioTiming(int sampleRate)
{
    /// <summary>Gaps shorter than this are normal packet jitter and are left alone.</summary>
    public const double GapTolerance = 0.03;
    /// <summary>Largest believable clock difference between an audio device and the system clock (±0.3 %).</summary>
    public const double MaxDrift = 0.003;

    public int SampleRate { get; } = sampleRate;
    public double? StartOffset { get; private set; }
    public long FramesWritten { get; private set; }

    /// <summary>
    /// Call when a packet of <paramref name="frames"/> frames arrives at session time <paramref name="now"/>
    /// (the time its last frame was captured). Returns the number of silent frames to write first.
    /// </summary>
    public long SilenceBefore(long frames, double now)
    {
        var packetStart = now - (double)frames / SampleRate;
        if (StartOffset is not double start)
        {
            StartOffset = Math.Max(0, packetStart);
            return 0;
        }
        var expected = (long)Math.Round((packetStart - start) * SampleRate);
        var gap = expected - FramesWritten;
        return gap > GapTolerance * SampleRate ? gap : 0;
    }

    public void Wrote(long frames) => FramesWritten += frames;

    /// <summary>Silence needed at stop so the track lasts until <paramref name="end"/>.</summary>
    public long TailSilence(double end)
    {
        if (StartOffset is not double start) return 0;
        var expected = (long)Math.Round((end - start) * SampleRate);
        return Math.Max(0, expected - FramesWritten);
    }

    /// <summary>
    /// Rate correction for a track whose sample count disagrees with the clock. Only corrected when the error
    /// is within crystal tolerance; anything larger means lost packets, not drift, and is left alone.
    /// </summary>
    public static double RateCorrection(long frames, int sampleRate, double measuredSeconds)
    {
        if (frames <= 0 || measuredSeconds < 5) return 1;
        var ratio = (double)frames / sampleRate / measuredSeconds;
        return Math.Abs(ratio - 1) <= MaxDrift ? ratio : 1;
    }
}

public static class PcmConvert
{
    /// <summary>Float samples (−1…1) to 16-bit PCM with clipping.</summary>
    public static void FloatToInt16(ReadOnlySpan<float> source, Span<short> target)
    {
        for (var i = 0; i < source.Length; i++)
        {
            var v = Math.Clamp(source[i], -1f, 1f);
            target[i] = (short)Math.Round(v * 32767f);
        }
    }

    /// <summary>
    /// Linear-interpolating resampler with channel mapping (mono ↔ stereo, n → stereo by taking the first two).
    /// Used to bring every decoded source to the export's 48 kHz stereo.
    /// </summary>
    public static float[] Resample(ReadOnlySpan<float> source, int sourceRate, int sourceChannels, int targetRate, int targetChannels)
    {
        if (sourceChannels <= 0 || source.Length < sourceChannels) return Array.Empty<float>();
        var inFrames = source.Length / sourceChannels;
        var outFrames = sourceRate == targetRate ? inFrames : (int)Math.Round((double)inFrames * targetRate / sourceRate);
        var result = new float[outFrames * targetChannels];
        var step = (double)sourceRate / targetRate;
        for (var f = 0; f < outFrames; f++)
        {
            var pos = f * step;
            var i0 = Math.Min((int)pos, inFrames - 1);
            var i1 = Math.Min(i0 + 1, inFrames - 1);
            var frac = (float)(pos - i0);
            for (var c = 0; c < targetChannels; c++)
            {
                var sc = sourceChannels == 1 ? 0 : Math.Min(c, sourceChannels - 1);
                var a = source[i0 * sourceChannels + sc];
                var b = source[i1 * sourceChannels + sc];
                result[f * targetChannels + c] = a + (b - a) * frac;
            }
        }
        return result;
    }
}
