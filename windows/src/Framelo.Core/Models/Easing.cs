namespace Framelo.Core;

/// <summary>Interpolation curves for camera and keyframe motion. All map 0→0 and 1→1.</summary>
public enum Easing { Linear, EaseIn, EaseOut, EaseInOut, Spring }

public static class EasingExtensions
{
    // Under-damped spring (ζ = 0.82): a small, quick overshoot that settles before t = 1.
    private const double Zeta = 0.82;
    private const double Omega = 11.0;
    private static readonly double SpringEnd = SpringValue(1);

    public static string DisplayName(this Easing e) => e switch
    {
        Easing.Linear => "Linear",
        Easing.EaseIn => "Ease In",
        Easing.EaseOut => "Ease Out",
        Easing.EaseInOut => "Ease In Out",
        _ => "Spring",
    };

    public static double Value(this Easing e, double t)
    {
        var x = Math.Clamp(t, 0, 1);
        switch (e)
        {
            case Easing.Linear: return x;
            case Easing.EaseIn: return x * x * x;
            case Easing.EaseOut: { var inv = 1 - x; return 1 - inv * inv * inv; }
            case Easing.EaseInOut: return x * x * x * (x * (x * 6 - 15) + 10); // quintic smootherstep
            default: return SpringValue(x) / SpringEnd;
        }
    }

    private static double SpringValue(double t)
    {
        var wd = Omega * Math.Sqrt(1 - Zeta * Zeta);
        var envelope = Math.Exp(-Zeta * Omega * t);
        return 1 - envelope * (Math.Cos(wd * t) + (Zeta * Omega / wd) * Math.Sin(wd * t));
    }
}

public static class MathUtil
{
    public static double Lerp(double a, double b, double t) => a + (b - a) * t;
}
