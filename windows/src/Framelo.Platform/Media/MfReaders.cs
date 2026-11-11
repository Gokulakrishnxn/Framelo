using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Framelo.Core;
using Vortice.MediaFoundation;

namespace Framelo.Platform.Media;

/// <summary>A decoded picture: top-down BGRA, tightly packed (stride = width × 4).</summary>
public sealed class VideoFrame(int width, int height, byte[] bgra, double time, double duration)
{
    public int Width { get; } = width;
    public int Height { get; } = height;
    public byte[] Bgra { get; } = bgra;
    /// <summary>File time of the frame in seconds, and how long it is shown.</summary>
    public double Time { get; } = time;
    public double Duration { get; } = duration;
    public bool Covers(double t) => t >= Time - 1e-6 && t < Time + Math.Max(Duration, 1e-3);
}

/// <summary>
/// Frame-accurate random access to a video file. Sequential requests (playback, export) decode forward;
/// jumps seek to the preceding keyframe and decode up to the requested time.
/// </summary>
public sealed class MfVideoReader : IDisposable
{
    private readonly IMFSourceReader _reader;
    private readonly object _gate = new();
    private VideoFrame? _current;
    private VideoFrame? _next;
    private bool _ended;

    public int Width { get; }
    public int Height { get; }
    public double Duration { get; }

    public MfVideoReader(string path)
    {
        MF.Startup();
        using var attributes = MediaFactory.MFCreateAttributes(2);
        attributes.Set(SourceReaderAttributeKeys.EnableVideoProcessing, 1u);
        _reader = MediaFactory.MFCreateSourceReaderFromURL(path, attributes);
        _reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
        _reader.SetStreamSelection(SourceReaderIndex.FirstVideoStream, true);
        using (var type = MediaFactory.MFCreateMediaType())
        {
            type.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            type.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.Rgb32);
            _reader.SetCurrentMediaType(SourceReaderIndex.FirstVideoStream, type);
        }
        using (var current = _reader.GetCurrentMediaType(SourceReaderIndex.FirstVideoStream))
        {
            MediaFactory.MFGetAttributeSize(current, MediaTypeAttributeKeys.FrameSize, out var w, out var h);
            Width = (int)w; Height = (int)h;
        }
        try
        {
            var v = _reader.GetPresentationAttribute(SourceReaderIndex.MediaSource, PresentationDescriptionAttributeKeys.Duration);
            Duration = Convert.ToUInt64(v.Value) / 10_000_000.0;
        }
        catch (Exception) { Duration = 0; }
    }

    /// <summary>The frame showing at a file time, or the nearest one at the ends. Null only for an empty file.</summary>
    public VideoFrame? FrameAt(double seconds)
    {
        lock (_gate)
        {
            seconds = Math.Max(0, seconds);
            if (_current != null && _current.Covers(seconds)) return _current;
            if (_current == null || seconds < _current.Time || seconds > _current.Time + 1.0)
            {
                _reader.SetCurrentPosition((long)(seconds * 10_000_000));
                _current = null; _next = null; _ended = false;
            }
            while (true)
            {
                var frame = _next ?? Read();
                _next = null;
                if (frame == null) return _current;  // end of file: hold the last picture
                if (frame.Time > seconds + 1e-6 && _current != null) { _next = frame; return _current; }
                _current = frame;
                if (frame.Covers(seconds) || frame.Time > seconds) return frame;
            }
        }
    }

    private unsafe VideoFrame? Read()
    {
        if (_ended) return null;
        for (var guard = 0; guard < 1000; guard++)
        {
            using var sample = _reader.ReadSample(SourceReaderIndex.FirstVideoStream, SourceReaderControlFlag.None, out _, out var flags, out var time);
            if ((flags & (SourceReaderFlag.EndOfStream | SourceReaderFlag.Error)) != 0 && sample == null) { _ended = true; return null; }
            if (sample == null) continue;
            var duration = sample.SampleDuration;
            var pixels = new byte[Width * Height * 4];
            using var buffer = sample.ConvertToContiguousBuffer();
            using var buffer2D = buffer.QueryInterfaceOrNull<IMF2DBuffer>();
            if (buffer2D != null)
            {
                buffer2D.Lock2D(out var scan0, out var pitch);
                try { CopyRows((byte*)scan0, pitch, pixels); }
                finally { buffer2D.Unlock2D(); }
            }
            else
            {
                buffer.Lock(out var data, out _, out _);
                try { CopyRows((byte*)data, Width * 4, pixels); }
                finally { buffer.Unlock(); }
            }
            if ((flags & SourceReaderFlag.EndOfStream) != 0) _ended = true;
            return new VideoFrame(Width, Height, pixels, time / 10_000_000.0, duration > 0 ? duration / 10_000_000.0 : 1.0 / 60);
        }
        _ended = true;
        return null;
    }

    private unsafe void CopyRows(byte* scan0, int pitch, byte[] target)
    {
        var row = Width * 4;
        fixed (byte* dst = target)
        {
            for (var y = 0; y < Height; y++)
            {
                var s = scan0 + (long)y * pitch;   // a negative pitch walks a bottom-up image upwards
                Buffer.MemoryCopy(s, dst + (long)y * row, row, row);
                for (var x = 3; x < row; x += 4) dst[(long)y * row + x] = 255;   // RGB32's X byte → opaque alpha
            }
        }
    }

    public void Dispose()
    {
        lock (_gate) _reader.Dispose();
    }
}

/// <summary>Decodes a whole audio track into the mix format (48 kHz stereo float).</summary>
public static class MfAudioDecoder
{
    public static PcmBuffer? Decode(string path)
    {
        if (!File.Exists(path)) return null;
        MF.Startup();
        try
        {
            using var reader = MediaFactory.MFCreateSourceReaderFromURL(path, null!);
            reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
            reader.SetStreamSelection(SourceReaderIndex.FirstAudioStream, true);
            using (var type = MediaFactory.MFCreateMediaType())
            {
                type.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
                type.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Float);
                reader.SetCurrentMediaType(SourceReaderIndex.FirstAudioStream, type);
            }
            int rate, channels;
            using (var current = reader.GetCurrentMediaType(SourceReaderIndex.FirstAudioStream))
            {
                rate = (int)current.GetUInt32(MediaTypeAttributeKeys.AudioSamplesPerSecond);
                channels = (int)current.GetUInt32(MediaTypeAttributeKeys.AudioNumChannels);
            }
            var samples = new List<float>(rate * channels * 60);
            long? firstTime = null;
            while (true)
            {
                using var sample = reader.ReadSample(SourceReaderIndex.FirstAudioStream, SourceReaderControlFlag.None, out _, out var flags, out var time);
                if (sample != null)
                {
                    firstTime ??= time;
                    // Keep samples aligned to their timestamps: pad if the decoder skipped ahead.
                    var expected = (long)Math.Round((time - firstTime.Value) / 10_000_000.0 * rate) * channels;
                    if (expected > samples.Count + channels * rate / 100) samples.AddRange(new float[expected - samples.Count]);
                    using var buffer = sample.ConvertToContiguousBuffer();
                    buffer.Lock(out var data, out _, out var length);
                    try
                    {
                        var chunk = new float[length / 4];
                        Marshal.Copy(data, chunk, 0, chunk.Length);
                        samples.AddRange(chunk);
                    }
                    finally { buffer.Unlock(); }
                }
                if ((flags & (SourceReaderFlag.EndOfStream | SourceReaderFlag.Error)) != 0) break;
            }
            var lead = (int)Math.Round((firstTime ?? 0) / 10_000_000.0 * rate) * channels;
            var raw = lead > 0 ? new float[lead].Concat(samples).ToArray() : samples.ToArray();
            return new PcmBuffer(PcmConvert.Resample(raw, rate, channels, PcmBuffer.Rate, PcmBuffer.Channels));
        }
        catch (Exception)
        {
            return null;
        }
    }
}

/// <summary>Decodes each source's audio once and keeps it for preview and export.</summary>
public sealed class AudioSourceCache(string packagePath) : Framelo.Core.IAudioSourceProvider
{
    private readonly ConcurrentDictionary<string, PcmBuffer?> _cache = new();

    public PcmBuffer? Get(MediaSource source, AudioRole role)
    {
        var file = role switch
        {
            AudioRole.Microphone => source.Microphone,
            AudioRole.SystemAudio => source.SystemAudio ?? (source.Screen?.HasAudio == true ? source.Screen : null),
            _ => source.Screen ?? source.SystemAudio ?? source.Microphone,
        };
        if (file == null) return null;
        var path = ProjectPackage.Resolve(file.RelativePath, packagePath);
        return _cache.GetOrAdd(path, MfAudioDecoder.Decode);
    }

    /// <summary>Decodes every audio file of a project in the background so playback starts without a stall.</summary>
    public Task WarmUpAsync(Project project) => Task.Run(() =>
    {
        foreach (var s in project.Sources)
        {
            Get(s, AudioRole.Microphone);
            Get(s, AudioRole.SystemAudio);
        }
    });
}

/// <summary>Opens one reader per video file and shares it.</summary>
public sealed class VideoSourceCache(string packagePath) : IDisposable
{
    private readonly Dictionary<string, MfVideoReader?> _readers = new();

    public MfVideoReader? Screen(MediaSource source) => Open(source.Screen);
    public MfVideoReader? Camera(MediaSource source) => Open(source.Camera);

    private MfVideoReader? Open(MediaFile? file)
    {
        if (file == null) return null;
        var path = ProjectPackage.Resolve(file.RelativePath, packagePath);
        lock (_readers)
        {
            if (_readers.TryGetValue(path, out var reader)) return reader;
            try { reader = new MfVideoReader(path); } catch (Exception) { reader = null; }
            _readers[path] = reader;
            return reader;
        }
    }

    public void Dispose()
    {
        lock (_readers)
        {
            foreach (var r in _readers.Values) r?.Dispose();
            _readers.Clear();
        }
    }
}
