namespace Strongroom.Core.Services;

/// <summary>Per-user local storage locations. Nothing here is ever synced or uploaded.</summary>
public sealed class AppPaths
{
    public string Root { get; }
    public string VaultFile => Path.Combine(Root, "vault.srdb");
    public string GateState => Path.Combine(Root, "unlock-gate.state");
    /// <summary>DPAPI seal over <see cref="GateState"/> (see <see cref="SealedUnlockGate"/>).</summary>
    public string GateSeal => Path.Combine(Root, "unlock-gate.seal");
    public string DeviceWrappedKey => Path.Combine(Root, "device-wrapped.key");
    public string LastPasswordBoot => Path.Combine(Root, "last-password-boot.txt");
    /// <summary>Inactivity lock choice in minutes (non-secret, see <see cref="AutoLockSetting"/>).</summary>
    public string AutoLockMinutes => Path.Combine(Root, "auto-lock-minutes.txt");

    public AppPaths(string? root = null)
    {
        Root = root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Strongroom");
        Directory.CreateDirectory(Root);
    }

    public bool VaultExists => File.Exists(VaultFile);
}

public static class Clock
{
    public static long Now() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();
}
