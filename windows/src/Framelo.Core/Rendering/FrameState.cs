namespace Framelo.Core;

/// <summary>
/// Everything the renderer needs to draw one frame. Computed only by FrameStateEvaluator, so preview and export
/// cannot disagree.
/// </summary>
public sealed record FrameState
{
    public sealed record ScreenState(Guid SourceId, MediaTime SourceTime, double Opacity, double TransitionScale);
    public sealed record CursorState(double X, double Y, double Scale, double Opacity, CursorKind Kind);
    public sealed record Ripple(double X, double Y, double Progress);
    public sealed record Pip(double CenterX, double CenterY, double Height, Guid SourceId, MediaTime SourceTime);
    public sealed record Overlay(Guid Id, double Opacity);

    public MediaTime Time { get; init; }
    /// <summary>Null in a gap: only the background is drawn.</summary>
    public ScreenState? Screen { get; init; }
    public CameraState Camera { get; init; } = CameraState.Identity;
    public double CameraVelocityX { get; init; }
    public double CameraVelocityY { get; init; }
    public double CameraVelocityScale { get; init; }
    public CursorState? Cursor { get; init; }
    public double CursorVelocityX { get; init; }
    public double CursorVelocityY { get; init; }
    public IReadOnlyList<Ripple> Ripples { get; init; } = Array.Empty<Ripple>();
    public Pip? CameraPip { get; init; }
    public IReadOnlyList<Overlay> Overlays { get; init; } = Array.Empty<Overlay>();
    public Guid? CaptionId { get; init; }

    /// <summary>Value equality including the lists (records compare lists by reference).</summary>
    public bool SameAs(FrameState other) =>
        this with { Ripples = Array.Empty<Ripple>(), Overlays = Array.Empty<Overlay>() } ==
        other with { Ripples = Array.Empty<Ripple>(), Overlays = Array.Empty<Overlay>() } &&
        Ripples.SequenceEqual(other.Ripples) && Overlays.SequenceEqual(other.Overlays);
}

/// <summary>Immutable snapshot of a project prepared for rendering. Safe to share between threads.</summary>
public sealed class RenderPlan
{
    public Project Project { get; }
    public TimeMap TimeMap { get; }
    public ResolvedMotion Motion { get; }
    public TimelineCursor Cursor { get; }
    public int Revision { get; }

    public RenderPlan(Project project, IReadOnlyDictionary<Guid, CursorTrack> cursorTracks, int revision = 0)
    {
        Project = project;
        TimeMap = new TimeMap(project);
        Cursor = new TimelineCursor(TimeMap, cursorTracks);
        Motion = MotionEngine.Resolve(project.Timeline, Cursor);
        Revision = revision;
    }

    public FrameStateEvaluator Evaluator => new(this);
}

/// <summary>The only code that turns (project, time) into a FrameState. Pure and deterministic.</summary>
public sealed class FrameStateEvaluator(RenderPlan plan)
{
    public const double RippleDuration = 0.55;
    public const double PressDuration = 0.09;

    public RenderPlan Plan { get; } = plan;

    public FrameState Evaluate(MediaTime time)
    {
        var project = Plan.Project;
        var settings = project.Settings;
        var seconds = time.Seconds;

        FrameState.ScreenState? screen = null;
        TimeMap.Segment? segment = null;
        if (Plan.TimeMap.Locate(time) is { } hit)
        {
            segment = Plan.TimeMap.Segments[hit.Index];
            var clip = project.Timeline.VideoClips.FirstOrDefault(c => c.Id == segment.ClipId);
            var (opacity, scale) = Transition(clip, seconds, segment);
            screen = new FrameState.ScreenState(segment.SourceId, hit.SourceTime, opacity, scale);
        }

        var camera = Plan.Motion.Path.State(seconds);
        var velocity = Plan.Motion.Path.Velocity(seconds);

        FrameState.CursorState? cursor = null;
        double cvx = 0, cvy = 0;
        var ripples = new List<FrameState.Ripple>();
        if (screen != null && Plan.Cursor.Lookup(time) is { } look)
        {
            var (track, sourceTime) = look;
            var style = settings.Cursor;
            if (style.IsVisible && CursorSmoother.Position(track, sourceTime, style.Smoothing) is { } p)
            {
                var opacity = 1.0;
                if (style.HidesWhenIdle)
                {
                    var idle = CursorSmoother.IdleTime(track, sourceTime, style.IdleDelay + 0.5);
                    opacity = 1 - Math.Clamp((idle - style.IdleDelay) / 0.4, 0, 1);
                }
                if (opacity > 0 && p.X > -0.05 && p.X < 1.05 && p.Y > -0.05 && p.Y < 1.05)
                {
                    cursor = new FrameState.CursorState(p.X, p.Y, style.Size * PressScale(track, sourceTime, style), opacity, track.KindAt(sourceTime));
                    const double dt = 1.0 / 120;
                    if (CursorSmoother.Position(track, sourceTime - dt, style.Smoothing) is { } a &&
                        CursorSmoother.Position(track, sourceTime + dt, style.Smoothing) is { } b)
                    {
                        var speed = segment?.Speed ?? 1;
                        cvx = (b.X - a.X) / (2 * dt) * speed;
                        cvy = (b.Y - a.Y) / (2 * dt) * speed;
                    }
                }
            }
            if (style.ClickEffect != ClickEffect.None)
                foreach (var click in track.Clicks)
                    if (sourceTime >= click.T && sourceTime < click.T + RippleDuration)
                        ripples.Add(new FrameState.Ripple(click.X, click.Y, (sourceTime - click.T) / RippleDuration));
        }

        FrameState.Pip? pip = null;
        if (screen != null && settings.Camera.IsVisible && (project.Timeline.Track(TrackKind.Camera)?.IsVisible ?? true) &&
            project.Source(screen.SourceId) is { Camera: MediaFile file } source)
        {
            var local = screen.SourceTime.Seconds - file.StartOffset;
            if (local >= 0 && local <= file.Duration)
            {
                var zoomAmount = Math.Clamp((camera.Scale - 1) / 0.5, 0, 1);
                var shrink = MathUtil.Lerp(1, settings.Camera.ZoomedScale, zoomAmount);
                pip = new FrameState.Pip(settings.Camera.PositionX, settings.Camera.PositionY, settings.Camera.Size * shrink, source.Id, screen.SourceTime);
            }
        }

        var overlays = new List<FrameState.Overlay>();
        foreach (var o in project.Timeline.TextOverlays.Where(o => o.Range.Contains(time)))
        {
            var fade = Math.Max(o.FadeDuration, 0);
            var opacity = fade > 0 ? Math.Min(1, Math.Min((seconds - o.StartTime.Seconds) / fade, (o.EndTime.Seconds - seconds) / fade)) : 1;
            overlays.Add(new FrameState.Overlay(o.Id, Math.Max(0, opacity)));
        }
        var caption = settings.Captions.IsVisible ? project.Timeline.Captions.FirstOrDefault(c => c.Range.Contains(time))?.Id : null;

        return new FrameState
        {
            Time = time, Screen = screen, Camera = camera,
            CameraVelocityX = velocity.CenterX, CameraVelocityY = velocity.CenterY, CameraVelocityScale = velocity.Scale,
            Cursor = cursor, CursorVelocityX = cvx, CursorVelocityY = cvy, Ripples = ripples, CameraPip = pip,
            Overlays = overlays, CaptionId = caption,
        };
    }

    private static (double Opacity, double Scale) Transition(VideoClip? clip, double seconds, TimeMap.Segment segment)
    {
        if (clip == null) return (1, 1);
        var amount = 1.0;
        var kind = TransitionKind.Fade;
        if (clip.TransitionIn is { Duration: > 0 } tin)
        {
            var p = (seconds - segment.Timeline.Start.Seconds) / tin.Duration;
            if (p < 1) { amount = Math.Min(amount, Easing.EaseOut.Value(p)); kind = tin.Kind; }
        }
        if (clip.TransitionOut is { Duration: > 0 } tout)
        {
            var p = (segment.Timeline.End.Seconds - seconds) / tout.Duration;
            if (p < 1) { amount = Math.Min(amount, Easing.EaseOut.Value(p)); kind = tout.Kind; }
        }
        return (amount, kind == TransitionKind.ZoomFade ? MathUtil.Lerp(0.94, 1, amount) : 1);
    }

    private static double PressScale(CursorTrack track, double time, CursorStyle style)
    {
        var amount = 0.0;
        foreach (var click in track.Clicks)
        {
            if (click.T > time) break;
            var release = Math.Max(click.ReleaseTime, click.T + PressDuration);
            if (time <= release) amount = Math.Max(amount, Math.Min(1, (time - click.T) / PressDuration));
            else if (time <= release + PressDuration) amount = Math.Max(amount, 1 - (time - release) / PressDuration);
        }
        return MathUtil.Lerp(1, style.PressScale, amount);
    }
}
