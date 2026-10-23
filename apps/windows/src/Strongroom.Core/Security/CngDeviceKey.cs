using Strongroom.Core.Native;

namespace Strongroom.Core.Security;

/// <summary>
/// A non-exportable P-256 ECDH key held by a CNG key storage provider.
/// Production uses the Microsoft Platform Crypto Provider (TPM). The software
/// KSP is supported only so the byte handling (blob layout, little-endian raw
/// secret) can be exercised on machines without a TPM, e.g. CI runners; the
/// app never selects it for a real device key.
/// </summary>
public sealed class CngDeviceKey : IDisposable
{
    public const string DefaultKeyName = "Strongroom-DeviceKey-v1";

    private nint _provider;
    private nint _key;
    private readonly byte[] _publicKey;

    public string ProviderName { get; }
    public string? KeyName { get; }

    private CngDeviceKey(string providerName, string? keyName, nint provider, nint key)
    {
        ProviderName = providerName;
        KeyName = keyName;
        _provider = provider;
        _key = key;
        _publicKey = ExportPublic(key);
    }

    /// <summary>65-byte uncompressed SEC1 public key.</summary>
    public byte[] PublicKey() => (byte[])_publicKey.Clone();

    /// <summary>Opens the persisted key, or returns null when it does not exist.</summary>
    public static CngDeviceKey? Open(string providerName = NCrypt.MS_PLATFORM_CRYPTO_PROVIDER, string keyName = DefaultKeyName)
    {
        nint provider = OpenProvider(providerName);
        int st = NCrypt.NCryptOpenKey(provider, out nint key, keyName, 0, 0);
        if (st == NCrypt.NTE_BAD_KEYSET || st == NCrypt.NTE_NOT_FOUND)
        {
            NCrypt.Free(ref provider);
            return null;
        }
        if (st != 0)
        {
            NCrypt.Free(ref provider);
            throw new NCryptException("NCryptOpenKey", st);
        }
        return Wrap(providerName, keyName, provider, key);
    }

    /// <summary>
    /// Creates a key. <paramref name="keyName"/> null creates an ephemeral
    /// (non-persisted) key. Export policy 0 = never exportable; usage is
    /// key agreement only. When <paramref name="uiPolicyDescription"/> is set,
    /// NCRYPT_UI_POLICY (protect-key) is applied so the provider itself
    /// demands user consent on use, in addition to the Windows Hello check
    /// the app performs before every agreement.
    /// </summary>
    public static CngDeviceKey Create(
        string providerName = NCrypt.MS_PLATFORM_CRYPTO_PROVIDER,
        string? keyName = DefaultKeyName,
        string? uiPolicyDescription = null,
        nint ownerWindow = 0)
    {
        nint provider = OpenProvider(providerName);
        nint key = 0;
        try
        {
            NCrypt.Check(NCrypt.NCryptCreatePersistedKey(provider, out key, NCrypt.BCRYPT_ECDH_P256_ALGORITHM, keyName, 0,
                keyName is null ? 0 : NCrypt.NCRYPT_OVERWRITE_KEY_FLAG), "NCryptCreatePersistedKey");

            NCrypt.Check(NCrypt.NCryptSetProperty(key, NCrypt.NCRYPT_EXPORT_POLICY_PROPERTY, BitConverter.GetBytes(0u), 4, 0),
                "set export policy");
            NCrypt.Check(NCrypt.NCryptSetProperty(key, NCrypt.NCRYPT_KEY_USAGE_PROPERTY,
                BitConverter.GetBytes(NCrypt.NCRYPT_ALLOW_KEY_AGREEMENT_FLAG), 4, 0), "set key usage");

            if (ownerWindow != 0)
            {
                var hwnd = IntPtr.Size == 8 ? BitConverter.GetBytes((long)ownerWindow) : BitConverter.GetBytes((int)ownerWindow);
                NCrypt.NCryptSetProperty(key, NCrypt.NCRYPT_WINDOW_HANDLE_PROPERTY, hwnd, hwnd.Length, 0);
            }

            if (uiPolicyDescription is not null)
            {
                var policy = new NCrypt.NCRYPT_UI_POLICY
                {
                    dwVersion = 1,
                    dwFlags = NCrypt.NCRYPT_UI_PROTECT_KEY_FLAG,
                    pszCreationTitle = "Strongroom",
                    pszFriendlyName = "Strongroom device key",
                    pszDescription = uiPolicyDescription,
                };
                NCrypt.Check(NCrypt.NCryptSetProperty(key, NCrypt.NCRYPT_UI_POLICY_PROPERTY, ref policy,
                    System.Runtime.InteropServices.Marshal.SizeOf<NCrypt.NCRYPT_UI_POLICY>(), 0), "set UI policy");
            }

            NCrypt.Check(NCrypt.NCryptFinalizeKey(key, 0), "NCryptFinalizeKey");
            var result = Wrap(providerName, keyName, provider, key);
            provider = 0;
            key = 0;
            return result;
        }
        finally
        {
            NCrypt.Free(ref key);
            NCrypt.Free(ref provider);
        }
    }

    /// <summary>Deletes the persisted key, if any.</summary>
    public static bool Delete(string providerName = NCrypt.MS_PLATFORM_CRYPTO_PROVIDER, string keyName = DefaultKeyName)
    {
        var existing = Open(providerName, keyName);
        if (existing is null)
            return false;
        int st = NCrypt.NCryptDeleteKey(existing._key, 0); // frees the handle on success
        if (st == 0)
            existing._key = 0;
        existing.Dispose();
        return st == 0;
    }

    /// <summary>
    /// One ECDH inside the provider. Returns the 32-byte shared x-coordinate,
    /// big-endian (NCrypt hands it back little-endian; we reverse it).
    /// </summary>
    public byte[] Agree(byte[] peerPublicKeySec1)
    {
        ObjectDisposedException.ThrowIf(_key == 0, this);
        var blob = EcP256.Sec1ToBlob(peerPublicKeySec1);
        nint peer = 0, secret = 0;
        try
        {
            NCrypt.Check(NCrypt.NCryptImportKey(_provider, 0, NCrypt.BCRYPT_ECCPUBLIC_BLOB, 0, out peer, blob, blob.Length, 0),
                "NCryptImportKey(peer)");
            NCrypt.Check(NCrypt.NCryptSecretAgreement(_key, peer, out secret, 0), "NCryptSecretAgreement");
            NCrypt.Check(NCrypt.NCryptDeriveKey(secret, NCrypt.BCRYPT_KDF_RAW_SECRET, 0, null, 0, out int len, 0),
                "NCryptDeriveKey(size)");
            var raw = new byte[len];
            try
            {
                NCrypt.Check(NCrypt.NCryptDeriveKey(secret, NCrypt.BCRYPT_KDF_RAW_SECRET, 0, raw, raw.Length, out len, 0),
                    "NCryptDeriveKey(raw)");
                return EcP256.RawSecretToBigEndian(raw.AsSpan(0, len));
            }
            finally
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(raw);
            }
        }
        finally
        {
            NCrypt.Free(ref secret);
            NCrypt.Free(ref peer);
        }
    }

    public void Dispose()
    {
        NCrypt.Free(ref _key);
        NCrypt.Free(ref _provider);
    }

    private static CngDeviceKey Wrap(string providerName, string? keyName, nint provider, nint key)
    {
        try
        {
            return new CngDeviceKey(providerName, keyName, provider, key);
        }
        catch
        {
            NCrypt.Free(ref key);
            NCrypt.Free(ref provider);
            throw;
        }
    }

    private static nint OpenProvider(string providerName)
    {
        NCrypt.Check(NCrypt.NCryptOpenStorageProvider(out nint provider, providerName, 0), $"open '{providerName}'");
        return provider;
    }

    private static byte[] ExportPublic(nint key)
    {
        NCrypt.Check(NCrypt.NCryptExportKey(key, 0, NCrypt.BCRYPT_ECCPUBLIC_BLOB, 0, null, 0, out int len, 0), "export size");
        var blob = new byte[len];
        NCrypt.Check(NCrypt.NCryptExportKey(key, 0, NCrypt.BCRYPT_ECCPUBLIC_BLOB, 0, blob, blob.Length, out len, 0), "export public");
        return EcP256.BlobToSec1(blob.AsSpan(0, len));
    }
}
