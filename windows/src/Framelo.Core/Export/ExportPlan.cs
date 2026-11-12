using System.Buffers.Binary;
using System.Text;

namespace Framelo.Core;

/// <summary>What an export will produce, computed before any frame is rendered.</summary>
public sealed record ExportPlan(int Width, int Height, int FrameRate, long FrameCount, double Duration, bool HasAudio, ExportSettings Settings)
{
    public static ExportPlan For(Project project, ExportSettings settings, bool hasAudio)
    {
        var (w, h) = settings.CanvasSize(project.CanvasAspect);
        var fps = Math.Clamp(settings.FrameRate, 1, 120);
        var duration = project.Duration.Seconds;
        return new ExportPlan(w, h, fps, Math.Max(1, (long)Math.Ceiling(duration * fps - 1e-6)), duration, hasAudio, settings);
    }

    /// <summary>Timeline time of a frame, exact in ticks (60 000 is divisible by every supported rate).</summary>
    public MediaTime FrameTime(long frame) => new(frame * MediaTime.Timescale / FrameRate);

    public long EstimatedBytes => Settings.EstimatedFileSize(Width, Height, Duration, HasAudio);
}

public sealed class ExportVerificationException(string message) : Exception(message);

/// <summary>Checks a finished file before it is moved to where the user asked for it.</summary>
public static class ExportVerifier
{
    public static void Verify(MediaFacts? facts, ExportPlan plan)
    {
        if (facts == null || !facts.HasVideo) throw new ExportVerificationException("the file has no readable video");
        var frame = 1.0 / plan.FrameRate;
        if (Math.Abs(facts.Duration - plan.Duration) > frame * 2 + 0.05)
            throw new ExportVerificationException($"duration is {facts.Duration:0.00} s, expected {plan.Duration:0.00} s");
        if (facts.PixelWidth != plan.Width || facts.PixelHeight != plan.Height)
            throw new ExportVerificationException($"size is {facts.PixelWidth}×{facts.PixelHeight}, expected {plan.Width}×{plan.Height}");
        var codec = plan.Settings.Codec == ExportCodec.H264 ? "h264" : "hevc";
        if (facts.VideoCodec != null && facts.VideoCodec != codec)
            throw new ExportVerificationException($"codec is {facts.VideoCodec}, expected {codec}");
        if (facts.FrameRate > 0 && Math.Abs(facts.FrameRate - plan.FrameRate) > 1.5)
            throw new ExportVerificationException($"frame rate is {facts.FrameRate:0.0}, expected {plan.FrameRate}");
        if (plan.HasAudio && !facts.HasAudio) throw new ExportVerificationException("the audio track is missing");
    }
}

/// <summary>
/// Writes iTunes-style metadata (author, title) into an MP4 whose moov box comes after the media data — which is
/// how Media Foundation writes files — so no sample offsets move.
/// </summary>
public static class Mp4Metadata
{
    public static bool AddAuthor(string path, string? author, string? title)
    {
        if (string.IsNullOrWhiteSpace(author) && string.IsNullOrWhiteSpace(title)) return false;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        // Find the top-level boxes; only a final moov can be extended in place.
        long position = 0, moovStart = -1, moovSize = 0;
        var header = new byte[16];
        var sawMdat = false;
        while (position + 8 <= stream.Length)
        {
            stream.Position = position;
            stream.ReadExactly(header, 0, 8);
            long size = BinaryPrimitives.ReadUInt32BigEndian(header);
            var type = Encoding.ASCII.GetString(header, 4, 4);
            if (size == 1) { stream.ReadExactly(header, 8, 8); size = (long)BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(8)); }
            else if (size == 0) size = stream.Length - position;
            if (size < 8) return false;
            if (type == "mdat") sawMdat = true;
            if (type == "moov") { moovStart = position; moovSize = size; }
            position += size;
        }
        if (moovStart < 0 || !sawMdat || moovStart + moovSize != stream.Length || moovSize > uint.MaxValue - 4096) return false;

        var items = new List<byte[]>();
        if (!string.IsNullOrWhiteSpace(author)) items.Add(Item("©ART", author!.Trim()));
        if (!string.IsNullOrWhiteSpace(title)) items.Add(Item("©nam", title!.Trim()));
        var ilst = Box("ilst", items.SelectMany(b => b).ToArray());
        var hdlr = Box("hdlr", new byte[] { 0, 0, 0, 0, 0, 0, 0, 0 }.Concat(Encoding.ASCII.GetBytes("mdirappl")).Concat(new byte[10]).ToArray());
        var meta = Box("meta", new byte[4].Concat(hdlr).Concat(ilst).ToArray());
        var udta = Box("udta", meta);

        stream.Position = stream.Length;
        stream.Write(udta);
        var newSize = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(newSize, (uint)(moovSize + udta.Length));
        stream.Position = moovStart;
        stream.Write(newSize);
        return true;
    }

    private static byte[] Item(string key, string value)
    {
        var data = Box("data", new byte[] { 0, 0, 0, 1, 0, 0, 0, 0 }.Concat(Encoding.UTF8.GetBytes(value)).ToArray());
        return Box(key, data);
    }

    private static byte[] Box(string type, byte[] payload)
    {
        var box = new byte[8 + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(box, (uint)box.Length);
        Encoding.Latin1.GetBytes(type, box.AsSpan(4, 4));
        payload.CopyTo(box, 8);
        return box;
    }
}
