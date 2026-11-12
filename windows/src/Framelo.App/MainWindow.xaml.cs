using Framelo.App.Views;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace Framelo.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Framelo.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1360, 860));
        RootFrame.Navigate(typeof(DashboardPage));
    }

    public void ShowDashboard(string? message = null) => RootFrame.Navigate(typeof(DashboardPage), message);
    public void Navigate(Type page, object? parameter = null) => RootFrame.Navigate(page, parameter);
}
