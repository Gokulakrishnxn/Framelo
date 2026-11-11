using Vortice.MediaFoundation;

namespace Framelo.Platform.Media;

/// <summary>Media Foundation start-up and the GUIDs Vortice does not expose.</summary>
public static class MF
{
    private static readonly object Gate = new();
    private static bool _started;

    public static readonly Guid TranscodeContainerType = new("150FF23F-4ABC-478B-AC4F-E1916FBA1CCA");
    public static readonly Guid ContainerFmpeg4 = new("9BA876F1-419F-4B77-A1E0-35959D9D4004");
    public static readonly Guid ContainerMpeg4 = new("DC6CD05D-B9D0-40EF-BD35-FA622C1AB28A");
    public static readonly Guid AudioPcm = new("00000001-0000-0010-8000-00AA00389B71");
    public static readonly Guid AllSamplesIndependent = new("C9173739-5E56-461C-B713-46FB995CB95F");
    public const uint InterlaceProgressive = 2;

    public static void Startup()
    {
        lock (Gate)
        {
            if (_started) return;
            MediaFactory.MFStartup(useLightVersion: false).CheckError();
            _started = true;
        }
    }
}

public sealed record VideoSpec(int Width, int Height, int FrameRate, int BitRate, bool Hevc = false, int KeyframeSeconds = 2);
public sealed record AudioSpec(int SampleRate = 48_000, int Channels = 2, int BitRate = 192_000);

public sealed class MediaWriterException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// H.264/HEVC + AAC MP4 writer on the Media Foundation sink writer. Video arrives as top-down BGRA,
/// audio as interleaved 16-bit PCM. With fragmented = true the file is readable even if the process dies.
/// </summary>
public sealed class MfWriter : IDisposable
{
    private readonly object _gate = new();
    private readonly IMFSinkWriter _writer;
    private readonly int _videoStream = -1;
    private readonly int _audioStream = -1;
    private readonly VideoSpec? _video;
    private readonly AudioSpec? _audio;
    private bool _finished;

    public MfWriter(string path, VideoSpec? video, AudioSpec? audio, bool fragmented)
    {
        if (video == null && audio == null) throw new ArgumentException("Nothing to write.");
        MF.Startup();
        _video = video;
        _audio = audio;
        using var attributes = MediaFactory.MFCreateAttributes(4);
        attributes.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, 1u);
        attributes.Set(SinkWriterAttributeKeys.DisableThrottling, 1u);
        attributes.Set(MF.TranscodeContainerType, fragmented ? MF.ContainerFmpeg4 : MF.ContainerMpeg4);
        try
        {
            _writer = MediaFactory.MFCreateSinkWriterFromURL(path, null!, attributes);
            if (video != null) _videoStream = AddVideo(video);
            if (audio != null) _audioStream = AddAudio(audio);
            _writer.BeginWriting();
        }
        catch (Exception e) when (e is not MediaWriterException)
        {
            throw new MediaWriterException(video?.Hevc == true
                ? "HEVC encoding is not available. Install “HEVC Video Extensions” from the Microsoft Store or choose H.264."
                : $"The video encoder could not be started ({e.Message}).", e);
        }
    }

    private int AddVideo(VideoSpec v)
    {
        using var output = MediaFactory.MFCreateMediaType();
        output.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        output.Set(MediaTypeAttributeKeys.Subtype, v.Hevc ? VideoFormatGuids.Hevc : VideoFormatGuids.H264);
        output.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)v.BitRate);
        output.Set(MediaTypeAttributeKeys.InterlaceMode, MF.InterlaceProgressive);
        MediaFactory.MFSetAttributeSize(output, MediaTypeAttributeKeys.FrameSize, (uint)v.Width, (uint)v.Height);
        MediaFactory.MFSetAttributeRatio(output, MediaTypeAttributeKeys.FrameRate, (uint)v.FrameRate, 1);
        MediaFactory.MFSetAttributeRatio(output, MediaTypeAttributeKeys.PixelAspectRatio, 1, 1);
        output.Set(MediaTypeAttributeKeys.MaxKeyframeSpacing, (uint)(v.FrameRate * v.KeyframeSeconds));
        var index = _writer.AddStream(output);

        using var input = MediaFactory.MFCreateMediaType();
        input.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        input.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.Rgb32);
        input.Set(MediaTypeAttributeKeys.InterlaceMode, MF.InterlaceProgressive);
        input.Set(MediaTypeAttributeKeys.DefaultStride, (uint)(v.Width * 4));
        MediaFactory.MFSetAttributeSize(input, MediaTypeAttributeKeys.FrameSize, (uint)v.Width, (uint)v.Height);
        MediaFactory.MFSetAttributeRatio(input, MediaTypeAttributeKeys.FrameRate, (uint)v.FrameRate, 1);
        MediaFactory.MFSetAttributeRatio(input, MediaTypeAttributeKeys.PixelAspectRatio, 1, 1);
        _writer.SetInputMediaType(index, input, null!);
        return index;
    }

    private int AddAudio(AudioSpec a)
    {
        using var output = MediaFactory.MFCreateMediaType();
        output.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
        output.Set(MediaTypeAttributeKeys.Subtype, AudioFormatGuids.Aac);
        output.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16u);
        output.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, (uint)a.SampleRate);
        output.Set(MediaTypeAttributeKeys.AudioNumChannels, (uint)a.Channels);
        output.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, (uint)(a.BitRate / 8));
        var index = _writer.AddStream(output);

        using var input = MediaFactory.MFCreateMediaType();
        input.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Audio);
        input.Set(MediaTypeAttributeKeys.Subtype, MF.AudioPcm);
        input.Set(MediaTypeAttributeKeys.AudioBitsPerSample, 16u);
        input.Set(MediaTypeAttributeKeys.AudioSamplesPerSecond, (uint)a.SampleRate);
        input.Set(MediaTypeAttributeKeys.AudioNumChannels, (uint)a.Channels);
        input.Set(MediaTypeAttributeKeys.AudioBlockAlignment, (uint)(a.Channels * 2));
        input.Set(MediaTypeAttributeKeys.AudioAvgBytesPerSecond, (uint)(a.SampleRate * a.Channels * 2));
        _writer.SetInputMediaType(index, input, null!);
        return index;
    }

    /// <summary>Writes one top-down BGRA frame. Times are in 100 ns units.</summary>
    public unsafe void WriteVideo(ReadOnlySpan<byte> bgra, int stride, long time, long duration)
    {
        if (_video == null) throw new InvalidOperationException("No video stream.");
        var rowBytes = _video.Width * 4;
        var length = rowBytes * _video.Height;
        using var buffer = MediaFactory.MFCreateMemoryBuffer(length);
        buffer.Lock(out var pointer, out _, out _);
        try
        {
            var target = new Span<byte>((void*)pointer, length);
            for (var y = 0; y < _video.Height; y++)
                bgra.Slice(y * stride, rowBytes).CopyTo(target.Slice(y * rowBytes, rowBytes));
        }
        finally { buffer.Unlock(); }
        buffer.CurrentLength = length;
        Write(_videoStream, buffer, time, duration);
    }

    /// <summary>Writes interleaved 16-bit PCM at the configured rate. Time in 100 ns units.</summary>
    public unsafe void WriteAudio(ReadOnlySpan<short> pcm, long time)
    {
        if (_audio == null) throw new InvalidOperationException("No audio stream.");
        if (pcm.IsEmpty) return;
        var length = pcm.Length * 2;
        using var buffer = MediaFactory.MFCreateMemoryBuffer(length);
        buffer.Lock(out var pointer, out _, out _);
        try { System.Runtime.InteropServices.MemoryMarshal.AsBytes(pcm).CopyTo(new Span<byte>((void*)pointer, length)); }
        finally { buffer.Unlock(); }
        buffer.CurrentLength = length;
        var frames = pcm.Length / _audio.Channels;
        Write(_audioStream, buffer, time, frames * 10_000_000L / _audio.SampleRate);
    }

    private void Write(int stream, IMFMediaBuffer buffer, long time, long duration)
    {
        using var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime = time;
        sample.SampleDuration = Math.Max(1, duration);
        lock (_gate)
        {
            if (_finished) return;
            _writer.WriteSample(stream, sample);
        }
    }

    /// <summary>Tells the muxer that a stream has nothing at this time (e.g. a still screen).</summary>
    public void Gap(long time)
    {
        lock (_gate) { if (!_finished && _videoStream >= 0) _writer.SendStreamTick(_videoStream, time); }
    }

    public void Finish()
    {
        lock (_gate)
        {
            if (_finished) return;
            _finished = true;
            _writer.Finalize();
        }
    }

    public void Dispose()
    {
        try { Finish(); } catch (Exception) { /* already reported by the caller's Finish */ }
        _writer.Dispose();
    }
}
