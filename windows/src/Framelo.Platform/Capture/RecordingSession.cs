using Framelo.Core;
using Framelo.Platform.Interop;
using Framelo.Platform.Media;
using Windows.Graphics.Capture;

namespace Framelo.Platform.Capture;

public enum RecordingState { Recording, Paused, Finishing, Finished, Failed }

/// <summary>
/// One recording: screen (display, window or area), optional microphone and system audio, and the cursor,
/// all on one session clock. The journal is rewritten every two seconds, so an interrupted session is rebuilt
/// by RecoveryService at the next launch.
/// </summary>
public sealed class RecordingSession : IDisposable
{
    private readonly ProjectStore _store;
    private readonly RecordingJournal _journal;
    private readonly string _package;
    private readonly RecordingClock _clock = new();
    private readonly GraphicsDevice _gpu;
    private readonly ScreenRecorder _screen;
    private readonly AudioRecorder? _mic;
    private readonly AudioRecorder? _system;
    private readonly CursorRecorder _cursor;
    private readonly Timer _heartbeat;
    private readonly object _gate = new();

    public RecordingState State { get; private set; } = RecordingState.Recording;
    public Guid ProjectId => _journal.Id;
    public string? FailureReason { get; private set; }
    public event Action<string>? Failed;

    public double Elapsed => _clock.SessionTime(HostClock.Now) ?? _pausedElapsed;
    private double _pausedElapsed;
    public float MicrophoneLevel => _mic?.Level ?? 0;

    private RecordingSession(ProjectStore store, RecordingConfig config, string name)
    {
        _store = store;
        _journal = new RecordingJournal { Id = Guid.NewGuid(), Name = name, Config = config };
        _package = store.CreatePackage(_journal.Id);
        _journal.Write(_package);
        _gpu = new GraphicsDevice();

        var (item, crop, area) = Resolve(config.Target);
        _journal.Capture = new CaptureInfo { X = area().Left, Y = area().Top, Width = area().Width, Height = area().Height, Scale = 1 };
        _screen = new ScreenRecorder(_gpu, item, _clock, config.FrameRate, crop);
        if (config.CaptureMicrophone)
        {
            try { _mic = AudioRecorder.Microphone(_clock, config.MicrophoneId); }
            catch (Exception) { _mic = null; /* no microphone: record without it */ }
        }
        if (config.CaptureSystemAudio)
        {
            try { _system = AudioRecorder.SystemAudio(_clock); }
            catch (Exception) { _system = null; }
        }
        _cursor = new CursorRecorder(Path.Combine(_package, ProjectPackage.CursorFile), _clock, area);
        _heartbeat = new Timer(_ => WriteJournal(), null, Timeout.Infinite, Timeout.Infinite);
    }

    /// <summary>Starts recording immediately (the countdown is the UI's job).</summary>
    public static RecordingSession Start(ProjectStore store, RecordingConfig config, string name, int bitRate)
    {
        var session = new RecordingSession(store, config, name);
        try
        {
            session.Begin(bitRate);
        }
        catch
        {
            session.Abort();
            throw;
        }
        return session;
    }

    private void Begin(int bitRate)
    {
        var media = Path.Combine(_package, ProjectPackage.MediaDirectory);
        _clock.Start(HostClock.Now);
        _screen.Failed += e => Fail($"Screen capture stopped: {e.Message}");
        _screen.Start(Path.Combine(media, RecordingJournal.FileName(JournalTrackKind.Screen)), bitRate);
        _journal.Tracks.Add(new RecordingJournal.Track { Kind = JournalTrackKind.Screen, RelativePath = RecordingJournal.RelativePathFor(JournalTrackKind.Screen) });
        StartAudio(_mic, JournalTrackKind.Microphone, media);
        StartAudio(_system, JournalTrackKind.SystemAudio, media);
        _cursor.Start();
        _journal.State = JournalState.Recording;
        WriteJournal();
        _heartbeat.Change(2000, 2000);
    }

    private void StartAudio(AudioRecorder? recorder, JournalTrackKind kind, string media)
    {
        if (recorder == null) return;
        recorder.Start(Path.Combine(media, RecordingJournal.FileName(kind)));
        _journal.Tracks.Add(new RecordingJournal.Track { Kind = kind, RelativePath = RecordingJournal.RelativePathFor(kind) });
    }

    /// <summary>Maps a target to a capture item, an optional crop inside it, and the captured screen rectangle.</summary>
    private static (GraphicsCaptureItem Item, (int, int, int, int)? Crop, Func<Native.RECT> Area) Resolve(CaptureTarget target)
    {
        switch (target)
        {
            case CaptureTarget.Window w:
            {
                var hwnd = new IntPtr(w.Id);
                var item = GraphicsDevice.CaptureItemForWindow(hwnd);
                return (item, null, () => CaptureCatalog.Bounds(hwnd));
            }
            case CaptureTarget.Region r:
            {
                var display = CaptureCatalog.Display(r.DisplayId) ?? throw new InvalidOperationException("That display is no longer connected.");
                var item = GraphicsDevice.CaptureItemForMonitor(display.Handle);
                var x = (int)Math.Clamp(r.X, 0, display.Width - 2);
                var y = (int)Math.Clamp(r.Y, 0, display.Height - 2);
                var width = (int)Math.Clamp(r.Width, 2, display.Width - x);
                var height = (int)Math.Clamp(r.Height, 2, display.Height - y);
                var rect = new Native.RECT { Left = display.X + x, Top = display.Y + y, Right = display.X + x + width, Bottom = display.Y + y + height };
                return (item, (x, y, width, height), () => rect);
            }
            case CaptureTarget.Display d:
            {
                var display = CaptureCatalog.Display(d.Id) ?? CaptureCatalog.Displays().First();
                var item = GraphicsDevice.CaptureItemForMonitor(display.Handle);
                var rect = new Native.RECT { Left = display.X, Top = display.Y, Right = display.X + display.Width, Bottom = display.Y + display.Height };
                return (item, null, () => rect);
            }
            default:
                throw new ArgumentOutOfRangeException(nameof(target));
        }
    }

    public void Pause()
    {
        lock (_gate)
        {
            if (State != RecordingState.Recording) return;
            _pausedElapsed = Elapsed;
            _clock.Pause(HostClock.Now);
            State = RecordingState.Paused;
            _journal.State = JournalState.Paused;
        }
        WriteJournal();
    }

    public void Resume()
    {
        lock (_gate)
        {
            if (State != RecordingState.Paused) return;
            _clock.Resume(HostClock.Now);
            State = RecordingState.Recording;
            _journal.State = JournalState.Recording;
        }
        WriteJournal();
    }

    /// <summary>Stops every track, finalises the files and builds the project.</summary>
    public Project Stop()
    {
        lock (_gate)
        {
            if (State is RecordingState.Finishing or RecordingState.Finished) throw new InvalidOperationException("Already stopped.");
            if (State == RecordingState.Paused) _clock.Resume(HostClock.Now);
            State = RecordingState.Finishing;
        }
        var end = _clock.SessionTime(HostClock.Now) ?? _screen.LastFrameTime;
        _heartbeat.Change(Timeout.Infinite, Timeout.Infinite);
        _journal.State = JournalState.Finalizing;
        WriteJournal();

        _cursor.Dispose();
        _screen.Stop(end);
        _mic?.Stop(end);
        _system?.Stop(end);
        UpdateOffsets();
        if (_mic is { StartOffset: double micStart })
            _journal.TrackFor(JournalTrackKind.Microphone)!.RateCorrection =
                AudioTiming.RateCorrection(_mic.FramesWritten, _mic.SampleRate, end - micStart);
        WriteJournal();

        try
        {
            var project = RecordingFinalizer.BuildProject(_package, _journal, recovered: false, new MfInspector());
            _store.Save(project);
            _journal.State = JournalState.Complete;
            WriteJournal();
            State = RecordingState.Finished;
            return project;
        }
        catch (Exception e)
        {
            State = RecordingState.Failed;
            _journal.State = JournalState.Failed;
            _journal.FailureReason = e.Message;
            WriteJournal();
            throw;
        }
        finally
        {
            DisposeRecorders();
        }
    }

    /// <summary>Stops without keeping anything: the package is deleted.</summary>
    public void Discard()
    {
        lock (_gate)
        {
            if (State is RecordingState.Finishing or RecordingState.Finished) return;
            State = RecordingState.Finished;
        }
        _heartbeat.Change(Timeout.Infinite, Timeout.Infinite);
        var end = _clock.SessionTime(HostClock.Now) ?? 0;
        try { _screen.Stop(end); } catch (Exception) { }
        try { _mic?.Stop(end); _system?.Stop(end); } catch (Exception) { }
        DisposeRecorders();
        try { Directory.Delete(_package, recursive: true); } catch (Exception) { /* RecoveryService tidies it up later */ }
    }

    private void UpdateOffsets()
    {
        if (_screen.StartOffset is double s) _journal.SetOffset(s, JournalTrackKind.Screen);
        if (_mic?.StartOffset is double m) _journal.SetOffset(m, JournalTrackKind.Microphone);
        if (_system?.StartOffset is double a) _journal.SetOffset(a, JournalTrackKind.SystemAudio);
    }

    private void WriteJournal()
    {
        lock (_gate)
        {
            try
            {
                UpdateOffsets();
                _journal.Heartbeat = DateTimeOffset.UtcNow;
                _journal.Write(_package);
            }
            catch (Exception) { /* the next heartbeat retries */ }
        }
    }

    private void Fail(string reason)
    {
        if (FailureReason != null) return;
        FailureReason = reason;
        Failed?.Invoke(reason);
    }

    /// <summary>Abandons a session that could not start. Files stay for RecoveryService to judge.</summary>
    private void Abort()
    {
        State = RecordingState.Failed;
        _journal.State = JournalState.Failed;
        WriteJournal();
        DisposeRecorders();
    }

    private void DisposeRecorders()
    {
        _heartbeat.Dispose();
        try { _cursor.Dispose(); } catch (Exception) { }
        try { _screen.Dispose(); } catch (Exception) { }
        try { _mic?.Dispose(); } catch (Exception) { }
        try { _system?.Dispose(); } catch (Exception) { }
        _gpu.Dispose();
    }

    public void Dispose()
    {
        if (State is RecordingState.Recording or RecordingState.Paused)
        {
            try { Stop(); } catch (Exception) { }
        }
    }
}
