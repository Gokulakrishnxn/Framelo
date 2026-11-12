using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Framelo.Core;

public enum CursorKind { Arrow, IBeam, PointingHand }

/// <summary>Cursor position, normalised to the captured area (0…1, top-left origin). Time is session seconds.</summary>
public readonly record struct CursorSample(double T, double X, double Y);

public sealed record ClickEvent(double T, double X, double Y)
{
    /// <summary>Time the button was released; equals T when unknown.</summary>
    public double ReleaseTime { get; set; } = T;
}

public readonly record struct CursorKindChange(double T, CursorKind Kind);

/// <summary>Everything recorded about the pointer during a session.</summary>
public sealed class CursorTrack
{
    public List<CursorSample> Samples { get; } = new();
    public List<ClickEvent> Clicks { get; } = new();
    public List<CursorKindChange> Kinds { get; } = new();

    public static CursorTrack Empty => new();
    public bool IsEmpty => Samples.Count == 0;

    /// <summary>Linear interpolation of the raw position at a session time.</summary>
    public (double X, double Y)? Position(double time)
    {
        if (Samples.Count == 0) return null;
        var first = Samples[0];
        var last = Samples[^1];
        if (time <= first.T) return (first.X, first.Y);
        if (time >= last.T) return (last.X, last.Y);
        int lo = 0, hi = Samples.Count - 1;
        while (hi - lo > 1)
        {
            var mid = (lo + hi) / 2;
            if (Samples[mid].T <= time) lo = mid; else hi = mid;
        }
        var a = Samples[lo];
        var b = Samples[hi];
        var span = b.T - a.T;
        var f = span > 0 ? (time - a.T) / span : 0;
        return (MathUtil.Lerp(a.X, b.X, f), MathUtil.Lerp(a.Y, b.Y, f));
    }

    public CursorKind KindAt(double time)
    {
        var result = CursorKind.Arrow;
        foreach (var change in Kinds)
        {
            if (change.T <= time) result = change.Kind; else break;
        }
        return result;
    }

    // Line-delimited storage, byte-compatible with macOS cursor.jsonl:
    // {"k":"m","t":1.2,"x":0.5,"y":0.5}  move · "d" down · "u" up · "c" cursor kind change.
    // Append-only while recording and tolerant of a truncated last line.

    public static string EncodeMove(CursorSample s) => Line("m", s.T, s.X, s.Y, null);
    public static string EncodeDown(double t, double x, double y) => Line("d", t, x, y, null);
    public static string EncodeUp(double t) => Line("u", t, null, null, null);
    public static string EncodeKind(double t, CursorKind kind) => Line("c", t, null, null, KindName(kind));

    private static string KindName(CursorKind k) => k switch
    {
        CursorKind.IBeam => "iBeam", CursorKind.PointingHand => "pointingHand", _ => "arrow",
    };

    private static string Line(string k, double t, double? x, double? y, string? c)
    {
        var sb = new StringBuilder("{");
        void Num(string key, double v) => sb.Append(",\"").Append(key).Append("\":").Append(v.ToString("R", CultureInfo.InvariantCulture));
        sb.Append("\"k\":\"").Append(k).Append('"');
        Num("t", t);
        if (x is double xv) Num("x", xv);
        if (y is double yv) Num("y", yv);
        if (c != null) sb.Append(",\"c\":\"").Append(c).Append('"');
        return sb.Append("}\n").ToString();
    }

    private sealed class RawLine
    {
        [JsonPropertyName("k")] public string? K { get; set; }
        [JsonPropertyName("t")] public double T { get; set; }
        [JsonPropertyName("x")] public double? X { get; set; }
        [JsonPropertyName("y")] public double? Y { get; set; }
        [JsonPropertyName("c")] public string? C { get; set; }
    }

    public static CursorTrack Parse(string text)
    {
        var track = new CursorTrack();
        foreach (var raw in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            RawLine? line;
            try { line = JsonSerializer.Deserialize<RawLine>(raw.Trim()); }
            catch (JsonException) { continue; }
            if (line == null) continue;
            switch (line.K)
            {
                case "m" when line.X is double x && line.Y is double y:
                    track.Samples.Add(new CursorSample(line.T, x, y)); break;
                case "d" when line.X is double x && line.Y is double y:
                    track.Clicks.Add(new ClickEvent(line.T, x, y)); break;
                case "u":
                    if (track.Clicks.Count > 0 && track.Clicks[^1].ReleaseTime == track.Clicks[^1].T)
                        track.Clicks[^1].ReleaseTime = Math.Max(line.T, track.Clicks[^1].T);
                    break;
                case "c":
                    var kind = line.C switch
                    {
                        "arrow" => CursorKind.Arrow, "iBeam" => CursorKind.IBeam,
                        "pointingHand" => CursorKind.PointingHand, _ => (CursorKind?)null,
                    };
                    if (kind is CursorKind kk) track.Kinds.Add(new CursorKindChange(line.T, kk));
                    break;
            }
        }
        track.Samples.Sort((a, b) => a.T.CompareTo(b.T));
        track.Clicks.Sort((a, b) => a.T.CompareTo(b.T));
        track.Kinds.Sort((a, b) => a.T.CompareTo(b.T));
        return track;
    }

    public static CursorTrack Load(string path)
    {
        try { return File.Exists(path) ? Parse(File.ReadAllText(path)) : Empty; }
        catch (IOException) { return Empty; }
    }
}
