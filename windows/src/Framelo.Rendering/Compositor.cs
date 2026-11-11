using Framelo.Core;
using SkiaSharp;

namespace Framelo.Rendering;

/// <summary>Supplies decoded pictures for the compositor. Images are owned by the source (cached).</summary>
public interface IFrameSource
{
    /// <summary>The screen picture of a source at a session time.</summary>
    SKImage? Screen(MediaSource source, MediaTime sessionTime);
    /// <summary>The camera picture of a source at a session time.</summary>
    SKImage? Camera(MediaSource source, MediaTime sessionTime);
}

/// <summary>
/// Draws a FrameState: background, drop shadow, rounded screen card under the camera transform (with optional
/// window title bar and inset), click ripples, the cursor, motion blur, camera bubble, text and captions.
/// Preview and export call this same code with the same evaluator, so they produce the same picture.
/// </summary>
public sealed class Compositor(RenderPlan plan)
{
    private static readonly SKColor TitleBar = new(0x2B, 0x2B, 0x30);
    private static readonly SKColor InsetColor = new(0x1C, 0x1C, 0x1F);
    private readonly Dictionary<string, SKImage?> _images = new();

    public RenderPlan Plan { get; } = plan;
    public FrameStateEvaluator Evaluator { get; } = plan.Evaluator;

    /// <summary>Evaluates and renders a timeline time into a new top-down BGRA buffer.</summary>
    public byte[] RenderBgra(MediaTime time, int width, int height, IFrameSource frames)
    {
        var info = new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var bitmap = new SKBitmap(info);
        using (var canvas = new SKCanvas(bitmap)) Draw(canvas, width, height, Evaluator.Evaluate(time), frames);
        return bitmap.Bytes;
    }

    public void Draw(SKCanvas canvas, int width, int height, FrameState state, IFrameSource frames)
    {
        var project = Plan.Project;
        var settings = project.Settings;
        var layout = new FrameLayout(project, width, height);
        DrawBackground(canvas, width, height, settings.Background);

        if (state.Screen is { } screen && project.Source(screen.SourceId) is MediaSource source)
        {
            var picture = frames.Screen(source, screen.SourceTime);
            var scale = state.Camera.Scale * screen.TransitionScale;
            var centre = layout.CameraCentre(state.Camera);

            // Motion blur: how far this frame's view moves during the shutter interval (half a frame at 60 fps).
            var shutter = settings.Motion.MotionBlur * 0.5 / 60;
            var blurX = shutter * state.CameraVelocityX * layout.Content.Width;
            var blurY = shutter * state.CameraVelocityY * layout.Content.Height;
            var blurScale = -shutter * state.CameraVelocityScale / Math.Max(state.Camera.Scale, 1);
            var magnitude = (Math.Sqrt(blurX * blurX + blurY * blurY) + Math.Abs(blurScale) * Math.Max(layout.Card.Width, layout.Card.Height) / 2) * scale;
            var taps = magnitude >= 0.75 ? Math.Clamp((int)Math.Ceiling(magnitude / 2), 4, 8) : 1;

            canvas.Save();
            canvas.Translate(width / 2f, height / 2f);
            canvas.Scale((float)scale);
            canvas.Translate((float)-centre.X, (float)-centre.Y);
            var opacity = (float)screen.Opacity;
            DrawShadow(canvas, layout, settings.Screen.ShadowOpacity * opacity, scale);

            using var clip = RoundRect(layout.Card, layout.CornerRadius);
            canvas.Save();
            canvas.ClipRoundRect(clip, SKClipOperation.Intersect, antialias: true);
            if (taps == 1)
            {
                DrawCard(canvas, layout, picture, state, settings, opacity, scale);
            }
            else
            {
                using var fade = opacity < 1 ? new SKPaint { Color = SKColors.White.WithAlpha((byte)(opacity * 255)) } : null;
                if (fade != null) canvas.SaveLayer(fade);
                // Average the card over the shutter interval: running mean with alpha 1/(i+1).
                for (var i = 0; i < taps; i++)
                {
                    var t = (i + 0.5) / taps - 0.5;
                    canvas.Save();
                    canvas.Translate((float)centre.X, (float)centre.Y);
                    var zoom = (float)(1 / (1 + blurScale * t));
                    canvas.Scale(zoom);
                    canvas.Translate((float)(-centre.X - blurX * t), (float)(-centre.Y - blurY * t));
                    using var tap = new SKPaint { Color = SKColors.White.WithAlpha((byte)Math.Round(255.0 / (i + 1))) };
                    canvas.SaveLayer(tap);
                    DrawCard(canvas, layout, picture, state, settings, 1, scale);
                    canvas.Restore();
                    canvas.Restore();
                }
                if (fade != null) canvas.Restore();
            }
            canvas.Restore();
            canvas.Restore();
        }

        if (state.CameraPip is { } pip && project.Source(pip.SourceId) is MediaSource pipSource)
            DrawPip(canvas, layout, pip, frames.Camera(pipSource, pip.SourceTime), settings.Camera);

        DrawText(canvas, width, height, state, project);
    }

    private void DrawBackground(SKCanvas canvas, int width, int height, BackgroundStyle bg)
    {
        switch (bg.Kind)
        {
            case BackgroundKind.Solid:
                canvas.Clear(ToSk(bg.Color));
                return;
            case BackgroundKind.Gradient:
            {
                var angle = bg.GradientAngle * Math.PI / 180;
                var dx = (float)Math.Cos(angle);
                var dy = (float)Math.Sin(angle);
                var half = (Math.Abs(dx) * width + Math.Abs(dy) * height) / 2;
                var c = new SKPoint(width / 2f, height / 2f);
                using var paint = new SKPaint
                {
                    Shader = SKShader.CreateLinearGradient(new SKPoint(c.X - dx * half, c.Y - dy * half), new SKPoint(c.X + dx * half, c.Y + dy * half),
                        new[] { ToSk(bg.GradientStart), ToSk(bg.GradientEnd) }, SKShaderTileMode.Clamp),
                };
                canvas.DrawRect(0, 0, width, height, paint);
                return;
            }
            case BackgroundKind.Image or BackgroundKind.Wallpaper when bg.ImagePath is string path && LoadImage(path) is SKImage image:
            {
                canvas.Clear(SKColors.Black);
                var s = Math.Max((float)width / image.Width, (float)height / image.Height);
                var w = image.Width * s;
                var h = image.Height * s;
                var blur = (float)(bg.BlurAmount * Math.Min(width, height) * 0.04);
                using var paint = new SKPaint { FilterQuality = SKFilterQuality.High, ImageFilter = blur > 0.5f ? SKImageFilter.CreateBlur(blur, blur, SKShaderTileMode.Clamp) : null };
                canvas.DrawImage(image, new SKRect((width - w) / 2, (height - h) / 2, (width + w) / 2, (height + h) / 2), paint);
                return;
            }
            default:
                canvas.Clear(SKColors.Black);
                return;
        }
    }

    private SKImage? LoadImage(string path)
    {
        lock (_images)
        {
            if (_images.TryGetValue(path, out var cached)) return cached;
            SKImage? image = null;
            try { if (File.Exists(path)) image = SKImage.FromEncodedData(path); } catch (Exception) { }
            _images[path] = image;
            return image;
        }
    }

    private static void DrawShadow(SKCanvas canvas, FrameLayout layout, double opacity, double scale)
    {
        if (opacity <= 0 || layout.ShadowRadius <= 0) return;
        var radius = layout.ShadowRadius / scale;
        using var rect = RoundRect(layout.Card, layout.CornerRadius);
        rect.Offset(0, (float)(radius * 0.35));
        using var paint = new SKPaint
        {
            IsAntialias = true, Color = new SKColor(0, 0, 0, (byte)(Math.Clamp(opacity, 0, 1) * 255)),
            MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, (float)Math.Max(radius * 0.45, 0.5)),
        };
        canvas.DrawRoundRect(rect, paint);
    }

    /// <summary>The card in pre-camera coordinates: title bar, inset, picture, ripples, cursor. Clipped by the caller.</summary>
    private static void DrawCard(SKCanvas canvas, FrameLayout layout, SKImage? picture, FrameState state, ProjectSettings settings, float opacity, double scale)
    {
        using var layer = opacity < 1 ? new SKPaint { Color = SKColors.White.WithAlpha((byte)(opacity * 255)) } : null;
        if (layer != null) canvas.SaveLayer(layer);

        var card = layout.Card;
        if (layout.TitleBarHeight > 0)
        {
            using var bar = new SKPaint { Color = TitleBar };
            canvas.DrawRect((float)card.X, (float)card.Y, (float)card.Width, (float)layout.TitleBarHeight, bar);
            var lights = new[] { new SKColor(255, 94, 87), new SKColor(255, 189, 46), new SKColor(40, 200, 64) };
            var cy = card.Y + layout.TitleBarHeight / 2;
            for (var i = 0; i < 3; i++)
            {
                using var light = new SKPaint { IsAntialias = true, Color = lights[i] };
                canvas.DrawCircle((float)(card.X + layout.TitleBarHeight * (0.6 + 0.6 * i)), (float)cy, (float)(layout.TitleBarHeight * 0.17), light);
            }
        }
        using (var inset = new SKPaint { Color = InsetColor })
            canvas.DrawRect((float)card.X, (float)(card.Y + layout.TitleBarHeight), (float)card.Width, (float)(card.Height - layout.TitleBarHeight), inset);

        var content = layout.Content;
        if (picture != null)
        {
            var crop = layout.Crop;
            var src = new SKRect((float)(crop.X * picture.Width), (float)(crop.Y * picture.Height),
                (float)((crop.X + crop.Width) * picture.Width), (float)((crop.Y + crop.Height) * picture.Height));
            using var paint = new SKPaint { FilterQuality = scale > 1.01 ? SKFilterQuality.High : SKFilterQuality.Medium, IsAntialias = true };
            canvas.DrawImage(picture, src, new SKRect((float)content.X, (float)content.Y, (float)content.Right, (float)content.Bottom), paint);
        }

        var cursorStyle = settings.Cursor;
        foreach (var ripple in state.Ripples.TakeLast(4))
        {
            var p = layout.ContentPoint(ripple.X, ripple.Y);
            var maxRadius = layout.CursorUnit * cursorStyle.Size * 1.1;
            var eased = 1 - Math.Pow(1 - ripple.Progress, 3);
            var r = (float)(maxRadius * (0.25 + 0.75 * eased));
            var alpha = (1 - ripple.Progress) * cursorStyle.ClickColor.A;
            var color = ToSk(cursorStyle.ClickColor with { A = 1 });
            using var paint = new SKPaint { IsAntialias = true };
            if (cursorStyle.ClickEffect == ClickEffect.Ring)
            {
                paint.Style = SKPaintStyle.Stroke;
                paint.StrokeWidth = (float)Math.Max(maxRadius * 0.09 * 2, 1.5 / scale);
                paint.Color = color.WithAlpha((byte)(alpha * 255));
            }
            else
            {
                paint.Color = color.WithAlpha((byte)(alpha * 0.55 * 255));
            }
            canvas.DrawCircle((float)p.X, (float)p.Y, r, paint);
        }

        if (state.Cursor is { } cursor)
        {
            var p = layout.ContentPoint(cursor.X, cursor.Y);
            CursorSprites.Draw(canvas, cursor.Kind, (float)p.X, (float)p.Y, (float)(layout.CursorUnit * cursor.Scale), (float)cursor.Opacity);
        }

        if (layer != null) canvas.Restore();
    }

    private static void DrawPip(SKCanvas canvas, FrameLayout layout, FrameState.Pip pip, SKImage? image, CameraStyle style)
    {
        var aspect = image != null ? (double)image.Width / image.Height : 16.0 / 9;
        var rect = layout.PipRect(pip, style.Shape, aspect);
        var r = style.Shape == CameraShape.Circle ? rect.Height / 2 : style.CornerRadius * rect.Height;
        using var shape = RoundRect(rect, r);
        if (style.ShadowOpacity > 0)
        {
            using var shadow = new SKPaint
            {
                IsAntialias = true, Color = new SKColor(0, 0, 0, (byte)(style.ShadowOpacity * 255)),
                MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, (float)(rect.Height * 0.12)),
            };
            canvas.Save();
            canvas.Translate(0, (float)(rect.Height * 0.05));
            canvas.DrawRoundRect(shape, shadow);
            canvas.Restore();
        }
        canvas.Save();
        canvas.ClipRoundRect(shape, SKClipOperation.Intersect, true);
        canvas.Clear(ToSk(style.BackgroundColor));
        if (image != null)
        {
            // Aspect-fill the bubble.
            var s = Math.Max(rect.Width / image.Width, rect.Height / image.Height);
            var w = image.Width * s;
            var h = image.Height * s;
            canvas.Save();
            if (style.IsMirrored) { canvas.Translate((float)(rect.X * 2 + rect.Width), 0); canvas.Scale(-1, 1); }
            using var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium };
            canvas.DrawImage(image, new SKRect((float)(rect.X + (rect.Width - w) / 2), (float)(rect.Y + (rect.Height - h) / 2),
                (float)(rect.X + (rect.Width + w) / 2), (float)(rect.Y + (rect.Height + h) / 2)), paint);
            canvas.Restore();
        }
        canvas.Restore();
        if (style.BorderWidth > 0)
        {
            var bw = (float)(style.BorderWidth * rect.Height);
            using var border = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = bw, Color = ToSk(style.BorderColor) };
            using var inner = RoundRect(new RectD(rect.X + bw / 2, rect.Y + bw / 2, rect.Width - bw, rect.Height - bw), Math.Max(0, r - bw / 2));
            canvas.DrawRoundRect(inner, border);
        }
    }

    private static void DrawText(SKCanvas canvas, int width, int height, FrameState state, Project project)
    {
        foreach (var o in state.Overlays)
        {
            if (project.Timeline.TextOverlays.FirstOrDefault(t => t.Id == o.Id) is not TextOverlay text) continue;
            var weight = text.Weight switch
            {
                TextWeight.Regular => SKFontStyleWeight.Normal, TextWeight.Medium => SKFontStyleWeight.Medium,
                TextWeight.Bold => SKFontStyleWeight.Bold, _ => SKFontStyleWeight.SemiBold,
            };
            Label(canvas, text.Text, (float)(text.PositionX * width), (float)(text.PositionY * height), (float)(text.FontSize * height),
                weight, text.Color, text.BackgroundColor, o.Opacity);
        }
        if (state.CaptionId is Guid id && project.Timeline.Captions.FirstOrDefault(c => c.Id == id) is Caption caption)
        {
            var style = project.Settings.Captions;
            Label(canvas, caption.Text, width / 2f, (float)(style.PositionY * height), (float)(style.FontSize * height),
                SKFontStyleWeight.Medium, style.Color, style.BackgroundColor, 1);
        }
    }

    private static void Label(SKCanvas canvas, string text, float cx, float cy, float size, SKFontStyleWeight weight,
        RgbaColor color, RgbaColor background, double opacity)
    {
        using var typeface = SKTypeface.FromFamilyName("Segoe UI", weight, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright);
        using var font = new SKFont(typeface, size);
        using var paint = new SKPaint(font) { IsAntialias = true, Color = ToSk(color, opacity) };
        var w = paint.MeasureText(text);
        if (background.A > 0)
        {
            using var bg = new SKPaint { IsAntialias = true, Color = ToSk(background, opacity) };
            canvas.DrawRoundRect(new SKRect(cx - w / 2 - size * 0.45f, cy - size * 0.75f, cx + w / 2 + size * 0.45f, cy + size * 0.55f), size * 0.25f, size * 0.25f, bg);
        }
        canvas.DrawText(text, cx - w / 2, cy + size * 0.32f, paint);
    }

    private static SKRoundRect RoundRect(RectD r, double radius) =>
        new(new SKRect((float)r.X, (float)r.Y, (float)r.Right, (float)r.Bottom), (float)radius, (float)radius);

    private static SKColor ToSk(RgbaColor c, double opacity = 1) =>
        new((byte)(Math.Clamp(c.R, 0, 1) * 255), (byte)(Math.Clamp(c.G, 0, 1) * 255), (byte)(Math.Clamp(c.B, 0, 1) * 255),
            (byte)(Math.Clamp(c.A * opacity, 0, 1) * 255));
}
