using Strongroom.Core.Native;
using Strongroom.Core.Security;
using Strongroom.Ffi;

namespace Strongroom.Core.Services;

/// <summary>
/// Windows Hello unlock: a TPM-resident P-256 key (Platform Crypto Provider)
/// plus the vault key HPKE-sealed to it by the core. Where no usable TPM
/// exists the feature reports itself unavailable and password unlock is the
/// only path.
/// </summary>
public sealed class DeviceUnlock
{
    private readonly AppPaths _paths;
    private readonly IUserPresence _presence;
    private readonly string _provider;

    public DeviceUnlock(AppPaths paths, IUserPresence presence, string provider = NCrypt.MS_PLATFORM_CRYPTO_PROVIDER)
    {
        _paths = paths;
        _presence = presence;
        _provider = provider;
    }

    /// <summary>Probes the TPM with an ephemeral key; null when usable, else the reason.</summary>
    public string? UnavailableReason()
    {
        var r = DeviceKeyProbe.Run(_provider);
        if (!r.ProviderOpened) return "No TPM key storage provider on this PC.";
        if (!r.KeyCreated) return "The TPM cannot create a P-256 key agreement key.";
        if (!r.AgreementMatches) return "The TPM key agreement self-check failed.";
        return null;
    }

    public bool IsEnrolled => File.Exists(_paths.DeviceWrappedKey) && OpenKey() is { } k && Dispose(k);

    /// <summary>Creates the TPM key and stores the vault key sealed to it. Requires an unlocked vault.</summary>
    public void Enroll(Strongroom.Ffi.Vault vault, nint ownerWindow)
    {
        if (!_presence.Verify("Turn on Windows Hello unlock for Strongroom"))
            throw new StrongroomException.UnlockFailed();
        using var key = CngDeviceKey.Create(_provider, CngDeviceKey.DefaultKeyName, uiPolicyDescription: null, ownerWindow: ownerWindow);
        byte[] wrapped = vault.WrapVaultKeyForDevice(key.PublicKey());
        File.WriteAllBytes(_paths.DeviceWrappedKey, wrapped);
    }

    public Strongroom.Ffi.Vault Unlock()
    {
        byte[] wrapped = File.ReadAllBytes(_paths.DeviceWrappedKey);
        using var key = OpenKey() ?? throw new StrongroomException.UnlockFailed();
        var agreement = new TpmDeviceKeyAgreement(key, _presence);
        return Strongroom.Ffi.Vault.UnlockWithDeviceKey(_paths.VaultFile, wrapped, agreement);
    }

    public void Disable()
    {
        if (File.Exists(_paths.DeviceWrappedKey))
            File.Delete(_paths.DeviceWrappedKey);
        try { CngDeviceKey.Delete(_provider); } catch (NCryptException) { }
    }

    private CngDeviceKey? OpenKey()
    {
        try { return CngDeviceKey.Open(_provider); }
        catch (NCryptException) { return null; }
    }

    private static bool Dispose(IDisposable d)
    {
        d.Dispose();
        return true;
    }
}
