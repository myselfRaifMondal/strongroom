using System.Security.Cryptography;
using Strongroom.Core.Native;

namespace Strongroom.Core.Security;

public sealed record DeviceKeyProbeResult(string Provider, bool ProviderOpened, bool KeyCreated, bool AgreementMatches, string Detail);

/// <summary>
/// Checks whether a provider can host the device key, using an ephemeral
/// (never persisted) key and a software peer whose result is computed
/// independently by .NET. Nothing is stored and no prompt is shown.
/// </summary>
public static class DeviceKeyProbe
{
    public static DeviceKeyProbeResult Run(string providerName)
    {
        int st = NCrypt.NCryptOpenStorageProvider(out nint provider, providerName, 0);
        if (st != 0)
            return new(providerName, false, false, false, $"NCryptOpenStorageProvider: 0x{st:X8}");
        NCrypt.Free(ref provider);

        CngDeviceKey key;
        try
        {
            key = CngDeviceKey.Create(providerName, keyName: null);
        }
        catch (Exception e)
        {
            return new(providerName, true, false, false, $"create ephemeral P-256 key: {e.Message}");
        }

        using (key)
        {
            try
            {
                using var peer = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
                var p = peer.ExportParameters(false);
                var peerSec1 = new byte[65];
                peerSec1[0] = 0x04;
                p.Q.X!.CopyTo(peerSec1, 1);
                p.Q.Y!.CopyTo(peerSec1, 33);

                byte[] ours = key.Agree(peerSec1);

                var mine = key.PublicKey();
                using var mineForNet = ECDiffieHellman.Create(new ECParameters
                {
                    Curve = ECCurve.NamedCurves.nistP256,
                    Q = new ECPoint { X = mine[1..33], Y = mine[33..65] },
                });
                byte[] expected = peer.DeriveRawSecretAgreement(mineForNet.PublicKey);
                bool ok = CryptographicOperations.FixedTimeEquals(ours, expected);
                return new(providerName, true, true, ok,
                    ok ? "NCryptSecretAgreement + raw secret (reversed to big-endian) matches .NET ECDH"
                       : "MISMATCH between CNG raw secret and .NET ECDH");
            }
            catch (Exception e)
            {
                return new(providerName, true, true, false, $"agreement: {e.Message}");
            }
        }
    }
}
