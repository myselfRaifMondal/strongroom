using Strongroom.Core.Native;
using Strongroom.Core.Services;

namespace Strongroom.Core.Platform;

/// <summary>
/// Session lock, user switching, logoff and suspend notifications, received
/// by the message-only window. A message-only window gets no broadcasts, so
/// it registers explicitly: WTSRegisterSessionNotification for session
/// changes and RegisterSuspendResumeNotification for PBT_APMSUSPEND.
/// </summary>
public sealed class SystemLockTriggers : IDisposable
{
    private readonly MessageWindow _window;
    private nint _suspendHandle;

    /// <summary>
    /// Raised on the message window thread. For <see cref="LockReason.Suspend"/>
    /// the system waits for the handler to return before it sleeps, so lock
    /// synchronously (with a short timeout) rather than fire-and-forget.
    /// </summary>
    public event Action<LockReason>? LockRequested;

    public bool SessionRegistered { get; private set; }
    public bool SuspendRegistered => _suspendHandle != 0;

    public SystemLockTriggers(MessageWindow window)
    {
        _window = window;
        _window.SessionChange += OnSessionChange;
        _window.PowerBroadcast += OnPowerBroadcast;
        _window.Invoke(() =>
        {
            SessionRegistered = WtsApi32.WTSRegisterSessionNotification(_window.Handle, WtsApi32.NOTIFY_FOR_THIS_SESSION);
            _suspendHandle = User32.RegisterSuspendResumeNotification(_window.Handle, User32.DEVICE_NOTIFY_WINDOW_HANDLE);
        });
    }

    private void OnSessionChange(nint wParam)
    {
        if (LockTriggers.ForSessionChange(wParam) is { } reason)
            LockRequested?.Invoke(reason);
    }

    private void OnPowerBroadcast(nint wParam)
    {
        if (LockTriggers.ForPowerBroadcast(wParam) is { } reason)
            LockRequested?.Invoke(reason);
    }

    public void Dispose()
    {
        _window.SessionChange -= OnSessionChange;
        _window.PowerBroadcast -= OnPowerBroadcast;
        if (_window.Handle == 0)
            return;
        _window.Invoke(() =>
        {
            if (SessionRegistered)
                WtsApi32.WTSUnRegisterSessionNotification(_window.Handle);
            if (_suspendHandle != 0)
                User32.UnregisterSuspendResumeNotification(_suspendHandle);
        });
        SessionRegistered = false;
        _suspendHandle = 0;
    }
}
