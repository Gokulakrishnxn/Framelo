using Framelo.Core;
using Framelo.Platform.Media;
using Framelo.Rendering;
using SkiaSharp;

namespace Framelo.App.Services;

/// <summary>Decoded frames from Media Foundation, as Skia images, for the compositor.</summary>
public sealed class MediaFrameSource(VideoSourceCache video) : IFrameSource
{
    private readonly Dictionary<MfVideoReader, (VideoFrame Frame, SKImage Image)> _last = new();

    public SKImage? Screen(MediaSource source, MediaTime sessionTime) =>
        source.Screen is MediaFile file ? Image(video.Screen(source), file, sessionTime) : null;

    public SKImage? Camera(MediaSource source, MediaTime sessionTime) =>
        source.Camera is MediaFile file ? Image(video.Camera(source), file, sessionTime) : null;

    private SKImage? Image(MfVideoReader? reader, MediaFile file, MediaTime sessionTime)
    {
        if (reader == null) return null;
        var fileTime = (sessionTime.Seconds - file.StartOffset) * (file.RateCorrection > 0 ? file.RateCorrection : 1);
        var frame = reader.FrameAt(fileTime);
        if (frame == null) return null;
        lock (_last)
        {
            if (_last.TryGetValue(reader, out var cached) && ReferenceEquals(cached.Frame, frame)) return cached.Image;
            var info = new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Opaque);
            var image = SKImage.FromPixelCopy(info, frame.Bgra, frame.Width * 4);
            if (_last.TryGetValue(reader, out var old)) old.Image.Dispose();
            _last[reader] = (frame, image);
            return image;
        }
    }

    public void Clear()
    {
        lock (_last)
        {
            foreach (var v in _last.Values) v.Image.Dispose();
            _last.Clear();
        }
    }
}

/// <summary>Editor preview through the shared compositor — the same code the export uses.</summary>
public sealed class StyledRenderer(VideoSourceCache video) : IPreviewRenderer
{
    private readonly MediaFrameSource _frames = new(video);
    private readonly object _gate = new();
    private Compositor? _compositor;
    private int _revision = -1;

    public PreviewImage? Render(EditorSession session, double seconds, int maxWidth, int maxHeight)
    {
        lock (_gate)
        {
            if (_compositor == null || _revision != session.Revision)
            {
                _compositor = new Compositor(new RenderPlan(session.Project, session.CursorTracks, session.Revision));
                _revision = session.Revision;
            }
            var aspect = session.Project.CanvasAspect;
            var (w, h) = Fit(aspect, maxWidth, maxHeight);
            var pixels = _compositor.RenderBgra(MediaTime.FromSeconds(seconds), w, h, _frames);
            return new PreviewImage(w, h, pixels);
        }
    }

    public static (int Width, int Height) Fit(double aspect, int maxWidth, int maxHeight)
    {
        var w = maxWidth;
        var h = (int)Math.Round(w / aspect);
        if (h > maxHeight) { h = maxHeight; w = (int)Math.Round(h * aspect); }
        return (Math.Max(2, w), Math.Max(2, h));
    }

    public void Dispose() => _frames.Clear();
}
