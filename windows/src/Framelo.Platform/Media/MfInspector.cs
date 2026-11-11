using Framelo.Core;
using Vortice.MediaFoundation;

namespace Framelo.Platform.Media;

/// <summary>Reads duration, picture size and track presence with the Media Foundation source reader.</summary>
public sealed class MfInspector : IMediaInspector
{
    public MediaFacts? Inspect(string path)
    {
        if (!File.Exists(path) || new FileInfo(path).Length == 0) return null;
        MF.Startup();
        try
        {
            using var reader = MediaFactory.MFCreateSourceReaderFromURL(path, null!);
            double duration = 0;
            try
            {
                var v = reader.GetPresentationAttribute(SourceReaderIndex.MediaSource, PresentationDescriptionAttributeKeys.Duration);
                duration = Convert.ToUInt64(v.Value) / 10_000_000.0;
            }
            catch (Exception) { /* fragmented files may not report a duration; measured below */ }

            int width = 0, height = 0;
            bool hasVideo = false, hasAudio = false;
            try
            {
                using var type = reader.GetNativeMediaType(SourceReaderIndex.FirstVideoStream, 0);
                MediaFactory.MFGetAttributeSize(type, MediaTypeAttributeKeys.FrameSize, out var w, out var h);
                width = (int)w; height = (int)h; hasVideo = true;
            }
            catch (Exception) { }
            try
            {
                using var type = reader.GetNativeMediaType(SourceReaderIndex.FirstAudioStream, 0);
                hasAudio = true;
            }
            catch (Exception) { }
            if (!hasVideo && !hasAudio) return null;
            if (duration <= 0) duration = MeasureDuration(reader, hasVideo);
            return new MediaFacts(duration, width, height, hasAudio, hasVideo);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Walks the samples of a file whose header has no duration (an interrupted fragmented recording).</summary>
    private static double MeasureDuration(IMFSourceReader reader, bool video)
    {
        var stream = video ? SourceReaderIndex.FirstVideoStream : SourceReaderIndex.FirstAudioStream;
        reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
        reader.SetStreamSelection(stream, true);
        long end = 0;
        for (var guard = 0; guard < 50_000_000; guard++)
        {
            using var sample = reader.ReadSample(stream, 0, out _, out var flags, out var time);
            if (sample != null) end = Math.Max(end, time + sample.SampleDuration);
            if ((flags & (SourceReaderFlag.EndOfStream | SourceReaderFlag.Error)) != 0) break;
        }
        return end / 10_000_000.0;
    }
}
