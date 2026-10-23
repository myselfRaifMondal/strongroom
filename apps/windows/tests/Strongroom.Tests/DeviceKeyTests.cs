using System.Security.Cryptography;
using Strongroom.Core.Native;
using Strongroom.Core.Security;
using Strongroom.Ffi;
using Xunit;
using Xunit.Abstractions;

namespace Strongroom.Tests;

public class EcP256Tests
{
    [Fact]
    public void Sec1AndBlobRoundTrip()
    {
        var sec1 = new byte[65];
        sec1[0] = 0x04;
        for (int i = 1; i < 65; i++) sec1[i] = (byte)i;
        var blob = EcP256.Sec1ToBlob(sec1);
        Assert.Equal(72, blob.Length);
        Assert.Equal(new byte[] { 0x45, 0x43, 0x4B, 0x31, 32, 0, 0, 0 }, blob[..8]); // "ECK1", cbKey=32 (LE)
        Assert.Equal(sec1, EcP256.BlobToSec1(blob));
    }

    [Fact]
    public void RejectsCompressedOrShortPoints()
    {
        Assert.Throws<ArgumentException>(() => EcP256.Sec1ToBlob(new byte[33]));
        var bad = new byte[65];
        bad[0] = 0x02;
        Assert.Throws<ArgumentException>(() => EcP256.Sec1ToBlob(bad));
    }

    [Fact]
    public void RawSecretIsReversedToBigEndian()
    {
        var le = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var be = EcP256.RawSecretToBigEndian(le);
        Assert.Equal(31, be[0]);
        Assert.Equal(0, be[31]);
        Assert.Equal(0, le[0]); // input untouched
        Assert.Throws<ArgumentException>(() => EcP256.RawSecretToBigEndian(new byte[31]));
    }
}

public class CngDeviceKeyTests
{
    private readonly ITestOutputHelper _out;
    public CngDeviceKeyTests(ITestOutputHelper output) => _out = output;

    private static byte[] Sec1(ECDiffieHellman k)
    {
        var p = k.ExportParameters(false);
        return new byte[] { 0x04 }.Concat(p.Q.X!).Concat(p.Q.Y!).ToArray();
    }

    // The software KSP exercises the exact NCrypt calls used with the TPM:
    // import peer blob, NCryptSecretAgreement, NCryptDeriveKey(RAW_SECRET),
    // little-endian -> big-endian. .NET's ECDH is the independent oracle.
    [Fact]
    public void SoftwareKspAgreementMatchesDotNetEcdh()
    {
        using var key = CngDeviceKey.Create(NCrypt.MS_KEY_STORAGE_PROVIDER, keyName: null);
        using var peer = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

        var ours = key.Agree(Sec1(peer));

        var pub = key.PublicKey();
        Assert.Equal(65, pub.Length);
        Assert.Equal(0x04, pub[0]);
        using var mine = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = pub[1..33], Y = pub[33..] },
        });
        var expected = peer.DeriveRawSecretAgreement(mine.PublicKey);
        Assert.Equal(expected, ours);
    }

    [Fact]
    public void SoftwareKspPersistedKeyIsNotExportableAndCanBeDeleted()
    {
        var name = $"Strongroom-Test-{Guid.NewGuid():N}";
        try
        {
            byte[] pub;
            using (var created = CngDeviceKey.Create(NCrypt.MS_KEY_STORAGE_PROVIDER, name))
                pub = created.PublicKey();
            using (var reopened = CngDeviceKey.Open(NCrypt.MS_KEY_STORAGE_PROVIDER, name))
            {
                Assert.NotNull(reopened);
                Assert.Equal(pub, reopened!.PublicKey());
            }
            // Export policy 0: the private key must not be exportable.
            using var cng = CngKey.Open(name, CngProvider.MicrosoftSoftwareKeyStorageProvider);
            Assert.Equal(CngExportPolicies.None, cng.ExportPolicy);
            Assert.ThrowsAny<CryptographicException>(() => cng.Export(CngKeyBlobFormat.EccPrivateBlob));
        }
        finally
        {
            CngDeviceKey.Delete(NCrypt.MS_KEY_STORAGE_PROVIDER, name);
        }
        Assert.Null(CngDeviceKey.Open(NCrypt.MS_KEY_STORAGE_PROVIDER, name));
    }

    [Fact]
    public void TpmProbeReportsHonestly()
    {
        // Not an assertion about the machine: CI runners usually lack a TPM.
        var r = DeviceKeyProbe.Run(NCrypt.MS_PLATFORM_CRYPTO_PROVIDER);
        _out.WriteLine($"TPM probe: opened={r.ProviderOpened} key={r.KeyCreated} match={r.AgreementMatches} :: {r.Detail}");
        if (r.KeyCreated)
            Assert.True(r.AgreementMatches, r.Detail);
    }

    private sealed class Presence(bool answer) : IUserPresence
    {
        public int Calls;
        public bool Verify(string message) { Calls++; return answer; }
    }

    [Fact]
    public void AgreementCallbackIsGatedOnUserPresence()
    {
        using var key = CngDeviceKey.Create(NCrypt.MS_KEY_STORAGE_PROVIDER, keyName: null);
        using var peer = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

        var denied = new Presence(false);
        Assert.Throws<StrongroomException.UnlockFailed>(() => new TpmDeviceKeyAgreement(key, denied).Agree(Sec1(peer)));
        Assert.Equal(1, denied.Calls);

        var allowed = new Presence(true);
        var cb = new TpmDeviceKeyAgreement(key, allowed);
        Assert.Equal(32, cb.Agree(Sec1(peer)).Length);
        Assert.Equal(key.PublicKey(), cb.PublicKey());

        // A malformed peer key surfaces only as UnlockFailed (no detail).
        Assert.Throws<StrongroomException.UnlockFailed>(() => cb.Agree(new byte[65]));
    }
}
