using System.Text.Json;
using System.Text.Json.Serialization;

namespace Framelo.Core;

/// <summary>
/// Exact, integer-based time used everywhere in the project model.
/// 60 000 ticks per second divides evenly by 24, 25, 30, 50, 60 and 120 fps and by milliseconds,
/// so timeline arithmetic is deterministic and free of floating-point drift.
/// Serialised as a bare integer, exactly like the macOS app.
/// </summary>
[JsonConverter(typeof(MediaTimeJsonConverter))]
public readonly record struct MediaTime(long Ticks) : IComparable<MediaTime>
{
    public const long Timescale = 60_000;
    public static readonly MediaTime Zero = new(0);

    public static MediaTime FromSeconds(double seconds) =>
        new(double.IsFinite(seconds) ? (long)Math.Round(seconds * Timescale, MidpointRounding.AwayFromZero) : 0);

    /// <summary>Converts from 100 ns units (Media Foundation / TimeSpan ticks).</summary>
    public static MediaTime FromHundredNanoseconds(long hns) =>
        new((long)Math.Round(hns * (double)Timescale / 10_000_000, MidpointRounding.AwayFromZero));

    public double Seconds => (double)Ticks / Timescale;
    public long HundredNanoseconds => (long)Math.Round(Ticks * 10_000_000.0 / Timescale, MidpointRounding.AwayFromZero);

    /// <summary>Divides by a speed factor, rounding to the nearest tick. The single place where rounding happens.</summary>
    public MediaTime DividedBy(double factor) => new((long)Math.Round(Ticks / factor, MidpointRounding.AwayFromZero));
    public MediaTime MultipliedBy(double factor) => new((long)Math.Round(Ticks * factor, MidpointRounding.AwayFromZero));

    public int CompareTo(MediaTime other) => Ticks.CompareTo(other.Ticks);
    public static bool operator <(MediaTime a, MediaTime b) => a.Ticks < b.Ticks;
    public static bool operator >(MediaTime a, MediaTime b) => a.Ticks > b.Ticks;
    public static bool operator <=(MediaTime a, MediaTime b) => a.Ticks <= b.Ticks;
    public static bool operator >=(MediaTime a, MediaTime b) => a.Ticks >= b.Ticks;
    public static MediaTime operator +(MediaTime a, MediaTime b) => new(a.Ticks + b.Ticks);
    public static MediaTime operator -(MediaTime a, MediaTime b) => new(a.Ticks - b.Ticks);
    public static MediaTime operator -(MediaTime a) => new(-a.Ticks);
    public static MediaTime Max(MediaTime a, MediaTime b) => a > b ? a : b;
    public static MediaTime Min(MediaTime a, MediaTime b) => a < b ? a : b;

    public override string ToString() => $"{Seconds:0.0000}s";
}

public sealed class MediaTimeJsonConverter : JsonConverter<MediaTime>
{
    public override MediaTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        new(reader.GetInt64());

    public override void Write(Utf8JsonWriter writer, MediaTime value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(value.Ticks);
}

/// <summary>Half-open time range [start, end).</summary>
public sealed record MediaRange
{
    public MediaTime Start { get; init; }
    public MediaTime Duration { get; init; }

    public MediaRange() { }
    public MediaRange(MediaTime start, MediaTime duration) { Start = start; Duration = duration; }
    public static MediaRange FromBounds(MediaTime start, MediaTime end) => new(start, end - start);

    [JsonIgnore] public MediaTime End => Start + Duration;
    [JsonIgnore] public bool IsEmpty => Duration.Ticks <= 0;

    public bool Contains(MediaTime time) => time >= Start && time < End;

    public bool Overlaps(MediaRange other) =>
        Start < other.End && other.Start < End && !IsEmpty && !other.IsEmpty;

    public MediaRange? Intersection(MediaRange other)
    {
        var s = MediaTime.Max(Start, other.Start);
        var e = MediaTime.Min(End, other.End);
        return e > s ? FromBounds(s, e) : null;
    }
}
