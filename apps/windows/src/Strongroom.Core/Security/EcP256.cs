using System.Buffers.Binary;
using Strongroom.Core.Native;

namespace Strongroom.Core.Security;

/// <summary>CNG key storage provider names.</summary>
public static class KeyProviders
{
    /// <summary>TPM-backed; the only provider used for real device keys.</summary>
    public const string PlatformTpm = NCrypt.MS_PLATFORM_CRYPTO_PROVIDER;
    /// <summary>Software KSP; diagnostics and tests only.</summary>
    public const string Software = NCrypt.MS_KEY_STORAGE_PROVIDER;
}

/// <summary>Pure byte-layout helpers for P-256 keys moving between CNG and the core.</summary>
public static class EcP256
{
    public const int CoordinateSize = 32;
    public const int Sec1UncompressedSize = 1 + 2 * CoordinateSize; // 65
    private const int BlobHeaderSize = 8; // BCRYPT_ECCKEY_BLOB { ULONG dwMagic; ULONG cbKey; }

    /// <summary>BCRYPT_ECCPUBLIC_BLOB (ECK1) -> 65-byte uncompressed SEC1 (0x04 || X || Y).</summary>
    public static byte[] BlobToSec1(ReadOnlySpan<byte> blob)
    {
        if (blob.Length != BlobHeaderSize + 2 * CoordinateSize)
            throw new ArgumentException($"unexpected ECC public blob length {blob.Length}");
        uint magic = BinaryPrimitives.ReadUInt32LittleEndian(blob);
        uint cbKey = BinaryPrimitives.ReadUInt32LittleEndian(blob[4..]);
        if (magic != NCrypt.BCRYPT_ECDH_PUBLIC_P256_MAGIC || cbKey != CoordinateSize)
            throw new ArgumentException("not a P-256 ECDH public blob");
        var sec1 = new byte[Sec1UncompressedSize];
        sec1[0] = 0x04;
        blob[BlobHeaderSize..].CopyTo(sec1.AsSpan(1)); // X and Y are big-endian in the blob
        return sec1;
    }

    /// <summary>65-byte uncompressed SEC1 -> BCRYPT_ECCPUBLIC_BLOB for NCryptImportKey.</summary>
    public static byte[] Sec1ToBlob(ReadOnlySpan<byte> sec1)
    {
        if (sec1.Length != Sec1UncompressedSize || sec1[0] != 0x04)
            throw new ArgumentException("peer key must be a 65-byte uncompressed SEC1 point");
        var blob = new byte[BlobHeaderSize + 2 * CoordinateSize];
        BinaryPrimitives.WriteUInt32LittleEndian(blob, NCrypt.BCRYPT_ECDH_PUBLIC_P256_MAGIC);
        BinaryPrimitives.WriteUInt32LittleEndian(blob.AsSpan(4), CoordinateSize);
        sec1[1..].CopyTo(blob.AsSpan(BlobHeaderSize));
        return blob;
    }

    /// <summary>
    /// NCryptDeriveKey(BCRYPT_KDF_RAW_SECRET) returns the shared x-coordinate
    /// little-endian. The core expects the SEC1/RFC 9180 big-endian encoding.
    /// </summary>
    public static byte[] RawSecretToBigEndian(ReadOnlySpan<byte> littleEndian)
    {
        if (littleEndian.Length != CoordinateSize)
            throw new ArgumentException($"raw secret must be {CoordinateSize} bytes, got {littleEndian.Length}");
        var be = littleEndian.ToArray();
        Array.Reverse(be);
        return be;
    }
}
