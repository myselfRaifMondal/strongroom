using Strongroom.Ffi;

namespace Strongroom.App;

/// <summary>List row; holds no secrets (summaries only).</summary>
public sealed class ItemRow
{
    public ItemRow(ItemSummary s)
    {
        Id = s.Id;
        Title = s.Title;
        var parts = new List<string> { s.Kind.ToString() };
        if (!string.IsNullOrEmpty(s.Subtitle)) parts.Add(s.Subtitle!);
        if (!string.IsNullOrEmpty(s.Folder)) parts.Add($"in {s.Folder}");
        if (s.HasTotp) parts.Add("2FA");
        Detail = string.Join("  ·  ", parts);
        Summary = s;
    }

    public string Id { get; }
    public string Title { get; }
    public string Detail { get; }
    public ItemSummary Summary { get; }

    public static List<ItemRow> Search(Vault vault, string query) =>
        vault.Search(query, null, null).OrderBy(s => s.Title, StringComparer.CurrentCultureIgnoreCase).Select(s => new ItemRow(s)).ToList();
}
