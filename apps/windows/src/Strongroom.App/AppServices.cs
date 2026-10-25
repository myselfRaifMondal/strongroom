using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Strongroom.Core.Platform;
using Strongroom.Core.Services;
using Strongroom.Ffi;

namespace Strongroom.App;

/// <summary>Process-wide services. Exactly one vault may be unlocked at a time.</summary>
public static class AppServices
{
    public static AppPaths Paths { get; } = new(Environment.GetEnvironmentVariable("STRONGROOM_DATA_DIR") is { Length: > 0 } d ? d : null);

    public static MainWindow? Main { get; private set; }
    public static MessageWindow? Messages { get; private set; }
    public static SecureClipboard? Clipboard { get; private set; }
    public static GlobalHotkey? Hotkey { get; private set; }
    public static SystemLockTriggers? SystemTriggers { get; private set; }
    public static AutoLockSetting AutoLock { get; } = new(Paths.AutoLockMinutes);
    public static IdleLock Idle { get; } = new(AutoLock.Load());
    public static AutoType AutoType { get; } = new();
    public static UnlockSignals Signals { get; } = new(Paths.LastPasswordBoot);
    public static DeviceUnlock Device { get; } = new(Paths, new HelloPresence(() => Main?.Hwnd ?? 0));

    private static Vault? s_vault;
    private static QuickAccessWindow? s_overlay;
    private static DispatcherQueueTimer? s_idleTimer;

    public static Vault? Vault => s_vault is { } v && !v.IsLocked() ? v : null;

    public static event Action? VaultChanged;

    public static void Start(MainWindow main)
    {
        Main = main;
        var dq = DispatcherQueue.GetForCurrentThread();
        try
        {
            Messages = new MessageWindow();
            Clipboard = new SecureClipboard(new Win32Clipboard(Messages.Handle));
            Diag.Log("clipboard: Win32 with history/cloud/monitor exclusion, auto-clear 25 s");
        }
        catch (Exception e)
        {
            Diag.Log($"clipboard/message window unavailable: {e.Message}");
        }

        if (Messages is not null)
        {
            try
            {
                Hotkey = new GlobalHotkey(Messages);
                Hotkey.Pressed += () => dq.TryEnqueue(() =>
                {
                    NoteInteraction();
                    ShowQuickAccess();
                });
                Diag.Log("hotkey: Ctrl+Shift+Space registered");
            }
            catch (Exception e)
            {
                Diag.Log($"hotkey: not registered ({e.Message})");
            }

            try
            {
                SystemTriggers = new SystemLockTriggers(Messages);
                SystemTriggers.LockRequested += reason => LockFromMessageThread(dq, reason);
                Diag.Log($"lock triggers: session notifications = {SystemTriggers.SessionRegistered}, suspend notifications = {SystemTriggers.SuspendRegistered}");
            }
            catch (Exception e)
            {
                Diag.Log($"lock triggers: not registered ({e.Message})");
            }
        }

        s_idleTimer = dq.CreateTimer();
        s_idleTimer.Interval = IdleLock.CheckInterval;
        s_idleTimer.Tick += (_, _) => CheckIdle();
        s_idleTimer.Start();
        WatchInteraction(main);
        main.Activated += (_, _) => CheckIdle();
        Diag.Log($"idle lock: {(Idle.Timeout is { } t ? $"{t.TotalMinutes} min" : "off")}");

        main.Closed += (_, _) => Shutdown();
    }

    public static SealedUnlockGate OpenGate() => new(Paths.GateState, Paths.GateSeal, new DpapiGateSealKey());

    public static void RecordPasswordUnlock()
    {
        try
        {
            using var gate = OpenGate();
            gate.RecordPasswordUnlock(Clock.Now());
        }
        catch (Exception e)
        {
            Diag.Log($"unlock gate: record password unlock failed ({e.GetType().Name})");
        }
        Signals.RecordPasswordUnlock();
    }

    /// <summary>Why the password is required right now (NotRequired means Hello may be offered).</summary>
    public static PasswordRequiredReason PasswordRequired()
    {
        try
        {
            bool hasKey = Device.IsEnrolled;
            using var gate = OpenGate();
            return gate.Check(Clock.Now(), Signals.RebootedSinceLastPassword(), Signals.EnrollmentChanged(), hasKey);
        }
        catch (Exception)
        {
            return PasswordRequiredReason.NoBiometricKey; // fail safe
        }
    }

    public static void SetVault(Vault vault)
    {
        s_vault?.Dispose();
        s_vault = vault;
        Idle.Reset();
        VaultChanged?.Invoke();
    }

    public static void Lock()
    {
        Clipboard?.ClearIfOurs();
        if (s_vault is { } v)
        {
            try { v.Lock(); } catch (Exception) { }
            v.Dispose();
        }
        s_vault = null;
        s_overlay?.Close();
        HideDialogs();
        VaultChanged?.Invoke();
    }

    /// <summary>Lock for a system event or inactivity (OQ-W7). Clears our clipboard secret even when already locked.</summary>
    public static void AutoLockNow(LockReason reason)
    {
        Diag.Log($"auto-lock: {reason}");
        if (s_vault is null && s_overlay is null)
        {
            Clipboard?.ClearIfOurs();
            return;
        }
        Lock();
    }

    public static void SetAutoLockMinutes(int minutes)
    {
        AutoLock.Save(minutes);
        Idle.SetMinutes(minutes);
        Diag.Log($"idle lock: {(minutes == AutoLockSetting.Off ? "off" : $"{minutes} min")}");
    }

    /// <summary>A key, click or wheel in our windows, or the hotkey. An expired session locks instead of being extended.</summary>
    public static void NoteInteraction()
    {
        if (s_vault is not null && Idle.Interact())
            AutoLockNow(LockReason.Idle);
    }

    public static void WatchInteraction(Window window)
    {
        if (window.Content is not UIElement root) return;
        root.PreviewKeyDown += (_, _) => NoteInteraction();
        root.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => NoteInteraction()), true);
        root.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler((_, _) => NoteInteraction()), true);
    }

    private static void CheckIdle()
    {
        if (s_vault is not null && Idle.Expired)
            AutoLockNow(LockReason.Idle);
    }

    private static void LockFromMessageThread(DispatcherQueue dq, LockReason reason)
    {
        var done = new ManualResetEventSlim();
        if (!dq.TryEnqueue(DispatcherQueuePriority.High, () =>
            {
                try { AutoLockNow(reason); }
                finally { done.Set(); }
            }))
            return;
        // Windows waits for WM_POWERBROADCAST to return before it sleeps
        // (about 2 s at most), so the lock happens before sleep, not on wake.
        if (reason == LockReason.Suspend)
            done.Wait(TimeSpan.FromMilliseconds(1500));
    }

    /// <summary>Closes open dialogs in the main window (export, import, confirmations): they return "cancel".</summary>
    private static void HideDialogs()
    {
        if (Main?.Content?.XamlRoot is not { } root) return;
        try
        {
            foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(root))
                if (popup.Child is ContentDialog dialog)
                    dialog.Hide();
        }
        catch (Exception) { }
    }

    public static void Copy(string secret) => Clipboard?.Copy(secret);

    public static void ShowQuickAccess()
    {
        // Capture the window the user was in BEFORE we take focus: it is the
        // only legitimate auto-type target, and it is shown to the user.
        var target = AutoType.CaptureForeground();
        if (target is not null && Main is not null && target.Handle == Main.Hwnd)
            target = null;
        s_overlay?.Close();
        s_overlay = new QuickAccessWindow(target);
        s_overlay.Closed += (_, _) => s_overlay = null;
        s_overlay.Activate();
    }

    private static void Shutdown()
    {
        Lock();
        s_idleTimer?.Stop();
        SystemTriggers?.Dispose();
        Hotkey?.Dispose();
        Clipboard?.Dispose();
        Messages?.Dispose();
    }
}

public static class Diag
{
    private static readonly object Gate = new();

    /// <summary>Non-secret diagnostics only (used as CI evidence that the app started).</summary>
    public static void Log(string line)
    {
        try
        {
            lock (Gate)
                File.AppendAllText(Path.Combine(AppServices.Paths.Root, "diagnostics.log"),
                    $"{DateTimeOffset.UtcNow:O} {line}{Environment.NewLine}");
        }
        catch (Exception) { }
    }
}
