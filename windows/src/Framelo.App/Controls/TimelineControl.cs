using Framelo.App.Services;
using Framelo.Core;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Color = Windows.UI.Color;

namespace Framelo.App.Controls;

/// <summary>
/// The editor timeline: ruler, amber clip bar, purple zoom lane and audio lanes, with a playhead.
/// Click to seek; drag clip edges to trim; drag in the zoom lane to add a zoom; drag a zoom to move or resize it.
/// All edits go through EditorSession commands, so they are validated and undoable.
/// </summary>
public sealed class TimelineControl : UserControl
{
    private const double RulerHeight = 26, ClipTop = 32, ClipHeight = 54, ZoomTop = 94, ZoomHeight = 30, TextTop = 130, TextHeight = 22, CaptionTop = 156, CaptionHeight = 18, AudioTop = 180, AudioHeight = 14, Edge = 7, Inset = 12;
    private static readonly Color Amber = ColorHelper.FromArgb(255, 0xF5, 0xA5, 0x24);
    private static readonly Color Purple = ColorHelper.FromArgb(255, 0x7C, 0x5C, 0xFF);

    private readonly Canvas _canvas = new() { Background = new SolidColorBrush(ColorHelper.FromArgb(255, 0x13, 0x13, 0x17)) };
    private readonly Rectangle _playhead = new() { Width = 2, Fill = new SolidColorBrush(Colors.White), IsHitTestVisible = false };
    private readonly Polygon _playheadKnob = new() { Fill = new SolidColorBrush(Colors.White), IsHitTestVisible = false };
    private EditorModel? _model;
    private double _zoom = 1;   // 1 = fit the whole timeline
    private double _offset;     // first visible second when zoomed in
    private Drag? _drag;

    private sealed record Drag(string Kind, Guid Id, double StartX, MediaTime A, MediaTime B, double Speed);

    public TimelineControl()
    {
        Content = _canvas;
        IsTabStop = true;
        _canvas.SizeChanged += (_, _) => Rebuild();
        _canvas.PointerPressed += OnPressed;
        _canvas.PointerMoved += OnMoved;
        _canvas.PointerReleased += OnReleased;
        _canvas.PointerWheelChanged += OnWheel;
    }

    public EditorModel? Model
    {
        get => _model;
        set
        {
            _model = value;
            if (value == null) return;
            value.Session.Changed += () => DispatcherQueue.TryEnqueue(Rebuild);
            value.PlayheadChanged += () => DispatcherQueue.TryEnqueue(UpdatePlayhead);
            value.SelectionChanged += () => DispatcherQueue.TryEnqueue(Rebuild);
            Rebuild();
        }
    }

    private double Span => Math.Max(_model?.Duration ?? 1, 1) / _zoom;
    private double PixelsPerSecond => Math.Max(1, (_canvas.ActualWidth - 2 * Inset)) / Span;
    private double X(double seconds) => Inset + (seconds - _offset) * PixelsPerSecond;
    private double Seconds(double x) => Math.Clamp((x - Inset) / PixelsPerSecond + _offset, 0, _model?.Duration ?? 0);

    public void Rebuild()
    {
        _canvas.Children.Clear();
        if (_model == null || _canvas.ActualWidth <= 0) return;
        var project = _model.Project;
        DrawRuler();

        foreach (var clip in project.Timeline.VideoClips)
        {
            var selected = _model.SelectedId == clip.Id;
            var left = X(clip.TimelinePosition.Seconds);
            var width = Math.Max(4, clip.TimelineDuration.Seconds * PixelsPerSecond - 2);
            var body = new Border
            {
                Width = width, Height = ClipHeight, CornerRadius = new CornerRadius(8),
                Background = new SolidColorBrush(selected ? Amber : ColorHelper.FromArgb(255, 0xC9, 0x86, 0x1A)),
                BorderBrush = new SolidColorBrush(selected ? Colors.White : Amber), BorderThickness = new Thickness(selected ? 2 : 1),
                Child = new TextBlock
                {
                    Text = clip.PlaybackSpeed == 1 ? "Clip" : $"Clip · {clip.PlaybackSpeed:0.##}×",
                    Foreground = new SolidColorBrush(ColorHelper.FromArgb(255, 0x2A, 0x1A, 0x00)), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    FontSize = 12, Margin = new Thickness(10, 6, 0, 0), IsHitTestVisible = false,
                },
            };
            Place(body, left, ClipTop);
            // Trim handles
            foreach (var x in new[] { left, left + width - 6 })
                Place(new Rectangle { Width = 6, Height = ClipHeight - 16, RadiusX = 2, RadiusY = 2, Fill = new SolidColorBrush(ColorHelper.FromArgb(160, 0x2A, 0x1A, 0x00)), IsHitTestVisible = false }, x, ClipTop + 8);
        }

        Place(new TextBlock { Text = "Zoom", FontSize = 10, Opacity = 0.5, IsHitTestVisible = false }, 2, ZoomTop - 2);
        foreach (var zoom in project.Timeline.ZoomEvents)
        {
            var selected = _model.SelectedId == zoom.Id;
            var left = X(zoom.StartTime.Seconds);
            var width = Math.Max(6, zoom.Duration.Seconds * PixelsPerSecond);
            var fill = zoom.IsAutomatic ? ColorHelper.FromArgb(150, Purple.R, Purple.G, Purple.B) : Purple;
            Place(new Border
            {
                Width = width, Height = ZoomHeight, CornerRadius = new CornerRadius(6), Background = new SolidColorBrush(fill),
                BorderBrush = new SolidColorBrush(selected ? Colors.White : Colors.Transparent), BorderThickness = new Thickness(2),
                Child = new TextBlock
                {
                    Text = $"{zoom.Scale:0.#}×{(zoom.IsAutomatic ? " · auto" : "")}", FontSize = 11, Foreground = new SolidColorBrush(Colors.White),
                    Margin = new Thickness(8, 5, 0, 0), IsHitTestVisible = false,
                },
            }, left, ZoomTop);
        }

        Place(new TextBlock { Text = "Text", FontSize = 10, Opacity = 0.5, IsHitTestVisible = false }, 2, TextTop + 3);
        foreach (var text in project.Timeline.TextOverlays)
            Interval(text.StartTime, text.EndTime, TextTop, TextHeight, ColorHelper.FromArgb(255, 0x00, 0xA8, 0x9A), text.Text, _model.SelectedId == text.Id);
        if (project.Timeline.Captions.Count > 0)
            Place(new TextBlock { Text = "Captions", FontSize = 10, Opacity = 0.5, IsHitTestVisible = false }, 2, CaptionTop + 2);
        foreach (var caption in project.Timeline.Captions)
            Interval(caption.StartTime, caption.EndTime, CaptionTop, CaptionHeight, ColorHelper.FromArgb(255, 0x4A, 0x4A, 0x55), caption.Text, _model.SelectedId == caption.Id);

        var lane = AudioTop;
        foreach (var track in project.Timeline.Tracks.Where(t => t.Type is TrackKind.Microphone or TrackKind.SystemAudio))
        {
            foreach (var clip in project.Timeline.VideoClips)
                Place(new Rectangle
                {
                    Width = Math.Max(2, clip.TimelineDuration.Seconds * PixelsPerSecond - 2), Height = AudioHeight, RadiusX = 3, RadiusY = 3,
                    Fill = new SolidColorBrush(track.IsMuted || clip.IsMuted ? ColorHelper.FromArgb(255, 0x33, 0x33, 0x3A) : ColorHelper.FromArgb(255, 0x1F, 0x8F, 0x86)),
                    IsHitTestVisible = false,
                }, X(clip.TimelinePosition.Seconds), lane);
            Place(new TextBlock { Text = track.Name, FontSize = 9, Opacity = 0.7, IsHitTestVisible = false }, X(0) + 4, lane);
            lane += AudioHeight + 4;
        }

        _canvas.Children.Add(_playhead);
        _canvas.Children.Add(_playheadKnob);
        UpdatePlayhead();
    }

    private void Interval(MediaTime start, MediaTime end, double top, double height, Color fill, string label, bool selected)
    {
        Place(new Border
        {
            Width = Math.Max(4, (end - start).Seconds * PixelsPerSecond - 1), Height = height, CornerRadius = new CornerRadius(5),
            Background = new SolidColorBrush(fill), BorderBrush = new SolidColorBrush(selected ? Colors.White : Colors.Transparent),
            BorderThickness = new Thickness(selected ? 2 : 0),
            Child = new TextBlock
            {
                Text = label, FontSize = 10, Foreground = new SolidColorBrush(Colors.White), Margin = new Thickness(6, height > 20 ? 4 : 2, 4, 0),
                TextTrimming = TextTrimming.CharacterEllipsis, IsHitTestVisible = false,
            },
        }, X(start.Seconds), top);
    }

    private void DrawRuler()
    {
        var span = Span;
        var step = new[] { 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300 }.First(s => s * PixelsPerSecond >= 70);
        for (var t = Math.Floor(_offset / step) * step; t <= Math.Min(_model?.Duration ?? 0, _offset + span) + 1e-6; t += step)
        {
            var x = X(t);
            Place(new Rectangle { Width = 1, Height = 6, Fill = new SolidColorBrush(ColorHelper.FromArgb(120, 255, 255, 255)), IsHitTestVisible = false }, x, RulerHeight - 6);
            Place(new TextBlock { Text = Views.Format.Duration(t), FontSize = 10, Opacity = 0.6, IsHitTestVisible = false }, x + 3, 4);
        }
    }

    private void UpdatePlayhead()
    {
        if (_model == null) return;
        if (_zoom > 1 && _drag == null && (_model.Playhead < _offset || _model.Playhead > _offset + Span))
        {
            _offset = Math.Clamp(_model.Playhead - Span * 0.1, 0, Math.Max(0, _model.Duration - Span));
            Rebuild();
            return;
        }
        var x = X(_model.Playhead);
        _playhead.Height = Math.Max(0, _canvas.ActualHeight);
        Canvas.SetLeft(_playhead, x - 1);
        _playheadKnob.Points = new PointCollection { new(x - 6, 0), new(x + 6, 0), new(x, 8) };
    }

    private void Place(UIElement e, double x, double y)
    {
        Canvas.SetLeft(e, x);
        Canvas.SetTop(e, y);
        _canvas.Children.Add(e);
    }

    // Interaction

    private (string Kind, Guid Id)? HitTest(Point p)
    {
        if (_model == null) return null;
        var t = Seconds(p.X);
        if (p.Y >= ClipTop && p.Y <= ClipTop + ClipHeight)
        {
            foreach (var c in _model.Project.Timeline.VideoClips)
            {
                var l = X(c.TimelinePosition.Seconds);
                var r = X(c.TimelineEnd.Seconds);
                if (Math.Abs(p.X - l) <= Edge) return ("clip-start", c.Id);
                if (Math.Abs(p.X - r) <= Edge) return ("clip-end", c.Id);
                if (p.X > l && p.X < r) return ("clip", c.Id);
            }
        }
        if (p.Y >= ZoomTop && p.Y <= ZoomTop + ZoomHeight)
        {
            foreach (var z in _model.Project.Timeline.ZoomEvents)
            {
                var l = X(z.StartTime.Seconds);
                var r = X(z.EndTime.Seconds);
                if (Math.Abs(p.X - l) <= Edge) return ("zoom-start", z.Id);
                if (Math.Abs(p.X - r) <= Edge) return ("zoom-end", z.Id);
                if (p.X > l && p.X < r) return ("zoom", z.Id);
            }
            return ("zoom-new", Guid.Empty);
        }
        (string, Guid)? Lane(string kind, IEnumerable<(Guid Id, MediaTime Start, MediaTime End)> items)
        {
            foreach (var (id, start, end) in items)
            {
                var l = X(start.Seconds);
                var r = X(end.Seconds);
                if (Math.Abs(p.X - l) <= Edge) return (kind + "-start", id);
                if (Math.Abs(p.X - r) <= Edge) return (kind + "-end", id);
                if (p.X > l && p.X < r) return (kind, id);
            }
            return null;
        }
        if (p.Y >= TextTop && p.Y <= TextTop + TextHeight)
            return Lane("text", _model.Project.Timeline.TextOverlays.Select(o => (o.Id, o.StartTime, o.EndTime)));
        if (p.Y >= CaptionTop && p.Y <= CaptionTop + CaptionHeight)
            return Lane("caption", _model.Project.Timeline.Captions.Select(c => (c.Id, c.StartTime, c.EndTime)));
        _ = t;
        return null;
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_model == null) return;
        Focus(FocusState.Pointer);
        var p = e.GetCurrentPoint(_canvas).Position;
        var hit = HitTest(p);
        _canvas.CapturePointer(e.Pointer);
        var project = _model.Project;
        switch (hit?.Kind)
        {
            case "clip" or "clip-start" or "clip-end":
            {
                var clip = project.Timeline.VideoClips.First(c => c.Id == hit.Value.Id);
                _model.Select(EditorSelectionKind.Clip, clip.Id);
                if (hit.Value.Kind != "clip") _drag = new Drag(hit.Value.Kind, clip.Id, p.X, clip.SourceStart, clip.SourceEnd, clip.PlaybackSpeed);
                else _model.Seek(Seconds(p.X));
                break;
            }
            case "zoom" or "zoom-start" or "zoom-end":
            {
                var zoom = project.Timeline.ZoomEvents.First(z => z.Id == hit.Value.Id);
                _model.Select(EditorSelectionKind.Zoom, zoom.Id);
                _drag = new Drag(hit.Value.Kind, zoom.Id, p.X, zoom.StartTime, zoom.EndTime, 1);
                break;
            }
            case "text" or "text-start" or "text-end":
            {
                var text = project.Timeline.TextOverlays.First(o => o.Id == hit.Value.Id);
                _model.Select(EditorSelectionKind.Text, text.Id);
                _drag = new Drag(hit.Value.Kind, text.Id, p.X, text.StartTime, text.EndTime, 1);
                break;
            }
            case "caption" or "caption-start" or "caption-end":
            {
                var caption = project.Timeline.Captions.First(c => c.Id == hit.Value.Id);
                _model.Select(EditorSelectionKind.Caption, caption.Id);
                _drag = new Drag(hit.Value.Kind, caption.Id, p.X, caption.StartTime, caption.EndTime, 1);
                _model.Seek(caption.StartTime.Seconds);
                break;
            }
            case "zoom-new":
            {
                var start = MediaTime.FromSeconds(Seconds(p.X));
                var settings = project.Settings.Motion;
                var zoom = new ZoomEvent
                {
                    StartTime = start, EndTime = start + MediaTime.FromSeconds(0.2), Scale = settings.DefaultZoomScale,
                    Easing = settings.Easing, TransitionIn = settings.ZoomInDuration, TransitionOut = settings.ZoomOutDuration,
                    FollowsCursor = true,
                };
                _drag = new Drag("zoom-create", zoom.Id, p.X, start, zoom.EndTime, 1);
                _model.Session.TryPerform(EditCommand.UpsertZoom(zoom, "Add Zoom"), out _);
                _model.Select(EditorSelectionKind.Zoom, zoom.Id);
                break;
            }
            default:
                _model.Select(EditorSelectionKind.None, null);
                _drag = new Drag("seek", Guid.Empty, p.X, MediaTime.Zero, MediaTime.Zero, 1);
                _model.Seek(Seconds(p.X));
                break;
        }
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(_canvas).Position;
        if (_drag == null || _model == null)
        {
            var hit = HitTest(p);
            ProtectedCursor = InputSystemCursor.Create(hit?.Kind is { } k && (k.EndsWith("-start") || k.EndsWith("-end"))
                ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.Arrow);
            return;
        }
        var delta = MediaTime.FromSeconds((p.X - _drag.StartX) / PixelsPerSecond);
        var session = _model.Session;
        switch (_drag.Kind)
        {
            case "seek":
                _model.Seek(Seconds(p.X));
                break;
            case "clip-start":
                session.TryPerform(EditCommand.Trim(_drag.Id, start: MediaTime.Max(MediaTime.Zero, _drag.A + delta.MultipliedBy(_drag.Speed))), out _);
                break;
            case "clip-end":
                session.TryPerform(EditCommand.Trim(_drag.Id, end: _drag.B + delta.MultipliedBy(_drag.Speed)), out _);
                break;
            case "zoom" or "zoom-start" or "zoom-end" or "zoom-create":
                if (_model.Project.Timeline.ZoomEvents.FirstOrDefault(z => z.Id == _drag.Id) is not ZoomEvent current) break;
                var zoom = current.Copy();
                var min = MediaTime.FromSeconds(0.4);
                if (_drag.Kind == "zoom")
                {
                    var length = _drag.B - _drag.A;
                    zoom.StartTime = MediaTime.Max(MediaTime.Zero, _drag.A + delta);
                    zoom.EndTime = zoom.StartTime + length;
                }
                else if (_drag.Kind == "zoom-start") zoom.StartTime = MediaTime.Min(MediaTime.Max(MediaTime.Zero, _drag.A + delta), zoom.EndTime - min);
                else zoom.EndTime = MediaTime.Max(_drag.B + delta, zoom.StartTime + (_drag.Kind == "zoom-create" ? MediaTime.FromSeconds(0.2) : min));
                zoom.IsAutomatic = false;   // any edit makes a suggestion manual
                session.TryPerform(EditCommand.UpsertZoom(zoom), out _);
                break;
            case "text" or "text-start" or "text-end":
            {
                if (_model.Project.Timeline.TextOverlays.FirstOrDefault(o => o.Id == _drag.Id) is not TextOverlay o) break;
                var copy = TextEdits.Copy(o);
                (copy.StartTime, copy.EndTime) = Moved(_drag, delta, copy.StartTime, copy.EndTime);
                session.TryPerform(TextEdits.UpdateText(copy, "Move Text"), out _);
                break;
            }
            case "caption" or "caption-start" or "caption-end":
            {
                if (_model.Project.Timeline.Captions.FirstOrDefault(c => c.Id == _drag.Id) is not Caption c) break;
                var copy = TextEdits.Copy(c);
                (copy.StartTime, copy.EndTime) = Moved(_drag, delta, copy.StartTime, copy.EndTime);
                session.TryPerform(TextEdits.UpdateCaption(copy, "Move Caption"), out _);
                break;
            }
        }
    }

    /// <summary>New start and end for a move ("x"), a start drag ("x-start") or an end drag ("x-end").</summary>
    private static (MediaTime Start, MediaTime End) Moved(Drag drag, MediaTime delta, MediaTime start, MediaTime end)
    {
        var min = MediaTime.FromSeconds(0.2);
        if (drag.Kind.EndsWith("-start")) return (MediaTime.Min(MediaTime.Max(MediaTime.Zero, drag.A + delta), end - min), end);
        if (drag.Kind.EndsWith("-end")) return (start, MediaTime.Max(drag.B + delta, start + min));
        var s = MediaTime.Max(MediaTime.Zero, drag.A + delta);
        return (s, s + (drag.B - drag.A));
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        _canvas.ReleasePointerCapture(e.Pointer);
        if (_drag?.Kind == "zoom-create" && _model?.Project.Timeline.ZoomEvents.FirstOrDefault(z => z.Id == _drag.Id) is ZoomEvent z
            && z.Duration.Seconds < 1)
        {
            // A click without a drag adds a zoom of a useful default length.
            var copy = z.Copy();
            copy.EndTime = MediaTime.Min(copy.StartTime + MediaTime.FromSeconds(3), MediaTime.Max(_model.Project.Duration, copy.StartTime + MediaTime.FromSeconds(1)));
            _model.Session.TryPerform(EditCommand.UpsertZoom(copy), out _);
        }
        _model?.Session.BreakCoalescing();
        _drag = null;
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var mods = e.KeyModifiers;
        if ((mods & Windows.System.VirtualKeyModifiers.Control) == 0) return;
        var d = e.GetCurrentPoint(_canvas).Properties.MouseWheelDelta;
        _zoom = Math.Clamp(_zoom * (d > 0 ? 1.25 : 0.8), 1, 50);
        _offset = _zoom <= 1 ? 0 : Math.Clamp((_model?.Playhead ?? 0) - Span / 2, 0, Math.Max(0, (_model?.Duration ?? 0) - Span));
        Rebuild();
        e.Handled = true;
    }
}
