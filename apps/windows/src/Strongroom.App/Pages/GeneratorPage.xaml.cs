using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.App.Pages;

public sealed partial class GeneratorPage : Page
{
    public static readonly PasswordPolicy DefaultPolicy = new(Length: 24, Lowercase: true, Uppercase: true, Digits: true, Symbols: true, AvoidAmbiguous: false);

    private bool _ready;

    public GeneratorPage()
    {
        InitializeComponent();
        _ready = true;
        Generate();
    }

    private void Generate()
    {
        if (!_ready) return;
        bool passphrase = Mode.SelectedIndex == 1;
        PasswordOptions.Visibility = passphrase ? Visibility.Collapsed : Visibility.Visible;
        PassphraseOptions.Visibility = passphrase ? Visibility.Visible : Visibility.Collapsed;
        try
        {
            string value = passphrase
                ? StrongroomCore.GeneratePassphrase(new PassphrasePolicy((byte)Words.Value, Separator.Text, Capitalize.IsChecked == true, IncludeNumber.IsChecked == true))
                : StrongroomCore.GeneratePassword(new PasswordPolicy((byte)Length.Value, Lower.IsChecked == true, Upper.IsChecked == true,
                    Digits.IsChecked == true, Symbols.IsChecked == true, AvoidAmbiguous.IsChecked == true));
            Result.Text = value;
            var s = StrongroomCore.EstimateStrength(value);
            Strength.Text = $"Strength {s.Score}/4, about {s.EntropyBits:F0} bits of entropy";
        }
        catch (Exception ex)
        {
            Result.Text = "";
            Strength.Text = CoreErrors.Describe(ex);
        }
    }

    private void OnChanged(object sender, RoutedEventArgs e) => Generate();
    private void OnModeChanged(object sender, SelectionChangedEventArgs e) => Generate();
    private void OnSlider(object sender, RangeBaseValueChangedEventArgs e) => Generate();
    private void OnText(object sender, TextChangedEventArgs e) => Generate();
    private void OnGenerate(object sender, RoutedEventArgs e) => Generate();

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (Result.Text.Length > 0) AppServices.Copy(Result.Text);
    }

    private void OnBack(object sender, RoutedEventArgs e) => AppServices.Main?.GoBack();
}
