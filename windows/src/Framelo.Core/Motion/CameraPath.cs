namespace Framelo.Core;

/// <summary>Where the virtual camera looks: scale ≥ 1, centre normalised to the screen content (top-left origin).</summary>
public readonly record struct CameraState(double Scale = 1, double CenterX = 0.5, double CenterY = 0.5)
{
    public static readonly CameraState Identity = new(1, 0.5, 0.5);

    /// <summary>Width (= height) of the visible part of the content, as a fraction of the whole.</summary>
    public double Viewport => 1 / Math.Max(Scale, 1);

    /// <summary>
    /// Interpolates the visible rectangle rather than the scale, which makes a zoom a straight push-in instead of
    /// a curve. The centre is clamped so the view never leaves the content.
    /// </summary>
    public static CameraState Interpolate(CameraState a, CameraState b, double p)
    {
        var width = MathUtil.Lerp(a.Viewport, b.Viewport, p);
        return new CameraState(1 / width, MathUtil.Lerp(a.CenterX, b.CenterX, p), MathUtil.Lerp(a.CenterY, b.CenterY, p)).Clamped();
    }

    public CameraState Clamped()
    {
        var s = Math.Clamp(Scale, 1, TimelineValidator.MaxZoomScale);
        var half = 0.5 / s;
        return new CameraState(s, Math.Clamp(CenterX, half, 1 - half), Math.Clamp(CenterY, half, 1 - half));
    }
}

public readonly record struct Vec2(double X, double Y)
{
    public static Vec2 operator +(Vec2 a, Vec2 b) => new(a.X + b.X, a.Y + b.Y);
    public static Vec2 operator -(Vec2 a, Vec2 b) => new(a.X - b.X, a.Y - b.Y);
    public static Vec2 operator *(Vec2 a, double s) => new(a.X * s, a.Y * s);
}

/// <summary>A zoom prepared for evaluation: clamped times and transitions plus the path followed while zoomed.</summary>
public sealed record ResolvedZoom(Guid Id, double Start, double End, double Scale, double TransitionIn, double TransitionOut,
    Easing Easing, IReadOnlyList<Vec2> Targets)
{
    public Vec2 Target(double time)
    {
        if (Targets.Count <= 1) return Targets.Count == 1 ? Targets[0] : new Vec2(0.5, 0.5);
        var position = Math.Max(0, (time - Start) * CameraPath.FollowRate);
        var index = Math.Min((int)position, Targets.Count - 2);
        var fraction = Math.Clamp(position - index, 0, 1);
        return Targets[index] + (Targets[index + 1] - Targets[index]) * fraction;
    }

    /// <summary>0 = fully zoomed out, 1 = fully zoomed in.</summary>
    public double Amount(double time)
    {
        if (time <= Start || time >= End) return 0;
        if (time < Start + TransitionIn) return Easing.Value((time - Start) / TransitionIn);
        if (time > End - TransitionOut) return 1 - Easing.Value((time - (End - TransitionOut)) / TransitionOut);
        return 1;
    }
}

public sealed record ResolvedKeyframe(double Time, CameraState State, Easing Easing);

/// <summary>The complete camera move for a timeline: random-access, deterministic, continuous.</summary>
public sealed class CameraPath
{
    public const double FollowRate = 60.0;
    /// <summary>Shortest transition allowed, so a zoom can never be an instant cut.</summary>
    public const double MinimumTransition = 0.15;
    /// <summary>Seconds of transition required per unit of zoom beyond 1×.</summary>
    public const double TransitionPerScale = 0.25;
    /// <summary>Lead-in / lead-out around a keyframed span.</summary>
    public const double KeyframeLead = 0.6;

    public static double MinimumTransitionForScale(double scale) => Math.Max(MinimumTransition, TransitionPerScale * (scale - 1));
    public static double MaximumScaleForTransition(double duration) => 1 + Math.Max(duration, 0) / TransitionPerScale;

    public IReadOnlyList<ResolvedZoom> Zooms { get; set; }
    public IReadOnlyList<ResolvedKeyframe> Keyframes { get; }

    public CameraPath(IReadOnlyList<ResolvedZoom>? zooms = null, IReadOnlyList<ResolvedKeyframe>? keyframes = null)
    {
        Zooms = zooms ?? Array.Empty<ResolvedZoom>();
        Keyframes = keyframes ?? Array.Empty<ResolvedKeyframe>();
    }

    public static readonly CameraPath Empty = new();

    public (double Lower, double Upper)? KeyframeSpan =>
        Keyframes.Count == 0 ? null : (Keyframes[0].Time - KeyframeLead, Keyframes[^1].Time + KeyframeLead);

    public CameraState State(double time)
    {
        if (KeyframeSpan is { } span && time >= span.Lower && time <= span.Upper) return KeyframeState(time);
        if (ZoomAt(time) is not ResolvedZoom zoom) return CameraState.Identity;
        var amount = zoom.Amount(time);
        if (amount <= 0) return CameraState.Identity;
        var target = zoom.Target(time);
        return CameraState.Interpolate(CameraState.Identity, new CameraState(zoom.Scale, target.X, target.Y), amount);
    }

    private ResolvedZoom? ZoomAt(double time)
    {
        int lo = 0, hi = Zooms.Count - 1;
        while (lo <= hi)
        {
            var mid = (lo + hi) / 2;
            if (time < Zooms[mid].Start) hi = mid - 1;
            else if (time >= Zooms[mid].End) lo = mid + 1;
            else return Zooms[mid];
        }
        return null;
    }

    private CameraState KeyframeState(double time)
    {
        var first = Keyframes[0];
        var last = Keyframes[^1];
        if (time < first.Time)
            return CameraState.Interpolate(CameraState.Identity, first.State.Clamped(), Easing.EaseInOut.Value((time - (first.Time - KeyframeLead)) / KeyframeLead));
        if (time >= last.Time)
            return CameraState.Interpolate(last.State.Clamped(), CameraState.Identity, Easing.EaseInOut.Value((time - last.Time) / KeyframeLead));
        var next = 0;
        while (next < Keyframes.Count && Keyframes[next].Time <= time) next++;
        if (next >= Keyframes.Count) next = Keyframes.Count - 1;
        var a = Keyframes[Math.Max(0, next - 1)];
        var b = Keyframes[next];
        var span = b.Time - a.Time;
        var p = span > 0 ? b.Easing.Value((time - a.Time) / span) : 1;
        return CameraState.Interpolate(a.State.Clamped(), b.State.Clamped(), p);
    }

    /// <summary>Camera velocity per second by central difference — drives motion blur.</summary>
    public (double CenterX, double CenterY, double Scale) Velocity(double time, double delta = 1.0 / 120)
    {
        var a = State(time - delta);
        var b = State(time + delta);
        var span = 2 * delta;
        return ((b.CenterX - a.CenterX) / span, (b.CenterY - a.CenterY) / span, (b.Scale - a.Scale) / span);
    }
}
