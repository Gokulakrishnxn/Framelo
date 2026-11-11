using System.Diagnostics;

namespace Framelo.Platform.Capture;

/// <summary>QueryPerformanceCounter in 100 ns units — the timebase of Direct3D11CaptureFrame.SystemRelativeTime.</summary>
public static class HostClock
{
    public static long Now => (long)(Stopwatch.GetTimestamp() * (10_000_000.0 / Stopwatch.Frequency));
}
