namespace Framelo.Core;

public enum JournalState { Preparing, Recording, Paused, Finalizing, Complete, Failed }

public enum JournalTrackKind { Screen, SystemAudio, Microphone, Camera }

/// <summary>
/// Durable record of a recording session, rewritten atomically as it progresses. If the app dies, this file
/// plus the fragmented media files are enough to rebuild the project. Same schema as macOS session.json.
/// </summary>
public sealed class RecordingJournal
{
    public sealed class Track
    {
        public JournalTrackKind Kind { get; set; }
        public string RelativePath { get; set; } = "";
        /// <summary>Session time of the first sample; null until the first sample is written.</summary>
        public double? StartOffset { get; set; }
        public double? RateCorrection { get; set; }
    }

    /// <summary>
    /// Windows writes fragmented MP4 for video and WAV (header refreshed every flush) for audio, both readable
    /// after a crash. Paths are stored per track, so macOS .mov sessions remain valid too.
    /// </summary>
    public static string FileName(JournalTrackKind kind) => kind switch
    {
        JournalTrackKind.Screen => "screen.mp4",
        JournalTrackKind.SystemAudio => "system-audio.wav",
        JournalTrackKind.Microphone => "microphone.wav",
        _ => "camera.mp4",
    };

    public static string RelativePathFor(JournalTrackKind kind) => $"{ProjectPackage.MediaDirectory}/{FileName(kind)}";

    public Guid Id { get; set; }
    public string Name { get; set; } = "";
    public JournalState State { get; set; } = JournalState.Preparing;
    public RecordingConfig Config { get; set; } = new();
    public CaptureInfo? Capture { get; set; }
    public DateTimeOffset StartedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset Heartbeat { get; set; } = DateTimeOffset.UtcNow;
    public List<Track> Tracks { get; set; } = new();
    public string? FailureReason { get; set; }

    public void SetOffset(double offset, JournalTrackKind kind)
    {
        var t = Tracks.FirstOrDefault(x => x.Kind == kind);
        if (t != null) t.StartOffset = offset;
        else Tracks.Add(new Track { Kind = kind, RelativePath = RelativePathFor(kind), StartOffset = offset });
    }

    public Track? TrackFor(JournalTrackKind kind) => Tracks.FirstOrDefault(t => t.Kind == kind);

    public static string PathIn(string package) => Path.Combine(package, ProjectPackage.SessionFile);
    public void Write(string package) => AtomicFile.WriteAllText(PathIn(package), ProjectJson.Serialize(this));
    public static RecordingJournal Read(string package) => ProjectJson.Deserialize<RecordingJournal>(File.ReadAllText(PathIn(package)));
}

/// <summary>Converts host time to session time and removes paused intervals. Thread-safe.</summary>
public sealed class RecordingClock
{
    private readonly object _gate = new();
    private long? _origin;
    private long? _pausedAt;
    private long _pausedTotal;
    private readonly long _frequency;

    public RecordingClock(long frequency = 10_000_000) => _frequency = frequency;

    public void Start(long hostTime) { lock (_gate) { _origin = hostTime; _pausedAt = null; _pausedTotal = 0; } }
    public void Pause(long hostTime) { lock (_gate) { _pausedAt ??= hostTime; } }

    public void Resume(long hostTime)
    {
        lock (_gate)
        {
            if (_pausedAt is long p) { _pausedTotal += hostTime - p; _pausedAt = null; }
        }
    }

    public bool IsPaused { get { lock (_gate) return _pausedAt != null; } }

    /// <summary>Session seconds for a host timestamp, or null before start or while paused.</summary>
    public double? SessionTime(long hostTime)
    {
        lock (_gate)
        {
            if (_origin is not long o || _pausedAt != null || hostTime < o) return null;
            return (double)(hostTime - o - _pausedTotal) / _frequency;
        }
    }
}
