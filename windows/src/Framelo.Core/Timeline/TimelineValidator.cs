namespace Framelo.Core;

public sealed class TimelineValidationException(string message) : Exception(message);

public static class TimelineValidator
{
    public const double MinSpeed = 0.1, MaxSpeed = 16;
    public const double MinZoomScale = 1, MaxZoomScale = 6;
    /// <summary>Shortest clip allowed: one frame at 60 fps.</summary>
    public static readonly MediaTime MinimumClipDuration = new(1000);

    public static void Validate(Project project)
    {
        var timeline = project.Timeline;
        foreach (var track in timeline.Tracks)
        {
            var sorted = track.Clips.OrderBy(c => c.TimelinePosition.Ticks).ToList();
            foreach (var clip in sorted)
            {
                var source = project.Source(clip.SourceId) ?? throw new TimelineValidationException("A clip refers to media that is not part of this project.");
                if (clip.PlaybackSpeed < MinSpeed || clip.PlaybackSpeed > MaxSpeed)
                    throw new TimelineValidationException($"Playback speed {clip.PlaybackSpeed} is outside the supported range (0.1× – 16×).");
                if (clip.SourceEnd <= clip.SourceStart || clip.TimelineDuration.Ticks <= 0)
                    throw new TimelineValidationException("A clip would have no duration.");
                var sourceEnd = MediaTime.FromSeconds(source.Duration) + new MediaTime(1);
                if (clip.SourceStart < MediaTime.Zero || clip.SourceEnd > sourceEnd)
                    throw new TimelineValidationException("A clip extends beyond the media it was cut from.");
                if (clip.TimelinePosition < MediaTime.Zero)
                    throw new TimelineValidationException("A clip would start before the beginning of the timeline.");
            }
            for (var i = 1; i < sorted.Count; i++)
                if (sorted[i - 1].TimelineEnd > sorted[i].TimelinePosition)
                    throw new TimelineValidationException("Two clips would overlap on the timeline.");

            var audio = track.AudioClips.OrderBy(c => c.TimelinePosition.Ticks).ToList();
            foreach (var clip in audio)
            {
                if (project.Source(clip.SourceId) == null) throw new TimelineValidationException("A clip refers to media that is not part of this project.");
                if (clip.SourceEnd <= clip.SourceStart) throw new TimelineValidationException("A clip would have no duration.");
                if (clip.TimelinePosition < MediaTime.Zero) throw new TimelineValidationException("A clip would start before the beginning of the timeline.");
            }
            for (var i = 1; i < audio.Count; i++)
                if (audio[i - 1].TimelineEnd > audio[i].TimelinePosition)
                    throw new TimelineValidationException("Two clips would overlap on the timeline.");
        }

        foreach (var e in timeline.ZoomEvents)
        {
            if (e.EndTime <= e.StartTime) throw new TimelineValidationException("Invalid zoom: it ends before it starts.");
            if (e.StartTime < MediaTime.Zero) throw new TimelineValidationException("Invalid zoom: it starts before the timeline.");
            if (e.Scale < MinZoomScale || e.Scale > MaxZoomScale) throw new TimelineValidationException("Invalid zoom: scale must be between 1× and 6×.");
            if (e.TargetX is < 0 or > 1 || e.TargetY is < 0 or > 1) throw new TimelineValidationException("Invalid zoom: its target is outside the screen.");
            if (e.TransitionIn < 0 || e.TransitionOut < 0) throw new TimelineValidationException("Invalid zoom: transition durations must be positive.");
        }

        for (var i = 1; i < timeline.Keyframes.Count; i++)
            if (timeline.Keyframes[i - 1].Timestamp > timeline.Keyframes[i].Timestamp)
                throw new TimelineValidationException("Keyframes are out of order.");
        if (timeline.Keyframes.Any(k => k.Scale < MinZoomScale || k.Scale > MaxZoomScale))
            throw new TimelineValidationException("Keyframe scale is out of range.");
        if (timeline.TextOverlays.Any(o => o.EndTime <= o.StartTime || o.StartTime < MediaTime.Zero) ||
            timeline.Captions.Any(c => c.EndTime <= c.StartTime || c.StartTime < MediaTime.Zero))
            throw new TimelineValidationException("A text item or caption has an invalid time range.");

        var s = project.Settings;
        if (s.Screen.Padding is < 0 or > 0.4) throw new TimelineValidationException("Padding is out of range.");
        if (s.Screen.CornerRadius is < 0 or > 0.2) throw new TimelineValidationException("Corner radius is out of range.");
        if (s.Camera.Size is < 0.05 or > 1) throw new TimelineValidationException("Camera size is out of range.");
        if (s.Cursor.Size is < 0.2 or > 6) throw new TimelineValidationException("Cursor size is out of range.");
    }
}
