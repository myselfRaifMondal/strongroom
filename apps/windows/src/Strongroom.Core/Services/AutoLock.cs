using System.Globalization;

namespace Strongroom.Core.Services;

/// <summary>Why the app locked the vault by itself. Non-secret; safe to log.</summary>
public enum LockReason
{
    SessionLock,
    SessionDisconnect,
    Logoff,
    Suspend,
    Idle,
}

/// <summary>
/// Maps Win32 session and power notifications to lock reasons (see
/// OPEN-QUESTIONS OQ-W7). Pure, so it is unit-tested without Win32 events.
/// </summary>
public static class LockTriggers
{
    // WM_WTSSESSION_CHANGE wParam (wtsapi32.h).
    public const int WTS_CONSOLE_CONNECT = 0x1;
    public const int WTS_CONSOLE_DISCONNECT = 0x2;
    public const int WTS_REMOTE_CONNECT = 0x3;
    public const int WTS_REMOTE_DISCONNECT = 0x4;
    public const int WTS_SESSION_LOGON = 0x5;
    public const int WTS_SESSION_LOGOFF = 0x6;
    public const int WTS_SESSION_LOCK = 0x7;
    public const int WTS_SESSION_UNLOCK = 0x8;

    // WM_POWERBROADCAST wParam (winuser.h).
    public const int PBT_APMSUSPEND = 0x4;
    public const int PBT_APMRESUMESUSPEND = 0x7;
    public const int PBT_APMRESUMEAUTOMATIC = 0x12;

    /// <summary>Win+L, user switching (console or remote disconnect) and logoff lock; connects and unlocks do not.</summary>
    public static LockReason? ForSessionChange(nint wParam) => (int)wParam switch
    {
        WTS_SESSION_LOCK => LockReason.SessionLock,
        WTS_CONSOLE_DISCONNECT or WTS_REMOTE_DISCONNECT => LockReason.SessionDisconnect,
        WTS_SESSION_LOGOFF => LockReason.Logoff,
        _ => null,
    };

    /// <summary>Lock before sleep or hibernate, never on wake.</summary>
    public static LockReason? ForPowerBroadcast(nint wParam) =>
        (int)wParam == PBT_APMSUSPEND ? LockReason.Suspend : null;
}

/// <summary>
/// The inactivity lock choice, stored as plain text minutes in the app's data
/// folder (non-secret). Off by default; anything unreadable reads as off.
/// </summary>
public sealed class AutoLockSetting
{
    public const int Off = 0;
    public static IReadOnlyList<int> Choices { get; } = new[] { Off, 5, 15, 30, 60 };

    private readonly string _file;

    public AutoLockSetting(string file) => _file = file;

    public int Load()
    {
        try
        {
            var minutes = int.Parse(File.ReadAllText(_file).Trim(), NumberStyles.None, CultureInfo.InvariantCulture);
            return Choices.Contains(minutes) ? minutes : Off;
        }
        catch (Exception)
        {
            return Off;
        }
    }

    public void Save(int minutes)
    {
        if (!Choices.Contains(minutes))
            throw new ArgumentOutOfRangeException(nameof(minutes), "Choose off, 5, 15, 30 or 60 minutes.");
        File.WriteAllText(_file, minutes.ToString(CultureInfo.InvariantCulture));
    }
}

/// <summary>
/// Inactivity deadline since the last Strongroom interaction. Uses the
/// monotonic tick count, so changing the wall clock does not move it. An
/// interaction after the deadline has passed never extends the session: the
/// caller must lock instead.
/// </summary>
public sealed class IdleLock
{
    /// <summary>How often the app checks the deadline while unlocked.</summary>
    public static readonly TimeSpan CheckInterval = TimeSpan.FromSeconds(15);

    private readonly Func<long> _nowMs;
    private long _lastMs;

    public IdleLock(int minutes, Func<long>? nowMs = null)
    {
        _nowMs = nowMs ?? (() => Environment.TickCount64);
        SetMinutes(minutes);
    }

    /// <summary>Null when the inactivity lock is off.</summary>
    public TimeSpan? Timeout { get; private set; }

    /// <summary>Changes the timeout and starts it again from now.</summary>
    public void SetMinutes(int minutes)
    {
        if (minutes < 0)
            throw new ArgumentOutOfRangeException(nameof(minutes));
        Timeout = minutes == AutoLockSetting.Off ? null : TimeSpan.FromMinutes(minutes);
        Reset();
    }

    /// <summary>Starts the timeout from now (call on unlock).</summary>
    public void Reset() => _lastMs = _nowMs();

    public bool Expired => Timeout is { } t && _nowMs() - _lastMs >= (long)t.TotalMilliseconds;

    /// <summary>Records an interaction. Returns true when the deadline had already passed (lock, do not extend).</summary>
    public bool Interact()
    {
        if (Expired)
            return true;
        _lastMs = _nowMs();
        return false;
    }
}
