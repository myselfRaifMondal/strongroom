using System.Runtime.InteropServices;

namespace Strongroom.Core.Native;

/// <summary>DPAPI (crypt32.dll) P/Invoke surface used by the unlock gate seal.</summary>
internal static class Crypt32
{
    public const uint CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    public struct DATA_BLOB
    {
        public int cbData;
        public nint pbData;
    }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CryptProtectData(ref DATA_BLOB pDataIn, string? szDataDescr, ref DATA_BLOB pOptionalEntropy,
        nint pvReserved, nint pPromptStruct, uint dwFlags, out DATA_BLOB pDataOut);

    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CryptUnprotectData(ref DATA_BLOB pDataIn, nint ppszDataDescr, ref DATA_BLOB pOptionalEntropy,
        nint pvReserved, nint pPromptStruct, uint dwFlags, out DATA_BLOB pDataOut);

    [DllImport("kernel32.dll")]
    public static extern nint LocalFree(nint hMem);

    /// <summary>CryptProtectData / CryptUnprotectData for the current user, no UI. Null on failure.</summary>
    public static unsafe byte[]? Run(bool protect, byte[] data, byte[] entropy)
    {
        fixed (byte* pData = data)
        fixed (byte* pEntropy = entropy)
        {
            var input = new DATA_BLOB { cbData = data.Length, pbData = (nint)pData };
            var ent = new DATA_BLOB { cbData = entropy.Length, pbData = (nint)pEntropy };
            DATA_BLOB output;
            bool ok = protect
                ? CryptProtectData(ref input, null, ref ent, 0, 0, CRYPTPROTECT_UI_FORBIDDEN, out output)
                : CryptUnprotectData(ref input, 0, ref ent, 0, 0, CRYPTPROTECT_UI_FORBIDDEN, out output);
            if (!ok)
                return null;
            try
            {
                var result = new byte[output.cbData];
                Marshal.Copy(output.pbData, result, 0, output.cbData);
                return result;
            }
            finally
            {
                LocalFree(output.pbData);
            }
        }
    }
}
