using Framelo.Core;
using Framelo.Platform.Media;
using Xunit;

namespace Framelo.Platform.Tests;

public class MediaFoundationTests
{
    internal static string TempDir()
    {
        var d = Path.Combine(Path.GetTempPath(), "framelo-platform-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(d);
        return d;
    }

    /// <summary>Writes a synthetic clip: a moving bar on a gradient, with a 440 Hz tone.</summary>
    internal static string WriteClip(string path, int width, int height, int fps, double seconds, bool audio, bool fragmented)
    {
        using var writer = new MfWriter(path, new VideoSpec(width, height, fps, 4_000_000), audio ? new AudioSpec() : null, fragmented);
        var frame = new byte[width * height * 4];
        var frames = (int)(seconds * fps);
        for (var i = 0; i < frames; i++)
        {
            for (var y = 0; y < height; y++)
                for (var x = 0; x < width; x++)
                {
                    var o = (y * width + x) * 4;
                    var bar = Math.Abs(x - i * width / frames) < 8;
                    frame[o] = (byte)(bar ? 255 : x * 255 / width);
                    frame[o + 1] = (byte)(bar ? 255 : y * 255 / height);
                    frame[o + 2] = (byte)(bar ? 255 : 80);
                    frame[o + 3] = 255;
                }
            writer.WriteVideo(frame, width * 4, i * 10_000_000L / fps, 10_000_000L / fps);
        }
        if (audio)
        {
            var total = (int)(seconds * 48_000);
            var pcm = new short[total * 2];
            for (var i = 0; i < total; i++) pcm[2 * i] = pcm[2 * i + 1] = (short)(Math.Sin(2 * Math.PI * 440 * i / 48_000) * 8000);
            for (var start = 0; start < total; start += 4800)
            {
                var n = Math.Min(4800, total - start);
                writer.WriteAudio(pcm.AsSpan(start * 2, n * 2), start * 10_000_000L / 48_000);
            }
        }
        writer.Finish();
        return path;
    }

    [Fact]
    public void WritesAPlayableH264Mp4WithAudio()
    {
        var path = WriteClip(Path.Combine(TempDir(), "clip.mp4"), 320, 240, 30, 2, audio: true, fragmented: false);
        var facts = new MfInspector().Inspect(path);
        Assert.NotNull(facts);
        Assert.Equal(320, facts!.PixelWidth);
        Assert.Equal(240, facts.PixelHeight);
        Assert.True(facts.HasAudio);
        Assert.InRange(facts.Duration, 1.9, 2.1);
    }

    [Fact]
    public void FragmentedRecordingFilesAreReadable()
    {
        var path = WriteClip(Path.Combine(TempDir(), "screen.mp4"), 256, 144, 30, 3, audio: false, fragmented: true);
        var facts = new MfInspector().Inspect(path);
        Assert.NotNull(facts);
        Assert.False(facts!.HasAudio);
        Assert.InRange(facts.Duration, 2.8, 3.2);
    }

    [Fact]
    public void WavRecordingsAreReadableAfterHeaderRepair()
    {
        var path = Path.Combine(TempDir(), "microphone.wav");
        using (var wav = new WavFile(path, 48_000, 2, 32, isFloat: true))
            wav.Write(new byte[48_000 * 8]);
        // Simulate a crash before the last header update.
        using (var s = new FileStream(path, FileMode.Open)) { s.Position = 40; s.Write(new byte[4]); }
        Assert.True(WavFile.Repair(path));
        var facts = new MfInspector().Inspect(path);
        Assert.NotNull(facts);
        Assert.True(facts!.HasAudio);
        Assert.InRange(facts.Duration, 0.99, 1.01);
    }
}
