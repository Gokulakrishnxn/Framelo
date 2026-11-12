using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace Framelo.App.Services;

public static class WindowHelpers
{
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hwnd);

    public static IntPtr Handle(Window window) => WinRT.Interop.WindowNative.GetWindowHandle(window);

    /// <summary>Pixels per DIP for the monitor the window is on.</summary>
    public static double Scale(Window window)
    {
        var dpi = GetDpiForWindow(Handle(window));
        return dpi > 0 ? dpi / 96.0 : 1;
    }

    /// <summary>A borderless, always-on-top tool window, as used for the capture bar.</summary>
    public static void MakeFloating(Window window)
    {
        if (window.AppWindow.Presenter is OverlappedPresenter p)
        {
            p.IsAlwaysOnTop = true;
            p.IsResizable = false;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
            p.SetBorderAndTitleBar(false, false);
        }
        window.AppWindow.IsShownInSwitchers = false;
    }

    public static void Minimize(Window window)
    {
        if (window.AppWindow.Presenter is OverlappedPresenter p) p.Minimize();
    }

    public static void Restore(Window window)
    {
        if (window.AppWindow.Presenter is OverlappedPresenter p) p.Restore();
        window.Activate();
    }
}
