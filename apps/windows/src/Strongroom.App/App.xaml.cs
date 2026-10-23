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

        // CI smoke test only: also open the quick-access overlay so its
        // window creation and capture exclusion are exercised on the runner.
        if (Environment.GetEnvironmentVariable("STRONGROOM_SMOKE_OVERLAY") == "1")
        {
            AppServices.ShowQuickAccess();
            Diag.Log("smoke: quick access overlay opened");
        }
    }
}
