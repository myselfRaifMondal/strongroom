using Strongroom.Core.Native;
using Strongroom.Core.Platform;
using Strongroom.Core.Services;
using Xunit;

namespace Strongroom.Tests;

public class LockTriggerTests
{
    [Theory]
    [InlineData(LockTriggers.WTS_SESSION_LOCK, LockReason.SessionLock)]
    [InlineData(LockTriggers.WTS_CONSOLE_DISCONNECT, LockReason.SessionDisconnect)]
    [InlineData(LockTriggers.WTS_REMOTE_DISCONNECT, LockReason.SessionDisconnect)]
    [InlineData(LockTriggers.WTS_SESSION_LOGOFF, LockReason.Logoff)]
    public void SessionEventsThatLock(int code, LockReason expected) =>
        Assert.Equal(expected, LockTriggers.ForSessionChange(code));

    [Theory]
    [InlineData(LockTriggers.WTS_CONSOLE_CONNECT)]
    [InlineData(LockTriggers.WTS_REMOTE_CONNECT)]
    [InlineData(LockTriggers.WTS_SESSION_LOGON)]
    [InlineData(LockTriggers.WTS_SESSION_UNLOCK)]
    [InlineData(0)]
    public void SessionEventsThatDoNotLock(int code) =>
        Assert.Null(LockTriggers.ForSessionChange(code));

    [Fact]
    public void LocksBeforeSleepNotOnWake()
    {
        Assert.Equal(LockReason.Suspend, LockTriggers.ForPowerBroadcast(LockTriggers.PBT_APMSUSPEND));
        Assert.Null(LockTriggers.ForPowerBroadcast(LockTriggers.PBT_APMRESUMESUSPEND));
        Assert.Null(LockTriggers.ForPowerBroadcast(LockTriggers.PBT_APMRESUMEAUTOMATIC));
    }

    [Fact]
    public void MessageWindowDeliversSessionAndPowerMessages()
    {
        using var window = new MessageWindow();
        using var triggers = new SystemLockTriggers(window);
        var seen = new System.Collections.Concurrent.BlockingCollection<LockReason>();
        triggers.LockRequested += seen.Add;

        // Messages Windows sends on Win+L, user switching and sleep, plus some that must not lock.
        Post(window, User32.WM_WTSSESSION_CHANGE, LockTriggers.WTS_SESSION_UNLOCK);
        Post(window, User32.WM_WTSSESSION_CHANGE, LockTriggers.WTS_SESSION_LOCK);
        Post(window, User32.WM_POWERBROADCAST, LockTriggers.PBT_APMRESUMEAUTOMATIC);
        Post(window, User32.WM_POWERBROADCAST, LockTriggers.PBT_APMSUSPEND);
        Post(window, User32.WM_WTSSESSION_CHANGE, LockTriggers.WTS_CONSOLE_DISCONNECT);
        Post(window, User32.WM_WTSSESSION_CHANGE, LockTriggers.WTS_SESSION_LOGOFF);

        var got = new List<LockReason>();
        for (int i = 0; i < 4; i++)
        {
            Assert.True(seen.TryTake(out var r, TimeSpan.FromSeconds(5)), $"only {got.Count} lock request(s) arrived");
            got.Add(r);
        }
        Assert.Equal(new[] { LockReason.SessionLock, LockReason.Suspend, LockReason.SessionDisconnect, LockReason.Logoff }, got);
        Assert.False(seen.TryTake(out _, TimeSpan.FromMilliseconds(200)));
    }

    [Fact]
    public void RegistersForSessionAndSuspendNotifications()
    {
        // The runner is an interactive session with the WTS service running,
        // so both registrations are expected to succeed there.
        using var window = new MessageWindow();
        using var triggers = new SystemLockTriggers(window);
        Assert.True(triggers.SessionRegistered);
        Assert.True(triggers.SuspendRegistered);
    }

    private static void Post(MessageWindow window, int msg, int wParam) =>
        Assert.True(User32.PostMessage(window.Handle, (uint)msg, wParam, 0));
}

public class AutoLockSettingTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "strongroom-autolock-" + Guid.NewGuid().ToString("N"));
    private string SettingFile => Path.Combine(_dir, "auto-lock-minutes.txt");

    public AutoLockSettingTests() => Directory.CreateDirectory(_dir);

    public void Dispose() => Directory.Delete(_dir, true);

    [Fact]
    public void OffByDefault() => Assert.Equal(AutoLockSetting.Off, new AutoLockSetting(SettingFile).Load());

    [Fact]
    public void OffersOffAnd5To60Minutes() =>
        Assert.Equal(new[] { 0, 5, 15, 30, 60 }, AutoLockSetting.Choices);

    [Theory]
    [InlineData(0)]
    [InlineData(5)]
    [InlineData(15)]
    [InlineData(30)]
    [InlineData(60)]
    public void RoundTrips(int minutes)
    {
        var s = new AutoLockSetting(SettingFile);
        s.Save(minutes);
        Assert.Equal(minutes, new AutoLockSetting(SettingFile).Load());
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(1)]
    [InlineData(240)]
    public void RejectsOtherValues(int minutes) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => new AutoLockSetting(SettingFile).Save(minutes));

    [Theory]
    [InlineData("")]
    [InlineData("abc")]
    [InlineData("7")]
    [InlineData("-5")]
    [InlineData("99999999999")]
    public void UnreadableValueReadsAsOff(string text)
    {
        File.WriteAllText(SettingFile, text);
        Assert.Equal(AutoLockSetting.Off, new AutoLockSetting(SettingFile).Load());
    }
}

public class IdleLockTests
{
    private long _now = 1_000_000;

    private IdleLock Make(int minutes) => new(minutes, () => _now);

    private void Advance(TimeSpan t) => _now += (long)t.TotalMilliseconds;

    [Fact]
    public void OffNeverExpires()
    {
        var idle = Make(0);
        Assert.Null(idle.Timeout);
        Advance(TimeSpan.FromDays(30));
        Assert.False(idle.Expired);
        Assert.False(idle.Interact());
    }

    [Fact]
    public void ExpiresAfterTimeoutWithoutInteraction()
    {
        var idle = Make(5);
        Advance(TimeSpan.FromMinutes(5) - TimeSpan.FromSeconds(1));
        Assert.False(idle.Expired);
        Advance(TimeSpan.FromSeconds(1));
        Assert.True(idle.Expired);
    }

    [Fact]
    public void InteractionExtendsBeforeDeadline()
    {
        var idle = Make(5);
        Advance(TimeSpan.FromMinutes(4));
        Assert.False(idle.Interact());
        Advance(TimeSpan.FromMinutes(4));
        Assert.False(idle.Expired);
    }

    [Fact]
    public void InteractionAfterDeadlineLocksAndDoesNotExtend()
    {
        var idle = Make(15);
        Advance(TimeSpan.FromMinutes(16));
        Assert.True(idle.Interact());
        Assert.True(idle.Expired); // still expired: the caller must lock
    }

    [Fact]
    public void ResetOnUnlockStartsAgain()
    {
        var idle = Make(5);
        Advance(TimeSpan.FromMinutes(10));
        idle.Reset();
        Assert.False(idle.Expired);
    }

    [Fact]
    public void ChangingTheSettingRestartsTheTimeout()
    {
        var idle = Make(0);
        Advance(TimeSpan.FromHours(2));
        idle.SetMinutes(30);
        Assert.Equal(TimeSpan.FromMinutes(30), idle.Timeout);
        Assert.False(idle.Expired);
        Advance(TimeSpan.FromMinutes(30));
        Assert.True(idle.Expired);
        idle.SetMinutes(0);
        Assert.False(idle.Expired);
    }

    [Fact]
    public void ChecksEvery15Seconds() => Assert.Equal(TimeSpan.FromSeconds(15), IdleLock.CheckInterval);
}

public class LockGenerationTests
{
    [Fact]
    public void TokenStaysCurrentWithoutALock()
    {
        var g = new LockGeneration();
        var token = g.Current;
        Assert.True(g.IsCurrent(token));
    }

    [Fact]
    public void LockDuringUnlockMakesTokenStale()
    {
        var g = new LockGeneration();
        var token = g.Current;
        g.Advance(); // e.g. Win+L or sleep while Argon2id runs
        Assert.False(g.IsCurrent(token));
        Assert.True(g.IsCurrent(g.Current));
    }
}
