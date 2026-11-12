using Framelo.Core;
using Xunit;

namespace Framelo.Core.Tests;

public class RecordingTimingTests
{
    [Fact]
    public void LoopbackSilenceIsFilledSoSamplesMatchTheClock()
    {
        var timing = new AudioTiming(48_000);
        Assert.Equal(0, timing.SilenceBefore(480, 1.01));       // first packet sets the start (1.0 s)
        timing.Wrote(480);
        Assert.Equal(0, timing.SilenceBefore(480, 1.02));       // contiguous
        timing.Wrote(480);
        var gap = timing.SilenceBefore(480, 3.02);              // nothing played from 1.02 s to 3.01 s
        Assert.InRange(gap, 95_510, 95_530);
        timing.Wrote(gap + 480);
        Assert.InRange(timing.TailSilence(4.02), 47_990, 48_010);
    }

    [Fact]
    public void SmallJitterIsNotTreatedAsAGap()
    {
        var timing = new AudioTiming(48_000);
        timing.SilenceBefore(480, 0.01);
        timing.Wrote(480);
        Assert.Equal(0, timing.SilenceBefore(480, 0.035));
    }

    [Fact]
    public void DriftIsCorrectedOnlyWithinCrystalTolerance()
    {
        Assert.Equal(1.001, AudioTiming.RateCorrection(48_048_000, 48_000, 1000), 6);
        Assert.Equal(1, AudioTiming.RateCorrection(47_000_000, 48_000, 1000));
        Assert.Equal(1, AudioTiming.RateCorrection(1000, 48_000, 1));
    }

    [Fact]
    public void ResamplesAndMapsChannels()
    {
        var mono = Enumerable.Range(0, 441).Select(i => (float)i / 441).ToArray();
        var stereo = PcmConvert.Resample(mono, 44_100, 1, 48_000, 2);
        Assert.Equal(480 * 2, stereo.Length);
        Assert.Equal(stereo[0], stereo[1]);
        Assert.True(stereo[^2] > 0.99f);
        var pcm = new short[3];
        PcmConvert.FloatToInt16(new[] { 2f, -1f, 0.5f }, pcm);
        Assert.Equal(new short[] { 32767, -32767, 16384 }, pcm);
    }
}
