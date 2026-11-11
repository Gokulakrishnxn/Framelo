using System.Text.Json.Serialization;

namespace Framelo.Core;

public sealed record RgbaColor
{
    public double R { get; init; }
    public double G { get; init; }
    public double B { get; init; }
    public double A { get; init; } = 1;

    public RgbaColor() { }
    public RgbaColor(double r, double g, double b, double a = 1) { R = r; G = g; B = b; A = a; }

    public static RgbaColor FromHex(uint hex, double alpha = 1) =>
        new(((hex >> 16) & 0xFF) / 255.0, ((hex >> 8) & 0xFF) / 255.0, (hex & 0xFF) / 255.0, alpha);

    public static readonly RgbaColor White = new(1, 1, 1);
    public static readonly RgbaColor Black = new(0, 0, 0);
    public static readonly RgbaColor Clear = new(0, 0, 0, 0);
}

public enum AspectKind { Auto, Wide, Standard, Square, Vertical, Custom }

public sealed class AspectRatio
{
    public AspectKind Kind { get; set; } = AspectKind.Wide;
    public double CustomWidth { get; set; } = 16;
    public double CustomHeight { get; set; } = 10;

    public double Value(double sourceRatio) => Kind switch
    {
        AspectKind.Auto => sourceRatio > 0 ? sourceRatio : 16.0 / 9.0,
        AspectKind.Wide => 16.0 / 9.0,
        AspectKind.Standard => 4.0 / 3.0,
        AspectKind.Square => 1,
        AspectKind.Vertical => 9.0 / 16.0,
        _ => CustomHeight > 0 && CustomWidth > 0 ? CustomWidth / CustomHeight : 16.0 / 9.0,
    };

    public static string DisplayName(AspectKind k) => k switch
    {
        AspectKind.Auto => "Auto", AspectKind.Wide => "16:9", AspectKind.Standard => "4:3",
        AspectKind.Square => "1:1", AspectKind.Vertical => "9:16", _ => "Custom",
    };
}

public enum BackgroundKind { None, Solid, Gradient, Image, Wallpaper }

public sealed class BackgroundStyle
{
    public BackgroundKind Kind { get; set; } = BackgroundKind.Gradient;
    public RgbaColor Color { get; set; } = RgbaColor.FromHex(0x1B1B1F);
    public RgbaColor GradientStart { get; set; } = RgbaColor.FromHex(0x4F46E5);
    public RgbaColor GradientEnd { get; set; } = RgbaColor.FromHex(0xC026D3);
    /// <summary>Degrees, 0 = left→right, 90 = top→bottom.</summary>
    public double GradientAngle { get; set; } = 45;
    public string? ImagePath { get; set; }
    public double? Blur { get; set; }

    [JsonIgnore] public double BlurAmount => Math.Clamp(Blur ?? 0, 0, 1);
}

public sealed record CropRect
{
    public double X { get; init; }
    public double Y { get; init; }
    public double Width { get; init; } = 1;
    public double Height { get; init; } = 1;

    public static readonly CropRect Full = new();
    [JsonIgnore] public bool IsFull => X <= 0.0001 && Y <= 0.0001 && Width >= 0.9999 && Height >= 0.9999;

    public CropRect Clamped()
    {
        var w = Math.Clamp(Width, 0.05, 1);
        var h = Math.Clamp(Height, 0.05, 1);
        return new CropRect { X = Math.Clamp(X, 0, 1 - w), Y = Math.Clamp(Y, 0, 1 - h), Width = w, Height = h };
    }
}

public enum ScreenFrame { None, Window }

public sealed class ScreenStyle
{
    public double Padding { get; set; } = 0.07;
    public double CornerRadius { get; set; } = 0.018;
    public double ShadowOpacity { get; set; } = 0.45;
    public double ShadowRadius { get; set; } = 0.04;
    public ScreenFrame Frame { get; set; } = ScreenFrame.None;
    public CropRect? Crop { get; set; }
    public double? Inset { get; set; }

    [JsonIgnore] public CropRect EffectiveCrop => (Crop ?? CropRect.Full).Clamped();
    [JsonIgnore] public double InsetAmount => Math.Clamp(Inset ?? 0, 0, 0.1);
}

public enum ClickEffect { None, Ripple, Ring }

public sealed class CursorStyle
{
    public bool IsVisible { get; set; } = true;
    public double Size { get; set; } = 1.6;
    public double Smoothing { get; set; } = 0.55;
    public ClickEffect ClickEffect { get; set; } = ClickEffect.Ripple;
    public RgbaColor ClickColor { get; set; } = new(1, 1, 1, 0.9);
    public double PressScale { get; set; } = 0.85;
    public bool HidesWhenIdle { get; set; }
    public double IdleDelay { get; set; } = 3;
}

public enum CameraShape { Circle, RoundedRect }

public sealed class CameraStyle
{
    public bool IsVisible { get; set; } = true;
    public CameraShape Shape { get; set; } = CameraShape.Circle;
    public double Size { get; set; } = 0.24;
    public double PositionX { get; set; } = 0.88;
    public double PositionY { get; set; } = 0.82;
    public double CornerRadius { get; set; } = 0.2;
    public double BorderWidth { get; set; } = 0.012;
    public RgbaColor BorderColor { get; set; } = new(1, 1, 1, 0.9);
    public double ShadowOpacity { get; set; } = 0.4;
    public bool IsMirrored { get; set; } = true;
    public RgbaColor BackgroundColor { get; set; } = RgbaColor.Black;
    public double ZoomedScale { get; set; } = 0.8;
}

public sealed class MotionSettings
{
    public bool AutoZoomEnabled { get; set; } = true;
    public double DefaultZoomScale { get; set; } = 2;
    public double MotionBlur { get; set; } = 0.5;
    public double ZoomInDuration { get; set; } = 0.7;
    public double ZoomOutDuration { get; set; } = 0.8;
    public Easing Easing { get; set; } = Easing.EaseInOut;
}

public sealed class AudioSettings
{
    public double FadeIn { get; set; }
    public double FadeOut { get; set; }
}

public sealed class CaptionStyle
{
    public bool IsVisible { get; set; } = true;
    public double FontSize { get; set; } = 0.038;
    public RgbaColor Color { get; set; } = RgbaColor.White;
    public RgbaColor BackgroundColor { get; set; } = new(0, 0, 0, 0.65);
    public double PositionY { get; set; } = 0.9;
}

public enum ExportContainer { Mp4, Mov }
public enum ExportCodec { H264, Hevc }
public enum ExportResolution { P720, P1080, P2160 }
public enum ExportQuality { Standard, High, Maximum }

public sealed class ExportSettings
{
    public const int AudioBitRate = 192_000;

    public ExportContainer Container { get; set; } = ExportContainer.Mp4;
    public ExportCodec Codec { get; set; } = ExportCodec.H264;
    public ExportResolution Resolution { get; set; } = ExportResolution.P1080;
    public int FrameRate { get; set; } = 60;
    public ExportQuality Quality { get; set; } = ExportQuality.High;
    public string? Author { get; set; }

    public static int ShortSide(ExportResolution r) => r switch
    {
        ExportResolution.P720 => 720, ExportResolution.P1080 => 1080, _ => 2160,
    };

    public (int Width, int Height) CanvasSize(double aspect) => CanvasSize(ShortSide(Resolution), aspect);

    /// <summary>Even-sized pixel dimensions for a canvas of the given aspect ratio (width / height).</summary>
    public static (int Width, int Height) CanvasSize(int shortSide, double aspect)
    {
        static int Even(double v) => Math.Max(2, (int)Math.Round(v / 2, MidpointRounding.AwayFromZero) * 2);
        var a = aspect > 0 ? aspect : 16.0 / 9.0;
        return a >= 1 ? (Even(shortSide * a), Even(shortSide)) : (Even(shortSide), Even(shortSide / a));
    }

    public int VideoBitRate(int width, int height)
    {
        var bpp = Quality switch { ExportQuality.Standard => 0.07, ExportQuality.High => 0.12, _ => 0.2 };
        var codecFactor = Codec == ExportCodec.Hevc ? 0.6 : 1.0;
        return Math.Max(1_000_000, (int)(width * (double)height * FrameRate * bpp * codecFactor));
    }

    public long EstimatedFileSize(int width, int height, double duration, bool hasAudio) =>
        (long)((VideoBitRate(width, height) + (hasAudio ? AudioBitRate : 0)) * Math.Max(duration, 0) / 8);
}

/// <summary>A named look: background + screen styling.</summary>
public sealed record StylePreset(string Id, string Name, Func<BackgroundStyle> Background, Func<ScreenStyle> Screen)
{
    public static readonly IReadOnlyList<StylePreset> All = new[]
    {
        Grad("aurora", "Aurora", 0x4F46E5, 0xC026D3, 45),
        Grad("ocean", "Ocean", 0x0EA5E9, 0x1E3A8A, 60),
        Grad("sunset", "Sunset", 0xF97316, 0xDB2777, 30),
        Grad("forest", "Forest", 0x10B981, 0x064E3B, 70),
        new StylePreset("graphite", "Graphite",
            () => new BackgroundStyle { Kind = BackgroundKind.Solid, Color = RgbaColor.FromHex(0x18181B) },
            () => new ScreenStyle { Padding = 0.06, CornerRadius = 0.014, ShadowOpacity = 0.6 }),
        new StylePreset("paper", "Paper",
            () => new BackgroundStyle { Kind = BackgroundKind.Solid, Color = RgbaColor.FromHex(0xF4F4F5) },
            () => new ScreenStyle { Padding = 0.08, CornerRadius = 0.02, ShadowOpacity = 0.25 }),
        new StylePreset("window", "Window",
            () => new BackgroundStyle { Kind = BackgroundKind.Gradient, GradientStart = RgbaColor.FromHex(0x334155), GradientEnd = RgbaColor.FromHex(0x0F172A), GradientAngle = 90 },
            () => new ScreenStyle { Padding = 0.08, Frame = ScreenFrame.Window }),
        new StylePreset("clean", "Full Frame",
            () => new BackgroundStyle { Kind = BackgroundKind.None, Color = RgbaColor.Black },
            () => new ScreenStyle { Padding = 0, CornerRadius = 0, ShadowOpacity = 0 }),
    };

    private static StylePreset Grad(string id, string name, uint a, uint b, double angle) =>
        new(id, name,
            () => new BackgroundStyle { Kind = BackgroundKind.Gradient, GradientStart = RgbaColor.FromHex(a), GradientEnd = RgbaColor.FromHex(b), GradientAngle = angle },
            () => new ScreenStyle());
}
