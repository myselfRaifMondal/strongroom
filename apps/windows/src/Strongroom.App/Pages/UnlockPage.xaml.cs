using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.App.Pages;

public sealed partial class UnlockPage : Page
{
    public UnlockPage()
    {
        InitializeComponent();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var reason = await Task.Run(() => AppServices.PasswordRequired());
        bool hello = reason == PasswordRequiredReason.NotRequired && await HelloPresence.IsAvailableAsync();
        HelloButton.Visibility = hello ? Visibility.Visible : Visibility.Collapsed;
        HelloNote.Text = reason switch
        {
            PasswordRequiredReason.NotRequired => hello ? "" : "Windows Hello is not available right now.",
            PasswordRequiredReason.FirstLaunchAfterReboot => "Your master password is required after a restart.",
            PasswordRequiredReason.TooManyBiometricFailures => "Too many Windows Hello attempts. Enter your master password.",
            PasswordRequiredReason.PeriodicCheck => "Enter your master password (required every 7 days).",
            PasswordRequiredReason.BiometricEnrollmentChanged => "Windows Hello sign-in changed. Enter your master password.",
            _ => "",
        };
        Password.Focus(FocusState.Programmatic);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
            OnUnlock(sender, e);
    }

    private async void OnUnlock(object sender, RoutedEventArgs e)
    {
        Error.Text = "";
        var password = Password.Password;
        var secretKey = SecretKey.Password.Trim();
        SetBusy(true);
        try
        {
            var path = AppServices.Paths.VaultFile;
            var vault = await CoreThread.RunAsync(() => Vault.UnlockWithPassword(path, password, secretKey, Clock.Now()));
            AppServices.RecordPasswordUnlock();
            Password.Password = "";
            SecretKey.Password = "";
            AppServices.SetVault(vault);
            AppServices.Main?.ShowVault();
            await PurgeExpiredTrash(vault);
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async void OnHello(object sender, RoutedEventArgs e)
    {
        Error.Text = "";
        SetBusy(true);
        try
        {
            var vault = await CoreThread.RunAsync(() => AppServices.Device.Unlock());
            using (var gate = AppServices.OpenGate())
                gate.RecordBiometricSuccess();
            AppServices.SetVault(vault);
            AppServices.Main?.ShowVault();
            await PurgeExpiredTrash(vault);
        }
        catch (Exception ex)
        {
            try
            {
                using var gate = AppServices.OpenGate();
                gate.RecordBiometricFailure();
            }
            catch (Exception) { }
            Error.Text = CoreErrors.Describe(ex);
            HelloButton.Visibility = AppServices.PasswordRequired() == PasswordRequiredReason.NotRequired
                ? Visibility.Visible : Visibility.Collapsed;
        }
        finally
        {
            SetBusy(false);
        }
    }

    /// <summary>Items trashed more than 180 days ago are deleted for good on every unlock.</summary>
    private static async Task PurgeExpiredTrash(Vault vault)
    {
        try
        {
            var n = await CoreThread.RunAsync(() => vault.PurgeExpiredTrash(Clock.Now()));
            if (VaultTools.PurgeOnUnlockMessage(n) is { } message)
                AppServices.Main?.Notify(message);
        }
        catch (Exception ex)
        {
            Diag.Log($"purge expired trash on unlock failed ({ex.GetType().Name})");
        }
    }

    private void SetBusy(bool busy)
    {
        Busy.IsActive = busy;
        UnlockButton.IsEnabled = !busy;
        HelloButton.IsEnabled = !busy;
    }
}
