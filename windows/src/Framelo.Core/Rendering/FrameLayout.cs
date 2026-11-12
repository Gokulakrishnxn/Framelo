namespace Framelo.Core;

public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public RectD Inset(double d) => new(X + d, Y + d, Math.Max(0, Width - 2 * d), Math.Max(0, Height - 2 * d));
}

/// <summary>Geometry of a frame on a canvas of a given pixel size. Pure; shared by the renderer and UI hit-testing.</summary>
public sealed class FrameLayout
{
    public double CanvasWidth { get; }
    public double CanvasHeight { get; }
    /// <summary>The screen card (picture plus optional window title bar), before the camera transform.</summary>
    public RectD Card { get; }
    /// <summary>The screen picture inside the card.</summary>
    public RectD Content { get; }
    public double TitleBarHeight { get; }
    public double CornerRadius { get; }
    public double ShadowRadius { get; }
    /// <summary>Cursor sprite box height in canvas pixels at size 1.</summary>
    public double CursorUnit { get; }
    public CropRect Crop { get; }

    public FrameLayout(Project project, double width, double height)
    {
        CanvasWidth = width;
        CanvasHeight = height;
        var style = project.Settings.Screen;
        var shortSide = Math.Min(width, height);
        var padding = style.Padding * shortSide;
        var availableW = Math.Max(1, width - 2 * padding);
        var availableH = Math.Max(1, height - 2 * padding);
        var aspect = project.SourceAspect;
        // The title bar scales with the card, so solve for the picture width that makes picture + bar fit.
        var barRatio = style.Frame == ScreenFrame.Window ? 0.045 : 0;
        var cardAspect = 1 / (1 / aspect + barRatio);
        var w = availableW;
        var h = w / cardAspect;
        if (h > availableH) { h = availableH; w = h * cardAspect; }
        Card = new RectD((width - w) / 2, (height - h) / 2, w, h);
        TitleBarHeight = w * barRatio;
        Crop = style.EffectiveCrop;
        var inset = style.InsetAmount * shortSide;
        Content = new RectD(Card.X, Card.Y + TitleBarHeight, w, h - TitleBarHeight).Inset(inset);
        CornerRadius = Math.Min(style.CornerRadius * shortSide, Math.Min(w, h) / 2);
        ShadowRadius = style.ShadowRadius * shortSide;
        // A system cursor is drawn in a 32-point box; keep that proportion relative to the captured height in points.
        var capturedHeight = project.Sources.FirstOrDefault(s => s.Capture != null)?.Capture?.Height ?? 1080;
        CursorUnit = Content.Height * 32 / (Math.Max(capturedHeight, 1) * Crop.Height);
    }

    /// <summary>Canvas pixel of a point in normalised content coordinates (recorded relative to the full picture).</summary>
    public (double X, double Y) ContentPoint(double x, double y)
    {
        var cx = (x - Crop.X) / Crop.Width;
        var cy = (y - Crop.Y) / Crop.Height;
        return (Content.X + cx * Content.Width, Content.Y + cy * Content.Height);
    }

    /// <summary>Camera centre on the canvas. At scale 1 it is the canvas centre, so an un-zoomed frame is undisturbed.</summary>
    public (double X, double Y) CameraCentre(CameraState camera)
    {
        var amount = Math.Clamp((camera.Scale - 1) / 0.25, 0, 1);
        var target = ContentPoint(camera.CenterX, camera.CenterY);
        var rest = (X: CanvasWidth / 2, Y: CanvasHeight / 2);
        return (rest.X + (target.X - rest.X) * amount, rest.Y + (target.Y - rest.Y) * amount);
    }

    /// <summary>Picture-in-picture rectangle on the canvas for a camera of the given aspect (width / height).</summary>
    public RectD PipRect(FrameState.Pip pip, CameraShape shape, double cameraAspect)
    {
        var h = pip.Height * CanvasHeight;
        var w = shape == CameraShape.Circle ? h : h * Math.Clamp(cameraAspect, 0.5, 2);
        return new RectD(pip.CenterX * CanvasWidth - w / 2, pip.CenterY * CanvasHeight - h / 2, w, h);
    }
}
