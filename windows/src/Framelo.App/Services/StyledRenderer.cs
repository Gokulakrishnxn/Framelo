using Framelo.Core;
using Framelo.Platform.Media;
using Framelo.Rendering;
using SkiaSharp;

namespace Framelo.App.Services;

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
