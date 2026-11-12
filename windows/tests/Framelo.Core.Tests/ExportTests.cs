using System.Text;
using Framelo.Core;
using Xunit;

namespace Framelo.Core.Tests;

public class ExportTests
{
    [Fact]
    public void PlansExactFrameTimesAndEvenSizes()
    {
        var p = TestData.Project(10);
        var plan = ExportPlan.For(p, new ExportSettings { Resolution = ExportResolution.P1080, FrameRate = 30 }, hasAudio: true);
        Assert.Equal((1920, 1080), (plan.Width, plan.Height));
        Assert.Equal(300, plan.FrameCount);
        Assert.Equal(MediaTime.FromSeconds(1), plan.FrameTime(30));
        p.Settings.Aspect.Kind = AspectKind.Vertical;
        var vertical = ExportPlan.For(p, new ExportSettings { Resolution = ExportResolution.P720 }, false);
        Assert.Equal((720, 1280), (vertical.Width, vertical.Height));
    }

    [Fact]
    public void VerificationCatchesBadFiles()
    {
        var plan = ExportPlan.For(TestData.Project(10), new ExportSettings { FrameRate = 60 }, hasAudio: true);
        ExportVerifier.Verify(new MediaFacts(10.01, 1920, 1080, true, true, "h264", 60), plan);
        Assert.Throws<ExportVerificationException>(() => ExportVerifier.Verify(new MediaFacts(9, 1920, 1080, true, true, "h264", 60), plan));
        Assert.Throws<ExportVerificationException>(() => ExportVerifier.Verify(new MediaFacts(10, 1280, 720, true, true, "h264", 60), plan));
        Assert.Throws<ExportVerificationException>(() => ExportVerifier.Verify(new MediaFacts(10, 1920, 1080, false, true, "h264", 60), plan));
        Assert.Throws<ExportVerificationException>(() => ExportVerifier.Verify(null, plan));
    }

    private static byte[] Box(string type, byte[] payload)
    {
        var b = new byte[8 + payload.Length];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(b, (uint)b.Length);
        Encoding.ASCII.GetBytes(type).CopyTo(b, 4);
        payload.CopyTo(b, 8);
        return b;
    }

    [Fact]
    public void AddsAuthorToAFinalMoovWithoutMovingMediaData()
    {
        var path = Path.Combine(TestData.TempDir(), "a.mp4");
        var mdat = Box("mdat", new byte[100]);
        var moov = Box("moov", Box("mvhd", new byte[20]));
        File.WriteAllBytes(path, Box("ftyp", Encoding.ASCII.GetBytes("isom")).Concat(mdat).Concat(moov).ToArray());
        var before = File.ReadAllBytes(path);
        Assert.True(Mp4Metadata.AddAuthor(path, "Ada", "Demo"));
        var after = File.ReadAllBytes(path);
        Assert.Equal(before.AsSpan(0, before.Length - moov.Length).ToArray(), after.AsSpan(0, before.Length - moov.Length).ToArray());
        var moovStart = before.Length - moov.Length;
        Assert.Equal(after.Length - moovStart, (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(after.AsSpan(moovStart)));
        Assert.Contains("Ada", Encoding.UTF8.GetString(after));
        Assert.False(Mp4Metadata.AddAuthor(path, null, null));
    }
}
