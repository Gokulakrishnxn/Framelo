using Framelo.App.Views;
using Framelo.Core;
using Framelo.Platform.Media;

namespace Framelo.App.Services;

/// <summary>App-level navigation between the dashboard, the capture bar, the editor and settings.</summary>
public static class Navigation
{
    private static CaptureBarWindow? _captureBar;

    public static void StartRecording()
    {
        if (_captureBar != null) { _captureBar.Activate(); return; }
        _captureBar = new CaptureBarWindow();
        _captureBar.Finished += (project, error) =>
        {
            _captureBar = null;
            WindowHelpers.Restore(App.MainWindow);
            if (project != null && App.Services.Preferences.OpenEditorAfterRecording) OpenProject(project.Id);
            else App.MainWindow.ShowDashboard(error ?? (project != null ? $"Saved “{project.Name}”." : null));
        };
        WindowHelpers.Minimize(App.MainWindow);
        _captureBar.Activate();
    }

    public static void OpenProject(Guid id) => OpenProjectHandler?.Invoke(id);
    public static void OpenSettings() => OpenSettingsHandler?.Invoke();

    /// <summary>Set by the editor and settings stages.</summary>
    public static Action<Guid>? OpenProjectHandler { get; set; }
    public static Action? OpenSettingsHandler { get; set; }

    /// <summary>Finishes interrupted recordings left by a crash. Runs once at launch, off the UI thread.</summary>
    public static async Task<string?> RecoverAsync()
    {
        try
        {
            var report = await Task.Run(() => RecoveryService.Run(App.Services.Store, new MfInspector()));
            if (report.Recovered.Count > 0)
                return report.Recovered.Count == 1 ? "An interrupted recording was recovered." : $"{report.Recovered.Count} interrupted recordings were recovered.";
            if (report.Quarantined.Count > 0)
                return "An interrupted recording could not be recovered and was moved to Recovery\\Quarantine in your library.";
        }
        catch (Exception e)
        {
            Log.Error("Recovery", e);
        }
        return null;
    }

    public static Task ImportVideoAsync() => Task.CompletedTask;
}
