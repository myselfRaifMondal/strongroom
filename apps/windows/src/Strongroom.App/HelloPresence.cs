using Strongroom.Core.Security;
using Windows.Security.Credentials.UI;

namespace Strongroom.App;

/// <summary>
/// Windows Hello user verification (face / fingerprint / PIN) parented to our
/// window. Called from a background thread (the core's DeviceKeyAgreement
/// callback runs on the thread that called into the vault), so blocking on
/// the async operation is safe.
/// </summary>
public sealed class HelloPresence : IUserPresence
{
    private readonly Func<nint> _owner;

    public HelloPresence(Func<nint> owner) => _owner = owner;

    public static async Task<bool> IsAvailableAsync()
    {
        try
        {
            return await UserConsentVerifier.CheckAvailabilityAsync() == UserConsentVerifierAvailability.Available;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public bool Verify(string message)
    {
        try
        {
            var op = UserConsentVerifierInterop.RequestVerificationForWindowAsync(_owner(), message);
            var result = op.AsTask().GetAwaiter().GetResult();
            Diag.Log($"hello verification: {result}");
            return result == UserConsentVerificationResult.Verified;
        }
        catch (Exception e)
        {
            Diag.Log($"hello verification error: {e.GetType().Name}");
            return false;
        }
    }
}
