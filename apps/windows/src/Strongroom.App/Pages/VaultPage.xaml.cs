using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.App.Pages;

public sealed partial class VaultPage : Page
{
    public VaultPage()
    {
        InitializeComponent();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Refresh();
        await UpdateHelloLabel();
    }

    private void Refresh()
    {
        var vault = AppServices.Vault;
        if (vault is null) return;
        try
        {
            var rows = ItemRow.Search(vault, Search.Text);
            Items.ItemsSource = rows;
            Footer.Text = $"{rows.Count} item(s). Copied secrets clear from the clipboard after 25 seconds and are kept out of clipboard history.";
        }
        catch (Exception ex)
        {
            Footer.Text = CoreErrors.Describe(ex);
        }
    }

    private async Task UpdateHelloLabel()
    {
        bool enrolled = await Task.Run(() => AppServices.Device.IsEnrolled);
        HelloToggle.Label = enrolled ? "Turn off Windows Hello" : "Turn on Windows Hello";
    }

    private void OnSearch(object sender, TextChangedEventArgs e) => Refresh();

    private void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ItemRow row)
            AppServices.Main?.Navigate(typeof(ItemDetailPage), row.Id);
    }

    private void OnNew(object sender, RoutedEventArgs e) => AppServices.Main?.Navigate(typeof(ItemEditPage), null);

    private void OnGenerator(object sender, RoutedEventArgs e) => AppServices.Main?.Navigate(typeof(GeneratorPage), null);

    private void OnQuickAccess(object sender, RoutedEventArgs e) => AppServices.ShowQuickAccess();

    private void OnLock(object sender, RoutedEventArgs e) => AppServices.Lock();

    private async void OnExport(object sender, RoutedEventArgs e)
    {
        var vault = AppServices.Vault;
        if (vault is null || AppServices.Main is null) return;
        var creds = await Dialogs.AskCredentials(XamlRoot, "Export vault",
            "The exported file is protected by your master password and Secret Key. Anyone with the file and both of them can read it.");
        if (creds is null) return;
        var file = await Dialogs.SaveVtf(AppServices.Main.Hwnd, $"strongroom-{DateTime.Now:yyyy-MM-dd}");
        if (file is null) return;
        try
        {
            var (password, secretKey) = creds.Value;
            var bytes = await CoreThread.RunAsync(() => vault.ExportVtf(password, secretKey, Array.Empty<byte[]>(), Clock.Now()));
            await File.WriteAllBytesAsync(file.Path, bytes);
            AppServices.Main.Notify($"Exported to {file.Path}", InfoBarSeverity.Success);
        }
        catch (Exception ex)
        {
            AppServices.Main.Notify(CoreErrors.Describe(ex), InfoBarSeverity.Error);
        }
    }

    private async void OnImport(object sender, RoutedEventArgs e)
    {
        var vault = AppServices.Vault;
        if (vault is null || AppServices.Main is null) return;
        var file = await Dialogs.OpenVtf(AppServices.Main.Hwnd);
        if (file is null) return;
        try
        {
            var bytes = await File.ReadAllBytesAsync(file.Path);
            var info = StrongroomCore.VtfInspect(bytes);
            var creds = await Dialogs.AskCredentials(XamlRoot, "Import VTF file",
                $"Enter the master password and Secret Key of the vault that exported this file (VTF v{info.Version}, {info.PasswordSlots} password slot(s)).");
            if (creds is null) return;
            var (password, secretKey) = creds.Value;
            var s = await CoreThread.RunAsync(() => vault.ImportVtf(bytes, password, secretKey, Clock.Now()));
            AppServices.Main.Notify($"Imported: {s.Added} added, {s.Updated} updated, {s.Unchanged} unchanged, {s.Conflicts} conflicts.", InfoBarSeverity.Success);
            Refresh();
        }
        catch (Exception ex)
        {
            AppServices.Main.Notify(CoreErrors.Describe(ex), InfoBarSeverity.Error);
        }
    }

    private async void OnImportCsv(object sender, RoutedEventArgs e)
    {
        var vault = AppServices.Vault;
        if (vault is null || AppServices.Main is null) return;
        if (sender is not MenuFlyoutItem { Tag: string tag } || !Enum.TryParse<CsvSource>(tag, out var source)) return;
        var file = await Dialogs.OpenCsv(AppServices.Main.Hwnd);
        if (file is null) return;
        try
        {
            var csv = await File.ReadAllTextAsync(file.Path);
            var s = await CoreThread.RunAsync(() => vault.ImportCsv(source, csv, Clock.Now()));
            Refresh();
            await Dialogs.Info(XamlRoot, "Import finished",
                $"Imported: {s.Added} added, {s.Updated} updated, {s.Unchanged} unchanged, {s.Conflicts} conflicts.\n\n" +
                $"The file {file.Path} still holds your passwords in plain text. Delete it now, then empty the Recycle Bin.");
        }
        catch (Exception ex)
        {
            AppServices.Main.Notify(CoreErrors.Describe(ex), InfoBarSeverity.Error);
        }
    }

    private async void OnHelloToggle(object sender, RoutedEventArgs e)
    {
        var vault = AppServices.Vault;
        var main = AppServices.Main;
        if (vault is null || main is null) return;
        try
        {
            if (await Task.Run(() => AppServices.Device.IsEnrolled))
            {
                AppServices.Device.Disable();
                main.Notify("Windows Hello unlock turned off.");
            }
            else
            {
                var reason = await Task.Run(() => AppServices.Device.UnavailableReason());
                if (reason is not null || !await HelloPresence.IsAvailableAsync())
                {
                    main.Notify($"Windows Hello unlock is unavailable on this PC: {reason ?? "Windows Hello is not set up."} Password unlock still works.", InfoBarSeverity.Warning);
                    return;
                }
                var hwnd = main.Hwnd;
                await CoreThread.RunAsync<object?>(() => { AppServices.Device.Enroll(vault, hwnd); return null; });
                main.Notify("Windows Hello unlock turned on. Your master password is still required after a restart, every 7 days and after 5 failed attempts.", InfoBarSeverity.Success);
            }
        }
        catch (Exception ex)
        {
            main.Notify(CoreErrors.Describe(ex), InfoBarSeverity.Error);
        }
        await UpdateHelloLabel();
    }
}
