using System.Runtime.InteropServices.WindowsRuntime;
using Framelo.App.Services;
using Framelo.Core;
using Framelo.Platform.Capture;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;

namespace Framelo.App.Views;

/// <summary>Full-screen picker over one display: a still of the screen, dimmed, with a drag-to-select rectangle.</summary>
public sealed partial class AreaPickerWindow : Window
{
    private readonly DisplayInfo _display;
    private readonly TaskCompletionSource<CaptureTarget.Region?> _result = new();
    private Point? _start;
    private Rect _selection;

    public AreaPickerWindow(DisplayInfo display)
    {
        InitializeComponent();
        _display = display;
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(display.X, display.Y, display.Width, display.Height));
        AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
        WindowCapture.Exclude(WindowHelpers.Handle(this));
        Closed += (_, _) => _result.TrySetResult(null);
    }

    public async Task<CaptureTarget.Region?> PickAsync()
    {
        try
        {
            var shot = await ScreenSnapshot.CaptureAsync(_display, TimeSpan.FromSeconds(2));
            var bitmap = new WriteableBitmap(shot.Width, shot.Height);
            using (var stream = bitmap.PixelBuffer.AsStream()) await stream.WriteAsync(shot.Bgra);
            bitmap.Invalidate();
            Backdrop.Source = bitmap;
        }
        catch (Exception e)
        {
            Log.Error("Snapshot", e); // the picker still works over a black backdrop
        }
        Activate();
        Root.Focus(FocusState.Programmatic);
        return await _result.Task;
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        _start = e.GetCurrentPoint(Surface).Position;
        Surface.CapturePointer(e.Pointer);
        Selection.Visibility = Visibility.Visible;
        Update(_start.Value);
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_start != null) Update(e.GetCurrentPoint(Surface).Position);
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        Surface.ReleasePointerCapture(e.Pointer);
        _start = null;
        if (_selection.Width >= 40 && _selection.Height >= 40) HintText.Text = "Press Enter to record this area, or drag again";
    }

    private void Update(Point p)
    {
        var s = _start!.Value;
        _selection = new Rect(Math.Min(s.X, p.X), Math.Min(s.Y, p.Y), Math.Abs(p.X - s.X), Math.Abs(p.Y - s.Y));
        Canvas.SetLeft(Selection, _selection.X);
        Canvas.SetTop(Selection, _selection.Y);
        Selection.Width = _selection.Width;
        Selection.Height = _selection.Height;
    }

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape) { _result.TrySetResult(null); Close(); }
        else if (e.Key == Windows.System.VirtualKey.Enter && _selection.Width >= 40 && _selection.Height >= 40)
        {
            // Convert DIPs to the display's physical pixels.
            var sx = _display.Width / Surface.ActualWidth;
            var sy = _display.Height / Surface.ActualHeight;
            _result.TrySetResult(new CaptureTarget.Region(_display.Index,
                Math.Round(_selection.X * sx), Math.Round(_selection.Y * sy), Math.Round(_selection.Width * sx), Math.Round(_selection.Height * sy)));
            Close();
        }
    }
}
