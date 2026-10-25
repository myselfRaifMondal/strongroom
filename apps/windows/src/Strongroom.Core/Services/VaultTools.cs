using Strongroom.Ffi;

namespace Strongroom.Core.Services;

/// <summary>
/// Trash, item history and travel mode on top of the existing Vault calls,
/// with the user-facing wording kept here so it can be tested headless.
/// Callers run these on <see cref="CoreThread"/>.
/// </summary>
public static class VaultTools
{
    /// <summary>The core deletes trashed items for good after this many days.</summary>
    public const int TrashRetentionDays = 180;

    /// <summary>Trashed items, most recently trashed first.</summary>
    public static List<TrashEntry> Trash(Vault vault) =>
        vault.ListTrash().OrderByDescending(e => e.DeletedAt).ToList();

    public static string PurgeResult(uint purged) => purged == 0
        ? $"Nothing in the trash is older than {TrashRetentionDays} days."
        : $"{purged} expired item(s) deleted for good.";

    /// <summary>Message after the automatic purge on unlock, or null when nothing was purged.</summary>
    public static string? PurgeOnUnlockMessage(uint purged) => purged == 0
        ? null
        : $"{purged} item(s) older than {TrashRetentionDays} days removed from the trash.";

    /// <summary>Earlier versions of an item, newest first.</summary>
    public static List<ItemRevision> HistoryNewestFirst(Vault vault, string id) =>
        vault.ItemHistory(id).OrderByDescending(r => r.ModifiedAt).ToList();

    /// <summary>Makes an earlier version current. The current version stays in the history.</summary>
    public static void RestoreRevision(Vault vault, string id, ItemRevision revision, long now) =>
        vault.UpdateItem(id, revision.Data, now);

    /// <summary>Items that turning travel mode on would remove from this PC.</summary>
    public static int NotTravelSafeCount(Vault vault) =>
        vault.Search("", null, null).Count(s =>
        {
            try { return !vault.GetItem(s.Id).Data.TravelSafe; }
            catch (StrongroomException) { return true; }
        });

    public static (string Title, string Message, string Confirm) TravelConfirmation(bool turnOn, int notTravelSafe) => turnOn
        ? ("Turn on travel mode?",
           $"{notTravelSafe} item(s) not marked travel-safe will be REMOVED from this PC, with their history. " +
           "Make sure you have an export (VTF) that contains them; import it after your trip to get them back.",
           "Remove and turn on")
        : ("Turn off travel mode?",
           "Travel mode will be turned off. Removed items come back only by importing an export that contains them.",
           "Turn off");

    public static string TravelResult(bool on) => on ? "Travel mode is on." : "Travel mode is off.";
}
