using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.App.Pages;

public sealed partial class ItemEditPage : Page
{
    private string? _id;
    private CustomField[] _fields = Array.Empty<CustomField>();

    public ItemEditPage()
    {
        InitializeComponent();
        Kind.ItemsSource = Enum.GetValues<ItemKind>();
        Kind.SelectedItem = ItemKind.Login;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _id = e.Parameter as string;
        if (_id is null || AppServices.Vault is not { } vault)
            return;
        try
        {
            var id = _id;
            var d = CoreThread.Run(() => vault.GetItem(id)).Data;
            Heading.Text = "Edit item";
            Kind.SelectedItem = d.Kind;
            TitleBox.Text = d.Title;
            Username.Text = d.Username ?? "";
            Password.Password = d.Password ?? "";
            Urls.Text = string.Join(Environment.NewLine, d.Urls);
            Totp.Password = d.Totp ?? "";
            Folder.Text = d.Folder ?? "";
            Tags.Text = string.Join(", ", d.Tags);
            Notes.Text = d.Notes ?? "";
            TravelSafe.IsChecked = d.TravelSafe;
            _fields = d.Fields;
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
        }
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        Password.Password = "";
        Totp.Password = "";
    }

    private void OnPasswordChanged(object sender, RoutedEventArgs e)
    {
        if (Password.Password.Length == 0) { Strength.Text = ""; return; }
        try
        {
            var r = StrongroomCore.EstimateStrength(Password.Password);
            Strength.Text = $"Strength {r.Score}/4 ({r.EntropyBits:F0} bits)";
        }
        catch (Exception) { Strength.Text = ""; }
    }

    private void OnGenerate(object sender, RoutedEventArgs e)
    {
        try
        {
            Password.Password = StrongroomCore.GeneratePassword(GeneratorPage.DefaultPolicy);
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
        }
    }

    private static string? NullIfEmpty(string s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var vault = AppServices.Vault;
        if (vault is null) return;
        if (string.IsNullOrWhiteSpace(TitleBox.Text)) { Error.Text = "A title is required."; return; }

        var input = new ItemInput(
            Kind: Kind.SelectedItem is ItemKind k ? k : ItemKind.Login,
            Title: TitleBox.Text.Trim(),
            Username: NullIfEmpty(Username.Text),
            Password: Password.Password.Length == 0 ? null : Password.Password,
            Urls: Urls.Text.Split('\n', '\r').Select(u => u.Trim()).Where(u => u.Length > 0).ToArray(),
            Notes: NullIfEmpty(Notes.Text),
            Totp: NullIfEmpty(Totp.Password),
            Folder: NullIfEmpty(Folder.Text),
            Tags: Tags.Text.Split(',').Select(t => t.Trim()).Where(t => t.Length > 0).ToArray(),
            Fields: _fields,
            TravelSafe: TravelSafe.IsChecked == true);
        try
        {
            if (_id is null)
                _id = CoreThread.Run(() => vault.AddItem(input, Clock.Now()));
            else
            {
                var id = _id;
                CoreThread.Run(() => vault.UpdateItem(id, input, Clock.Now()));
            }
            AppServices.Main?.Navigate(typeof(ItemDetailPage), _id);
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
        }
    }

    private void OnCancel(object sender, RoutedEventArgs e) => AppServices.Main?.GoBack();
}
