using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.App.Pages;

public sealed partial class ItemDetailPage : Page
{
    private string? _id;
    private Item? _item;
    private DispatcherTimer? _totpTimer;
    private string? _totpCode;

    public ItemDetailPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _id = e.Parameter as string;
        Load();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _totpTimer?.Stop();
        _item = null;
        PasswordText.Text = "";
    }

    private void Load()
    {
        var vault = AppServices.Vault;
        if (vault is null || _id is null) return;
        try
        {
            _item = CoreThread.Run(() => vault.GetItem(_id));
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
            return;
        }
        var d = _item.Data;
        TitleText.Text = d.Title;
        KindText.Text = d.Kind + (d.Folder is { Length: > 0 } f ? $" · {f}" : "") + (d.TravelSafe ? " · travel safe" : "");
        UsernameText.Text = d.Username ?? "";
        UsernameRow.Visibility = string.IsNullOrEmpty(d.Username) ? Visibility.Collapsed : Visibility.Visible;
        PasswordRow.Visibility = string.IsNullOrEmpty(d.Password) ? Visibility.Collapsed : Visibility.Visible;
        Reveal.IsChecked = false;
        UrlsText.Text = d.Urls.Length > 0 ? "URLs: " + string.Join("  ", d.Urls) : "";
        TagsText.Text = d.Tags.Length > 0 ? "Tags: " + string.Join(", ", d.Tags) : "";
        NotesText.Text = d.Notes ?? "";
        FieldsPanel.Children.Clear();
        foreach (var field in d.Fields)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            row.Children.Add(new TextBlock { Text = field.Name, Width = 110 });
            row.Children.Add(new TextBlock { Text = field.Concealed ? "••••••" : field.Value, IsTextSelectionEnabled = !field.Concealed, MinWidth = 240 });
            var copy = new Button { Content = "Copy" };
            var value = field.Value;
            copy.Click += (_, _) => AppServices.Copy(value);
            row.Children.Add(copy);
            FieldsPanel.Children.Add(row);
        }
        MetaText.Text = $"Created {DateTimeOffset.FromUnixTimeSeconds(_item.CreatedAt).LocalDateTime:g} · modified {DateTimeOffset.FromUnixTimeSeconds(_item.ModifiedAt).LocalDateTime:g}";

        bool hasTotp = !string.IsNullOrEmpty(d.Totp);
        TotpRow.Visibility = hasTotp ? Visibility.Visible : Visibility.Collapsed;
        if (hasTotp)
        {
            _totpTimer ??= new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _totpTimer.Tick -= OnTotpTick;
            _totpTimer.Tick += OnTotpTick;
            _totpTimer.Start();
            OnTotpTick(null, null);
        }
    }

    private void OnTotpTick(object? sender, object? e)
    {
        var vault = AppServices.Vault;
        if (vault is null || _id is null) { _totpTimer?.Stop(); return; }
        try
        {
            var totpId = _id;
            var code = CoreThread.Run(() => vault.ItemTotp(totpId, Clock.Now()));
            _totpCode = code.Code;
            TotpText.Text = code.Code.Length == 6 ? $"{code.Code[..3]} {code.Code[3..]}" : code.Code;
            TotpProgress.Maximum = code.Period;
            TotpProgress.Value = code.SecondsRemaining;
            TotpSeconds.Text = $"{code.SecondsRemaining}s";
        }
        catch (Exception ex)
        {
            TotpText.Text = CoreErrors.Describe(ex);
            _totpTimer?.Stop();
        }
    }

    private void OnReveal(object sender, RoutedEventArgs e) =>
        PasswordText.Text = Reveal.IsChecked == true ? _item?.Data.Password ?? "" : "••••••••••••";

    private void OnCopyUsername(object sender, RoutedEventArgs e)
    {
        if (_item?.Data.Username is { } u) AppServices.Copy(u);
    }

    private void OnCopyPassword(object sender, RoutedEventArgs e)
    {
        if (_item?.Data.Password is { } p)
        {
            AppServices.Copy(p);
            AppServices.Main?.Notify("Password copied. It will be cleared from the clipboard in 25 seconds.");
        }
    }

    private void OnCopyTotp(object sender, RoutedEventArgs e)
    {
        if (_totpCode is { } c) AppServices.Copy(c);
    }

    private void OnBack(object sender, RoutedEventArgs e) => AppServices.Main?.ShowVault();

    private void OnEdit(object sender, RoutedEventArgs e)
    {
        if (_id is not null) AppServices.Main?.Navigate(typeof(ItemEditPage), _id);
    }

    private async void OnTrash(object sender, RoutedEventArgs e)
    {
        var vault = AppServices.Vault;
        if (vault is null || _id is null || _item is null) return;
        if (!await Dialogs.Confirm(XamlRoot, "Move to trash?", $"'{_item.Data.Title}' will be moved to the trash, where it can be restored until it is purged.", "Move to trash"))
            return;
        try
        {
            var id = _id;
            CoreThread.Run(() => vault.TrashItem(id, Clock.Now()));
            AppServices.Main?.ShowVault();
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
        }
    }
}
