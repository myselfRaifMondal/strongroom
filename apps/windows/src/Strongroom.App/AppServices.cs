using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
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
    public static AutoType AutoType { get; } = new();
    public static UnlockSignals Signals { get; } = new(Paths.LastPasswordBoot);
    public static DeviceUnlock Device { get; private set; } = null!;

    private static Vault? s_vault;
    private static QuickAccessWindow? s_overlay;

    public static Vault? Vault => s_vault is { } v && !v.IsLocked() ? v : null;

    public static event Action? VaultChanged;

    public static void Start(MainWindow main)
    {
        Main = main;
        Device = new DeviceUnlock(Paths, new HelloPresence(() => main.Hwnd));
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
                var dq = DispatcherQueue.GetForCurrentThread();
                Hotkey.Pressed += () => dq.TryEnqueue(ShowQuickAccess);
                Diag.Log("hotkey: Ctrl+Shift+Space registered");
            }
            catch (Exception e)
            {
                Diag.Log($"hotkey: not registered ({e.Message})");
            }
        }

        main.Closed += (_, _) => Shutdown();
    }

    public static UnlockGate OpenGate() => new(Paths.GateState);

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
        bool hasKey = Device.IsEnrolled;
        try
        {
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
        VaultChanged?.Invoke();
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
