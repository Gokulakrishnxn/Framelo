using Framelo.Core;
using Framelo.Platform.Media;
using Vortice.MediaFoundation;

namespace Framelo.Platform.Capture;

public sealed record CameraDevice(string Id, string Name);

/// <summary>
/// Records a webcam into a fragmented MP4 on the session clock. Frames are read with the Media Foundation source
/// reader (converted to RGB32), stamped with the host clock on arrival and encoded like the screen.
/// </summary>
public sealed class CameraRecorder : IDisposable
{
    private readonly RecordingClock _clock;
    private readonly IMFMediaSource _source;
    private readonly IMFSourceReader _reader;
    private readonly int _fps;
    private readonly Thread _thread;
    private MfWriter? _writer;
    private volatile bool _running;
    private byte[]? _last;
    private long _lastTime = long.MinValue;

    public int Width { get; }
    public int Height { get; }
    public double? StartOffset { get; private set; }
    public event Action<Exception>? Failed;

    public static IReadOnlyList<CameraDevice> Devices()
    {
        try
        {
            MF.Startup();
            using var devices = MediaFactory.MFEnumVideoDeviceSources();
            return devices.Select(d => new CameraDevice(d.SymbolicLink, d.FriendlyName)).ToList();
        }
        catch (Exception)
        {
            return Array.Empty<CameraDevice>();
        }
    }

    /// <summary>Opens a camera (or the first one). Throws when none is available or camera access is off in Windows privacy settings.</summary>
    public CameraRecorder(RecordingClock clock, string? deviceId)
    {
        MF.Startup();
        _clock = clock;
        using (var devices = MediaFactory.MFEnumVideoDeviceSources())
        {
            var list = devices.ToList();
            var activate = list.FirstOrDefault(d => deviceId != null && d.SymbolicLink == deviceId) ?? list.FirstOrDefault()
                ?? throw new InvalidOperationException("No camera is connected.");
            _source = activate.ActivateObject<IMFMediaSource>();
        }
        using var attributes = MediaFactory.MFCreateAttributes(2);
        attributes.Set(SourceReaderAttributeKeys.EnableVideoProcessing, 1u);
        _reader = MediaFactory.MFCreateSourceReaderFromMediaSource(_source, attributes);

        // Pick the native mode closest to 720p at 24 fps or more.
        IMFMediaType? best = null;
        var bestScore = double.MaxValue;
        for (var i = 0; ; i++)
        {
            IMFMediaType type;
            try { type = _reader.GetNativeMediaType(SourceReaderIndex.FirstVideoStream, i); }
            catch (Exception) { break; }
            MediaFactory.MFGetAttributeSize(type, MediaTypeAttributeKeys.FrameSize, out var w, out var h);
            MediaFactory.MFGetAttributeRatio(type, MediaTypeAttributeKeys.FrameRate, out var num, out var den);
            var fps = den > 0 ? (double)num / den : 0;
            var score = Math.Abs((double)h - 720) + (fps < 24 ? 10_000 : 0) - Math.Min(fps, 30);
            if (w > 0 && h > 0 && score < bestScore) { best?.Dispose(); best = type; bestScore = score; }
            else type.Dispose();
        }
        if (best == null) throw new InvalidOperationException("The camera reports no video modes.");
        MediaFactory.MFGetAttributeSize(best, MediaTypeAttributeKeys.FrameSize, out var bw, out var bh);
        MediaFactory.MFGetAttributeRatio(best, MediaTypeAttributeKeys.FrameRate, out var bn, out var bd);
        _reader.SetCurrentMediaType(SourceReaderIndex.FirstVideoStream, best);
        best.Dispose();
        Width = (int)bw & ~1;
        Height = (int)bh & ~1;
        _fps = Math.Clamp(bd > 0 ? (int)Math.Round((double)bn / bd) : 30, 15, 60);
        using (var rgb = MediaFactory.MFCreateMediaType())
        {
            rgb.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            rgb.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.Rgb32);
            MediaFactory.MFSetAttributeSize(rgb, MediaTypeAttributeKeys.FrameSize, bw, bh);
            _reader.SetCurrentMediaType(SourceReaderIndex.FirstVideoStream, rgb);
        }
        _thread = new Thread(Run) { IsBackground = true, Name = "Framelo camera" };
    }

    public void Start(string path)
    {
        _writer = new MfWriter(path, new VideoSpec(Width, Height, _fps, 6_000_000), null, fragmented: true);
        _running = true;
        _thread.Start();
    }

    private void Run()
    {
        var interval = 10_000_000L / _fps;
        while (_running)
        {
            try
            {
                using var sample = _reader.ReadSample(SourceReaderIndex.FirstVideoStream, SourceReaderControlFlag.None, out _, out var flags, out _);
                if ((flags & (SourceReaderFlag.EndOfStream | SourceReaderFlag.Error)) != 0) throw new InvalidOperationException("The camera stopped.");
                if (sample == null || !_running) continue;
                if (_clock.SessionTime(HostClock.Now) is not double t) continue;   // paused
                var time = (long)(t * 10_000_000);
                if (_lastTime != long.MinValue && time - _lastTime < interval * 3 / 4) continue;
                var pixels = MfFrames.CopyBgra(sample, Width, Height);
                _writer!.WriteVideo(pixels, Width * 4, time, interval);
                _last = pixels;
                _lastTime = time;
                StartOffset ??= t;
            }
            catch (Exception e)
            {
                if (_running) Failed?.Invoke(e);
                _running = false;
            }
        }
    }

    /// <summary>Stops and repeats the last picture at endTime so the track lasts as long as the session.</summary>
    public void Stop(double endTime)
    {
        if (_thread.IsAlive) { _running = false; _thread.Join(2000); }
        _running = false;
        try
        {
            var end = (long)(endTime * 10_000_000);
            if (_last != null && end > _lastTime + 10_000_000L / _fps) _writer?.WriteVideo(_last, Width * 4, end, 10_000_000L / _fps);
            _writer?.Finish();
        }
        catch (Exception e) { Failed?.Invoke(e); }
    }

    public void Dispose()
    {
        if (_running) Stop(_lastTime / 10_000_000.0);
        _writer?.Dispose();
        _reader.Dispose();
        try { _source.Shutdown(); } catch (Exception) { }
        _source.Dispose();
    }
}
