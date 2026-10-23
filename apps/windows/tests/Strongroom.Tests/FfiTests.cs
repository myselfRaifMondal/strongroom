using Strongroom.Core.Services;
using Strongroom.Ffi;
using Xunit;

namespace Strongroom.Tests;

/// <summary>
/// Calls through the generated bindings into strongroom_ffi.dll. While the
/// core bodies are stubs they return Unsupported; those tests skip with that
/// reason instead of passing silently.
/// </summary>
public class FfiTests
{
    [Fact]
    public void NativeLibraryLoadsAndChecksumsMatch()
    {
        // Any call triggers the contract-version and checksum verification
        // of the generated bindings against the DLL.
        _ = StrongroomCore.GenerateSecretKey();
        var report = StrongroomCore.EstimateStrength("x");
        Assert.InRange(report.Score, (byte)0, (byte)4);
    }

    [Fact]
    public void ErrorsAreDescribedWithoutFactorDetail()
    {
        Assert.Equal("Unlock failed. Check the master password and Secret Key.",
            CoreErrors.Describe(new StrongroomException.UnlockFailed()));
        Assert.Contains("x", CoreErrors.Describe(new StrongroomException.FormatRejected("x")));
    }

    // Runs on a large-stack thread: see CoreThread (1 MB default Windows
    // stacks overflowed inside the core's Vault.create on CI).
    [SkippableFact]
    public void CreateAddSearchExportImport() => CoreThread.Run(CreateAddSearchExportImportBody);

    private static void CreateAddSearchExportImportBody()
    {
        var dir = Directory.CreateTempSubdirectory("sr-ffi-").FullName;
        try
        {
            string sk = StrongroomCore.GenerateSecretKey();
            Skip.If(sk.Length == 0, "core stub: generate_secret_key returns an empty string");
            Vault vault;
            try
            {
                vault = Vault.Create(Path.Combine(dir, "a.srdb"), "pw for tests 1", sk, 1_800_000_000);
            }
            catch (StrongroomException.Unsupported e)
            {
                Skip.If(true, $"core stub: {e.@reason}");
                return;
            }
            using (vault)
            {
                var input = new ItemInput(ItemKind.Login, "Mail", "me", "pw", new[] { "https://mail.example" }, null, null,
                    "Work", new[] { "t1" }, Array.Empty<CustomField>(), false);
                var id = vault.AddItem(input, 1_800_000_001);
                Assert.Equal("Mail", vault.GetItem(id).Data.Title);
                Assert.Single(vault.Search("mai", null, null));
                Assert.Empty(vault.Search("nothing-matches", null, null));

                var vtf = vault.ExportVtf("pw for tests 1", sk, Array.Empty<byte[]>(), 1_800_000_002);
                Assert.Equal(1, StrongroomCore.VtfInspect(vtf).PasswordSlots);

                using var other = Vault.Create(Path.Combine(dir, "b.srdb"), "other pw 2", StrongroomCore.GenerateSecretKey(), 1_800_000_003);
                var s = other.ImportVtf(vtf, "pw for tests 1", sk, 1_800_000_004);
                Assert.Equal(1u, s.Added);
                Assert.Throws<StrongroomException.UnlockFailed>(() =>
                    other.ImportVtf(vtf, "wrong", sk, 1_800_000_005));
            }
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }
}
