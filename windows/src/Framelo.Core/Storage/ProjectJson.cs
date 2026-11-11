using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Framelo.Core;

/// <summary>
/// JSON settings that match the macOS app's encoder: camelCase keys, enum raw values as camelCase strings,
/// nil optionals omitted, ISO-8601 dates without fractional seconds, upper-case UUIDs.
/// </summary>
public static class ProjectJson
{
    public static readonly JsonSerializerOptions Options = Create();

    private static JsonSerializerOptions Create()
    {
        var o = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = true,
            PropertyNameCaseInsensitive = false,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
        };
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        o.Converters.Add(new IsoDateConverter());
        o.Converters.Add(new UpperGuidConverter());
        o.TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver
        {
            Modifiers = { SwiftKeyNames },
        };
        return o;
    }

    /// <summary>Swift spells identifier-suffixed keys "sourceID", not "sourceId".</summary>
    private static void SwiftKeyNames(System.Text.Json.Serialization.Metadata.JsonTypeInfo info)
    {
        foreach (var p in info.Properties)
        {
            if (p.Name.EndsWith("Id", StringComparison.Ordinal) && p.Name.Length > 2) p.Name = p.Name[..^2] + "ID";
        }
    }

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Options);
    public static Project Deserialize(string json) =>
        JsonSerializer.Deserialize<Project>(json, Options) ?? throw new JsonException("Empty project file.");
    public static T Deserialize<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, Options) ?? throw new JsonException("Empty file.");

    private sealed class IsoDateConverter : JsonConverter<DateTimeOffset>
    {
        public override DateTimeOffset Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o)
        {
            if (reader.TokenType == JsonTokenType.Number)
                return new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero).AddSeconds(reader.GetDouble());
            return DateTimeOffset.Parse(reader.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);
        }

        public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions o) =>
            writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }

    private sealed class UpperGuidConverter : JsonConverter<Guid>
    {
        public override Guid Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o) => Guid.Parse(reader.GetString()!);
        public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions o) =>
            writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
    }
}

/// <summary>Reads and writes the Swift synthesised encoding of RecordingConfig.Target.</summary>
public sealed class CaptureTargetJsonConverter : JsonConverter<CaptureTarget>
{
    public override CaptureTarget Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var prop = doc.RootElement.EnumerateObject().First();
        var v = prop.Value;
        double D(string k) => v.GetProperty(k).GetDouble();
        return prop.Name switch
        {
            "display" => new CaptureTarget.Display(v.GetProperty("id").GetUInt32()),
            "window" => new CaptureTarget.Window(v.GetProperty("id").GetUInt32()),
            "region" => new CaptureTarget.Region(v.GetProperty("displayID").GetUInt32(), D("x"), D("y"), D("width"), D("height")),
            _ => throw new JsonException($"Unknown capture target '{prop.Name}'."),
        };
    }

    public override void Write(Utf8JsonWriter w, CaptureTarget value, JsonSerializerOptions o)
    {
        w.WriteStartObject();
        switch (value)
        {
            case CaptureTarget.Display d:
                w.WriteStartObject("display"); w.WriteNumber("id", d.Id); w.WriteEndObject(); break;
            case CaptureTarget.Window win:
                w.WriteStartObject("window"); w.WriteNumber("id", win.Id); w.WriteEndObject(); break;
            case CaptureTarget.Region r:
                w.WriteStartObject("region");
                w.WriteNumber("displayID", r.DisplayId); w.WriteNumber("x", r.X); w.WriteNumber("y", r.Y);
                w.WriteNumber("width", r.Width); w.WriteNumber("height", r.Height);
                w.WriteEndObject(); break;
        }
        w.WriteEndObject();
    }
}
