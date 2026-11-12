using System.Text.Json.Serialization;

namespace Framelo.Core;

// The project model mirrors FrameloCore/Models on macOS property for property, so a project.json
// written by either app opens in the other. Property names become camelCase JSON keys.

public sealed class ClipTransform
{
    public double Scale { get; set; } = 1;
    public double OffsetX { get; set; }
    public double OffsetY { get; set; }
}

public enum TransitionKind { Fade, ZoomFade }

public sealed class ClipTransition
{
    public TransitionKind Kind { get; set; } = TransitionKind.Fade;
    public double Duration { get; set; } = 0.4;
}

/// <summary>A non-destructive reference to a time range of a source, placed on the timeline.</summary>
public sealed class VideoClip
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid SourceId { get; set; }
    public MediaTime SourceStart { get; set; }
    public MediaTime SourceEnd { get; set; }
    public MediaTime TimelinePosition { get; set; }
    public double PlaybackSpeed { get; set; } = 1;
    public double Volume { get; set; } = 1;
    public bool IsMuted { get; set; }
    public ClipTransform Transform { get; set; } = new();
    public ClipTransition? TransitionIn { get; set; }
    public ClipTransition? TransitionOut { get; set; }

    [JsonIgnore] public MediaTime SourceDuration => SourceEnd - SourceStart;
    [JsonIgnore] public MediaTime TimelineDuration => SourceDuration.DividedBy(PlaybackSpeed);
    [JsonIgnore] public MediaRange TimelineRange => new(TimelinePosition, TimelineDuration);
    [JsonIgnore] public MediaTime TimelineEnd => TimelinePosition + TimelineDuration;

    public MediaTime SourceTime(MediaTime timeline)
    {
        var local = (timeline - TimelinePosition).MultipliedBy(PlaybackSpeed);
        return MediaTime.Min(MediaTime.Max(SourceStart + local, SourceStart), SourceEnd);
    }
}

public sealed class AudioClip
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid SourceId { get; set; }
    public MediaTime SourceStart { get; set; }
    public MediaTime SourceEnd { get; set; }
    public MediaTime TimelinePosition { get; set; }
    public double Volume { get; set; } = 1;
    public bool IsMuted { get; set; }
    public double FadeIn { get; set; }
    public double FadeOut { get; set; }

    [JsonIgnore] public MediaTime Duration => SourceEnd - SourceStart;
    [JsonIgnore] public MediaTime TimelineEnd => TimelinePosition + Duration;
}

public enum TrackKind { Video, Camera, Microphone, SystemAudio, Audio }

public sealed class TimelineTrack
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public TrackKind Type { get; set; }
    public List<VideoClip> Clips { get; set; } = new();
    public List<AudioClip> AudioClips { get; set; } = new();
    public bool IsMuted { get; set; }
    public bool IsVisible { get; set; } = true;
    public double Volume { get; set; } = 1;
}

/// <summary>A camera zoom on the timeline. Targets are normalised to the screen content (0…1, top-left origin).</summary>
public sealed class ZoomEvent
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public MediaTime StartTime { get; set; }
    public MediaTime EndTime { get; set; }
    public double Scale { get; set; } = 2;
    public double TargetX { get; set; } = 0.5;
    public double TargetY { get; set; } = 0.5;
    public Easing Easing { get; set; } = Easing.EaseInOut;
    /// <summary>True while the event is an untouched automatic suggestion. Any user edit makes it manual.</summary>
    public bool IsAutomatic { get; set; }
    public bool FollowsCursor { get; set; } = true;
    public double TransitionIn { get; set; } = 0.7;
    public double TransitionOut { get; set; } = 0.8;

    [JsonIgnore] public MediaRange Range => MediaRange.FromBounds(StartTime, EndTime);
    [JsonIgnore] public MediaTime Duration => EndTime - StartTime;

    public ZoomEvent Copy() => (ZoomEvent)MemberwiseClone();
}

public sealed class MotionKeyframe
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public MediaTime Timestamp { get; set; }
    public double Scale { get; set; } = 1;
    public double PositionX { get; set; } = 0.5;
    public double PositionY { get; set; } = 0.5;
    public Easing Easing { get; set; } = Easing.EaseInOut;
}

public enum TextWeight { Regular, Medium, Semibold, Bold }

public sealed class TextOverlay
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "Text";
    public MediaTime StartTime { get; set; }
    public MediaTime EndTime { get; set; }
    public double PositionX { get; set; } = 0.5;
    public double PositionY { get; set; } = 0.14;
    public double FontSize { get; set; } = 0.06;
    public TextWeight Weight { get; set; } = TextWeight.Semibold;
    public RgbaColor Color { get; set; } = RgbaColor.White;
    public RgbaColor BackgroundColor { get; set; } = RgbaColor.Clear;
    public double FadeDuration { get; set; } = 0.25;
    [JsonIgnore] public MediaRange Range => MediaRange.FromBounds(StartTime, EndTime);
}

public sealed class Caption
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "";
    public MediaTime StartTime { get; set; }
    public MediaTime EndTime { get; set; }
    [JsonIgnore] public MediaRange Range => MediaRange.FromBounds(StartTime, EndTime);
}

public sealed class Timeline
{
    public List<TimelineTrack> Tracks { get; set; } = new();
    public List<ZoomEvent> ZoomEvents { get; set; } = new();
    public List<MotionKeyframe> Keyframes { get; set; } = new();
    public List<TextOverlay> TextOverlays { get; set; } = new();
    public List<Caption> Captions { get; set; } = new();
    /// <summary>Ranges where the user removed an automatic zoom; regeneration will not put one back.</summary>
    public List<MediaRange> SuppressedAutoZoomRanges { get; set; } = new();

    [JsonIgnore] public int VideoTrackIndex => Tracks.FindIndex(t => t.Type == TrackKind.Video);

    [JsonIgnore]
    public List<VideoClip> VideoClips
    {
        get
        {
            var index = VideoTrackIndex;
            return index >= 0 ? Tracks[index].Clips : new List<VideoClip>();
        }
    }

    public TimelineTrack? Track(TrackKind kind) => Tracks.FirstOrDefault(t => t.Type == kind);

    /// <summary>End of the last clip on any track.</summary>
    [JsonIgnore]
    public MediaTime Duration
    {
        get
        {
            var end = MediaTime.Zero;
            foreach (var track in Tracks)
            {
                foreach (var c in track.Clips) end = MediaTime.Max(end, c.TimelineEnd);
                foreach (var c in track.AudioClips) end = MediaTime.Max(end, c.TimelineEnd);
            }
            return end;
        }
    }
}

public sealed class ProjectSettings
{
    public AspectRatio Aspect { get; set; } = new();
    public BackgroundStyle Background { get; set; } = new();
    public ScreenStyle Screen { get; set; } = new();
    public CursorStyle Cursor { get; set; } = new();
    public CameraStyle Camera { get; set; } = new();
    public MotionSettings Motion { get; set; } = new();
    public AudioSettings Audio { get; set; } = new();
    public CaptionStyle Captions { get; set; } = new();
    public ExportSettings Export { get; set; } = new();
}

/// <summary>The complete, non-destructive description of an edit. Source media is referenced, never modified.</summary>
public sealed class Project
{
    public const int CurrentFormatVersion = 1;

    public int FormatVersion { get; set; } = CurrentFormatVersion;
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
    public List<MediaSource> Sources { get; set; } = new();
    public Timeline Timeline { get; set; } = new();
    public ProjectSettings Settings { get; set; } = new();
    /// <summary>Stored as a file URL string, like the macOS app.</summary>
    [JsonPropertyName("exportURL")] public string? ExportUrl { get; set; }
    public bool IsRecovered { get; set; }

    public MediaSource? Source(Guid id) => Sources.FirstOrDefault(s => s.Id == id);

    [JsonIgnore] public MediaTime Duration => Timeline.Duration;

    /// <summary>Width / height of the primary source's picture, after crop.</summary>
    [JsonIgnore]
    public double SourceAspect
    {
        get
        {
            var file = Sources.FirstOrDefault(s => s.Screen != null)?.Screen;
            if (file == null || file.PixelHeight <= 0) return 16.0 / 9.0;
            var crop = Settings.Screen.EffectiveCrop;
            return file.PixelWidth * crop.Width / (file.PixelHeight * crop.Height);
        }
    }

    [JsonIgnore] public double CanvasAspect => Settings.Aspect.Value(SourceAspect);

    /// <summary>Deep copy; commands are applied to a copy and only committed after validation.</summary>
    public Project Clone() => ProjectJson.Deserialize(ProjectJson.Serialize(this));

    /// <summary>Builds a fresh project around one source: one clip covering it, plus linked tracks.</summary>
    public static Project Make(string name, MediaSource source, Guid? id = null)
    {
        var tracks = new List<TimelineTrack>
        {
            new()
            {
                Name = "Screen", Type = TrackKind.Video,
                Clips = { new VideoClip { SourceId = source.Id, SourceStart = MediaTime.Zero, SourceEnd = MediaTime.FromSeconds(source.Duration) } },
            },
        };
        if (source.Camera != null) tracks.Add(new TimelineTrack { Name = "Camera", Type = TrackKind.Camera });
        if (source.Microphone != null) tracks.Add(new TimelineTrack { Name = "Microphone", Type = TrackKind.Microphone });
        if (source.SystemAudio != null || (source.Screen?.HasAudio ?? false))
            tracks.Add(new TimelineTrack { Name = source.Kind == SourceKind.Recording ? "System Audio" : "Audio", Type = TrackKind.SystemAudio });

        var settings = new ProjectSettings { Aspect = new AspectRatio { Kind = AspectKind.Auto } };
        settings.Camera.IsVisible = source.Camera != null;
        if (source.Kind != SourceKind.Recording)
        {
            settings.Motion.AutoZoomEnabled = false;
            settings.Cursor.IsVisible = false;
        }
        return new Project
        {
            Id = id ?? Guid.NewGuid(), Name = name, Sources = { source },
            Timeline = new Timeline { Tracks = tracks }, Settings = settings,
        };
    }
}
