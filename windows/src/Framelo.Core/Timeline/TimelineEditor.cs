namespace Framelo.Core;

public sealed class TimelineEditException(string message) : Exception(message)
{
    public static TimelineEditException ClipNotFound() => new("That clip no longer exists.");
    public static TimelineEditException NothingAtPlayhead() => new("There is no clip under the playhead.");
    public static TimelineEditException TooCloseToEdge() => new("The playhead is too close to the edge of the clip to cut there.");
    public static TimelineEditException NoVideoTrack() => new("This project has no video track.");
}

/// <summary>Pure edit operations on a Timeline. Callers pass a copy (see CommandStack).</summary>
public static class TimelineEditor
{
    private static List<VideoClip> Clips(Timeline t)
    {
        var i = t.VideoTrackIndex;
        if (i < 0) throw TimelineEditException.NoVideoTrack();
        return t.Tracks[i].Clips;
    }

    private static int IndexOf(List<VideoClip> clips, Guid id)
    {
        var i = clips.FindIndex(c => c.Id == id);
        if (i < 0) throw TimelineEditException.ClipNotFound();
        return i;
    }

    private static VideoClip Copy(VideoClip c) => new()
    {
        Id = c.Id, SourceId = c.SourceId, SourceStart = c.SourceStart, SourceEnd = c.SourceEnd,
        TimelinePosition = c.TimelinePosition, PlaybackSpeed = c.PlaybackSpeed, Volume = c.Volume, IsMuted = c.IsMuted,
        Transform = new ClipTransform { Scale = c.Transform.Scale, OffsetX = c.Transform.OffsetX, OffsetY = c.Transform.OffsetY },
        TransitionIn = c.TransitionIn, TransitionOut = c.TransitionOut,
    };

    /// <summary>Splits the clip under time in two. Returns the IDs of the left and right halves.</summary>
    public static (Guid Left, Guid Right) Split(Timeline timeline, MediaTime time)
    {
        var clips = Clips(timeline);
        var index = clips.FindIndex(c => c.TimelineRange.Contains(time));
        if (index < 0) throw TimelineEditException.NothingAtPlayhead();
        var clip = clips[index];
        var min = TimelineValidator.MinimumClipDuration;
        if (time - clip.TimelinePosition < min || clip.TimelineEnd - time < min) throw TimelineEditException.TooCloseToEdge();
        var cut = clip.SourceTime(time);
        var right = Copy(clip);
        right.Id = Guid.NewGuid();
        right.SourceStart = cut;
        right.TimelinePosition = time;
        right.TransitionIn = null;
        clip.SourceEnd = cut;
        clip.TransitionOut = null;
        clips.Insert(index + 1, right);
        return (clip.Id, right.Id);
    }

    /// <summary>Changes a clip's in/out points (source time). With ripple, everything after stays attached.</summary>
    public static void Trim(Timeline timeline, Guid clipId, MediaTime? sourceStart = null, MediaTime? sourceEnd = null, bool ripple = true)
    {
        var clips = Clips(timeline);
        var index = IndexOf(clips, clipId);
        var clip = clips[index];
        var oldRange = clip.TimelineRange;
        if (sourceStart is MediaTime s)
        {
            var delta = (s - clip.SourceStart).DividedBy(clip.PlaybackSpeed);
            clip.SourceStart = s;
            if (!ripple) clip.TimelinePosition += delta;
        }
        if (sourceEnd is MediaTime e) clip.SourceEnd = e;
        if (ripple)
        {
            var delta = clip.TimelineDuration - oldRange.Duration;
            Shift(clips, index, delta);
            RippleAnnotations(timeline, delta.Ticks < 0 ? oldRange.End + delta : oldRange.End, delta);
        }
    }

    public static void Delete(Timeline timeline, Guid clipId, bool ripple = true)
    {
        var clips = Clips(timeline);
        var index = IndexOf(clips, clipId);
        var range = clips[index].TimelineRange;
        clips.RemoveAt(index);
        if (ripple)
        {
            Shift(clips, index - 1, -range.Duration);
            RippleAnnotations(timeline, range.Start, -range.Duration);
        }
    }

    /// <summary>Removes a section of the timeline, cutting clips at its edges.</summary>
    public static void DeleteRange(Timeline timeline, MediaRange range, bool ripple = true)
    {
        var track = timeline.VideoTrackIndex;
        if (track < 0) throw TimelineEditException.NoVideoTrack();
        if (range.IsEmpty) return;
        var result = new List<VideoClip>();
        foreach (var clip in timeline.Tracks[track].Clips)
        {
            var r = clip.TimelineRange;
            if (!r.Overlaps(range)) { result.Add(clip); continue; }
            if (r.Start < range.Start)
            {
                var head = Copy(clip);
                head.SourceEnd = clip.SourceTime(range.Start);
                head.TransitionOut = null;
                if (head.SourceDuration.Ticks > 0) result.Add(head);
            }
            if (r.End > range.End)
            {
                var tail = Copy(clip);
                if (r.Start < range.Start) tail.Id = Guid.NewGuid();
                tail.SourceStart = clip.SourceTime(range.End);
                tail.TimelinePosition = range.End;
                tail.TransitionIn = null;
                if (tail.SourceDuration.Ticks > 0) result.Add(tail);
            }
        }
        if (ripple)
        {
            var delta = -range.Duration;
            foreach (var c in result) if (c.TimelinePosition >= range.End) c.TimelinePosition += delta;
            RippleAnnotations(timeline, range.Start, delta);
        }
        timeline.Tracks[track].Clips = result;
    }

    public static void Reorder(Timeline timeline, Guid clipId, int toIndex)
    {
        var clips = Clips(timeline);
        var index = IndexOf(clips, clipId);
        var clip = clips[index];
        clips.RemoveAt(index);
        clips.Insert(Math.Clamp(toIndex, 0, clips.Count), clip);
        Pack(clips);
    }

    public static void Move(Timeline timeline, Guid clipId, MediaTime position)
    {
        var clips = Clips(timeline);
        clips[IndexOf(clips, clipId)].TimelinePosition = MediaTime.Max(position, MediaTime.Zero);
        clips.Sort((a, b) => a.TimelinePosition.CompareTo(b.TimelinePosition));
    }

    public static void SetSpeed(Timeline timeline, Guid clipId, double speed, bool ripple = true)
    {
        var clips = Clips(timeline);
        var index = IndexOf(clips, clipId);
        var old = clips[index].TimelineRange;
        clips[index].PlaybackSpeed = speed;
        if (ripple)
        {
            var delta = clips[index].TimelineDuration - old.Duration;
            Shift(clips, index, delta);
            RippleAnnotations(timeline, delta.Ticks < 0 ? old.End + delta : old.End, delta);
        }
    }

    public static void CloseGaps(Timeline timeline)
    {
        var track = timeline.VideoTrackIndex;
        if (track < 0) return;
        var clips = timeline.Tracks[track].Clips;
        clips.Sort((a, b) => a.TimelinePosition.CompareTo(b.TimelinePosition));
        Pack(clips);
    }

    // Zoom events and keyframes

    public static void UpsertZoom(Timeline timeline, ZoomEvent e)
    {
        var i = timeline.ZoomEvents.FindIndex(z => z.Id == e.Id);
        if (i >= 0) timeline.ZoomEvents[i] = e; else timeline.ZoomEvents.Add(e);
        timeline.ZoomEvents.Sort((a, b) => a.StartTime.CompareTo(b.StartTime));
    }

    /// <summary>Removing an automatic zoom remembers its range so regeneration does not bring it back.</summary>
    public static void RemoveZoom(Timeline timeline, Guid id)
    {
        var i = timeline.ZoomEvents.FindIndex(z => z.Id == id);
        if (i < 0) return;
        var e = timeline.ZoomEvents[i];
        timeline.ZoomEvents.RemoveAt(i);
        if (e.IsAutomatic) timeline.SuppressedAutoZoomRanges.Add(e.Range);
    }

    public static void UpsertKeyframe(Timeline timeline, MotionKeyframe k)
    {
        var i = timeline.Keyframes.FindIndex(x => x.Id == k.Id);
        if (i >= 0) timeline.Keyframes[i] = k; else timeline.Keyframes.Add(k);
        timeline.Keyframes.Sort((a, b) => a.Timestamp.CompareTo(b.Timestamp));
    }

    // Helpers

    private static void Pack(List<VideoClip> clips)
    {
        var cursor = MediaTime.Zero;
        foreach (var c in clips) { c.TimelinePosition = cursor; cursor = c.TimelineEnd; }
    }

    private static void Shift(List<VideoClip> clips, int after, MediaTime delta)
    {
        if (delta.Ticks == 0) return;
        for (var i = after + 1; i < clips.Count; i++) clips[i].TimelinePosition += delta;
    }

    /// <summary>
    /// Inserts (delta &gt; 0) or removes (delta &lt; 0) time at a point for everything that lives in timeline time:
    /// zoom events, keyframes, text, captions, suppression ranges and independent audio clips.
    /// </summary>
    internal static void RippleAnnotations(Timeline timeline, MediaTime time, MediaTime delta)
    {
        if (delta.Ticks == 0) return;
        MediaRange? removed = delta.Ticks < 0 ? new MediaRange(time, -delta) : null;

        MediaTime Map(MediaTime t)
        {
            if (removed != null)
            {
                if (t <= removed.Start) return t;
                if (t >= removed.End) return t + delta;
                return removed.Start;
            }
            return t >= time ? t + delta : t;
        }

        bool MapRange(MediaTime s, MediaTime e, out MediaTime ms, out MediaTime me)
        {
            ms = Map(s); me = Map(e);
            return me > ms;
        }

        timeline.ZoomEvents = timeline.ZoomEvents.Where(z =>
        {
            if (!MapRange(z.StartTime, z.EndTime, out var s, out var e)) return false;
            z.StartTime = s; z.EndTime = e; return true;
        }).ToList();
        timeline.Keyframes = timeline.Keyframes.Where(k =>
        {
            if (removed != null && k.Timestamp > removed.Start && k.Timestamp < removed.End) return false;
            k.Timestamp = Map(k.Timestamp); return true;
        }).ToList();
        timeline.TextOverlays = timeline.TextOverlays.Where(o =>
        {
            if (!MapRange(o.StartTime, o.EndTime, out var s, out var e)) return false;
            o.StartTime = s; o.EndTime = e; return true;
        }).ToList();
        timeline.Captions = timeline.Captions.Where(c =>
        {
            if (!MapRange(c.StartTime, c.EndTime, out var s, out var e)) return false;
            c.StartTime = s; c.EndTime = e; return true;
        }).ToList();
        timeline.SuppressedAutoZoomRanges = timeline.SuppressedAutoZoomRanges
            .Select(r => MapRange(r.Start, r.End, out var s, out var e) ? MediaRange.FromBounds(s, e) : null)
            .Where(r => r != null).Select(r => r!).ToList();
        foreach (var track in timeline.Tracks.Where(t => t.Type == TrackKind.Audio))
            foreach (var c in track.AudioClips.Where(c => c.TimelinePosition >= time))
                c.TimelinePosition = MediaTime.Max(c.TimelinePosition + delta, MediaTime.Zero);
    }
}
