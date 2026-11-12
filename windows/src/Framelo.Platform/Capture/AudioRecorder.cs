using Framelo.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Framelo.Platform.Capture;

public sealed record AudioDevice(string Id, string Name, bool IsDefault);

/// <summary>
/// Records the microphone or the system output (WASAPI loopback) into a crash-tolerant WAV file kept on the
/// session clock: silence is inserted where loopback delivered nothing, and paused time is dropped.
/// </summary>
public sealed class AudioRecorder : IDisposable
{
    private readonly IWaveIn _capture;
    private readonly RecordingClock _clock;
    private readonly object _gate = new();
    private WavFile? _file;
    private AudioTiming? _timing;
    private DateTime _lastFlush = DateTime.UtcNow;
    private bool _stopped;

    public bool IsLoopback { get; }
    public double? StartOffset => _timing?.StartOffset;
    public long FramesWritten => _timing?.FramesWritten ?? 0;
    public int SampleRate => _capture.WaveFormat.SampleRate;
    public event Action<Exception>? Failed;
    /// <summary>Peak level of the latest packet, 0…1, for the capture bar's meter.</summary>
    public float Level { get; private set; }

    private AudioRecorder(IWaveIn capture, RecordingClock clock, bool loopback)
    {
        _capture = capture; _clock = clock; IsLoopback = loopback;
        _capture.DataAvailable += OnData;
        _capture.RecordingStopped += (_, e) => { if (e.Exception != null) Failed?.Invoke(e.Exception); };
    }

    public static AudioRecorder SystemAudio(RecordingClock clock) => new(new WasapiLoopbackCapture(), clock, true);

    public static AudioRecorder Microphone(RecordingClock clock, string? deviceId)
    {
        using var enumerator = new MMDeviceEnumerator();
        MMDevice device;
        try
        {
            device = deviceId != null ? enumerator.GetDevice(deviceId) : enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
        }
        catch (Exception)
        {
            device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
        }
        return new AudioRecorder(new WasapiCapture(device, true, 20), clock, false);
    }

    public static IReadOnlyList<AudioDevice> Microphones()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            string? defaultId = null;
            try { defaultId = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).ID; } catch (Exception) { }
            return enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
                .Select(d => new AudioDevice(d.ID, d.FriendlyName, d.ID == defaultId)).ToList();
        }
        catch (Exception)
        {
            return Array.Empty<AudioDevice>();
        }
    }

    public void Start(string path)
    {
        var f = _capture.WaveFormat;
        var isFloat = f.Encoding == WaveFormatEncoding.IeeeFloat ||
                      (f is WaveFormatExtensible ext && ext.SubFormat == NAudio.Dmo.AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT);
        _file = new WavFile(path, f.SampleRate, f.Channels, f.BitsPerSample, isFloat);
        _timing = new AudioTiming(f.SampleRate);
        _capture.StartRecording();
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        try
        {
            if (e.BytesRecorded == 0) return;
            var now = _clock.SessionTime(HostClock.Now);
            lock (_gate)
            {
                if (_stopped || _file == null || _timing == null || now is not double t) return;
                var frames = e.BytesRecorded / _file.BlockAlign;
                var silence = _timing.SilenceBefore(frames, t);
                WriteSilence(silence);
                _file.Write(e.Buffer.AsSpan(0, frames * _file.BlockAlign));
                _timing.Wrote(frames);
                Level = Peak(e.Buffer.AsSpan(0, frames * _file.BlockAlign));
                if ((DateTime.UtcNow - _lastFlush).TotalSeconds >= 1)
                {
                    _file.Flush();
                    _lastFlush = DateTime.UtcNow;
                }
            }
        }
        catch (Exception ex)
        {
            Failed?.Invoke(ex);
        }
    }

    private void WriteSilence(long frames)
    {
        if (frames <= 0 || _file == null) return;
        var chunk = new byte[Math.Min(frames, 48_000) * _file.BlockAlign];
        while (frames > 0)
        {
            var n = Math.Min(frames, chunk.Length / _file.BlockAlign);
            _file.Write(chunk.AsSpan(0, (int)n * _file.BlockAlign));
            _timing!.Wrote(n);
            frames -= n;
        }
    }

    private float Peak(ReadOnlySpan<byte> data)
    {
        if (_file == null) return 0;
        float peak = 0;
        if (_file.IsFloat && _file.BitsPerSample == 32)
        {
            foreach (var s in System.Runtime.InteropServices.MemoryMarshal.Cast<byte, float>(data)) peak = Math.Max(peak, Math.Abs(s));
        }
        else if (_file.BitsPerSample == 16)
        {
            foreach (var s in System.Runtime.InteropServices.MemoryMarshal.Cast<byte, short>(data)) peak = Math.Max(peak, Math.Abs(s / 32768f));
        }
        return Math.Min(peak, 1);
    }

    /// <summary>Stops and pads the file with silence to endTime (session seconds).</summary>
    public void Stop(double endTime)
    {
        try { _capture.StopRecording(); } catch (Exception) { }
        lock (_gate)
        {
            if (_stopped) return;
            _stopped = true;
            if (_timing != null && _timing.StartOffset != null) WriteSilence(_timing.TailSilence(endTime));
            _file?.Dispose();
        }
    }

    public void Dispose()
    {
        Stop(0);
        _capture.Dispose();
    }
}
