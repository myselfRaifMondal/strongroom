using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Strongroom.App.Pages;
using Strongroom.Core.Platform;

namespace Strongroom.App;

public sealed partial class MainWindow : Window
{
    public nint Hwnd { get; }

    public MainWindow()
    {
        InitializeComponent();
        Hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var protection = CaptureExclusion.Apply(Hwnd);
        Diag.Log($"main window: capture protection = {protection}");
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1000, 720));

        AppServices.VaultChanged += () =>
        {
            if (AppServices.Vault is null)
                ShowLockScreen();
        };
        ShowLockScreen();
    }

    public void Navigate(Type page, object? parameter = null) => RootFrame.Navigate(page, parameter);

    public void GoBack()
    {
        if (RootFrame.CanGoBack)
            RootFrame.GoBack();
        else
            ShowVault();
    }

    public void ShowLockScreen()
    {
        RootFrame.BackStack.Clear();
        RootFrame.Navigate(AppServices.Paths.VaultExists ? typeof(UnlockPage) : typeof(CreateVaultPage));
        Diag.Log($"navigated to {(AppServices.Paths.VaultExists ? "unlock" : "create vault")} page");
    }

    public void ShowVault()
    {
        RootFrame.BackStack.Clear();
        RootFrame.Navigate(typeof(VaultPage));
    }

    public void Notify(string message, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        Status.Message = message;
        Status.Severity = severity;
        Status.IsOpen = true;
    }
}
