using Framelo.Core;
using Framelo.Platform.Interop;
using Framelo.Platform.Media;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;

namespace Framelo.Platform.Capture;

/// <summary>
/// Records a GraphicsCaptureItem (display or window) into a fragmented MP4, optionally cropped to an area.
/// Windows.Graphics.Capture only delivers frames when something changes, so a heartbeat repeats the last frame
/// while the screen is still; that keeps the file's duration equal to wall-clock time and fragments flowing.
/// The system cursor is never captured — it is recorded separately and drawn by the renderer.
/// </summary>
public sealed class ScreenRecorder : IDisposable
{
    private readonly GraphicsDevice _gpu;
    private readonly GraphicsCaptureItem _item;
    private readonly RecordingClock _clock;
    private readonly (int X, int Y)? _cropOrigin;
    private readonly int _fps;
    private readonly long _interval;
    private readonly object _gate = new();
    private Direct3D11CaptureFramePool? _pool;
    private Windows.Graphics.SizeInt32 _poolSize;
    private GraphicsCaptureSession? _session;
    private ID3D11Texture2D? _staging;
    private MfWriter? _writer;
    private Timer? _heartbeat;
    private long _lastWritten = long.MinValue;
    private bool _haveFrame;
    private bool _stopped;

    public int Width { get; }
    public int Height { get; }
    /// <summary>Session time of the first frame, once one has been written.</summary>
    public double? StartOffset { get; private set; }
    public double LastFrameTime { get; private set; }
    public event Action<Exception>? Failed;

    /// <param name="crop">Area inside the item in item pixels (area recording), or null for the whole item.</param>
    public ScreenRecorder(GraphicsDevice gpu, GraphicsCaptureItem item, RecordingClock clock, int fps,
        (int X, int Y, int Width, int Height)? crop)
    {
        _gpu = gpu; _item = item; _clock = clock; _fps = Math.Clamp(fps, 1, 120);
        _interval = 10_000_000L / _fps;
        var w = crop?.Width ?? item.Size.Width;
        var h = crop?.Height ?? item.Size.Height;
        Width = Math.Max(2, w & ~1);
        Height = Math.Max(2, h & ~1);
        if (crop is { } c) _cropOrigin = (c.X, c.Y);
    }

    public void Start(string path, int bitRate)
    {
        _writer = new MfWriter(path, new VideoSpec(Width, Height, _fps, bitRate), null, fragmented: true);
        _staging = _gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)Width, Height = (uint)Height, MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read, BindFlags = BindFlags.None,
        });
        _poolSize = _item.Size;
        _pool = Direct3D11CaptureFramePool.CreateFreeThreaded(_gpu.WinRTDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, _poolSize);
        _pool.FrameArrived += OnFrame;
        _session = _pool.CreateCaptureSession(_item);
        _session.IsCursorCaptureEnabled = false;
        // Windows 11 can hide the yellow capture border; Windows 10 always shows it.
        if (Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired"))
        {
            try { _session.IsBorderRequired = false; } catch (Exception) { }
        }
        _session.StartCapture();
        _heartbeat = new Timer(_ => Heartbeat(), null, 250, 250);
    }

    private void OnFrame(Direct3D11CaptureFramePool pool, object _)
    {
        try
        {
            using var frame = pool.TryGetNextFrame();
            if (frame == null) return;
            var host = frame.SystemRelativeTime.Ticks;
            if (_clock.SessionTime(host) is not double t) return;
            var time = (long)(t * 10_000_000);
            lock (_gate)
            {
                if (_stopped) return;
                // Keep to the requested frame rate; WGC can deliver faster than that.
                if (_lastWritten != long.MinValue && time - _lastWritten < _interval * 3 / 4) return;
                using (var texture = GraphicsDevice.TextureFromSurface(frame.Surface))
                {
                    var desc = texture.Description;
                    var x = _cropOrigin?.X ?? 0;
                    var y = _cropOrigin?.Y ?? 0;
                    var w = Math.Min(Width, (int)desc.Width - x);
                    var h = Math.Min(Height, (int)desc.Height - y);
                    if (w <= 0 || h <= 0) return;
                    lock (_gpu.ContextLock)
                    {
                        _gpu.Context.CopySubresourceRegion(_staging!, 0, 0, 0, 0, texture, 0, new Vortice.Mathematics.Box(x, y, 0, x + w, y + h, 1));
                    }
                }
                WriteStaging(time);
                _haveFrame = true;
                StartOffset ??= t;
            }
            // A window that changes size keeps the encoder size; the pool follows its content so frames are not
            // clipped or padded. Compare with the pool's own size — the item's size has already changed.
            var content = frame.ContentSize;
            if (content.Width > 0 && content.Height > 0 && (content.Width != _poolSize.Width || content.Height != _poolSize.Height))
            {
                _poolSize = content;
                pool.Recreate(_gpu.WinRTDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, content);
            }
        }
        catch (Exception e)
        {
            Failed?.Invoke(e);
        }
    }

    private void Heartbeat()
    {
        try
        {
            if (_clock.SessionTime(HostClock.Now) is not double t) return;
            var time = (long)(t * 10_000_000);
            lock (_gate)
            {
                if (_stopped || !_haveFrame || time - _lastWritten < _interval * 4) return;
                WriteStaging(time);
            }
        }
        catch (Exception e)
        {
            Failed?.Invoke(e);
        }
    }

    /// <summary>Encodes the staging texture at a session time (100 ns). Caller holds _gate.</summary>
    private unsafe void WriteStaging(long time)
    {
        MappedSubresource map;
        lock (_gpu.ContextLock) map = _gpu.Context.Map(_staging!, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        try
        {
            var span = new ReadOnlySpan<byte>((void*)map.DataPointer, (int)map.RowPitch * Height);
            _writer!.WriteVideo(span, (int)map.RowPitch, time, _interval);
        }
        finally
        {
            lock (_gpu.ContextLock) _gpu.Context.Unmap(_staging!, 0);
        }
        _lastWritten = time;
        LastFrameTime = time / 10_000_000.0;
    }

    /// <summary>Stops capture. The last picture is repeated at endTime so the video lasts as long as the session.</summary>
    public void Stop(double endTime)
    {
        _heartbeat?.Dispose();
        _session?.Dispose();
        _pool?.Dispose();
        lock (_gate)
        {
            if (_stopped) return;
            var time = (long)(endTime * 10_000_000);
            if (_haveFrame && time > _lastWritten + _interval / 2) WriteStaging(time);
            _stopped = true;
            _writer?.Finish();
        }
    }

    public void Dispose()
    {
        if (!_stopped) Stop(LastFrameTime);
        _writer?.Dispose();
        _staging?.Dispose();
    }
}
