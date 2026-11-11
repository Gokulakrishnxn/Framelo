namespace Framelo.Core;

/// <summary>Deterministic mapping between timeline time and source (session) time. Immutable.</summary>
public sealed class TimeMap
{
    public sealed record Segment(Guid ClipId, Guid SourceId, MediaRange Timeline, MediaTime SourceStart, MediaTime SourceEnd, double Speed);

    public IReadOnlyList<Segment> Segments { get; }
    public MediaTime Duration { get; }

    public TimeMap(IEnumerable<VideoClip> clips, MediaTime? duration = null)
    {
        Segments = clips.OrderBy(c => c.TimelinePosition.Ticks)
            .Select(c => new Segment(c.Id, c.SourceId, c.TimelineRange, c.SourceStart, c.SourceEnd, c.PlaybackSpeed))
            .ToList();
        Duration = duration ?? (Segments.Count > 0 ? Segments.Max(s => s.Timeline.End) : MediaTime.Zero);
    }

    public TimeMap(Project project) : this(project.Timeline.VideoClips, project.Timeline.Duration) { }

    /// <summary>Index of the segment covering time. The final instant of the timeline belongs to the last segment.</summary>
    public int? SegmentIndex(MediaTime time)
    {
        int lo = 0, hi = Segments.Count - 1;
        while (lo <= hi)
        {
            var mid = (lo + hi) / 2;
            var r = Segments[mid].Timeline;
            if (time < r.Start) hi = mid - 1;
            else if (time >= r.End) lo = mid + 1;
            else return mid;
        }
        if (Segments.Count > 0 && time == Segments[^1].Timeline.End && time == Duration) return Segments.Count - 1;
        return null;
    }

    /// <summary>The segment and source time showing at a timeline time, or null in a gap.</summary>
    public (int Index, MediaTime SourceTime)? Locate(MediaTime time)
    {
        var index = SegmentIndex(time);
        return index is int i ? (i, SourceTime(i, time)) : null;
    }

    public MediaTime SourceTime(int index, MediaTime time)
    {
        var s = Segments[index];
        var local = (time - s.Timeline.Start).MultipliedBy(s.Speed);
        return MediaTime.Min(MediaTime.Max(s.SourceStart + local, s.SourceStart), s.SourceEnd);
    }

    public IReadOnlyList<MediaTime> TimelineTimes(MediaTime source, Guid sourceId) =>
        Segments.Where(s => s.SourceId == sourceId && source >= s.SourceStart && source < s.SourceEnd)
            .Select(s => s.Timeline.Start + (source - s.SourceStart).DividedBy(s.Speed)).ToList();

    public IReadOnlyList<MediaRange> Gaps
    {
        get
        {
            var result = new List<MediaRange>();
            var cursor = MediaTime.Zero;
            foreach (var s in Segments)
            {
                if (s.Timeline.Start > cursor) result.Add(MediaRange.FromBounds(cursor, s.Timeline.Start));
                cursor = MediaTime.Max(cursor, s.Timeline.End);
            }
            if (Duration > cursor) result.Add(MediaRange.FromBounds(cursor, Duration));
            return result;
        }
    }
}
