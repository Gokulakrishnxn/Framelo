using Framelo.App.Services;
using Framelo.Core;
using Framelo.Platform.Capture;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;

namespace Framelo.App.Views;

/// <summary>
/// The Settings window: Profile, Appearance, Recording, Editing &amp; Export, Storage, Privacy and About,
/// chosen from an icon rail. Every change is saved immediately.
/// </summary>
public sealed class SettingsWindow : Window
{
    private static SettingsWindow? _open;
    private readonly NavigationView _nav;
    private readonly StackPanel _page = new() { Spacing = 14, Padding = new Thickness(32, 24, 32, 32), MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
    private Preferences Prefs => App.Services.Preferences;

    public static void Show()
    {
        if (_open != null) { _open.Activate(); return; }
        _open = new SettingsWindow();
        _open.Closed += (_, _) => _open = null;
        _open.Activate();
    }

    private SettingsWindow()
    {
        Title = "Framelo Settings";
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(860 * WindowHelpers.Scale(this)), (int)(640 * WindowHelpers.Scale(this))));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Framelo.ico"));
        _nav = new NavigationView
        {
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed, IsSettingsVisible = false, PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
            OpenPaneLength = 220, IsPaneToggleButtonVisible = false,
            Content = new ScrollViewer { Content = _page },
        };
        foreach (var (key, glyph, name) in new[]
        {
            ("profile", "", "Profile"), ("appearance", "", "Appearance"), ("recording", "", "Recording"),
            ("editing", "", "Editing & Export"), ("storage", "", "Storage"), ("privacy", "", "Privacy & Data"), ("about", "", "About"),
        })
            _nav.MenuItems.Add(new NavigationViewItem { Content = name, Tag = key, Icon = new FontIcon { Glyph = glyph } });
        _nav.SelectionChanged += (_, e) => { if (e.SelectedItem is NavigationViewItem { Tag: string key }) Build(key); };
        Content = new Grid { Background = (Brush)Application.Current.Resources["WindowBackgroundBrush"], Children = { _nav } };
        Appearance.Register(this);
        _nav.SelectedItem = _nav.MenuItems[0];
    }

    private void Save() => App.Services.SavePreferences();

    private void Build(string key)
    {
        _page.Children.Clear();
        switch (key)
        {
            case "profile": Profile(); break;
            case "appearance": AppearancePage(); break;
            case "recording": Recording(); break;
            case "editing": Editing(); break;
            case "storage": Storage(); break;
            case "privacy": Privacy(); break;
            default: About(); break;
        }
    }

    private void Profile()
    {
        Title("Profile", "Your name is written into exported videos as their author.");
        _page.Children.Add(new PersonPicture { DisplayName = Prefs.DisplayName, Width = 72, Height = 72, HorizontalAlignment = HorizontalAlignment.Left });
        Text("Name", Prefs.DisplayName, v => { Prefs.DisplayName = v; Save(); });
        Text("Email", Prefs.Email, v => { Prefs.Email = v; Save(); });
        Toggle("Add my name to exported videos", Prefs.EmbedAuthorInExports, v => { Prefs.EmbedAuthorInExports = v; Save(); });
    }

    private void AppearancePage()
    {
        Title("Appearance", null);
        Combo("Theme", new[] { "System", "Dark", "Light" }, (int)Prefs.Theme, i => { Prefs.Theme = (ThemeChoice)i; Save(); Appearance.ApplyAll(); });
        Combo("Accent colour", Enum.GetNames<AccentChoice>(), (int)Prefs.Accent, i => { Prefs.Accent = (AccentChoice)i; Save(); Appearance.ApplyAll(); });
    }

    private void Recording()
    {
        Title("Recording", "Defaults for the capture bar.");
        Combo("Frame rate", new[] { "30 fps", "60 fps" }, Prefs.FrameRate >= 60 ? 1 : 0, i => { Prefs.FrameRate = i == 1 ? 60 : 30; Save(); });
        var countdowns = new[] { 0, 3, 5, 10 };
        Combo("Countdown", new[] { "None", "3 seconds", "5 seconds", "10 seconds" }, Math.Max(0, Array.IndexOf(countdowns, Prefs.CountdownSeconds)),
            i => { Prefs.CountdownSeconds = countdowns[i]; Save(); });
        var mics = AudioRecorder.Microphones();
        var names = new[] { "System default" }.Concat(mics.Select(m => m.Name)).ToArray();
        Combo("Microphone", names, Math.Max(0, mics.ToList().FindIndex(m => m.Id == Prefs.MicrophoneId) + 1),
            i => { Prefs.MicrophoneId = i == 0 ? null : mics[i - 1].Id; Save(); });
        Toggle("Record microphone", Prefs.CaptureMicrophone, v => { Prefs.CaptureMicrophone = v; Save(); });
        Toggle("Record system audio", Prefs.CaptureSystemAudio, v => { Prefs.CaptureSystemAudio = v; Save(); });
        Toggle("Open the editor when a recording stops", Prefs.OpenEditorAfterRecording, v => { Prefs.OpenEditorAfterRecording = v; Save(); });
    }

    private void Editing()
    {
        Title("Editing & Export", "Applied to new recordings and imported videos.");
        Combo("Default style", StylePreset.All.Select(p => p.Name).ToArray(), Math.Max(0, StylePreset.All.ToList().FindIndex(p => p.Id == Prefs.DefaultPresetId)),
            i => { Prefs.DefaultPresetId = StylePreset.All[i].Id; Save(); });
        Toggle("Suggest zooms from clicks", Prefs.AutoZoomByDefault, v => { Prefs.AutoZoomByDefault = v; Save(); });
        var smoothing = new Slider { Header = "Cursor smoothing", Minimum = 0, Maximum = 1, StepFrequency = 0.05, Value = Prefs.CursorSmoothingDefault };
        smoothing.ValueChanged += (_, e) => { Prefs.CursorSmoothingDefault = e.NewValue; Save(); };
        _page.Children.Add(smoothing);
        Combo("Export resolution", new[] { "720p", "1080p", "4K" }, (int)Prefs.ExportResolution, i => { Prefs.ExportResolution = (ExportResolution)i; Save(); });
        Combo("Export frame rate", new[] { "30 fps", "60 fps" }, Prefs.ExportFrameRate >= 60 ? 1 : 0, i => { Prefs.ExportFrameRate = i == 1 ? 60 : 30; Save(); });
        Combo("Export codec", new[] { "H.264", "HEVC" }, (int)Prefs.ExportCodec, i => { Prefs.ExportCodec = (ExportCodec)i; Save(); });
        Combo("Export quality", new[] { "Standard", "High", "Maximum" }, (int)Prefs.ExportQuality, i => { Prefs.ExportQuality = (ExportQuality)i; Save(); });
    }

    private void Storage()
    {
        Title("Storage", null);
        var location = App.Services.Store.Location;
        Note($"Library: {location.Root}");
        long Size(string dir) => Directory.Exists(dir) ? Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length) : 0;
        var count = App.Services.Store.List().Count;
        Note($"{count} project{(count == 1 ? "" : "s")} · {Format.Bytes(Size(location.ProjectsDirectory))}");
        Button("Open library folder", () => System.Diagnostics.Process.Start("explorer.exe", $"\"{location.Root}\""));
        Button("Choose another library folder…", async () =>
        {
            var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.VideosLibrary };
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHelpers.Handle(this));
            if (await picker.PickSingleFolderAsync() is { } folder)
            {
                Prefs.LibraryPath = folder.Path;
                Save();
                App.Services.ReloadLibrary();
                App.MainWindow.ShowDashboard($"The library is now {folder.Path}. Existing projects stay where they are.");
                Build("storage");
            }
        });
        if (Prefs.LibraryPath != null)
            Button("Use the default folder", () => { Prefs.LibraryPath = null; Save(); App.Services.ReloadLibrary(); App.MainWindow.ShowDashboard(); Build("storage"); });
    }

    private void Privacy()
    {
        Title("Privacy & Data", "Framelo works offline. Recordings never leave this PC unless you share an export.");
        Toggle("Hide Framelo's own windows from recordings", Prefs.ExcludeFrameloFromCapture, v => { Prefs.ExcludeFrameloFromCapture = v; Save(); });
        Button("Reset all settings", async () =>
        {
            if (!await Confirm("Reset all settings?", "Your profile, appearance and default options go back to their original values. Projects are not affected.", "Reset")) return;
            var library = Prefs.LibraryPath;
            var fresh = new Preferences { LibraryPath = library };
            foreach (var p in typeof(Preferences).GetProperties().Where(p => p.CanWrite)) p.SetValue(Prefs, p.GetValue(fresh));
            Save();
            Appearance.ApplyAll();
            Build("privacy");
        });
        Button("Move all projects to the Recycle Bin…", async () =>
        {
            var projects = App.Services.Store.List();
            if (projects.Count == 0) return;
            if (!await Confirm($"Move {projects.Count} project{(projects.Count == 1 ? "" : "s")} to the Recycle Bin?",
                    "You can restore them from the Recycle Bin until you empty it.", "Move to Recycle Bin")) return;
            foreach (var p in projects) RecycleBin.Send(p.PackagePath);
            App.MainWindow.ShowDashboard();
        });
    }

    private void About()
    {
        Title("Framelo", "Record. Polish. Share.");
        Note($"Version {typeof(App).Assembly.GetName().Version?.ToString(3)} for Windows");
        Note($"Log file: {Log.PathName}");
    }

    // Building blocks

    private void Title(string text, string? subtitle)
    {
        _page.Children.Add(new TextBlock { Text = text, FontSize = 24, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        if (subtitle != null) Note(subtitle);
    }

    private void Note(string text) => _page.Children.Add(new TextBlock
    {
        Text = text, TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["TextSecondaryBrush"], IsTextSelectionEnabled = true,
    });

    private void Text(string header, string value, Action<string> changed)
    {
        var box = new TextBox { Header = header, Text = value, MaxWidth = 360, HorizontalAlignment = HorizontalAlignment.Left, Width = 360 };
        box.LostFocus += (_, _) => changed(box.Text.Trim());
        _page.Children.Add(box);
    }

    private void Toggle(string header, bool value, Action<bool> changed)
    {
        var t = new ToggleSwitch { Header = header, IsOn = value };
        t.Toggled += (_, _) => changed(t.IsOn);
        _page.Children.Add(t);
    }

    private void Combo(string header, string[] items, int selected, Action<int> changed)
    {
        var c = new ComboBox { Header = header, ItemsSource = items, SelectedIndex = Math.Clamp(selected, 0, items.Length - 1), Width = 280 };
        c.SelectionChanged += (_, _) => { if (c.SelectedIndex >= 0) changed(c.SelectedIndex); };
        _page.Children.Add(c);
    }

    private void Button(string text, Action action)
    {
        var b = new Button { Content = text };
        b.Click += (_, _) => action();
        _page.Children.Add(b);
    }

    private async Task<bool> Confirm(string title, string message, string action) =>
        await new ContentDialog
        {
            Title = title, Content = message, PrimaryButtonText = action, CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close, XamlRoot = Content.XamlRoot,
        }.ShowAsync() == ContentDialogResult.Primary;
}

/// <summary>Moves files and folders to the Recycle Bin, so deletions can be undone.</summary>
public static class RecycleBin
{
    public static bool Send(string path)
    {
        try
        {
            if (Directory.Exists(path))
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            else if (File.Exists(path))
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            return true;
        }
        catch (Exception e)
        {
            Log.Error("Recycle", e);
            return false;
        }
    }
}
