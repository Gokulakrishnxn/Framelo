using Framelo.Core;
using SkiaSharp;

namespace Framelo.Rendering;

/// <summary>
/// Vector cursors drawn by the renderer (the system cursor is never captured). Each sprite is designed in a
/// 32 × 32 box; the hotspot is the point that sits on the recorded position.
/// </summary>
public static class CursorSprites
{
    public static SKPoint Hotspot(CursorKind kind) => kind switch
    {
        CursorKind.IBeam => new SKPoint(16, 16),
        CursorKind.PointingHand => new SKPoint(12.5f, 4),
        _ => new SKPoint(6, 3),
    };

    private static readonly SKPath Arrow = SKPath.ParseSvgPathData(
        "M6 3 L6 25.5 L11.2 20.6 L14.6 28.4 L18.4 26.8 L15.1 19.2 L22.2 19.2 Z");
    private static readonly SKPath IBeam = SKPath.ParseSvgPathData(
        "M12 6 L15 6 Q16 6.6 17 6 L20 6 L20 8 L17 8 L17 24 L20 24 L20 26 L17 26 Q16 25.4 15 26 L12 26 L12 24 L15 24 L15 8 L12 8 Z");
    private static readonly SKPath Hand = SKPath.ParseSvgPathData(
        "M11 4.5 Q12.5 3 14 4.5 L14 14 L14.5 11.5 Q16 10.3 17.4 11.6 L17.6 14.5 L18.2 12.6 Q19.7 11.6 20.9 13 L21.1 15.6 " +
        "L21.7 14.3 Q23.2 13.6 24.2 15.1 L24.2 21.5 Q24 26 21 28.6 L13.6 28.6 Q12 27.4 10.6 25 L7 18.9 Q6.3 17.2 7.8 16.5 " +
        "Q9.3 16 10.4 17.4 L11 18.6 Z");

    /// <summary>Draws a cursor whose 32-unit box is <paramref name="size"/> pixels, with its hotspot at (x, y).</summary>
    public static void Draw(SKCanvas canvas, CursorKind kind, float x, float y, float size, float opacity)
    {
        var path = kind switch { CursorKind.IBeam => IBeam, CursorKind.PointingHand => Hand, _ => Arrow };
        var hot = Hotspot(kind);
        var s = size / 32f;
        canvas.Save();
        canvas.Translate(x - hot.X * s, y - hot.Y * s);
        canvas.Scale(s);
        var alpha = (byte)(Math.Clamp(opacity, 0, 1) * 255);
        using (var shadow = new SKPaint { IsAntialias = true, Color = new SKColor(0, 0, 0, (byte)(alpha * 0.35)), MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 1.2f) })
        {
            canvas.Save();
            canvas.Translate(0, 1.2f);
            canvas.DrawPath(path, shadow);
            canvas.Restore();
        }
        var dark = kind == CursorKind.IBeam;
        using (var fill = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Fill, Color = dark ? new SKColor(0, 0, 0, alpha) : new SKColor(255, 255, 255, alpha) })
            canvas.DrawPath(path, fill);
        using (var stroke = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 1.5f, StrokeJoin = SKStrokeJoin.Round, Color = dark ? new SKColor(255, 255, 255, alpha) : new SKColor(0, 0, 0, alpha) })
            canvas.DrawPath(path, stroke);
        canvas.Restore();
    }
}
