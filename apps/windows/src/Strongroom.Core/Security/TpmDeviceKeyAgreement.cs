using Strongroom.Ffi;

namespace Strongroom.Core.Security;

/// <summary>Asks the user to prove presence (Windows Hello) before each hardware ECDH.</summary>
public interface IUserPresence
{
    /// <summary>Blocking; returns false on cancel, failure or unavailability.</summary>
    bool Verify(string message);
}

/// <summary>
/// The core's <see cref="DeviceKeyAgreement"/> callback over a CNG key.
/// Every agreement is gated on <see cref="IUserPresence"/>; any failure is
/// reported as UnlockFailed so the UI cannot learn which factor was wrong.
/// </summary>
public sealed class TpmDeviceKeyAgreement : DeviceKeyAgreement
{
    private readonly CngDeviceKey _key;
    private readonly IUserPresence _presence;
    private readonly string _prompt;

    public TpmDeviceKeyAgreement(CngDeviceKey key, IUserPresence presence, string prompt = "Unlock Strongroom")
    {
        _key = key;
        _presence = presence;
        _prompt = prompt;
    }

    public byte[] PublicKey() => _key.PublicKey();

    public byte[] Agree(byte[] peerPublicKey)
    {
        if (!_presence.Verify(_prompt))
            throw new StrongroomException.UnlockFailed();
        try
        {
            return _key.Agree(peerPublicKey);
        }
        catch (Exception)
        {
            throw new StrongroomException.UnlockFailed();
        }
    }
}
