using System.Security.Cryptography;
using System.Text;
using Strongroom.Core.Native;
using Strongroom.Ffi;

namespace Strongroom.Core.Services;

/// <summary>Makes and checks the seal over the gate state. Must not need user presence.</summary>
public interface IGateSealKey
{
    /// <summary>Null when no seal can be made.</summary>
    byte[]? Seal(byte[] message);

    bool IsValid(byte[] seal, byte[] message);
}

/// <summary>
/// DPAPI for the current user. The seal is the DPAPI blob of the message; it
/// carries DPAPI's own integrity check, and making one needs the user's DPAPI
/// master key, which an attacker with only the files on disk does not have.
/// </summary>
public sealed class DpapiGateSealKey : IGateSealKey
{
    private readonly byte[] _entropy;

    public DpapiGateSealKey(string entropy = "strongroom-gate-seal-v1") => _entropy = Encoding.UTF8.GetBytes(entropy);

    public byte[]? Seal(byte[] message) => Crypt32.Run(protect: true, message, _entropy);

    public bool IsValid(byte[] seal, byte[] message) =>
        Crypt32.Run(protect: false, seal, _entropy) is { } opened
        && CryptographicOperations.FixedTimeEquals(opened, message);
}

/// <summary>
/// <c>UnlockGate</c> plus an integrity seal over its state file, kept in a
/// sibling file (threat model residual risk 3). The core file format and the
/// FFI are unchanged.
///
/// A state file with a missing or invalid seal is treated as tampered and
/// deleted; the core reads a missing file as "never unlocked with the
/// password", so the master password is required (fail closed). After each
/// write the state is sealed again; if that fails the seal is removed, which
/// also fails closed. Not covered: replaying an older state file together
/// with its seal.
/// </summary>
public sealed class SealedUnlockGate : IDisposable
{
    private static readonly byte[] Domain = Encoding.UTF8.GetBytes("strongroom-gate-seal-v1\0");
    private static readonly object Lock = new();

    private readonly UnlockGate _gate;
    private readonly IGateSealKey _key;

    public string StatePath { get; }
    public string SealPath { get; }

    public SealedUnlockGate(string statePath, string sealPath, IGateSealKey key)
    {
        _gate = new UnlockGate(statePath);
        StatePath = statePath;
        SealPath = sealPath;
        _key = key;
    }

    /// <summary>Domain tag, then the state file's name, then its exact bytes.</summary>
    private byte[] Message(byte[] state) =>
        [.. Domain, .. Encoding.UTF8.GetBytes(Path.GetFileName(StatePath)), 0, .. state];

    /// <summary>True when the state file is absent or carries a valid seal.</summary>
    public bool StateIsIntact()
    {
        if (!File.Exists(StatePath))
            return true;
        try
        {
            return _key.IsValid(File.ReadAllBytes(SealPath), Message(File.ReadAllBytes(StatePath)));
        }
        catch (Exception)
        {
            return false;
        }
    }

    private void DropTamperedState()
    {
        if (StateIsIntact())
            return;
        TryDelete(StatePath);
        TryDelete(SealPath);
    }

    private void Reseal()
    {
        try
        {
            if (_key.Seal(Message(File.ReadAllBytes(StatePath))) is { } seal)
            {
                var tmp = SealPath + ".tmp";
                File.WriteAllBytes(tmp, seal);
                File.Move(tmp, SealPath, overwrite: true);
                return;
            }
        }
        catch (Exception)
        {
        }
        TryDelete(SealPath);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (Exception) { }
    }

    public PasswordRequiredReason Check(long now, bool rebootedSinceLastPassword, bool enrollmentChanged, bool hasDeviceKey)
    {
        lock (Lock)
        {
            DropTamperedState();
            return _gate.Check(now, rebootedSinceLastPassword, enrollmentChanged, hasDeviceKey);
        }
    }

    public void RecordPasswordUnlock(long now)
    {
        lock (Lock)
        {
            _gate.RecordPasswordUnlock(now);
            Reseal();
        }
    }

    public void RecordBiometricFailure()
    {
        lock (Lock)
        {
            DropTamperedState();
            _gate.RecordBiometricFailure();
            Reseal();
        }
    }

    public void RecordBiometricSuccess()
    {
        lock (Lock)
        {
            DropTamperedState();
            _gate.RecordBiometricSuccess();
            Reseal();
        }
    }

    public void Dispose() => _gate.Dispose();
}
