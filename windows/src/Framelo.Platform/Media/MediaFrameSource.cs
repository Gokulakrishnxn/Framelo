using Framelo.Core;
using Framelo.Rendering;
using SkiaSharp;

namespace Framelo.Platform.Media;

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
