using Framelo.App.Services;
using Framelo.Core;
using Framelo.Platform.Capture;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Framelo.App.Views;

/// <summary>
/// Floating capture bar: choose display / window / area, microphone and system audio, then record.
/// While recording it shows the time, a microphone meter, pause, stop and discard.
/// </summary>
public sealed partial class CaptureBarWindow : Window
{
    private const int BarWidth = 1010, BarHeight = 64, RecordingWidth = 420;
    private readonly DispatcherQueueTimer _ticker;
    private RecordingSession? _session;
    private CaptureTarget.Region? _area;
    private string _mode = "display";

    /// <summary>Raised with the finished project, or null when the user closed the bar or discarded.</summary>
    public event Action<Project?, string?>? Finished;

    public CaptureBarWindow()
    {
        InitializeComponent();
        WindowHelpers.MakeFloating(this);
        Place(BarWidth);
        WindowCapture.Exclude(WindowHelpers.Handle(this));
        _ticker = DispatcherQueue.CreateTimer();
        _ticker.Interval = TimeSpan.FromMilliseconds(100);
        _ticker.Tick += (_, _) => Tick();

        var prefs = App.Services.Preferences;
        MicToggle.IsChecked = prefs.CaptureMicrophone;
        SystemAudioToggle.IsChecked = prefs.CaptureSystemAudio;
        var mics = AudioRecorder.Microphones();
        MicPicker.ItemsSource = mics.Select(m => m.Name).ToList();
        MicPicker.Tag = mics;
        var selected = mics.ToList().FindIndex(m => m.Id == prefs.MicrophoneId);
        MicPicker.SelectedIndex = selected >= 0 ? selected : mics.ToList().FindIndex(m => m.IsDefault);
        MicPicker.IsEnabled = mics.Count > 0;
        LoadSources();
    }

    private void Place(int widthDip)
    {
        var scale = WindowHelpers.Scale(this);
        var w = (int)(widthDip * scale);
        var h = (int)(BarHeight * scale);
        var area = Microsoft.UI.Windowing.DisplayArea.Primary.WorkArea;
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - w) / 2, area.Y + area.Height - h - (int)(32 * scale), w, h));
    }

    private void OnMode(object sender, RoutedEventArgs e)
    {
        _mode = (string)((FrameworkElement)sender).Tag;
        DisplayMode.IsChecked = _mode == "display";
        WindowMode.IsChecked = _mode == "window";
        AreaMode.IsChecked = _mode == "area";
        _area = null;
        LoadSources();
        if (_mode == "area") _ = PickAreaAsync();
    }

    private void LoadSources()
    {
        if (_mode == "window")
        {
            var windows = CaptureCatalog.Windows();
            SourcePicker.ItemsSource = windows.Select(w => string.IsNullOrEmpty(w.ProcessName) ? w.Title : $"{w.Title} — {w.ProcessName}").ToList();
            SourcePicker.Tag = windows;
        }
        else
        {
            var displays = CaptureCatalog.Displays();
            SourcePicker.ItemsSource = displays.Select(d => d.Label).ToList();
            SourcePicker.Tag = displays;
        }
        SourcePicker.SelectedIndex = SourcePicker.Items.Count > 0 ? 0 : -1;
        RecordButton.IsEnabled = SourcePicker.Items.Count > 0;
    }

    private async Task PickAreaAsync()
    {
        if (SourcePicker.Tag is not IReadOnlyList<DisplayInfo> displays || SourcePicker.SelectedIndex < 0) return;
        var display = displays[SourcePicker.SelectedIndex];
        AppWindow.Hide();
        try
        {
            var picker = new AreaPickerWindow(display);
            _area = await picker.PickAsync();
        }
        catch (Exception e)
        {
            Log.Error("Area picker", e);
        }
        finally
        {
            AppWindow.Show();
        }
        if (_area == null) { _mode = "display"; DisplayMode.IsChecked = true; AreaMode.IsChecked = false; }
    }

    private CaptureTarget? Target()
    {
        if (_mode == "area") return _area;
        var index = SourcePicker.SelectedIndex;
        if (index < 0) return null;
        return SourcePicker.Tag switch
        {
            IReadOnlyList<WindowInfo> windows => new CaptureTarget.Window(windows[index].Id),
            IReadOnlyList<DisplayInfo> displays => new CaptureTarget.Display(displays[index].Index),
            _ => null,
        };
    }

    private async void OnRecord(object sender, RoutedEventArgs e)
    {
        var target = Target();
        if (target == null) { if (_mode == "area") await PickAreaAsync(); return; }
        var prefs = App.Services.Preferences;
        var mics = MicPicker.Tag as IReadOnlyList<AudioDevice>;
        prefs.CaptureMicrophone = MicToggle.IsChecked == true;
        prefs.CaptureSystemAudio = SystemAudioToggle.IsChecked == true;
        prefs.MicrophoneId = mics != null && MicPicker.SelectedIndex >= 0 ? mics[MicPicker.SelectedIndex].Id : null;
        App.Services.SavePreferences();
        var config = new RecordingConfig
        {
            Target = target, FrameRate = prefs.FrameRate, CaptureMicrophone = prefs.CaptureMicrophone,
            MicrophoneId = prefs.MicrophoneId, CaptureSystemAudio = prefs.CaptureSystemAudio, CountdownSeconds = prefs.CountdownSeconds,
        };

        SetupPanel.Visibility = Visibility.Collapsed;
        Place(RecordingWidth);
        for (var n = config.CountdownSeconds; n > 0; n--)
        {
            CountdownText.Text = n.ToString();
            CountdownText.Visibility = Visibility.Visible;
            await Task.Delay(1000);
        }
        CountdownText.Visibility = Visibility.Collapsed;

        var name = $"Recording {DateTime.Now:yyyy-MM-dd HH.mm}";
        var bitRate = config.FrameRate * 1920 * 1080 / 6; // ~20 Mbit/s at 1080p60: high quality intermediate
        try
        {
            _session = await Task.Run(() => RecordingSession.Start(App.Services.Store, config, name, Math.Max(bitRate, 8_000_000)));
        }
        catch (Exception ex)
        {
            Log.Error("Start recording", ex);
            ShowSetup();
            await new ContentDialog
            {
                Title = "Recording could not start", Content = ex.Message, CloseButtonText = "OK", XamlRoot = Root.XamlRoot,
            }.ShowAsync();
            return;
        }
        _session.Failed += reason => DispatcherQueue.TryEnqueue(() => { StatusText.Text = reason; });
        RecordingPanel.Visibility = Visibility.Visible;
        _ticker.Start();
    }

    private void Tick()
    {
        if (_session == null) return;
        ElapsedText.Text = Format.Duration(_session.Elapsed);
        MicLevel.Value = _session.MicrophoneLevel;
        RecDot.Opacity = _session.State == RecordingState.Paused ? 0.3 : (DateTime.Now.Millisecond < 500 ? 1 : 0.4);
    }

    private void OnPause(object sender, RoutedEventArgs e)
    {
        if (_session == null) return;
        if (_session.State == RecordingState.Paused) { _session.Resume(); PauseIcon.Glyph = ""; }
        else { _session.Pause(); PauseIcon.Glyph = ""; }
    }

    private async void OnStop(object sender, RoutedEventArgs e)
    {
        if (_session == null) return;
        var session = _session;
        _session = null;
        _ticker.Stop();
        RecordingPanel.Visibility = Visibility.Collapsed;
        StatusText.Text = "Saving…";
        StatusText.Visibility = Visibility.Visible;
        try
        {
            var project = await Task.Run(session.Stop);
            Finish(project, null);
        }
        catch (Exception ex)
        {
            Log.Error("Stop recording", ex);
            Finish(null, $"The recording could not be saved: {ex.Message}");
        }
    }

    private async void OnDiscard(object sender, RoutedEventArgs e)
    {
        if (_session == null) return;
        var session = _session;
        _session = null;
        _ticker.Stop();
        await Task.Run(session.Discard);
        Finish(null, null);
    }

    private void OnClose(object sender, RoutedEventArgs e) => Finish(null, null);

    private void ShowSetup()
    {
        CountdownText.Visibility = Visibility.Collapsed;
        RecordingPanel.Visibility = Visibility.Collapsed;
        SetupPanel.Visibility = Visibility.Visible;
        Place(BarWidth);
    }

    private void Finish(Project? project, string? error)
    {
        Finished?.Invoke(project, error);
        Close();
    }
}
