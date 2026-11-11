using Framelo.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Framelo.App.Services;

/// <summary>Applies Settings › Appearance: light/dark/system theme and the accent colour.</summary>
public static class Appearance
{
    private static readonly List<WeakReference<Window>> Windows = new();

    public static void Register(Window window)
    {
        Windows.Add(new WeakReference<Window>(window));
        Apply(window);
    }

    public static void ApplyAll()
    {
        ApplyAccent();
        foreach (var w in Windows.ToList())
            if (w.TryGetTarget(out var window)) Apply(window);
            else Windows.Remove(w);
    }

    private static void Apply(Window window)
    {
        if (window.Content is FrameworkElement root)
            root.RequestedTheme = App.Services.Preferences.Theme switch
            {
                ThemeChoice.Light => ElementTheme.Light,
                ThemeChoice.Dark => ElementTheme.Dark,
                _ => ElementTheme.Default,
            };
    }

    public static void ApplyAccent()
    {
        var hex = Preferences.AccentHex(App.Services.Preferences.Accent);
        var color = ColorHelper.FromArgb(255, (byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);
        var resources = Application.Current.Resources;
        void Set(string key, byte alpha)
        {
            if (resources.TryGetValue(key, out var value) && value is SolidColorBrush brush)
                brush.Color = ColorHelper.FromArgb(alpha, color.R, color.G, color.B);
        }
        Set("AccentFillColorDefaultBrush", 255);
        Set("AccentFillColorSecondaryBrush", 230);
        Set("AccentFillColorTertiaryBrush", 204);
        Set("AccentPurpleBrush", 255);
    }
}
