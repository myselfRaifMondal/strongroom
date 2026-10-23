using System.Runtime.InteropServices;

namespace Strongroom.Core.Native;

/// <summary>CNG key storage (ncrypt.dll) P/Invoke surface used by the device key.</summary>
internal static class NCrypt
{
    public const string MS_PLATFORM_CRYPTO_PROVIDER = "Microsoft Platform Crypto Provider";
    public const string MS_KEY_STORAGE_PROVIDER = "Microsoft Software Key Storage Provider";
    public const string BCRYPT_ECDH_P256_ALGORITHM = "ECDH_P256";
    public const string BCRYPT_ECCPUBLIC_BLOB = "ECCPUBLICBLOB";
    // bcrypt.h: #define BCRYPT_KDF_RAW_SECRET L"TRUNCATE"
    public const string BCRYPT_KDF_RAW_SECRET = "TRUNCATE";

    public const string NCRYPT_EXPORT_POLICY_PROPERTY = "Export Policy";
    public const string NCRYPT_KEY_USAGE_PROPERTY = "Key Usage";
    public const string NCRYPT_UI_POLICY_PROPERTY = "UI Policy";
    public const string NCRYPT_WINDOW_HANDLE_PROPERTY = "HWND Handle";

    public const uint NCRYPT_ALLOW_KEY_AGREEMENT_FLAG = 0x00000004;
    public const uint NCRYPT_UI_PROTECT_KEY_FLAG = 0x00000001;
    public const uint NCRYPT_OVERWRITE_KEY_FLAG = 0x00000080;
    public const uint NCRYPT_SILENT_FLAG = 0x00000040;

    public const uint BCRYPT_ECDH_PUBLIC_P256_MAGIC = 0x314B4345; // "ECK1"

    public const int ERROR_SUCCESS = 0;
    public const int NTE_BAD_KEYSET = unchecked((int)0x80090016);
    public const int NTE_NOT_FOUND = unchecked((int)0x80090011);
    public const int NTE_EXISTS = unchecked((int)0x8009000F);
    public const int NTE_DEVICE_NOT_READY = unchecked((int)0x80090030);
    public const int TPM_E_PCP_DEVICE_NOT_READY = unchecked((int)0x80290101);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NCRYPT_UI_POLICY
    {
        public uint dwVersion;
        public uint dwFlags;
        public string? pszCreationTitle;
        public string? pszFriendlyName;
        public string? pszDescription;
    }

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptOpenStorageProvider(out nint phProvider, string pszProviderName, uint dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptCreatePersistedKey(nint hProvider, out nint phKey, string pszAlgId, string? pszKeyName, uint dwLegacyKeySpec, uint dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptOpenKey(nint hProvider, out nint phKey, string pszKeyName, uint dwLegacyKeySpec, uint dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptSetProperty(nint hObject, string pszProperty, byte[] pbInput, int cbInput, uint dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptSetProperty(nint hObject, string pszProperty, ref NCRYPT_UI_POLICY pbInput, int cbInput, uint dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptFinalizeKey(nint hKey, uint dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptExportKey(nint hKey, nint hExportKey, string pszBlobType, nint pParameterList, byte[]? pbOutput, int cbOutput, out int pcbResult, uint dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptImportKey(nint hProvider, nint hImportKey, string pszBlobType, nint pParameterList, out nint phKey, byte[] pbData, int cbData, uint dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptSecretAgreement(nint hPrivKey, nint hPubKey, out nint phAgreedSecret, uint dwFlags);

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    public static extern int NCryptDeriveKey(nint hSharedSecret, string pwszKDF, nint pParameterList, byte[]? pbDerivedKey, int cbDerivedKey, out int pcbResult, uint dwFlags);

    [DllImport("ncrypt.dll")]
    public static extern int NCryptDeleteKey(nint hKey, uint dwFlags);

    [DllImport("ncrypt.dll")]
    public static extern int NCryptFreeObject(nint hObject);

    public static void Check(int status, string what)
    {
        if (status != ERROR_SUCCESS)
            throw new NCryptException(what, status);
    }

    public static void Free(ref nint handle)
    {
        if (handle != 0)
        {
            NCryptFreeObject(handle);
            handle = 0;
        }
    }
}

public sealed class NCryptException : Exception
{
    public int Status { get; }

    public NCryptException(string what, int status)
        : base($"{what} failed: 0x{status:X8}")
    {
        Status = status;
    }
}
