using System.Text;
using Strongroom.Core.Services;
using Strongroom.Ffi;
using Xunit;

namespace Strongroom.Tests;

/// <summary>
/// Threat model residual risk 3: a tampered UnlockGate state must force the
/// master password. Uses the real DPAPI key for the current test user.
/// </summary>
public class GateSealTests
{
    private const long Now = 1_750_000_000;

    private sealed class NoKey : IGateSealKey
    {
        public byte[]? Seal(byte[] message) => null;
        public bool IsValid(byte[] seal, byte[] message) => false;
    }

    private static PasswordRequiredReason Check(SealedUnlockGate gate, long now) =>
        gate.Check(now, rebootedSinceLastPassword: false, enrollmentChanged: false, hasDeviceKey: true);

    private static void WithGate(Action<SealedUnlockGate, string> body, IGateSealKey? key = null)
    {
        var dir = Directory.CreateTempSubdirectory("sr-seal-").FullName;
        try
        {
            using var gate = new SealedUnlockGate(
                Path.Combine(dir, "unlock-gate.state"), Path.Combine(dir, "unlock-gate.seal"), key ?? new DpapiGateSealKey());
            body(gate, dir);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void DpapiKeyRejectsChangedMessageAndOtherKey()
    {
        var key = new DpapiGateSealKey();
        var msg = Encoding.UTF8.GetBytes("SRGATE1\n1\n0\n");
        var seal = key.Seal(msg);
        Assert.NotNull(seal);
        Assert.True(key.IsValid(seal!, msg));
        Assert.False(key.IsValid(seal!, Encoding.UTF8.GetBytes("SRGATE1\n2\n0\n")));
        Assert.False(new DpapiGateSealKey("other").IsValid(seal!, msg));
        Assert.False(key.IsValid([1, 2, 3], msg));
    }

    [Fact]
    public void SealedStateAllowsBiometrics() => WithGate((gate, _) =>
    {
        Assert.Equal(PasswordRequiredReason.PeriodicCheck, Check(gate, Now));
        gate.RecordPasswordUnlock(Now);
        Assert.True(gate.StateIsIntact());
        Assert.Equal(PasswordRequiredReason.NotRequired, Check(gate, Now + 60));
        gate.RecordBiometricFailure();
        gate.RecordBiometricSuccess();
        Assert.Equal(PasswordRequiredReason.NotRequired, Check(gate, Now + 60));
    });

    [Fact]
    public void ResetFailureCounterForcesPassword() => WithGate((gate, _) =>
    {
        gate.RecordPasswordUnlock(Now);
        for (int i = 0; i < 5; i++)
            gate.RecordBiometricFailure();
        Assert.Equal(PasswordRequiredReason.TooManyBiometricFailures, Check(gate, Now + 60));

        // Attacker rewrites the counter to 0 (valid core format, old seal).
        File.WriteAllText(gate.StatePath, $"SRGATE1\n{Now}\n0\n");
        Assert.False(gate.StateIsIntact());
        Assert.Equal(PasswordRequiredReason.PeriodicCheck, Check(gate, Now + 60));
        Assert.False(File.Exists(gate.StatePath));

        gate.RecordBiometricFailure();
        Assert.Equal(PasswordRequiredReason.PeriodicCheck, Check(gate, Now + 60));

        gate.RecordPasswordUnlock(Now + 120);
        Assert.Equal(PasswordRequiredReason.NotRequired, Check(gate, Now + 180));
    });

    [Fact]
    public void MissingForgedOrLegacySealForcesPassword() => WithGate((gate, _) =>
    {
        gate.RecordPasswordUnlock(Now);
        File.Delete(gate.SealPath);
        Assert.Equal(PasswordRequiredReason.PeriodicCheck, Check(gate, Now + 60));

        gate.RecordPasswordUnlock(Now);
        File.WriteAllBytes(gate.SealPath, new DpapiGateSealKey("other").Seal(File.ReadAllBytes(gate.StatePath))!);
        Assert.Equal(PasswordRequiredReason.PeriodicCheck, Check(gate, Now + 60));

        // A state file written before sealing existed.
        File.WriteAllText(gate.StatePath, $"SRGATE1\n{Now}\n0\n");
        Assert.Equal(PasswordRequiredReason.PeriodicCheck, Check(gate, Now + 60));
    });

    [Fact]
    public void SealIsBoundToItsStateFile() => WithGate((gate, dir) =>
    {
        gate.RecordPasswordUnlock(Now);
        using var other = new SealedUnlockGate(
            Path.Combine(dir, "other.state"), Path.Combine(dir, "other.seal"), new DpapiGateSealKey());
        File.Copy(gate.StatePath, other.StatePath);
        File.Copy(gate.SealPath, other.SealPath);
        Assert.Equal(PasswordRequiredReason.NotRequired, Check(gate, Now + 60));
        Assert.Equal(PasswordRequiredReason.PeriodicCheck, Check(other, Now + 60));
    });

    [Fact]
    public void NoSealKeyFailsClosed() => WithGate((gate, _) =>
    {
        gate.RecordPasswordUnlock(Now);
        Assert.False(File.Exists(gate.SealPath));
        Assert.Equal(PasswordRequiredReason.PeriodicCheck, Check(gate, Now + 60));
    }, new NoKey());
}
