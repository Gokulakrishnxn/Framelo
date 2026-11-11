using Framelo.App.Services;
using Framelo.Core;
using Framelo.Platform.Media;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;

namespace Framelo.App.Views;

/// <summary>Export: choose settings, choose a file, render with progress and cancel, verify, then reveal the file.</summary>
public static class ExportFlow
{
    public static async Task RunAsync(EditorPage page, EditorModel model)
    {
        var prefs = App.Services.Preferences;
        var settings = ProjectJson.Deserialize<ExportSettings>(ProjectJson.Serialize(model.Project.Settings.Export));
        settings.Author = prefs.ExportAuthor;

        // 1. Settings
        var resolution = Combo("Resolution", new[] { "720p", "1080p", "4K" }, (int)settings.Resolution);
        var fps = Combo("Frame rate", new[] { "30 fps", "60 fps" }, settings.FrameRate >= 60 ? 1 : 0);
        var codec = Combo("Codec", new[] { "H.264 (most compatible)", "HEVC (smaller files)" }, (int)settings.Codec);
        var quality = Combo("Quality", new[] { "Standard", "High", "Maximum" }, (int)settings.Quality);
        var estimate = new TextBlock { Foreground = (Brush)Application.Current.Resources["TextSecondaryBrush"] };
        void Update()
        {
            settings.Resolution = (ExportResolution)Math.Max(0, resolution.SelectedIndex);
            settings.FrameRate = fps.SelectedIndex == 1 ? 60 : 30;
            settings.Codec = (ExportCodec)Math.Max(0, codec.SelectedIndex);
            settings.Quality = (ExportQuality)Math.Max(0, quality.SelectedIndex);
            var plan = ExportPlan.For(model.Project, settings, hasAudio: true);
            estimate.Text = $"MP4 · {plan.Width}×{plan.Height} · {Format.Duration(plan.Duration)} · about {Format.Bytes(plan.EstimatedBytes)}";
        }
        foreach (var c in new[] { resolution, fps, codec, quality }) c.SelectionChanged += (_, _) => Update();
        Update();
        var choose = new ContentDialog
        {
            Title = "Export video", PrimaryButtonText = "Export…", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
            XamlRoot = page.Root,
            Content = new StackPanel { Spacing = 12, MinWidth = 360, Children = { resolution, fps, codec, quality, estimate } },
        };
        if (await choose.ShowAsync() != ContentDialogResult.Primary) return;

        // 2. Destination
        var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.VideosLibrary, SuggestedFileName = SafeName(model.Project.Name) };
        picker.FileTypeChoices.Add("MPEG-4 video", new List<string> { ".mp4" });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHelpers.Handle(App.MainWindow));
        var file = await picker.PickSaveFileAsync();
        if (file == null) return;
        var destination = file.Path;

        // Remember the choices for this project and as defaults.
        model.Session.TryPerform(EditCommand.Settings("Export Settings", s => s.Export = ProjectJson.Deserialize<ExportSettings>(ProjectJson.Serialize(settings))), out _);
        prefs.ExportCodec = settings.Codec; prefs.ExportResolution = settings.Resolution; prefs.ExportFrameRate = settings.FrameRate;
        prefs.ExportQuality = settings.Quality; prefs.ExportFolder = Path.GetDirectoryName(destination);
        App.Services.SavePreferences();

        // 3. Render
        var bar = new ProgressBar { Maximum = 1, Minimum = 0, Width = 360 };
        var status = new TextBlock { Text = "Preparing…", Foreground = (Brush)Application.Current.Resources["TextSecondaryBrush"] };
        using var cancel = new CancellationTokenSource();
        var progressDialog = new ContentDialog
        {
            Title = "Exporting", CloseButtonText = "Cancel", XamlRoot = page.Root,
            Content = new StackPanel { Spacing = 12, Children = { bar, status } },
        };
        progressDialog.CloseButtonClick += (_, _) => cancel.Cancel();
        var progress = new Progress<ExportProgress>(p =>
        {
            bar.Value = p.Fraction;
            status.Text = p.Remaining is TimeSpan r ? $"{p.Fraction:P0} · about {Format.Duration(r.TotalSeconds)} left" : $"{p.Fraction:P0}";
        });
        var project = model.Session.Project;
        var cursors = model.Session.CursorTracks;
        var package = model.Session.PackagePath;
        var work = App.Services.Store.Location.ExportTempDirectory;
        var task = Task.Run(() => ExportService.Export(project, cursors, package, settings, destination, work, progress, cancel.Token));
        _ = progressDialog.ShowAsync();
        ExportResult? result = null;
        string? error = null;
        try { result = await task; }
        catch (OperationCanceledException) { }
        catch (Exception e) { Log.Error("Export", e); error = e is ExportVerificationException ? $"The exported file failed its check: {e.Message}." : e.Message; }
        progressDialog.Hide();

        // 4. Result
        if (result != null)
        {
            model.Session.TryPerform(new EditCommand("Export", p => p.ExportUrl = new Uri(result.Path).AbsoluteUri), out _);
            var done = new ContentDialog
            {
                Title = "Export complete", PrimaryButtonText = "Show in folder", CloseButtonText = "Done", XamlRoot = page.Root,
                Content = $"{Path.GetFileName(result.Path)} · {result.Facts.PixelWidth}×{result.Facts.PixelHeight} · {Format.Bytes(result.Bytes)} · rendered in {Format.Duration(result.Elapsed.TotalSeconds)}",
            };
            if (await done.ShowAsync() == ContentDialogResult.Primary)
                System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{result.Path}\"");
        }
        else if (error != null)
        {
            await new ContentDialog { Title = "Export failed", Content = error, CloseButtonText = "OK", XamlRoot = page.Root }.ShowAsync();
        }
    }

    private static ComboBox Combo(string header, string[] items, int selected) =>
        new() { Header = header, ItemsSource = items, SelectedIndex = Math.Clamp(selected, 0, items.Length - 1), HorizontalAlignment = HorizontalAlignment.Stretch };

    private static string SafeName(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '-');
        return string.IsNullOrWhiteSpace(name) ? "Framelo export" : name;
    }
}
