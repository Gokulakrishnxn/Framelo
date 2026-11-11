namespace Framelo.App.Services;

/// <summary>App-level navigation. Each stage of the port fills in its destination.</summary>
public static partial class Navigation
{
    public static void OpenProject(Guid id) => OpenProjectCore(id);
    public static void StartRecording() => StartRecordingCore();
    public static void OpenSettings() => OpenSettingsCore();
    public static Task ImportVideoAsync() => ImportVideoCore();

    static partial void OpenProjectCore(Guid id);
    static partial void StartRecordingCore();
    static partial void OpenSettingsCore();
    private static Task ImportVideoCore() => Task.CompletedTask;
}
