using Microsoft.UI.Xaml;

namespace Strongroom.App;

public partial class App : Application
{
    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => Diag.Log($"unhandled: {e.Exception.GetType().Name}: {e.Message}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Diag.Log($"launch: data dir {AppServices.Paths.Root}");
        var window = new MainWindow();
        AppServices.Start(window);
        window.Activate();
        Diag.Log("main window activated");
    }
}
