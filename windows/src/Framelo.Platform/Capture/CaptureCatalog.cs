using System.Diagnostics;
using Framelo.Platform.Interop;

namespace Framelo.Platform.Capture;

/// <summary>A monitor, in physical pixels of the virtual desktop.</summary>
public sealed record DisplayInfo(uint Index, IntPtr Handle, string Name, int X, int Y, int Width, int Height, bool IsPrimary)
{
    public string Label => $"{(IsPrimary ? "Main display" : $"Display {Index + 1}")} · {Width}×{Height}";
}

public sealed record WindowInfo(IntPtr Handle, string Title, string ProcessName, int X, int Y, int Width, int Height)
{
    public uint Id => (uint)Handle.ToInt64();
}

/// <summary>Lists what can be recorded. Identifiers match RecordingConfig: displays by index, windows by HWND.</summary>
public static class CaptureCatalog
{
    public static IReadOnlyList<DisplayInfo> Displays()
    {
        var result = new List<DisplayInfo>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr _, ref Native.RECT _, IntPtr _) =>
        {
            var info = new Native.MONITORINFOEX { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFOEX>() };
            if (Native.GetMonitorInfo(h, ref info))
            {
                var r = info.rcMonitor;
                result.Add(new DisplayInfo((uint)result.Count, h, info.szDevice, r.Left, r.Top, r.Width, r.Height, (info.dwFlags & 1) != 0));
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static DisplayInfo? Display(uint index) => Displays().FirstOrDefault(d => d.Index == index);

    /// <summary>Visible, titled top-level windows of other apps, in Z-order.</summary>
    public static IReadOnlyList<WindowInfo> Windows()
    {
        var result = new List<WindowInfo>();
        var shell = Native.GetShellWindow();
        var self = (uint)Environment.ProcessId;
        Native.EnumWindows((hwnd, _) =>
        {
            if (hwnd == shell || !Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd)) return true;
            if (Native.GetAncestor(hwnd, Native.GA_ROOT) != hwnd) return true;
            if ((Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE) & Native.WS_EX_TOOLWINDOW) != 0) return true;
            if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            var title = Native.WindowTitle(hwnd);
            if (string.IsNullOrWhiteSpace(title)) return true;
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == self) return true;
            var rect = Bounds(hwnd);
            if (rect.Width < 50 || rect.Height < 50) return true;
            string process;
            try { process = Process.GetProcessById((int)pid).ProcessName; } catch (Exception) { process = ""; }
            result.Add(new WindowInfo(hwnd, title, process, rect.Left, rect.Top, rect.Width, rect.Height));
            return true;
        }, IntPtr.Zero);
        return result;
    }

    /// <summary>Visible frame of a window without the invisible resize border.</summary>
    internal static Native.RECT Bounds(IntPtr hwnd)
    {
        if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out Native.RECT r,
                System.Runtime.InteropServices.Marshal.SizeOf<Native.RECT>()) == 0) return r;
        Native.GetWindowRect(hwnd, out r);
        return r;
    }
}
