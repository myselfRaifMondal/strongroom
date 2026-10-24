using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Strongroom.App;

public static class Dialogs
{
    public static async Task<(string Password, string SecretKey)?> AskCredentials(XamlRoot root, string title, string explanation)
    {
        var password = new PasswordBox { Header = "Master password" };
        var secretKey = new PasswordBox { Header = "Secret Key" };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = explanation, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(password);
        panel.Children.Add(secretKey);
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = panel,
            PrimaryButtonText = "Continue",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        var result = await dialog.ShowAsync();
        var creds = (password.Password, secretKey.Password.Trim());
        password.Password = "";
        secretKey.Password = "";
        return result == ContentDialogResult.Primary ? creds : null;
    }

    public static async Task<bool> Confirm(XamlRoot root, string title, string message, string yes)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = yes,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    public static async Task Info(XamlRoot root, string title, string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "OK",
        };
        await dialog.ShowAsync();
    }

    public static async Task<StorageFile?> SaveVtf(nint hwnd, string suggestedName)
    {
        var picker = new FileSavePicker { SuggestedFileName = suggestedName, SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeChoices.Add("Strongroom transfer file", new List<string> { ".vtf" });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        return await picker.PickSaveFileAsync();
    }

    public static async Task<StorageFile?> OpenVtf(nint hwnd)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".vtf");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        return await picker.PickSingleFileAsync();
    }

    public static async Task<StorageFile?> OpenCsv(nint hwnd)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add(".csv");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        return await picker.PickSingleFileAsync();
    }
}
