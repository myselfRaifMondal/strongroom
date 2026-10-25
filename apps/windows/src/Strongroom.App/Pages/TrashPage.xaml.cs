using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.App.Pages;

/// <summary>Trashed items: restore one, or delete the ones past their 180 days.</summary>
public sealed partial class TrashPage : Page
{
    public TrashPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Load();
    }

    private void Load()
    {
        var vault = AppServices.Vault;
        if (vault is null) return;
        List<TrashEntry> entries;
        try
        {
            entries = CoreThread.Run(() => VaultTools.Trash(vault));
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
            return;
        }
        EntriesPanel.Children.Clear();
        EmptyText.Visibility = entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        PurgeButton.IsEnabled = entries.Count > 0;
        foreach (var entry in entries)
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = entry.Item.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextWrapping = TextWrapping.Wrap });
            text.Children.Add(new TextBlock
            {
                Text = $"{entry.Item.Kind} · trashed {Date(entry.DeletedAt)} · deleted for good after {Date(entry.PurgeAt)}",
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                TextWrapping = TextWrapping.Wrap,
            });
            row.Children.Add(text);
            var restore = new Button { Content = "Restore", VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(restore, 1);
            var id = entry.Item.Id;
            var title = entry.Item.Title;
            restore.Click += (_, _) => Restore(id, title);
            row.Children.Add(restore);
            EntriesPanel.Children.Add(row);
        }
    }

    private static string Date(long t) => DateTimeOffset.FromUnixTimeSeconds(t).LocalDateTime.ToString("d");

    private void Restore(string id, string title)
    {
        var vault = AppServices.Vault;
        if (vault is null) return;
        Error.Text = "";
        try
        {
            CoreThread.Run(() => vault.RestoreItem(id, Clock.Now()));
            AppServices.Main?.Notify($"Restored '{title}'.", InfoBarSeverity.Success);
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
        }
        Load();
    }

    private async void OnPurge(object sender, RoutedEventArgs e)
    {
        var vault = AppServices.Vault;
        if (vault is null) return;
        if (!await Dialogs.Confirm(XamlRoot, "Delete expired items for good?",
                $"Only items trashed more than {VaultTools.TrashRetentionDays} days ago are deleted. They cannot be restored afterwards.",
                "Delete expired items"))
            return;
        Error.Text = "";
        try
        {
            var n = CoreThread.Run(() => vault.PurgeExpiredTrash(Clock.Now()));
            AppServices.Main?.Notify(VaultTools.PurgeResult(n));
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
        }
        Load();
    }

    private void OnBack(object sender, RoutedEventArgs e) => AppServices.Main?.ShowVault();
}
