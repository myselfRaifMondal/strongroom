using Strongroom.Core.Services;
using Strongroom.Ffi;
using Xunit;

namespace Strongroom.Tests;

/// <summary>
/// Trash, item history and travel mode as the app uses them (VaultTools over
/// the real strongroom_ffi.dll). Made-up data only.
/// </summary>
public class VaultToolsTests
{
    private const long T0 = 1_800_000_000;
    private const long Day = 24 * 60 * 60;

    private static ItemInput Login(string title, string username, bool travelSafe = false) =>
        new(ItemKind.Login, title, username, "made-up pw", new[] { "https://login.example.test" }, null, null,
            null, Array.Empty<string>(), Array.Empty<CustomField>(), travelSafe);

    private static void WithVault(Action<Vault> body)
    {
        var dir = Directory.CreateTempSubdirectory("sr-tools-").FullName;
        try
        {
            Vault vault;
            try
            {
                vault = Vault.Create(Path.Combine(dir, "t.srdb"), "pw for tests 1", StrongroomCore.GenerateSecretKey(), T0);
            }
            catch (StrongroomException.Unsupported e)
            {
                Skip.If(true, $"core reported Unsupported: {e.@reason}");
                return;
            }
            using (vault)
                body(vault);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }

    [SkippableFact]
    public void TrashRestoreAndPurgeExpired() => CoreThread.Run(() => WithVault(vault =>
    {
        var keep = vault.AddItem(Login("Mail", "me@example.test"), T0 + 1);
        var gone = vault.AddItem(Login("Forum", "old@example.test"), T0 + 2);
        vault.TrashItem(keep, T0 + 10);
        vault.TrashItem(gone, T0 + 20);
        Assert.Empty(vault.Search("", null, null));

        var trash = VaultTools.Trash(vault);
        Assert.Equal(new[] { "Forum", "Mail" }, trash.Select(e => e.Item.Title));
        Assert.Equal(T0 + 20 + VaultTools.TrashRetentionDays * Day, trash[0].PurgeAt);

        vault.RestoreItem(keep, T0 + 30);
        Assert.Equal("Mail", Assert.Single(vault.Search("", null, null)).Title);
        Assert.Equal("Forum", Assert.Single(VaultTools.Trash(vault)).Item.Title);

        // Not yet expired: nothing is deleted.
        Assert.Equal(0u, vault.PurgeExpiredTrash(T0 + 20 + 179 * Day));
        Assert.Single(VaultTools.Trash(vault));

        Assert.Equal(1u, vault.PurgeExpiredTrash(T0 + 20 + VaultTools.TrashRetentionDays * Day));
        Assert.Empty(VaultTools.Trash(vault));
        Assert.Throws<StrongroomException.NotFound>(() => vault.RestoreItem(gone, T0 + 200 * Day));
        Assert.Single(vault.Search("", null, null));
    }));

    [SkippableFact]
    public void HistoryNewestFirstAndRestoreRevision() => CoreThread.Run(() => WithVault(vault =>
    {
        var id = vault.AddItem(Login("Bank", "v1@example.test"), T0 + 1);
        vault.UpdateItem(id, Login("Bank", "v2@example.test"), T0 + 2);
        vault.UpdateItem(id, Login("Bank", "v3@example.test"), T0 + 3);

        var history = VaultTools.HistoryNewestFirst(vault, id);
        Assert.Equal(new[] { "v2@example.test", "v1@example.test" }, history.Select(r => r.Data.Username));

        var oldest = history[^1];
        VaultTools.RestoreRevision(vault, id, oldest, T0 + 4);
        Assert.Equal("v1@example.test", vault.GetItem(id).Data.Username);
        // The version that was current before the restore is kept.
        Assert.Contains("v3@example.test", VaultTools.HistoryNewestFirst(vault, id).Select(r => r.Data.Username));
    }));

    [SkippableFact]
    public void TravelModeRemovesItemsNotMarkedTravelSafe() => CoreThread.Run(() => WithVault(vault =>
    {
        vault.AddItem(Login("Phone carrier", "travel@example.test", travelSafe: true), T0 + 1);
        vault.AddItem(Login("Work VPN", "work@example.test"), T0 + 2);
        vault.AddItem(Login("Shop", "shop@example.test"), T0 + 3);
        Assert.False(vault.TravelMode());
        Assert.Equal(2, VaultTools.NotTravelSafeCount(vault));

        vault.SetTravelMode(true, T0 + 4);
        Assert.True(vault.TravelMode());
        Assert.Equal("Phone carrier", Assert.Single(vault.Search("", null, null)).Title);
        Assert.Equal(0, VaultTools.NotTravelSafeCount(vault));

        // Turning it off does not bring removed items back.
        vault.SetTravelMode(false, T0 + 5);
        Assert.False(vault.TravelMode());
        Assert.Single(vault.Search("", null, null));
    }));

    [Fact]
    public void TravelConfirmationSaysHowManyItemsLeaveThisPc()
    {
        var (title, message, confirm) = VaultTools.TravelConfirmation(true, 3);
        Assert.Equal("Turn on travel mode?", title);
        Assert.StartsWith("3 item(s) not marked travel-safe will be REMOVED from this PC", message);
        Assert.Equal("Remove and turn on", confirm);

        (title, message, confirm) = VaultTools.TravelConfirmation(false, 0);
        Assert.Equal("Turn off travel mode?", title);
        Assert.Contains("come back only by importing an export", message);
        Assert.Equal("Turn off", confirm);
    }

    [Fact]
    public void PurgeMessages()
    {
        Assert.Equal("Nothing in the trash is older than 180 days.", VaultTools.PurgeResult(0));
        Assert.Equal("2 expired item(s) deleted for good.", VaultTools.PurgeResult(2));
        Assert.Null(VaultTools.PurgeOnUnlockMessage(0));
        Assert.Equal("1 item(s) older than 180 days removed from the trash.", VaultTools.PurgeOnUnlockMessage(1));
    }
}
