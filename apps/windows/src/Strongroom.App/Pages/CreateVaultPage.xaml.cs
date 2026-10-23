using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.App.Pages;

public sealed partial class CreateVaultPage : Page
{
    private Vault? _created;
    private string? _secretKey;

    public CreateVaultPage()
    {
        InitializeComponent();
    }

    private void OnPasswordChanged(object sender, RoutedEventArgs e)
    {
        try
        {
            var r = StrongroomCore.EstimateStrength(Password.Password);
            Strength.Text = Password.Password.Length == 0 ? "" : $"Strength {r.Score}/4 ({r.EntropyBits:F0} bits){(r.Warnings.Length > 0 ? " - " + string.Join("; ", r.Warnings) : "")}";
        }
        catch (Exception ex)
        {
            Strength.Text = CoreErrors.Describe(ex);
        }
    }

    private async void OnCreate(object sender, RoutedEventArgs e)
    {
        Error.Text = "";
        var password = Password.Password;
        if (password.Length < 8) { Error.Text = "Use at least 8 characters."; return; }
        if (password != Confirm.Password) { Error.Text = "The passwords do not match."; return; }

        CreateButton.IsEnabled = false;
        Busy.IsActive = true;
        try
        {
            var path = AppServices.Paths.VaultFile;
            var (vault, key) = await CoreThread.RunAsync(() =>
            {
                var sk = StrongroomCore.GenerateSecretKey();
                if (string.IsNullOrEmpty(sk))
                    throw new StrongroomException.Unsupported("Secret Key generation is not available in this build of the core");
                return (Vault.Create(path, password, sk, Clock.Now()), sk);
            });
            _created = vault;
            _secretKey = key;
            AppServices.RecordPasswordUnlock();

            Password.Password = "";
            Confirm.Password = "";
            SecretKeyText.Text = key;
            PasswordPanel.Visibility = Visibility.Collapsed;
            SecretKeyPanel.Visibility = Visibility.Visible;
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
            CreateButton.IsEnabled = true;
        }
        finally
        {
            Busy.IsActive = false;
        }
    }

    private void OnCopySecretKey(object sender, RoutedEventArgs e)
    {
        if (_secretKey is not null)
            AppServices.Copy(_secretKey);
    }

    private void OnAcknowledge(object sender, RoutedEventArgs e) =>
        ContinueButton.IsEnabled = Acknowledge.IsChecked == true;

    private void OnContinue(object sender, RoutedEventArgs e)
    {
        if (_created is null) return;
        SecretKeyText.Text = "";
        _secretKey = null;
        AppServices.SetVault(_created);
        AppServices.Main?.ShowVault();
    }
}
