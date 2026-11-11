using Framelo.App.Services;
using Framelo.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;

namespace Framelo.App.Views;

public sealed class ProjectCard(ProjectSummary summary)
{
    public ProjectSummary Summary { get; } = summary;
    public string Name => Summary.Name;
    public BitmapImage? Poster => Summary.PosterPath is string p ? new BitmapImage(new Uri(p)) : null;
    public string Detail =>
        $"{Format.Duration(Summary.Duration)} · {Summary.UpdatedAt.LocalDateTime:d MMM yyyy}" + (Summary.IsRecovered ? " · Recovered" : "");
}

public static class Format
{
    public static string Duration(double seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
    }

    public static string Bytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double v = bytes;
        var i = 0;
        while (v >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
        return $"{v:0.#} {units[i]}";
    }
}

public sealed partial class DashboardPage : Page
{
    public DashboardPage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is string message) ShowBanner(message, InfoBarSeverity.Success);
        Reload();
    }

    public void Reload()
    {
        IReadOnlyList<ProjectSummary> list;
        try { list = App.Services.Store.List(); }
        catch (Exception ex) { Log.Error("List", ex); list = Array.Empty<ProjectSummary>(); }
        Projects.ItemsSource = list.Select(s => new ProjectCard(s)).ToList();
        EmptyState.Visibility = list.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Subtitle.Text = list.Count == 1 ? "1 project" : $"{list.Count} projects";
    }

    public void ShowBanner(string message, InfoBarSeverity severity)
    {
        Banner.Message = message;
        Banner.Severity = severity;
        Banner.IsOpen = true;
    }

    private void OnOpen(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ProjectCard card) Navigation.OpenProject(card.Summary.Id);
    }

    private void OnCardRightTapped(object sender, Microsoft.UI.Xaml.Input.RightTappedRoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: ProjectCard card } element) return;
        var menu = new MenuFlyout();
        void Add(string text, string glyph, Action action)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Add("Open", "\uE8A7", () => Navigation.OpenProject(card.Summary.Id));
        Add("Rename…", "\uE8AC", async () =>
        {
            var box = new TextBox { Text = card.Name };
            var dialog = new ContentDialog { Title = "Rename project", Content = box, PrimaryButtonText = "Rename", CloseButtonText = "Cancel", XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Primary };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && box.Text.Trim().Length > 0)
            {
                try { App.Services.Store.Rename(card.Summary.Id, box.Text.Trim()); } catch (Exception ex) { ShowBanner(ex.Message, InfoBarSeverity.Error); }
                Reload();
            }
        });
        Add("Show in File Explorer", "\uE838", () => System.Diagnostics.Process.Start("explorer.exe", $"\"{card.Summary.PackagePath}\""));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("Move to Recycle Bin…", "\uE74D", async () =>
        {
            var dialog = new ContentDialog
            {
                Title = $"Move “{card.Name}” to the Recycle Bin?", Content = "You can restore it from the Recycle Bin until you empty it.",
                PrimaryButtonText = "Move to Recycle Bin", CloseButtonText = "Cancel", XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && RecycleBin.Send(card.Summary.PackagePath)) Reload();
        });
        menu.ShowAt(element, e.GetPosition(element));
        e.Handled = true;
    }

    private void OnNewRecording(object sender, RoutedEventArgs e) => Navigation.StartRecording();
    private void OnSettings(object sender, RoutedEventArgs e) => Navigation.OpenSettings();
    private async void OnImport(object sender, RoutedEventArgs e) => await Navigation.ImportVideoAsync();
}
