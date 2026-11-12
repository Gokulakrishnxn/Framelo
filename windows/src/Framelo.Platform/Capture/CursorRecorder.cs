using System.Text;
using Framelo.Core;
using Framelo.Platform.Interop;

namespace Framelo.Platform.Capture;

/// <summary>
/// Samples the pointer at 120 Hz and writes cursor.jsonl (same format as macOS): moves, button down/up, and
/// cursor-shape changes, normalised to the captured rectangle. Uses polling, so it needs no hooks or elevation.
/// </summary>
public sealed class CursorRecorder : IDisposable
{
    private readonly RecordingClock _clock;
    private readonly Func<Native.RECT> _area;
    private readonly StreamWriter _writer;
    private readonly Thread _thread;
    private readonly IntPtr _ibeam = Native.LoadCursor(IntPtr.Zero, Native.IDC_IBEAM);
    private readonly IntPtr _hand = Native.LoadCursor(IntPtr.Zero, Native.IDC_HAND);
    private volatile bool _running = true;

    internal CursorRecorder(string path, RecordingClock clock, Func<Native.RECT> area)
    {
        _clock = clock;
        _area = area;
        _writer = new StreamWriter(new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read), new UTF8Encoding(false));
        _thread = new Thread(Run) { IsBackground = true, Name = "Framelo cursor", Priority = ThreadPriority.AboveNormal };
    }

    public void Start() => _thread.Start();

    private void Run()
    {
        double lastX = double.NaN, lastY = double.NaN;
        var down = false;
        CursorKind? kind = null;
        var lastFlush = Environment.TickCount64;
        var button = Native.GetSystemMetrics(Native.SM_SWAPBUTTON) != 0 ? Native.VK_RBUTTON : Native.VK_LBUTTON;
        var info = new Native.CURSORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.CURSORINFO>() };
        while (_running)
        {
            try
            {
                if (_clock.SessionTime(HostClock.Now) is double t && Native.GetCursorInfo(ref info))
                {
                    var r = _area();
                    if (r.Width > 0 && r.Height > 0)
                    {
                        var x = (info.ptScreenPos.X - r.Left + 0.5) / r.Width;
                        var y = (info.ptScreenPos.Y - r.Top + 0.5) / r.Height;
                        if (Math.Abs(x - lastX) > 1e-5 || Math.Abs(y - lastY) > 1e-5)
                        {
                            _writer.Write(CursorTrack.EncodeMove(new CursorSample(t, x, y)));
                            lastX = x; lastY = y;
                        }
                        var k = info.hCursor == _ibeam ? CursorKind.IBeam : info.hCursor == _hand ? CursorKind.PointingHand : CursorKind.Arrow;
                        if (k != kind) { _writer.Write(CursorTrack.EncodeKind(t, k)); kind = k; }
                        var pressed = (Native.GetAsyncKeyState(button) & 0x8000) != 0;
                        if (pressed && !down) _writer.Write(CursorTrack.EncodeDown(t, x, y));
                        if (!pressed && down) _writer.Write(CursorTrack.EncodeUp(t));
                        down = pressed;
                    }
                }
                if (Environment.TickCount64 - lastFlush > 500) { _writer.Flush(); lastFlush = Environment.TickCount64; }
            }
            catch (Exception) { /* a transient failure must not end the recording */ }
            Thread.Sleep(8);
        }
        _writer.Flush();
    }

    public void Dispose()
    {
        _running = false;
        if (_thread.IsAlive) _thread.Join(500);
        _writer.Dispose();
    }
}
