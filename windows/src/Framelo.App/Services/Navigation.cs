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
        _captureBar.Finished += async (project, error) =>
        {
            _captureBar = null;
            if (project != null) project = await Task.Run(() => Prepare(project));
            WindowHelpers.Restore(App.MainWindow);
            if (project != null && error == null && App.Services.Preferences.OpenEditorAfterRecording) OpenProject(project.Id);
            else App.MainWindow.ShowDashboard(error ?? (project != null ? $"Saved “{project.Name}”." : null));
        };
        WindowHelpers.Minimize(App.MainWindow);
        _captureBar.Activate();
    }

    /// <summary>Ctrl+Shift+2: open the capture bar, start recording, or stop the current recording.</summary>
    public static void ToggleRecording()
    {
        if (_captureBar == null) { StartRecording(); return; }
        _captureBar.ToggleRecording();
    }

    /// <summary>Ctrl+Shift+3: pause or resume the current recording.</summary>
    public static void TogglePause() => _captureBar?.TogglePause();

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

    /// <summary>Applies the user's defaults to a new project, saves it and writes its poster.</summary>
    private static Project Prepare(Project project)
    {
        try
        {
            App.Services.Preferences.ApplyTo(project);
            App.Services.Store.Save(project);
            var package = App.Services.Store.Location.PackagePath(project.Id);
            var cursors = project.Sources.Where(s => s.CursorPath != null)
                .ToDictionary(s => s.Id, s => CursorTrack.Load(ProjectPackage.Resolve(s.CursorPath!, package)));
            PosterWriter.Write(project, cursors, package);
        }
        catch (Exception e)
        {
            Log.Error("Prepare project", e);
        }
        return project;
    }

    /// <summary>Makes a project around a video file. The file is referenced where it is, never copied or changed.</summary>
    public static async Task ImportVideoAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker { SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.VideosLibrary };
        foreach (var ext in new[] { ".mp4", ".mov", ".m4v", ".wmv", ".avi", ".mkv" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHelpers.Handle(App.MainWindow));
        var file = await picker.PickSingleFileAsync();
        if (file == null) return;
        var path = file.Path;
        var project = await Task.Run(() =>
        {
            var facts = new MfInspector().Inspect(path);
            if (facts == null || !facts.HasVideo || facts.Duration <= 0) return null;
            var name = Path.GetFileNameWithoutExtension(path);
            var source = new MediaSource
            {
                Kind = SourceKind.ImportedVideo, Name = name, Duration = facts.Duration,
                Screen = new MediaFile { RelativePath = path, Duration = facts.Duration, PixelWidth = facts.PixelWidth, PixelHeight = facts.PixelHeight, HasAudio = facts.HasAudio },
            };
            return Prepare(Project.Make(name, source));
        });
        if (project == null) App.MainWindow.ShowDashboard($"“{file.Name}” could not be opened as a video.");
        else OpenProject(project.Id);
    }
}
