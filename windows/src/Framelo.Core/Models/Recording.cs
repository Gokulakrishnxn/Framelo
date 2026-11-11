using System.Text.Json.Serialization;

namespace Framelo.Core;

/// <summary>One media file on disk that belongs to a source. Paths are relative to the project package.</summary>
public sealed class MediaFile
{
    public string RelativePath { get; set; } = "";
    /// <summary>Seconds between the session's time zero and this file's first sample.</summary>
    public double StartOffset { get; set; }
    public double Duration { get; set; }
    public int PixelWidth { get; set; }
    public int PixelHeight { get; set; }
    public bool HasAudio { get; set; }
    /// <summary>Rate applied to cancel measured clock drift against the screen video (1 = none).</summary>
    public double RateCorrection { get; set; } = 1;
}

/// <summary>Captured rectangle in global screen pixels (top-left origin) and its DPI scale.</summary>
public sealed class CaptureInfo
{
    public double X { get; set; }
    public double Y { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }
    public double Scale { get; set; } = 1;
}

public enum SourceKind { Recording, ImportedVideo, ImportedAudio }

public sealed class MediaSource
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public SourceKind Kind { get; set; }
    public string Name { get; set; } = "";
    public MediaFile? Screen { get; set; }
    public MediaFile? Camera { get; set; }
    public MediaFile? Microphone { get; set; }
    public MediaFile? SystemAudio { get; set; }
    public string? CursorPath { get; set; }
    public CaptureInfo? Capture { get; set; }
    /// <summary>Usable duration of the session in seconds.</summary>
    public double Duration { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>What to capture. Serialised like Swift's enum-with-associated-values: {"display":{"id":1}}.</summary>
[JsonConverter(typeof(CaptureTargetJsonConverter))]
public abstract record CaptureTarget
{
    /// <summary>A monitor, identified by its HMONITOR index in enumeration order (Windows) or CGDirectDisplayID (macOS).</summary>
    public sealed record Display(uint Id) : CaptureTarget;
    /// <summary>A top-level window, identified by its HWND.</summary>
    public sealed record Window(uint Id) : CaptureTarget;
    /// <summary>Area in the display's pixel coordinates, top-left origin.</summary>
    public sealed record Region(uint DisplayId, double X, double Y, double Width, double Height) : CaptureTarget;
}

public enum CaptureResolution { Native, P1080, P720 }

public sealed class RecordingConfig
{
    public CaptureTarget Target { get; set; } = new CaptureTarget.Display(0);
    public int FrameRate { get; set; } = 60;
    public CaptureResolution Resolution { get; set; } = CaptureResolution.Native;
    public bool CaptureSystemAudio { get; set; } = true;
    public bool CaptureMicrophone { get; set; } = true;
    [JsonPropertyName("microphoneID")] public string? MicrophoneId { get; set; }
    public bool NoiseReduction { get; set; }
    public bool CaptureCamera { get; set; }
    [JsonPropertyName("cameraID")] public string? CameraId { get; set; }
    public int CountdownSeconds { get; set; } = 3;

    public static int? MaxHeight(CaptureResolution r) => r switch
    {
        CaptureResolution.P1080 => 1080,
        CaptureResolution.P720 => 720,
        _ => null,
    };
}
