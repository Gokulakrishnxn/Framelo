using Framelo.App.Services;
using Framelo.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Framelo.App.Views;

/// <summary>Builds the editor's settings panel for the section chosen on the icon rail.</summary>
internal sealed class Inspector(EditorPage page)
{
    /// <summary>Session revision produced by the inspector's latest edit.</summary>
    public int OwnRevision { get; private set; } = -1;

    /// <summary>Extra sections added by later stages (e.g. auto-zoom controls).</summary>
    public static event Action<string, Inspector, EditorModel>? Extend;

    private StackPanel Panel => page.InspectorPanel;
    private EditorModel Model => page.Model!;
    private ProjectSettings S => Model.Project.Settings;

    public void Build(string section)
    {
        Panel.Children.Clear();
        if (page.Model == null) return;
        switch (section)
        {
            case "style": Style(); break;
            case "cursor": Cursor(); break;
            case "zoom": Zoom(); break;
            case "clip": Clip(); break;
            case "audio": Audio(); break;
        }
        Extend?.Invoke(section, this, Model);
    }

    public void Edit(EditCommand command)
    {
        if (page.Perform(command)) OwnRevision = Model.Session.Revision;
    }

    private void Setting(string name, Action<ProjectSettings> change, string key) => Edit(EditCommand.Settings(name, change, key));

    // Sections

    private void Style()
    {
        Header("Background");
        var presets = new GridView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true, Margin = new Thickness(-4, 0, 0, 0) };
        foreach (var preset in StylePreset.All)
        {
            var bg = preset.Background();
            Brush brush = bg.Kind == BackgroundKind.Gradient
                ? new LinearGradientBrush(new GradientStopCollection
                    {
                        new GradientStop { Color = ToColor(bg.GradientStart), Offset = 0 },
                        new GradientStop { Color = ToColor(bg.GradientEnd), Offset = 1 },
                    }, bg.GradientAngle)
                : new SolidColorBrush(ToColor(bg.Color));
            var tile = new Border { Width = 56, Height = 40, CornerRadius = new CornerRadius(8), Background = brush, Tag = preset };
            ToolTipService.SetToolTip(tile, preset.Name);
            presets.Items.Add(tile);
        }
        presets.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is Border { Tag: StylePreset p })
                Edit(EditCommand.Settings($"Style: {p.Name}", s =>
                {
                    s.Background = p.Background();
                    var screen = p.Screen();
                    screen.Crop = s.Screen.Crop;
                    screen.Inset = s.Screen.Inset;
                    s.Screen = screen;
                }));
        };
        Panel.Children.Add(presets);

        Combo("Aspect ratio", Enum.GetValues<AspectKind>().Where(k => k != AspectKind.Custom).Select(AspectRatio.DisplayName).ToArray(),
            (int)S.Aspect.Kind, i => Setting("Aspect Ratio", s => s.Aspect.Kind = (AspectKind)i, "aspect"));
        Combo("Background", new[] { "None", "Solid", "Gradient" }, Math.Min((int)S.Background.Kind, 2),
            i => Setting("Background", s => s.Background.Kind = (BackgroundKind)i, "bg-kind"));
        if (S.Background.Kind == BackgroundKind.Gradient)
            SliderRow("Gradient angle", 0, 360, S.Background.GradientAngle, "0°", v => Setting("Gradient Angle", s => s.Background.GradientAngle = v, "angle"));

        Header("Screen");
        SliderRow("Padding", 0, 0.3, S.Screen.Padding, "P0", v => Setting("Padding", s => s.Screen.Padding = v, "padding"));
        SliderRow("Corner radius", 0, 0.08, S.Screen.CornerRadius, "P1", v => Setting("Corner Radius", s => s.Screen.CornerRadius = v, "corner"));
        SliderRow("Shadow", 0, 1, S.Screen.ShadowOpacity, "P0", v => Setting("Shadow", s => s.Screen.ShadowOpacity = v, "shadow"));
        SliderRow("Inset", 0, 0.05, S.Screen.InsetAmount, "P1", v => Setting("Inset", s => s.Screen.Inset = v, "inset"));
        Toggle("Window frame", S.Screen.Frame == ScreenFrame.Window, v => Setting("Window Frame", s => s.Screen.Frame = v ? ScreenFrame.Window : ScreenFrame.None, "frame"));
    }

    private void Cursor()
    {
        Header("Cursor");
        Toggle("Show cursor", S.Cursor.IsVisible, v => Setting("Cursor Visibility", s => s.Cursor.IsVisible = v, "cursor-visible"));
        SliderRow("Size", 0.5, 4, S.Cursor.Size, "0.0×", v => Setting("Cursor Size", s => s.Cursor.Size = v, "cursor-size"));
        SliderRow("Smoothing", 0, 1, S.Cursor.Smoothing, "P0", v => Setting("Cursor Smoothing", s => s.Cursor.Smoothing = v, "cursor-smooth"));
        Combo("Click effect", new[] { "None", "Ripple", "Ring" }, (int)S.Cursor.ClickEffect,
            i => Setting("Click Effect", s => s.Cursor.ClickEffect = (ClickEffect)i, "click"));
        Toggle("Hide when idle", S.Cursor.HidesWhenIdle, v => Setting("Hide Idle Cursor", s => s.Cursor.HidesWhenIdle = v, "idle"));
        if (Model.Session.CursorTracks.Count == 0) Note("This project has no recorded cursor (imported video).");
    }

    private void Zoom()
    {
        Header("Zoom");
        if (Model.SelectedZoom is ZoomEvent z)
        {
            Note(z.IsAutomatic ? "Automatic zoom — editing it makes it manual." : "Manual zoom");
            void Change(string name, Action<ZoomEvent> change, string key)
            {
                var copy = z.Copy();
                change(copy);
                copy.IsAutomatic = false;
                Edit(EditCommand.Timeline(name, t => TimelineEditor.UpsertZoom(t, copy), $"{key}-{z.Id}"));
            }
            SliderRow("Scale", 1, 4, z.Scale, "0.0×", v => Change("Zoom Scale", e => e.Scale = v, "zoom-scale"));
            Toggle("Follow cursor", z.FollowsCursor, v => Change("Follow Cursor", e => e.FollowsCursor = v, "zoom-follow"));
            SliderRow("Target X", 0, 1, z.TargetX, "P0", v => Change("Zoom Target", e => e.TargetX = v, "zoom-x"));
            SliderRow("Target Y", 0, 1, z.TargetY, "P0", v => Change("Zoom Target", e => e.TargetY = v, "zoom-y"));
            Combo("Easing", Enum.GetValues<Easing>().Select(e => e.DisplayName()).ToArray(), (int)z.Easing,
                i => Change("Zoom Easing", e => e.Easing = (Easing)i, "zoom-easing"));
            SliderRow("Zoom in", 0.15, 2, z.TransitionIn, "0.00 s", v => Change("Zoom In", e => e.TransitionIn = v, "zoom-in"));
            SliderRow("Zoom out", 0.15, 2, z.TransitionOut, "0.00 s", v => Change("Zoom Out", e => e.TransitionOut = v, "zoom-out"));
            Action("Delete zoom", () => Edit(EditCommand.RemoveZoom(z.Id)));
        }
        else
        {
            Note("Drag in the purple zoom lane, or press Z, to add a zoom at the playhead.");
        }
        Header("Automatic zoom");
        Toggle("Zoom in on clicks", S.Motion.AutoZoomEnabled, v => Edit(new EditCommand(v ? "Turn On Auto Zoom" : "Turn Off Auto Zoom", p =>
        {
            p.Settings.Motion.AutoZoomEnabled = v;
            MotionEngine.RegenerateAutomaticZooms(p.Timeline, Cursor(p), p.Settings.Motion);
        })));
        if (S.Motion.AutoZoomEnabled)
        {
            var count = Model.Project.Timeline.ZoomEvents.Count(z => z.IsAutomatic);
            Note(count == 1 ? "1 suggested zoom. Manual zooms always take priority." : $"{count} suggested zooms. Manual zooms always take priority.");
            Action("Regenerate suggestions", () => Edit(new EditCommand("Regenerate Zooms",
                p => MotionEngine.RegenerateAutomaticZooms(p.Timeline, Cursor(p), p.Settings.Motion))));
            if (Model.Project.Timeline.SuppressedAutoZoomRanges.Count > 0)
                Action("Bring back removed suggestions", () => Edit(new EditCommand("Allow Removed Zooms", p =>
                {
                    p.Timeline.SuppressedAutoZoomRanges.Clear();
                    MotionEngine.RegenerateAutomaticZooms(p.Timeline, Cursor(p), p.Settings.Motion);
                })));
        }
        Header("Defaults");
        SliderRow("Default scale", 1.2, 4, S.Motion.DefaultZoomScale, "0.0×", v => Setting("Default Zoom", s => s.Motion.DefaultZoomScale = v, "zoom-default"));
        SliderRow("Motion blur", 0, 1, S.Motion.MotionBlur, "P0", v => Setting("Motion Blur", s => s.Motion.MotionBlur = v, "blur"));
    }

    private void Clip()
    {
        Header("Clip");
        if (Model.SelectedClip is not VideoClip c) { Note("Select a clip on the timeline."); return; }
        Note($"{Format.Duration(c.TimelineDuration.Seconds)} on the timeline");
        SliderRow("Speed", 0.25, 4, c.PlaybackSpeed, "0.00×", v => Edit(EditCommand.SetSpeed(c.Id, Math.Round(v, 2))));
        SliderRow("Volume", 0, 2, c.Volume, "P0", v => Edit(EditCommand.Timeline("Clip Volume", t => t.VideoClips.First(x => x.Id == c.Id).Volume = v, $"volume-{c.Id}")));
        Toggle("Mute", c.IsMuted, v => Edit(EditCommand.Timeline("Mute Clip", t => t.VideoClips.First(x => x.Id == c.Id).IsMuted = v)));
        Action("Close gaps", () => Edit(EditCommand.CloseGaps()));
    }

    private void Audio()
    {
        foreach (var track in Model.Project.Timeline.Tracks.Where(t => t.Type is TrackKind.Microphone or TrackKind.SystemAudio or TrackKind.Audio))
        {
            Header(track.Name);
            var id = track.Id;
            SliderRow("Volume", 0, 2, track.Volume, "P0", v => Edit(EditCommand.Timeline("Track Volume", t => t.Tracks.First(x => x.Id == id).Volume = v, $"track-{id}")));
            Toggle("Mute", track.IsMuted, v => Edit(EditCommand.Timeline("Mute Track", t => t.Tracks.First(x => x.Id == id).IsMuted = v)));
        }
        Header("Fades");
        SliderRow("Fade in", 0, 5, S.Audio.FadeIn, "0.0 s", v => Setting("Fade In", s => s.Audio.FadeIn = v, "fade-in"));
        SliderRow("Fade out", 0, 5, S.Audio.FadeOut, "0.0 s", v => Setting("Fade Out", s => s.Audio.FadeOut = v, "fade-out"));
    }

    private TimelineCursor Cursor(Project p) => new(new TimeMap(p), Model.Session.CursorTracks);

    // Building blocks

    public void Header(string text) =>
        Panel.Children.Add(new TextBlock { Text = text.ToUpperInvariant(), Style = (Style)Application.Current.Resources["SectionHeader"], Margin = new Thickness(0, 6, 0, 0) });

    public void Note(string text) =>
        Panel.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = (Brush)Application.Current.Resources["TextSecondaryBrush"] });

    public void SliderRow(string label, double min, double max, double value, string format, Action<double> changed)
    {
        var valueText = new TextBlock { Text = Show(value, format), FontSize = 12, Foreground = (Brush)Application.Current.Resources["TextSecondaryBrush"], HorizontalAlignment = HorizontalAlignment.Right };
        var slider = new Slider { Minimum = min, Maximum = max, StepFrequency = (max - min) / 200, Value = Math.Clamp(value, min, max), IsThumbToolTipEnabled = false };
        slider.ValueChanged += (_, e) => { valueText.Text = Show(e.NewValue, format); changed(e.NewValue); };
        slider.PointerCaptureLost += (_, _) => Model.Session.BreakCoalescing();
        var header = new Grid();
        header.Children.Add(new TextBlock { Text = label, FontSize = 13 });
        header.Children.Add(valueText);
        Panel.Children.Add(new StackPanel { Spacing = 0, Children = { header, slider } });
    }

    public void Toggle(string label, bool value, Action<bool> changed)
    {
        var toggle = new ToggleSwitch { Header = label, IsOn = value, OnContent = "", OffContent = "" };
        toggle.Toggled += (_, _) => changed(toggle.IsOn);
        Panel.Children.Add(toggle);
    }

    public void Combo(string label, string[] items, int selected, Action<int> changed)
    {
        var combo = new ComboBox { Header = label, ItemsSource = items, SelectedIndex = Math.Clamp(selected, -1, items.Length - 1), HorizontalAlignment = HorizontalAlignment.Stretch };
        combo.SelectionChanged += (_, _) => { if (combo.SelectedIndex >= 0) changed(combo.SelectedIndex); };
        Panel.Children.Add(combo);
    }

    public void Action(string label, Action action, bool primary = false)
    {
        var button = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Stretch };
        if (primary) button.Style = (Style)Application.Current.Resources["PrimaryButton"];
        button.Click += (_, _) => action();
        Panel.Children.Add(button);
    }

    private static string Show(double v, string format) => format switch
    {
        "P0" => $"{v * 100:0}%",
        "P1" => $"{v * 100:0.0}%",
        _ when format.EndsWith("×") => v.ToString(format[..^1]) + "×",
        _ when format.EndsWith(" s") => v.ToString(format[..^2]) + " s",
        _ when format.EndsWith("°") => v.ToString(format[..^1]) + "°",
        _ => v.ToString(format),
    };

    private static Windows.UI.Color ToColor(RgbaColor c) =>
        ColorHelper.FromArgb((byte)(c.A * 255), (byte)(c.R * 255), (byte)(c.G * 255), (byte)(c.B * 255));
}
