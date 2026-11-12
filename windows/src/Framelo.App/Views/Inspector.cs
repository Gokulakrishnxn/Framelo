using Framelo.App.Services;
using Framelo.Core;
using Framelo.Platform.Media;
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
            case "camera": Camera(); break;
            case "text": Text(); break;
            case "captions": Captions(); break;
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

    private void Camera()
    {
        Header("Camera");
        if (!Model.Project.Sources.Any(s => s.Camera != null)) { Note("This project has no camera recording. Turn on the camera in the capture bar to record one."); return; }
        var c = S.Camera;
        Toggle("Show camera", c.IsVisible, v => Setting("Camera Visibility", s => s.Camera.IsVisible = v, "cam-visible"));
        Combo("Shape", new[] { "Circle", "Rounded" }, (int)c.Shape, i => Setting("Camera Shape", s => s.Camera.Shape = (CameraShape)i, "cam-shape"));
        SliderRow("Size", 0.1, 0.5, c.Size, "P0", v => Setting("Camera Size", s => s.Camera.Size = v, "cam-size"));
        var corners = new (string Name, double X, double Y)[] { ("Bottom right", 0.88, 0.82), ("Bottom left", 0.12, 0.82), ("Top right", 0.88, 0.18), ("Top left", 0.12, 0.18) };
        var nearest = Array.FindIndex(corners, k => Math.Abs(k.X - c.PositionX) < 0.01 && Math.Abs(k.Y - c.PositionY) < 0.01);
        Combo("Position", corners.Select(k => k.Name).ToArray(), nearest,
            i => Setting("Camera Position", s => { s.Camera.PositionX = corners[i].X; s.Camera.PositionY = corners[i].Y; }, "cam-pos"));
        Toggle("Mirror", c.IsMirrored, v => Setting("Mirror Camera", s => s.Camera.IsMirrored = v, "cam-mirror"));
        SliderRow("Shrink while zoomed", 0.4, 1, c.ZoomedScale, "P0", v => Setting("Camera Zoom Size", s => s.Camera.ZoomedScale = v, "cam-zoom"));
    }

    private static readonly (string Name, RgbaColor Color)[] TextColors =
    {
        ("White", RgbaColor.White), ("Black", RgbaColor.Black), ("Teal", RgbaColor.FromHex(0x00D1BF)),
        ("Purple", RgbaColor.FromHex(0x7C5CFF)), ("Amber", RgbaColor.FromHex(0xF5A524)),
    };

    private static readonly (string Name, RgbaColor Color)[] TextBackgrounds =
    {
        ("None", RgbaColor.Clear), ("Dark", new RgbaColor(0, 0, 0, 0.55)), ("Light", new RgbaColor(1, 1, 1, 0.85)),
        ("Purple", RgbaColor.FromHex(0x7C5CFF, 0.9)),
    };

    private static int Nearest((string Name, RgbaColor Color)[] options, RgbaColor color) =>
        Array.FindIndex(options, o => Math.Abs(o.Color.R - color.R) + Math.Abs(o.Color.G - color.G) + Math.Abs(o.Color.B - color.B) + Math.Abs(o.Color.A - color.A) < 0.05);

    private void Text()
    {
        Header("Text");
        if (Model.SelectedText is not TextOverlay t)
        {
            Note("Add a title or label that appears over the video. Press T to add one at the playhead.");
            Action("Add text", () => page.OnAddText(page, new RoutedEventArgs()), primary: true);
            foreach (var o in Model.Project.Timeline.TextOverlays)
                Action($"{Format.Duration(o.StartTime.Seconds)}  {o.Text}", () => { Model.Select(EditorSelectionKind.Text, o.Id); Model.Seek(o.StartTime.Seconds); });
            return;
        }
        void Change(string name, Action<TextOverlay> change, string key)
        {
            var copy = TextEdits.Copy(t);
            change(copy);
            Edit(TextEdits.UpdateText(copy, name, $"{key}-{t.Id}"));
        }
        var box = new TextBox { Header = "Text", Text = t.Text, AcceptsReturn = false, HorizontalAlignment = HorizontalAlignment.Stretch };
        box.TextChanged += (_, _) => { if (box.Text.Trim().Length > 0) Change("Edit Text", o => o.Text = box.Text, "text-content"); };
        Panel.Children.Add(box);
        SliderRow("Size", 0.02, 0.15, t.FontSize, "P1", v => Change("Text Size", o => o.FontSize = v, "text-size"));
        Combo("Weight", new[] { "Regular", "Medium", "Semibold", "Bold" }, (int)t.Weight, i => Change("Text Weight", o => o.Weight = (TextWeight)i, "text-weight"));
        Combo("Colour", TextColors.Select(c => c.Name).ToArray(), Nearest(TextColors, t.Color), i => Change("Text Colour", o => o.Color = TextColors[i].Color, "text-color"));
        Combo("Background", TextBackgrounds.Select(c => c.Name).ToArray(), Nearest(TextBackgrounds, t.BackgroundColor),
            i => Change("Text Background", o => o.BackgroundColor = TextBackgrounds[i].Color, "text-bg"));
        SliderRow("Horizontal position", 0, 1, t.PositionX, "P0", v => Change("Move Text", o => o.PositionX = v, "text-x"));
        SliderRow("Vertical position", 0, 1, t.PositionY, "P0", v => Change("Move Text", o => o.PositionY = v, "text-y"));
        SliderRow("Fade", 0, 1, t.FadeDuration, "0.00 s", v => Change("Text Fade", o => o.FadeDuration = v, "text-fade"));
        Note($"{Format.Duration(t.StartTime.Seconds)} – {Format.Duration(t.EndTime.Seconds)} · drag it in the text lane to move or resize it.");
        Action("Delete text", () => Edit(TextEdits.RemoveText(t.Id)));
    }

    private void Captions()
    {
        Header("Captions");
        var captions = Model.Project.Timeline.Captions;
        var languages = SpeechTranscriber.Languages();
        if (languages.Count == 0)
            Note("Windows speech recognition is not installed. Add a speech language in Settings › Time & language › Speech, then come back.");
        else
        {
            Note("Captions are made from your microphone on this PC. Nothing is uploaded.");
            var index = Math.Max(0, languages.ToList().FindIndex(l => l.Name == System.Globalization.CultureInfo.CurrentUICulture.Name));
            var language = languages[index];
            if (languages.Count > 1) Combo("Language", languages.Select(l => l.DisplayName).ToArray(), index, i => language = languages[i]);
            Action(captions.Count == 0 ? "Generate captions" : "Generate again", () => _ = CaptionFlow.GenerateAsync(page, Model, language), primary: true);
        }
        Action("Add caption at playhead", () =>
        {
            var start = MediaTime.FromSeconds(Model.Playhead);
            var caption = new Caption { Text = "Caption", StartTime = start, EndTime = MediaTime.Min(start + MediaTime.FromSeconds(2), Model.Project.Duration) };
            if (caption.EndTime <= caption.StartTime) return;
            var list = captions.Select(TextEdits.Copy).Where(c => !c.Range.Overlaps(caption.Range)).Append(caption).OrderBy(c => c.StartTime.Ticks);
            Edit(TextEdits.SetCaptions(list, "Add Caption"));
            Model.Select(EditorSelectionKind.Caption, caption.Id);
        });
        if (captions.Count == 0) return;

        Header("Style");
        Toggle("Show captions", S.Captions.IsVisible, v => Setting("Show Captions", s => s.Captions.IsVisible = v, "cap-visible"));
        SliderRow("Size", 0.02, 0.08, S.Captions.FontSize, "P1", v => Setting("Caption Size", s => s.Captions.FontSize = v, "cap-size"));
        SliderRow("Vertical position", 0.5, 0.97, S.Captions.PositionY, "P0", v => Setting("Caption Position", s => s.Captions.PositionY = v, "cap-y"));
        SliderRow("Background", 0, 1, S.Captions.BackgroundColor.A, "P0", v => Setting("Caption Background", s => s.Captions.BackgroundColor = s.Captions.BackgroundColor with { A = v }, "cap-bg"));

        Header($"Lines ({captions.Count})");
        Action("Delete all captions", () => Edit(TextEdits.SetCaptions(Array.Empty<Caption>(), "Delete Captions")));
        foreach (var caption in captions)
        {
            var c = caption;
            var selected = Model.SelectedId == c.Id;
            var time = new HyperlinkButton { Content = Format.Duration(c.StartTime.Seconds), Padding = new Thickness(0), FontSize = 12 };
            time.Click += (_, _) => { Model.Select(EditorSelectionKind.Caption, c.Id); Model.Seek(c.StartTime.Seconds); };
            var box = new TextBox { Text = c.Text, TextWrapping = TextWrapping.Wrap, AcceptsReturn = false, FontSize = 13 };
            if (selected) box.BorderBrush = (Brush)Application.Current.Resources["AccentPurpleBrush"];
            box.LostFocus += (_, _) =>
            {
                var text = box.Text.Trim();
                if (text.Length == 0 || text == c.Text) return;
                var copy = TextEdits.Copy(c);
                copy.Text = text;
                Edit(TextEdits.UpdateCaption(copy));
            };
            var remove = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 10 }, Padding = new Thickness(6), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
            ToolTipService.SetToolTip(remove, "Delete line");
            remove.Click += (_, _) => Edit(TextEdits.RemoveCaption(c.Id));
            var header = new Grid();
            header.Children.Add(time);
            remove.HorizontalAlignment = HorizontalAlignment.Right;
            header.Children.Add(remove);
            Panel.Children.Add(new StackPanel { Spacing = 2, Children = { header, box } });
        }
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
