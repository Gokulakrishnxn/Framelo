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

    private static async Task RecoverAtLaunch()
    {
        if (await Navigation.RecoverAsync() is string message) MainWindow.ShowDashboard(message);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Services = AppServices.Create();
        Navigation.OpenProjectHandler = id => MainWindow.Navigate(typeof(Views.EditorPage), id);
        Views.EditorPage.RendererFactory = model => new StyledRenderer(model.Video);
        MainWindow = new MainWindow();
        MainWindow.Activate();
        _ = RecoverAtLaunch();
    }
}
