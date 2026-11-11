using System.Runtime.InteropServices.WindowsRuntime;
using Framelo.App.Services;
using Framelo.Core;
using Framelo.Platform.Media;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using VirtualKey = Windows.System.VirtualKey;

namespace Framelo.App.Views;

/// <summary>The editor: preview, settings panel with an icon rail, transport and timeline.</summary>
public sealed partial class EditorPage : Page
{
    /// <summary>Set by later stages to supply the styled renderer and the export flow.</summary>
    public static Func<EditorModel, IPreviewRenderer>? RendererFactory { get; set; }
    public static Func<EditorPage, EditorModel, Task>? ExportHandler { get; set; }

    private EditorModel? _model;
    private DispatcherQueueTimer? _timer;
    private WriteableBitmap? _bitmap;
    private bool _rendering;
    private (double Time, int Revision, int W, int H) _lastRendered = (-1, -1, 0, 0);
    private string _section = "style";
    private readonly Inspector _inspector;

    public EditorPage()
    {
        InitializeComponent();
        _inspector = new Inspector(this);
    }

    public EditorModel? Model => _model;
    public XamlRoot Root => XamlRoot;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is not Guid id) return;
        Project project;
        try { project = App.Services.Store.Load(id); }
        catch (Exception ex) { App.MainWindow.ShowDashboard(ex.Message); return; }

        var session = new EditorSession(App.Services.Store, project);
        // First open of a recording: suggest zooms from the recorded clicks (not an undoable user edit).
        if (project.Timeline.ZoomEvents.Count == 0 && project.Timeline.SuppressedAutoZoomRanges.Count == 0 &&
            project.Settings.Motion.AutoZoomEnabled && session.CursorTracks.Count > 0)
        {
            session.TryPerform(new EditCommand("Suggest Zooms", p =>
                MotionEngine.RegenerateAutomaticZooms(p.Timeline, new TimelineCursor(new TimeMap(p), session.CursorTracks), p.Settings.Motion)), out _);
        }
        session.SaveFailed += ex => DispatcherQueue.TryEnqueue(() => StatusText.Text = $"Could not save: {ex.Message}");
        _model = new EditorModel(session, null!);
        _model.Renderer = RendererFactory?.Invoke(_model) ?? new RawFrameRenderer(_model.Video);
        session.Changed += () => DispatcherQueue.TryEnqueue(OnProjectChanged);
        _model.SelectionChanged += () => DispatcherQueue.TryEnqueue(() => { if (_model.SelectionKind != EditorSelectionKind.None) ShowSection(_model.SelectionKind == EditorSelectionKind.Zoom ? "zoom" : "clip"); else RefreshInspector(); });
        NameBox.Text = project.Name;
        RecoveredBadge.Visibility = project.IsRecovered ? Visibility.Visible : Visibility.Collapsed;
        Timeline.Model = _model;
        BuildRail();
        ShowSection("style");
        OnProjectChanged();

        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(15);
        _timer.Tick += (_, _) => Frame();
        _timer.Start();
        Loaded += (_, _) => Focus(FocusState.Programmatic);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _timer?.Stop();
        var model = _model;
        _model = null;
        if (model != null)
            _ = Task.Run(() =>
            {
                model.Dispose();   // saves pending changes
                try { PosterWriter.Write(model.Project, model.Session.CursorTracks, model.Session.PackagePath); }
                catch (Exception ex) { Log.Error("Poster", ex); }
            });
    }

    private void OnProjectChanged()
    {
        if (_model == null) return;
        UndoButton.IsEnabled = _model.Session.CanUndo;
        RedoButton.IsEnabled = _model.Session.CanRedo;
        ToolTipService.SetToolTip(UndoButton, _model.Session.UndoName is string u ? $"Undo {u}" : "Undo");
        ToolTipService.SetToolTip(RedoButton, _model.Session.RedoName is string r ? $"Redo {r}" : "Redo");
        RefreshInspector();
    }

    public void RefreshInspector()
    {
        // Skip rebuilding for the inspector's own edits, so a slider being dragged is not replaced under the pointer.
        if (_model != null && _model.Session.Revision == _inspector.OwnRevision) return;
        _inspector.Build(_section);
    }

    // Preview

    private void Frame()
    {
        if (_model == null) return;
        _model.Tick();
        PlayIcon.Glyph = _model.IsPlaying ? "" : "";
        TimeText.Text = $"{Format.Duration(_model.Playhead)} / {Format.Duration(_model.Duration)}";
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var w = (int)Math.Max(64, (PreviewHost.ActualWidth - 48) * scale);
        var h = (int)Math.Max(36, (PreviewHost.ActualHeight - 48) * scale);
        var key = (Math.Round(_model.Playhead, 4), _model.Session.Revision, w, h);
        if (_rendering || key == _lastRendered) return;
        _rendering = true;
        _lastRendered = key;
        var model = _model;
        var time = _model.Playhead;
        Task.Run(() =>
        {
            try { return model.Renderer.Render(model.Session, time, w, h); }
            catch (Exception ex) { Log.Error("Preview", ex); return null; }
        }).ContinueWith(t => DispatcherQueue.TryEnqueue(() =>
        {
            _rendering = false;
            Show(t.Result);
        }));
    }

    private void Show(PreviewImage? image)
    {
        if (image == null)
        {
            PreviewMessage.Text = _model?.Duration > 0 ? "" : "This project is empty.";
            return;
        }
        PreviewMessage.Text = "";
        if (_bitmap == null || _bitmap.PixelWidth != image.Width || _bitmap.PixelHeight != image.Height)
        {
            _bitmap = new WriteableBitmap(image.Width, image.Height);
            Preview.Source = _bitmap;
        }
        using (var stream = _bitmap.PixelBuffer.AsStream()) stream.Write(image.Bgra, 0, Math.Min(image.Bgra.Length, (int)stream.Length));
        _bitmap.Invalidate();
    }

    private void OnPreviewSize(object sender, SizeChangedEventArgs e) => _lastRendered = (-1, -1, 0, 0);

    // Commands

    public bool Perform(EditCommand command)
    {
        if (_model == null) return false;
        if (_model.Session.TryPerform(command, out var error)) { StatusText.Text = ""; return true; }
        StatusText.Text = error ?? "";
        return false;
    }

    private void OnPlay(object sender, RoutedEventArgs e) => _model?.TogglePlay();
    private void OnUndo(object sender, RoutedEventArgs e) => _model?.Session.Undo();
    private void OnRedo(object sender, RoutedEventArgs e) => _model?.Session.Redo();

    private void OnSplit(object sender, RoutedEventArgs e)
    {
        if (_model != null) Perform(EditCommand.Split(MediaTime.FromSeconds(_model.Playhead)));
    }

    private void OnDelete(object sender, RoutedEventArgs e)
    {
        if (_model == null) return;
        if (_model.SelectedZoom is ZoomEvent z) Perform(EditCommand.RemoveZoom(z.Id));
        else if (_model.SelectedClip is VideoClip c)
        {
            if (_model.Project.Timeline.VideoClips.Count == 1) { StatusText.Text = "A project needs at least one clip."; return; }
            Perform(EditCommand.Delete(c.Id));
        }
    }

    private void OnAddZoom(object sender, RoutedEventArgs e)
    {
        if (_model == null) return;
        var m = _model.Project.Settings.Motion;
        var start = MediaTime.FromSeconds(_model.Playhead);
        var zoom = new ZoomEvent
        {
            StartTime = start, EndTime = MediaTime.Min(start + MediaTime.FromSeconds(3), _model.Project.Duration),
            Scale = m.DefaultZoomScale, Easing = m.Easing, TransitionIn = m.ZoomInDuration, TransitionOut = m.ZoomOutDuration,
        };
        if (zoom.EndTime > zoom.StartTime && Perform(EditCommand.UpsertZoom(zoom, "Add Zoom"))) _model.Select(EditorSelectionKind.Zoom, zoom.Id);
    }

    private async void OnExport(object sender, RoutedEventArgs e)
    {
        if (_model == null) return;
        _model.Pause();
        _model.Session.Save();
        if (ExportHandler != null) await ExportHandler(this, _model);
    }

    private void OnBack(object sender, RoutedEventArgs e) => App.MainWindow.ShowDashboard();

    private void OnRename(object sender, RoutedEventArgs e)
    {
        var name = NameBox.Text.Trim();
        if (_model == null || name.Length == 0 || name == _model.Project.Name) return;
        Perform(new EditCommand("Rename", p => p.Name = name));
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_model == null || e.OriginalSource is TextBox) return;
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        switch (e.Key)
        {
            case VirtualKey.Space: _model.TogglePlay(); break;
            case VirtualKey.S when !ctrl: OnSplit(this, e); break;
            case VirtualKey.Z when ctrl && shift: _model.Session.Redo(); break;
            case VirtualKey.Z when ctrl: _model.Session.Undo(); break;
            case VirtualKey.Y when ctrl: _model.Session.Redo(); break;
            case VirtualKey.Z: OnAddZoom(this, e); break;
            case VirtualKey.Delete or VirtualKey.Back: OnDelete(this, e); break;
            case VirtualKey.Left: _model.Seek(_model.Playhead - (shift ? 1 : 1.0 / 30)); break;
            case VirtualKey.Right: _model.Seek(_model.Playhead + (shift ? 1 : 1.0 / 30)); break;
            case VirtualKey.Home: _model.Seek(0); break;
            case VirtualKey.End: _model.Seek(_model.Duration); break;
            default: return;
        }
        e.Handled = true;
    }

    // Rail

    private static readonly (string Key, string Glyph, string Name)[] Sections =
    {
        ("style", "", "Background & frame"),
        ("cursor", "", "Cursor"),
        ("zoom", "", "Zoom & motion"),
        ("clip", "", "Clip"),
        ("audio", "", "Audio"),
    };

    private void BuildRail()
    {
        Rail.Children.Clear();
        foreach (var (key, glyph, name) in Sections)
        {
            var button = new ToggleButton
            {
                Tag = key, Width = 44, Height = 44, Padding = new Thickness(0), CornerRadius = new CornerRadius(10),
                Content = new FontIcon { Glyph = glyph, FontSize = 18 }, IsChecked = key == _section,
            };
            ToolTipService.SetToolTip(button, name);
            button.Click += (_, _) => ShowSection(key);
            Rail.Children.Add(button);
        }
    }

    public void ShowSection(string key)
    {
        _section = key;
        foreach (var b in Rail.Children.OfType<ToggleButton>()) b.IsChecked = (string)b.Tag == key;
        _inspector.Build(_section);
    }

    public StackPanel InspectorPanel => Inspector;
}
