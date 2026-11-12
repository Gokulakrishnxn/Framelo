using Framelo.Platform.Interop;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;

namespace Framelo.Platform.Capture;

/// <summary>A single BGRA still of a display, used as the backdrop of the area picker.</summary>
public sealed record Snapshot(int Width, int Height, byte[] Bgra);

public static class ScreenSnapshot
{
    public static async Task<Snapshot> CaptureAsync(DisplayInfo display, TimeSpan timeout)
    {
        using var gpu = new GraphicsDevice();
        var item = GraphicsDevice.CaptureItemForMonitor(display.Handle);
        using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(gpu.WinRTDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 1, item.Size);
        var done = new TaskCompletionSource<Snapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        pool.FrameArrived += (p, _) =>
        {
            try
            {
                using var frame = p.TryGetNextFrame();
                if (frame == null) return;
                using var texture = GraphicsDevice.TextureFromSurface(frame.Surface);
                done.TrySetResult(Read(gpu, texture));
            }
            catch (Exception e) { done.TrySetException(e); }
        };
        using var session = pool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled = false;
        session.StartCapture();
        var finished = await Task.WhenAny(done.Task, Task.Delay(timeout));
        if (finished != done.Task) throw new TimeoutException("The display did not return a picture.");
        return await done.Task;
    }

    private static unsafe Snapshot Read(GraphicsDevice gpu, ID3D11Texture2D texture)
    {
        var d = texture.Description;
        using var staging = gpu.Device.CreateTexture2D(new Texture2DDescription
        {
            Width = d.Width, Height = d.Height, MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Staging, CPUAccessFlags = CpuAccessFlags.Read,
        });
        lock (gpu.ContextLock) gpu.Context.CopyResource(staging, texture);
        var w = (int)d.Width; var h = (int)d.Height;
        var result = new byte[w * h * 4];
        lock (gpu.ContextLock)
        {
            var map = gpu.Context.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
            try
            {
                for (var y = 0; y < h; y++)
                    new ReadOnlySpan<byte>((byte*)map.DataPointer + y * map.RowPitch, w * 4).CopyTo(result.AsSpan(y * w * 4));
            }
            finally { gpu.Context.Unmap(staging, 0); }
        }
        return new Snapshot(w, h, result);
    }
}

/// <summary>Window helpers the UI needs.</summary>
public static class WindowCapture
{
    /// <summary>Keeps one of Framelo's own windows (capture bar, countdown) out of every recording.</summary>
    public static void Exclude(IntPtr hwnd) => Native.ExcludeFromCapture(hwnd);
}
