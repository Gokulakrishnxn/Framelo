using Framelo.Core;
using Framelo.Rendering;
using SkiaSharp;
using Xunit;

namespace Framelo.Rendering.Tests;

/// <summary>A synthetic source: left half red, right half blue, with a white square in the middle.</summary>
internal sealed class FakeFrames : IFrameSource
{
    private readonly SKImage _image;

    public FakeFrames(int width = 320, int height = 180)
    {
        using var bitmap = new SKBitmap(width, height);
        using (var c = new SKCanvas(bitmap))
        {
            c.DrawRect(0, 0, width / 2f, height, new SKPaint { Color = SKColors.Red });
            c.DrawRect(width / 2f, 0, width / 2f, height, new SKPaint { Color = SKColors.Blue });
            c.DrawRect(width / 2f - 10, height / 2f - 10, 20, 20, new SKPaint { Color = SKColors.White });
        }
        _image = SKImage.FromBitmap(bitmap);
    }

    public SKImage? Screen(MediaSource source, MediaTime sessionTime) => _image;
    public SKImage? Camera(MediaSource source, MediaTime sessionTime) => null;
}

public class RenderTests
{
    private static Project Project()
    {
        var source = new MediaSource
        {
            Kind = SourceKind.Recording, Name = "Test", Duration = 10,
            Screen = new MediaFile { RelativePath = "media/screen.mp4", Duration = 10, PixelWidth = 1920, PixelHeight = 1080 },
            Capture = new CaptureInfo { Width = 1920, Height = 1080, Scale = 1 },
        };
        var p = Core.Project.Make("Render", source);
        p.Settings.Aspect.Kind = AspectKind.Wide;
        return p;
    }

    private static Dictionary<Guid, CursorTrack> Cursor(Project p, double x = 0.25, double y = 0.5)
    {
        var track = new CursorTrack();
        for (var t = 0.0; t <= 10; t += 0.05) track.Samples.Add(new CursorSample(t, x, y));
        track.Clicks.Add(new ClickEvent(5, x, y) { ReleaseTime = 5.1 });
        return new Dictionary<Guid, CursorTrack> { [p.Sources[0].Id] = track };
    }

    private static SKColor Pixel(byte[] bgra, int width, int x, int y)
    {
        var o = (y * width + x) * 4;
        return new SKColor(bgra[o + 2], bgra[o + 1], bgra[o], bgra[o + 3]);
    }

    internal static void Save(byte[] bgra, int w, int h, string name)
    {
        var dir = Environment.GetEnvironmentVariable("FRAMELO_RENDER_OUT");
        if (string.IsNullOrEmpty(dir)) return;
        Directory.CreateDirectory(dir);
        using var bitmap = new SKBitmap(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
        System.Runtime.InteropServices.Marshal.Copy(bgra, 0, bitmap.GetPixels(), bgra.Length);
        using var data = bitmap.Encode(SKEncodedImageFormat.Png, 90);
        File.WriteAllBytes(Path.Combine(dir, name + ".png"), data.ToArray());
    }

    [Fact]
    public void DrawsBackgroundCardAndPicture()
    {
        var p = Project();
        p.Settings.Background = new BackgroundStyle { Kind = BackgroundKind.Solid, Color = RgbaColor.FromHex(0x00FF00) };
        var compositor = new Compositor(new RenderPlan(p, new Dictionary<Guid, CursorTrack>()));
        var px = compositor.RenderBgra(MediaTime.FromSeconds(1), 640, 360, new FakeFrames());
        Save(px, 640, 360, "card");
        Assert.Equal(SKColors.Lime, Pixel(px, 640, 3, 3));                      // background
        var left = Pixel(px, 640, 200, 180);
        Assert.True(left.Red > 200 && left.Blue < 60, $"left of card should be red, was {left}");
        var right = Pixel(px, 640, 440, 180);
        Assert.True(right.Blue > 200 && right.Red < 60, $"right of card should be blue, was {right}");
    }

    [Fact]
    public void ZoomMagnifiesTowardsTheTarget()
    {
        var p = Project();
        p.Settings.Screen.Padding = 0;
        p.Settings.Screen.CornerRadius = 0;
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(1), EndTime = MediaTime.FromSeconds(9), Scale = 4, TargetX = 0.5, TargetY = 0.5, FollowsCursor = false });
        var compositor = new Compositor(new RenderPlan(p, new Dictionary<Guid, CursorTrack>()));
        var px = compositor.RenderBgra(MediaTime.FromSeconds(5), 640, 360, new FakeFrames());
        Save(px, 640, 360, "zoom");
        // The 20-px white square of a 320-px source covers 1/16 of the width; at 4× it covers a quarter of the frame.
        Assert.Equal(SKColors.White, Pixel(px, 640, 320 + 60, 180));
        var outside = Pixel(px, 640, 320 + 100, 180);
        Assert.True(outside.Blue > 200, $"just outside the square should be blue, was {outside}");
    }

    [Fact]
    public void DrawsTheCursorAndClickRipple()
    {
        var p = Project();
        p.Settings.Screen.Padding = 0;
        p.Settings.Cursor.Size = 3;
        var without = new Compositor(new RenderPlan(p, new Dictionary<Guid, CursorTrack>())).RenderBgra(MediaTime.FromSeconds(5.2), 640, 360, new FakeFrames());
        var with = new Compositor(new RenderPlan(p, Cursor(p))).RenderBgra(MediaTime.FromSeconds(5.2), 640, 360, new FakeFrames());
        Save(with, 640, 360, "cursor");
        var differing = 0;
        for (var i = 0; i < with.Length; i += 4) if (with[i] != without[i] || with[i + 2] != without[i + 2]) differing++;
        Assert.InRange(differing, 200, 640 * 360 / 4);
    }

    [Fact]
    public void PreviewAndExportProduceIdenticalPixels()
    {
        // Preview and export build separate plans and compositors; they must agree byte for byte.
        var p = Project();
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(1), EndTime = MediaTime.FromSeconds(6), Scale = 2.5 });
        p.Settings.Screen.Frame = ScreenFrame.Window;
        var cursor = Cursor(p);
        var preview = new Compositor(new RenderPlan(p, cursor));
        var export = new Compositor(new RenderPlan(ProjectJson.Deserialize(ProjectJson.Serialize(p)), cursor));
        foreach (var t in new[] { 0.5, 1.3, 3.0, 5.25, 5.9, 8.0 })
            Assert.Equal(preview.RenderBgra(MediaTime.FromSeconds(t), 480, 270, new FakeFrames()),
                         export.RenderBgra(MediaTime.FromSeconds(t), 480, 270, new FakeFrames()));
    }

    [Fact]
    public void GapsShowOnlyTheBackground()
    {
        var p = Project();
        TimelineEditor.Split(p.Timeline, MediaTime.FromSeconds(5));
        TimelineEditor.Move(p.Timeline, p.Timeline.VideoClips[1].Id, MediaTime.FromSeconds(7));
        p.Settings.Background = new BackgroundStyle { Kind = BackgroundKind.Solid, Color = RgbaColor.Black };
        p.Settings.Screen.ShadowOpacity = 0;
        var px = new Compositor(new RenderPlan(p, new Dictionary<Guid, CursorTrack>())).RenderBgra(MediaTime.FromSeconds(6), 320, 180, new FakeFrames());
        Assert.All(Enumerable.Range(0, 320 * 180), i => Assert.Equal(0, px[i * 4] | px[i * 4 + 1] | px[i * 4 + 2]));
    }
}
