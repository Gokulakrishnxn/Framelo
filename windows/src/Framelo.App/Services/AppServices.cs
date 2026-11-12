using Framelo.Core;

namespace Framelo.App.Services;

/// <summary>Process-wide services. Created once at launch.</summary>
public sealed class AppServices
{
    public required Preferences Preferences { get; init; }
    public required ProjectStore Store { get; set; }

    public static AppServices Create()
    {
        var prefs = Preferences.Load();
        var store = new ProjectStore(prefs.Library);
        try { store.PrepareLibrary(); } catch (Exception e) { Log.Error("Library", e); }
        return new AppServices { Preferences = prefs, Store = store };
    }

    public void SavePreferences()
    {
        try { Preferences.Save(); } catch (Exception e) { Log.Error("Preferences", e); }
    }

    /// <summary>Re-points the library after Settings › Storage changes it.</summary>
    public void ReloadLibrary()
    {
        Store = new ProjectStore(Preferences.Library);
        try { Store.PrepareLibrary(); } catch (Exception e) { Log.Error("Library", e); }
    }
}

public static class Log
{
    private static readonly object Gate = new();
    public static string PathName => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Framelo", "framelo.log");

    public static void Info(string message) => Write("INFO", message);
    public static void Error(string context, Exception e) => Write("ERROR", $"{context}: {e}");

    private static void Write(string level, string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PathName)!);
                File.AppendAllText(PathName, $"{DateTimeOffset.Now:O} {level} {message}{Environment.NewLine}");
            }
        }
        catch (IOException) { }
    }
}
