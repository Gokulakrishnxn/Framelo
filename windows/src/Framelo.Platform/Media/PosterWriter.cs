using Framelo.Core;
using Framelo.Rendering;
using SkiaSharp;

namespace Framelo.Platform.Media;

/// <summary>Writes poster.jpg — the dashboard thumbnail — with the shared compositor.</summary>
public static class PosterWriter
{
    public static void Write(Project project, IReadOnlyDictionary<Guid, CursorTrack> cursors, string package, int width = 640)
    {
        if (project.Duration.Ticks <= 0) return;
        using var video = new VideoSourceCache(package);
        var frames = new MediaFrameSource(video);
        try
        {
            var height = Math.Max(2, (int)Math.Round(width / project.CanvasAspect));
            var time = MediaTime.FromSeconds(Math.Min(1.0, project.Duration.Seconds / 2));
            var pixels = new Compositor(new RenderPlan(project, cursors)).RenderBgra(time, width, height, frames);
            using var bitmap = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
            System.Runtime.InteropServices.Marshal.Copy(pixels, 0, bitmap.GetPixels(), pixels.Length);
            using var data = bitmap.Encode(SKEncodedImageFormat.Jpeg, 85);
            var path = Path.Combine(package, ProjectPackage.PosterFile);
            var temp = path + ".tmp";
            File.WriteAllBytes(temp, data.ToArray());
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            frames.Clear();
        }
    }
}
