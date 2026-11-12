namespace Framelo.Core;

public readonly record struct TimelineClick(double Time, double X, double Y);

/// <summary>Cursor data mapped onto the timeline through the current edit.</summary>
public sealed class TimelineCursor(TimeMap timeMap, IReadOnlyDictionary<Guid, CursorTrack> tracks)
{
    public TimeMap TimeMap { get; } = timeMap;
    public IReadOnlyDictionary<Guid, CursorTrack> Tracks { get; } = tracks;

    public static TimelineCursor Empty => new(new TimeMap(Array.Empty<VideoClip>()), new Dictionary<Guid, CursorTrack>());

    /// <summary>Cursor track and session time for a timeline time, or null in a gap or without a cursor.</summary>
    public (CursorTrack Track, double SourceTime)? Lookup(MediaTime time)
    {
        if (TimeMap.Locate(time) is not { } hit) return null;
        if (!Tracks.TryGetValue(TimeMap.Segments[hit.Index].SourceId, out var track) || track.IsEmpty) return null;
        return (track, hit.SourceTime.Seconds);
    }

    public (double X, double Y)? RawPosition(double seconds) =>
        Lookup(MediaTime.FromSeconds(seconds)) is { } l ? l.Track.Position(l.SourceTime) : null;

    /// <summary>Every click that survives the edit, in timeline time, sorted.</summary>
    public IReadOnlyList<TimelineClick> Clicks
    {
        get
        {
            var result = new List<TimelineClick>();
            foreach (var s in TimeMap.Segments)
            {
                if (!Tracks.TryGetValue(s.SourceId, out var track)) continue;
                var start = s.SourceStart.Seconds;
                var end = s.SourceEnd.Seconds;
                foreach (var c in track.Clicks)
                    if (c.T >= start && c.T < end)
                        result.Add(new TimelineClick(s.Timeline.Start.Seconds + (c.T - start) / s.Speed, c.X, c.Y));
            }
            return result.OrderBy(c => c.Time).ToList();
        }
    }
}

/// <summary>Suggests zooms from where and when the user clicked.</summary>
public static class AutoZoomGenerator
{
    /// <summary>Clicks closer together than this belong to one zoom.</summary>
    public const double ClusterGap = 3.0;
    /// <summary>How long the camera stays in after the last click of a cluster.</summary>
    public const double Hold = 1.6;
    /// <summary>Zooms separated by less than this are merged, so the camera does not bounce out and back in.</summary>
    public const double MinimumGap = 1.2;

    public static List<ZoomEvent> Generate(IEnumerable<TimelineClick> clicks, double duration, MotionSettings settings)
    {
        var usable = clicks.Where(c => c.X is >= 0 and <= 1 && c.Y is >= 0 and <= 1 && c.Time >= 0 && c.Time <= duration)
            .OrderBy(c => c.Time).ToList();
        if (usable.Count == 0 || duration <= 0) return new List<ZoomEvent>();

        var clusters = new List<List<TimelineClick>>();
        foreach (var click in usable)
        {
            if (clusters.Count > 0 && click.Time - clusters[^1][^1].Time <= ClusterGap) clusters[^1].Add(click);
            else clusters.Add(new List<TimelineClick> { click });
        }

        var events = new List<ZoomEvent>();
        foreach (var cluster in clusters)
        {
            var first = cluster[0];
            var last = cluster[^1];
            // Arrive at the target just before the first click lands.
            var start = Math.Max(0, first.Time - settings.ZoomInDuration * 0.9);
            var end = Math.Min(duration, last.Time + Hold + settings.ZoomOutDuration);
            if (end - start < settings.ZoomInDuration + settings.ZoomOutDuration) continue;
            events.Add(new ZoomEvent
            {
                StartTime = MediaTime.FromSeconds(start), EndTime = MediaTime.FromSeconds(end), Scale = settings.DefaultZoomScale,
                TargetX = first.X, TargetY = first.Y, Easing = settings.Easing, IsAutomatic = true, FollowsCursor = true,
                TransitionIn = settings.ZoomInDuration, TransitionOut = settings.ZoomOutDuration,
            });
        }
        return Merge(events);
    }

    /// <summary>
    /// Merges events that overlap or sit closer than MinimumGap. The merged event keeps the first target
    /// (the camera then follows the cursor to later ones) and the larger scale.
    /// </summary>
    public static List<ZoomEvent> Merge(IEnumerable<ZoomEvent> events)
    {
        var result = new List<ZoomEvent>();
        foreach (var e in events.OrderBy(e => e.StartTime.Ticks).Select(e => e.Copy()))
        {
            if (result.Count > 0 && e.StartTime.Seconds - result[^1].EndTime.Seconds < MinimumGap)
            {
                var last = result[^1];
                last.EndTime = MediaTime.Max(last.EndTime, e.EndTime);
                last.Scale = Math.Max(last.Scale, e.Scale);
                last.FollowsCursor = true;
            }
            else result.Add(e);
        }
        return result;
    }
}

/// <summary>The camera move for a project, ready to evaluate.</summary>
public sealed record ResolvedMotion(IReadOnlyList<ZoomEvent> Events, CameraPath Path)
{
    public static readonly ResolvedMotion None = new(Array.Empty<ZoomEvent>(), CameraPath.Empty);
}

public static class MotionEngine
{
    /// <summary>
    /// Replaces the automatic zooms with fresh suggestions. Manual zooms are never touched, and no suggestion is
    /// placed over a manual zoom, a keyframed span, or a range where the user deleted a suggestion.
    /// </summary>
    public static void RegenerateAutomaticZooms(Timeline timeline, TimelineCursor cursor, MotionSettings settings)
    {
        var manual = timeline.ZoomEvents.Where(z => !z.IsAutomatic).ToList();
        if (!settings.AutoZoomEnabled) { timeline.ZoomEvents = manual; return; }
        var duration = timeline.Duration.Seconds;
        var blocked = manual.Select(z => z.Range).Concat(timeline.SuppressedAutoZoomRanges).ToList();
        if (timeline.Keyframes.Count > 0)
            blocked.Add(MediaRange.FromBounds(timeline.Keyframes[0].Timestamp - MediaTime.FromSeconds(CameraPath.KeyframeLead),
                timeline.Keyframes[^1].Timestamp + MediaTime.FromSeconds(CameraPath.KeyframeLead)));
        // Keep clear of manual zooms by the merge gap too, so the camera has time to settle between them.
        var margin = MediaTime.FromSeconds(AutoZoomGenerator.MinimumGap);
        var accepted = AutoZoomGenerator.Generate(cursor.Clicks, duration, settings).Where(c =>
        {
            var padded = MediaRange.FromBounds(c.StartTime - margin, c.EndTime + margin);
            return !blocked.Any(b => b.Overlaps(padded));
        });
        timeline.ZoomEvents = manual.Concat(accepted).OrderBy(z => z.StartTime.Ticks).ToList();
    }

    /// <summary>
    /// Resolves conflicts and builds the camera path: manual events beat overlapping automatic ones; overlapping
    /// automatic events merge; overlapping manual events are sequenced; events inside a keyframed span are dropped;
    /// times, transitions and targets are clamped so the move is continuous and stays inside the picture.
    /// </summary>
    public static ResolvedMotion Resolve(Timeline timeline, TimelineCursor cursor)
    {
        var duration = timeline.Duration.Seconds;
        var keyframes = timeline.Keyframes.OrderBy(k => k.Timestamp.Ticks)
            .Select(k => new ResolvedKeyframe(k.Timestamp.Seconds, new CameraState(k.Scale, k.PositionX, k.PositionY).Clamped(), k.Easing))
            .ToList();
        var path = new CameraPath(null, keyframes);
        var span = path.KeyframeSpan;

        var manual = timeline.ZoomEvents.Where(z => !z.IsAutomatic).OrderBy(z => z.StartTime.Ticks).ToList();
        var automatic = AutoZoomGenerator.Merge(timeline.ZoomEvents.Where(z => z.IsAutomatic))
            .Where(a => !manual.Any(m => m.Range.Overlaps(a.Range)));

        var ordered = new List<ZoomEvent>();
        foreach (var source in manual.Concat(automatic).OrderBy(z => z.StartTime.Ticks))
        {
            var e = source.Copy();
            if (ordered.Count > 0 && e.StartTime < ordered[^1].EndTime) e.StartTime = ordered[^1].EndTime;
            e.StartTime = MediaTime.Max(e.StartTime, MediaTime.Zero);
            if (duration > 0) e.EndTime = MediaTime.Min(e.EndTime, MediaTime.FromSeconds(duration));
            if (e.Duration.Seconds < 2 * CameraPath.MinimumTransition) continue;
            if (span is { } s && e.StartTime.Seconds < s.Upper && e.EndTime.Seconds > s.Lower) continue;
            ordered.Add(e);
        }

        path.Zooms = ordered.Select(e =>
        {
            var start = e.StartTime.Seconds;
            var end = e.EndTime.Seconds;
            // Bigger zooms need longer transitions; if the event is too short, reduce the zoom rather than snap.
            var scale = Math.Clamp(e.Scale, 1, TimelineValidator.MaxZoomScale);
            if (2 * CameraPath.MinimumTransitionForScale(scale) > end - start)
                scale = Math.Max(1, CameraPath.MaximumScaleForTransition((end - start) / 2));
            var floor = CameraPath.MinimumTransitionForScale(scale);
            var tin = Math.Max(e.TransitionIn, floor);
            var tout = Math.Max(e.TransitionOut, floor);
            if (tin + tout > end - start)
            {
                var factor = (end - start) / (tin + tout);
                tin *= factor;
                tout *= factor;
            }
            return new ResolvedZoom(e.Id, start, end, scale, tin, tout, e.Easing, FollowTargets(e, start, end, scale, cursor));
        }).ToList();
        return new ResolvedMotion(ordered, path);
    }

    /// <summary>
    /// The camera target over an event: fixed, or a critically damped spring chasing the cursor. The spring starts
    /// at rest on the event's own target, so the camera never jumps when the event begins.
    /// </summary>
    internal static IReadOnlyList<Vec2> FollowTargets(ZoomEvent e, double start, double end, double scale, TimelineCursor cursor)
    {
        var half = 0.5 / scale;
        Vec2 Clamp(Vec2 p) => new(Math.Clamp(p.X, half, 1 - half), Math.Clamp(p.Y, half, 1 - half));
        var origin = Clamp(new Vec2(e.TargetX, e.TargetY));
        if (!e.FollowsCursor || cursor.RawPosition(start) == null) return new[] { origin };

        const double omega = 3.2;   // rad/s — settles in roughly 1.5 s
        const int substeps = 4;
        var dt = 1 / (CameraPath.FollowRate * substeps);
        var count = (int)Math.Ceiling((end - start) * CameraPath.FollowRate) + 1;
        var position = origin;
        var velocity = new Vec2(0, 0);
        var samples = new List<Vec2>(count);
        for (var i = 0; i < count; i++)
        {
            samples.Add(Clamp(position));
            for (var s = 0; s < substeps; s++)
            {
                var time = start + (i + (double)s / substeps) / CameraPath.FollowRate;
                var goal = position;
                if (cursor.RawPosition(time) is { } raw)
                {
                    goal = Clamp(new Vec2(raw.X, raw.Y));
                    // Ignore small movements so the camera does not drift with every twitch of the hand.
                    var offset = goal - position;
                    var dead = 0.12 / scale;
                    if (Math.Abs(offset.X) < dead && Math.Abs(offset.Y) < dead) goal = position;
                }
                var acceleration = (goal - position) * (omega * omega) - velocity * (2 * omega);
                velocity += acceleration * dt;
                position += velocity * dt;
            }
        }
        return samples;
    }
}

/// <summary>
/// Zero-phase cursor smoothing: a Gaussian-weighted average of the raw path around the requested time. Being
/// symmetric it adds no lag, so the smoothed cursor still rests on click targets, and being a pure function of
/// time it gives identical results in preview and export.
/// </summary>
public static class CursorSmoother
{
    private const double MaxSigma = 0.09;
    private const double Step = 1.0 / 120;

    public static (double X, double Y)? Position(CursorTrack track, double time, double smoothing)
    {
        if (track.Position(time) is not { } raw) return null;
        var sigma = Math.Clamp(smoothing, 0, 1) * MaxSigma;
        if (sigma <= 0.002) return raw;
        var radius = (int)Math.Ceiling(sigma * 2.5 / Step);
        double sx = 0, sy = 0, total = 0;
        for (var k = -radius; k <= radius; k++)
        {
            var offset = k * Step;
            if (track.Position(time + offset) is not { } p) continue;
            var weight = Math.Exp(-(offset * offset) / (2 * sigma * sigma));
            sx += p.X * weight;
            sy += p.Y * weight;
            total += weight;
        }
        return total > 0 ? (sx / total, sy / total) : raw;
    }

    /// <summary>Time since the pointer last moved noticeably, looking back at most limit seconds.</summary>
    public static double IdleTime(CursorTrack track, double time, double limit)
    {
        if (track.Position(time) is not { } now) return 0;
        for (var back = 0.1; back <= limit; back += 0.1)
        {
            if (track.Position(time - back) is not { } then) break;
            if (Math.Abs(then.X - now.X) > 0.002 || Math.Abs(then.Y - now.Y) > 0.002) return back - 0.1;
        }
        return limit;
    }
}
