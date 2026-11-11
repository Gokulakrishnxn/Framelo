using Framelo.App.Services;
using Microsoft.UI.Xaml;

namespace Framelo.App;

public partial class App : Application
{
    public static AppServices Services { get; private set; } = null!;
    public static MainWindow MainWindow { get; private set; } = null!;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => Log.Error("Unhandled", e.Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Services = AppServices.Create();
        MainWindow = new MainWindow();
        MainWindow.Activate();
    }
}
