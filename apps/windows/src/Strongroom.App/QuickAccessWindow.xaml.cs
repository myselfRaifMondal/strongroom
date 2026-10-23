using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Strongroom.Core.Platform;
using Strongroom.Core.Services;

namespace Strongroom.App;

/// <summary>
/// Hotkey overlay: always on top, excluded from screen capture. Copy mode
/// uses the 25 s auto-clearing, history-excluded clipboard. Auto-type shows
/// the previously focused window and types only after explicit confirmation,
/// every time.
/// </summary>
public sealed partial class QuickAccessWindow : Window
{
    private readonly TargetWindow? _target;
    private readonly nint _hwnd;

    public QuickAccessWindow(TargetWindow? target)
    {
        InitializeComponent();
        _target = target;
        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var protection = CaptureExclusion.Apply(_hwnd);
        Diag.Log($"quick access: capture protection = {protection}");

        AppWindow.Resize(new Windows.Graphics.SizeInt32(560, 520));
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.IsAlwaysOnTop = true;
            p.IsMinimizable = false;
            p.IsMaximizable = false;
        }

        TargetText.Text = target is null
            ? "No target window: auto-type is unavailable. Copy works."
            : $"Previous window: {target}";
        AutoTypeButton.IsEnabled = target is not null;

        if (AppServices.Vault is null)
        {
            Search.IsEnabled = false;
            Actions.Visibility = Visibility.Collapsed;
            Message.Text = "Strongroom is locked. Unlock it in the main window first.";
        }
        else
        {
            Refresh();
        }
        Activated += (_, _) => Search.Focus(FocusState.Programmatic);
    }

    private void Refresh()
    {
        if (AppServices.Vault is not { } vault) return;
        try
        {
            var rows = ItemRow.Search(vault, Search.Text);
            Items.ItemsSource = rows;
            if (rows.Count > 0) Items.SelectedIndex = 0;
        }
        catch (Exception ex)
        {
            Message.Text = CoreErrors.Describe(ex);
        }
    }

    private void OnSearch(object sender, TextChangedEventArgs e) => Refresh();

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape)
            Close();
    }

    private Strongroom.Ffi.Item? Selected()
    {
        if (Items.SelectedItem is not ItemRow row || AppServices.Vault is not { } vault) return null;
        try { return vault.GetItem(row.Id); }
        catch (Exception ex) { Message.Text = CoreErrors.Describe(ex); return null; }
    }

    private void CopyAndClose(string? value, string what)
    {
        if (string.IsNullOrEmpty(value)) { Message.Text = $"This item has no {what}."; return; }
        AppServices.Copy(value);
        Close();
    }

    private void OnCopyUsername(object sender, RoutedEventArgs e) => CopyAndClose(Selected()?.Data.Username, "username");

    private void OnCopyPassword(object sender, RoutedEventArgs e) => CopyAndClose(Selected()?.Data.Password, "password");

    private void OnCopyTotp(object sender, RoutedEventArgs e)
    {
        if (Items.SelectedItem is not ItemRow row || AppServices.Vault is not { } vault) return;
        try { CopyAndClose(vault.ItemTotp(row.Id, Clock.Now()).Code, "one-time code"); }
        catch (Exception ex) { Message.Text = CoreErrors.Describe(ex); }
    }

    private async void OnAutoType(object sender, RoutedEventArgs e)
    {
        if (_target is null) return;
        var item = Selected();
        if (item is null) return;
        var fields = new List<string>();
        if (!string.IsNullOrEmpty(item.Data.Username)) fields.Add(item.Data.Username!);
        if (!string.IsNullOrEmpty(item.Data.Password)) fields.Add(item.Data.Password!);
        if (fields.Count == 0) { Message.Text = "Nothing to type for this item."; return; }

        var what = fields.Count == 2 ? "username, Tab, password" : "the password";
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "Type into this window?",
            Content = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                Text = $"Strongroom will type {what} for \"{item.Data.Title}\" into:\n\n{_target}\n\n" +
                       "Only continue if this is the window you expect.",
            },
            PrimaryButtonText = "Type",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            fields.Clear();
            return;
        }

        var confirmation = AppServices.AutoType.Confirm(_target);
        AppWindow.Hide();
        var result = await Task.Run(() => AppServices.AutoType.Type(confirmation, fields));
        fields.Clear();
        Diag.Log($"auto-type: {result}");
        if (result == AutoTypeResult.Typed)
        {
            Close();
            return;
        }
        AppWindow.Show();
        Message.Text = result switch
        {
            AutoTypeResult.TargetGone => "The target window has closed. Nothing was typed.",
            AutoTypeResult.FocusNotRestored => "Could not bring the target window back to the front. Nothing was typed.",
            AutoTypeResult.InputBlocked => "Windows blocked the simulated input (for example, the target runs as administrator).",
            _ => "Nothing was typed.",
        };
    }
}
