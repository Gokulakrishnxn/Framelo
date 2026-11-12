using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace Framelo.App.Services;

/// <summary>
/// System-wide recording shortcuts, the Windows counterpart of the macOS HotKeyCenter:
/// Ctrl+Shift+2 starts or stops a recording, Ctrl+Shift+3 pauses or resumes it.
/// Registered on the main window with RegisterHotKey; WM_HOTKEY arrives through a window subclass.
/// </summary>
public static class HotKeys
{
    public const string RecordLabel = "Ctrl+Shift+2";
    public const string PauseLabel = "Ctrl+Shift+3";

    private const int WM_HOTKEY = 0x0312;
    private const uint MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_NOREPEAT = 0x4000;
    private const int RecordId = 0xF101, PauseId = 0xF102;

    private delegate IntPtr SubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id, UIntPtr data);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hwnd, int id);

    private static SubclassProc? _proc;   // kept alive for the lifetime of the window
    private static IntPtr _hwnd;
    private static bool _registered;

    public static event Action? RecordPressed;
    public static event Action? PausePressed;

    /// <summary>Hooks the main window once. Call Apply afterwards to follow the preference.</summary>
    public static void Attach(Window window)
    {
        if (_proc != null) return;
        _hwnd = WindowHelpers.Handle(window);
        _proc = (hwnd, msg, wParam, lParam, _, _) =>
        {
            if (msg == WM_HOTKEY)
            {
                var id = wParam.ToInt32();
                if (id == RecordId) window.DispatcherQueue.TryEnqueue(() => RecordPressed?.Invoke());
                else if (id == PauseId) window.DispatcherQueue.TryEnqueue(() => PausePressed?.Invoke());
                return IntPtr.Zero;
            }
            return DefSubclassProc(hwnd, msg, wParam, lParam);
        };
        SetWindowSubclass(_hwnd, _proc, (UIntPtr)1, UIntPtr.Zero);
        window.Closed += (_, _) => Unregister();
    }

    /// <summary>Registers or removes the shortcuts to match Settings › Recording. Returns false if another app owns them.</summary>
    public static bool Apply(bool enabled)
    {
        Unregister();
        if (!enabled || _hwnd == IntPtr.Zero) return true;
        var record = RegisterHotKey(_hwnd, RecordId, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, '2');
        var pause = RegisterHotKey(_hwnd, PauseId, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, '3');
        _registered = record || pause;
        return record && pause;
    }

    private static void Unregister()
    {
        if (!_registered) return;
        UnregisterHotKey(_hwnd, RecordId);
        UnregisterHotKey(_hwnd, PauseId);
        _registered = false;
    }
}
