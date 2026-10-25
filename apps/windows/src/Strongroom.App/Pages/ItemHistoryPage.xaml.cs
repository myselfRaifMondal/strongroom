using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.App.Pages;

/// <summary>Earlier versions of an item; any of them can be made current again. Secrets are not shown.</summary>
public sealed partial class ItemHistoryPage : Page
{
    private string? _id;

    public ItemHistoryPage()
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
        RevisionsPanel.Children.Clear();
    }

    private void Load()
    {
        var vault = AppServices.Vault;
        if (vault is null || _id is null) return;
        List<ItemRevision> revisions;
        try
        {
            var id = _id;
            revisions = CoreThread.Run(() => VaultTools.HistoryNewestFirst(vault, id));
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
            return;
        }
        RevisionsPanel.Children.Clear();
        EmptyText.Visibility = revisions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var revision in revisions)
        {
            var d = revision.Data;
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel();
            text.Children.Add(new TextBlock
            {
                Text = DateTimeOffset.FromUnixTimeSeconds(revision.ModifiedAt).LocalDateTime.ToString("g"),
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            });
            text.Children.Add(new TextBlock { Text = d.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextWrapping = TextWrapping.Wrap });
            var parts = new List<string>();
            if (!string.IsNullOrEmpty(d.Username)) parts.Add(d.Username!);
            if (!string.IsNullOrEmpty(d.Folder)) parts.Add($"in {d.Folder}");
            parts.Add($"{d.Fields.Length} field(s)");
            text.Children.Add(new TextBlock { Text = string.Join("  ·  ", parts), TextWrapping = TextWrapping.Wrap });
            row.Children.Add(text);
            var restore = new Button { Content = "Restore this version", VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(restore, 1);
            var chosen = revision;
            restore.Click += (_, _) => Restore(chosen);
            row.Children.Add(restore);
            RevisionsPanel.Children.Add(row);
        }
    }

    private void Restore(ItemRevision revision)
    {
        var vault = AppServices.Vault;
        if (vault is null || _id is null) return;
        Error.Text = "";
        try
        {
            var id = _id;
            CoreThread.Run(() => VaultTools.RestoreRevision(vault, id, revision, Clock.Now()));
            AppServices.Main?.Notify("Earlier version restored. The previous version is kept in the history.", InfoBarSeverity.Success);
            AppServices.Main?.Navigate(typeof(ItemDetailPage), id);
        }
        catch (Exception ex)
        {
            Error.Text = CoreErrors.Describe(ex);
        }
    }

    private void OnBack(object sender, RoutedEventArgs e)
    {
        if (_id is not null) AppServices.Main?.Navigate(typeof(ItemDetailPage), _id);
        else AppServices.Main?.ShowVault();
    }
}
