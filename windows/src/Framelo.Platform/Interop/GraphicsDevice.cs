using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace Framelo.Platform.Interop;

/// <summary>One Direct3D 11 device, usable both by Vortice (D3D11) and by WinRT (Windows.Graphics.Capture).</summary>
public sealed class GraphicsDevice : IDisposable
{
    private static readonly Guid DxgiDeviceGuid = typeof(IDXGIDevice).GUID;
    private static readonly Guid Texture2DGuid = typeof(ID3D11Texture2D).GUID;
    private static readonly Guid GraphicsCaptureItemGuid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    public ID3D11Device Device { get; }
    public ID3D11DeviceContext Context { get; }
    public IDirect3DDevice WinRTDevice { get; }
    /// <summary>The immediate context is not thread-safe; take this lock around every use.</summary>
    public object ContextLock { get; } = new();

    public GraphicsDevice()
    {
        var flags = DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport;
        var result = D3D11.D3D11CreateDevice(null, DriverType.Hardware, flags,
            new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0, FeatureLevel.Level_10_1 }, out ID3D11Device device, out ID3D11DeviceContext context);
        if (result.Failure)
        {
            // No usable GPU (e.g. a VM without acceleration): fall back to the WARP software rasteriser.
            D3D11.D3D11CreateDevice(null, DriverType.Warp, DeviceCreationFlags.BgraSupport,
                new[] { FeatureLevel.Level_11_0 }, out device, out context).CheckError();
        }
        Device = device!;
        Context = context!;
        using (var multithread = Device.QueryInterfaceOrNull<ID3D11Multithread>()) multithread?.SetMultithreadProtected(true);
        using var dxgi = Device.QueryInterface<IDXGIDevice>();
        Marshal.ThrowExceptionForHR(Native.CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var inspectable));
        WinRTDevice = MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
        Marshal.Release(inspectable);
    }

    public static ID3D11Texture2D TextureFromSurface(IDirect3DSurface surface)
    {
        var access = surface.As<IDirect3DDxgiInterfaceAccess>();
        var guid = Texture2DGuid;
        return new ID3D11Texture2D(access.GetInterface(ref guid));
    }

    public static GraphicsCaptureItem CaptureItemForMonitor(IntPtr hmonitor)
    {
        var interop = GraphicsCaptureItem.As<IGraphicsCaptureItemInterop>();
        var guid = GraphicsCaptureItemGuid;
        var pointer = interop.CreateForMonitor(hmonitor, ref guid);
        try { return GraphicsCaptureItem.FromAbi(pointer); }
        finally { Marshal.Release(pointer); }
    }

    public static GraphicsCaptureItem CaptureItemForWindow(IntPtr hwnd)
    {
        var interop = GraphicsCaptureItem.As<IGraphicsCaptureItemInterop>();
        var guid = GraphicsCaptureItemGuid;
        var pointer = interop.CreateForWindow(hwnd, ref guid);
        try { return GraphicsCaptureItem.FromAbi(pointer); }
        finally { Marshal.Release(pointer); }
    }

    public void Dispose()
    {
        WinRTDevice.Dispose();
        Context.Dispose();
        Device.Dispose();
    }
}
