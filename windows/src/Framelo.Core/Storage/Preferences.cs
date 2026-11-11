namespace Framelo.Core;

public enum ThemeChoice { System, Dark, Light }
public enum AccentChoice { Violet, Blue, Pink, Orange, Green, Graphite }

/// <summary>
/// User preferences, the counterpart of the macOS Settings window (Profile, Appearance, Recording, Storage, Privacy).
/// Stored as JSON in %LOCALAPPDATA%\Framelo\preferences.json.
/// </summary>
public sealed class Preferences
{
    // Profile
    public string DisplayName { get; set; } = Environment.UserName;
    public string Email { get; set; } = "";
    public string? AvatarPath { get; set; }
    public bool EmbedAuthorInExports { get; set; } = true;

    // Appearance
    public ThemeChoice Theme { get; set; } = ThemeChoice.Dark;
    public AccentChoice Accent { get; set; } = AccentChoice.Violet;

    // Recording
    public int FrameRate { get; set; } = 60;
    public int CountdownSeconds { get; set; } = 3;
    public bool CaptureSystemAudio { get; set; } = true;
    public bool CaptureMicrophone { get; set; } = true;
    public string? MicrophoneId { get; set; }
    public bool OpenEditorAfterRecording { get; set; } = true;
    public bool GlobalShortcutsEnabled { get; set; } = true;

    // Editing and export defaults
    public string DefaultPresetId { get; set; } = "aurora";
    public bool AutoZoomByDefault { get; set; } = true;
    public double CursorSmoothingDefault { get; set; } = 0.55;
    public ExportCodec ExportCodec { get; set; } = ExportCodec.H264;
    public ExportResolution ExportResolution { get; set; } = ExportResolution.P1080;
    public int ExportFrameRate { get; set; } = 60;
    public ExportQuality ExportQuality { get; set; } = ExportQuality.High;
    public string? ExportFolder { get; set; }

    // Storage
    public string? LibraryPath { get; set; }

    // Privacy
    public bool HideDesktopIconsWhileRecording { get; set; }
    public bool ExcludeFrameloFromCapture { get; set; } = true;

    public static uint AccentHex(AccentChoice a) => a switch
    {
        AccentChoice.Blue => 0x0A84FF, AccentChoice.Pink => 0xFF375F, AccentChoice.Orange => 0xFF9F0A,
        AccentChoice.Green => 0x30D158, AccentChoice.Graphite => 0x8E8E93, _ => 0x7C5CFF,
    };

    public LibraryLocation Library => string.IsNullOrWhiteSpace(LibraryPath) ? LibraryLocation.Default : new LibraryLocation(LibraryPath);

    public string? ExportAuthor => EmbedAuthorInExports && !string.IsNullOrWhiteSpace(DisplayName) ? DisplayName.Trim() : null;

    public ExportSettings ExportDefaults => new()
    {
        Codec = ExportCodec, Resolution = ExportResolution, FrameRate = ExportFrameRate, Quality = ExportQuality, Author = ExportAuthor,
    };

    public string Initials
    {
        get
        {
            var parts = DisplayName.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            return string.Concat(parts.Take(2).Select(p => char.ToUpperInvariant(p[0])));
        }
    }

    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Framelo", "preferences.json");

    public static Preferences Load(string? path = null)
    {
        path ??= DefaultPath;
        try { return File.Exists(path) ? ProjectJson.Deserialize<Preferences>(File.ReadAllText(path)) : new Preferences(); }
        catch (Exception e) when (e is IOException or System.Text.Json.JsonException) { return new Preferences(); }
    }

    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        AtomicFile.WriteAllText(path, ProjectJson.Serialize(this));
    }
}
