using System.Diagnostics;
using Strongroom.Core.Native;

namespace Strongroom.Core.Platform;

/// <summary>The window that had focus before Strongroom took it.</summary>
public sealed record TargetWindow(nint Handle, string Title, string ProcessName)
{
    public override string ToString() =>
        string.IsNullOrWhiteSpace(Title) ? $"(untitled window of {ProcessName})" : $"{Title} ({ProcessName})";
}

/// <summary>Opaque single-use permission to type into one specific window.</summary>
public sealed class AutoTypeConfirmation
{
    internal AutoTypeConfirmation(TargetWindow target) => Target = target;
    public TargetWindow Target { get; }
    internal bool Used { get; set; }
}

public enum AutoTypeResult { Typed, TargetGone, FocusNotRestored, AlreadyUsed, InputBlocked }

/// <summary>
/// Types text into the previously focused window with SendInput. The only way
/// to obtain an <see cref="AutoTypeConfirmation"/> is <see cref="Confirm"/>,
/// which the UI calls after the user has seen the target window's title and
/// explicitly approved; each confirmation is consumed by one typing attempt.
/// </summary>
public sealed class AutoType
{
    private readonly IInputSink _sink;

    public AutoType(IInputSink? sink = null) => _sink = sink ?? new Win32InputSink();

    /// <summary>Captures the current foreground window (call before showing Strongroom UI).</summary>
    public TargetWindow? CaptureForeground() => _sink.Describe(_sink.Foreground());

    /// <summary>Called only from the confirmation dialog's explicit "Type" action.</summary>
    public AutoTypeConfirmation Confirm(TargetWindow target) => new(target);

    /// <summary>Types the given sequence (fields joined by Tab when requested).</summary>
    public AutoTypeResult Type(AutoTypeConfirmation confirmation, IReadOnlyList<string> fields, bool pressEnter = false)
    {
        lock (confirmation)
        {
            if (confirmation.Used)
                return AutoTypeResult.AlreadyUsed;
            confirmation.Used = true;
        }
        var target = confirmation.Target;
        if (!_sink.IsWindow(target.Handle))
            return AutoTypeResult.TargetGone;
        if (!_sink.Activate(target.Handle))
            return AutoTypeResult.FocusNotRestored;
        // Never type into anything other than the window the user approved.
        if (_sink.Foreground() != target.Handle)
            return AutoTypeResult.FocusNotRestored;

        var keys = new List<KeyStroke>();
        for (int i = 0; i < fields.Count; i++)
        {
            if (i > 0) keys.Add(KeyStroke.Virtual(0x09)); // Tab
            foreach (char c in fields[i])
                keys.Add(KeyStroke.Unicode(c));
        }
        if (pressEnter) keys.Add(KeyStroke.Virtual(0x0D));
        return _sink.Send(keys) ? AutoTypeResult.Typed : AutoTypeResult.InputBlocked;
    }
}

public readonly record struct KeyStroke(ushort VirtualKey, char Char)
{
    public static KeyStroke Unicode(char c) => new(0, c);
    public static KeyStroke Virtual(ushort vk) => new(vk, '\0');
}

/// <summary>OS input abstraction (tests substitute a fake).</summary>
public interface IInputSink
{
    nint Foreground();
    TargetWindow? Describe(nint hwnd);
    bool IsWindow(nint hwnd);
    bool Activate(nint hwnd);
    bool Send(IReadOnlyList<KeyStroke> keys);
}

public sealed class Win32InputSink : IInputSink
{
    public nint Foreground() => User32.GetForegroundWindow();

    public TargetWindow? Describe(nint hwnd)
    {
        if (hwnd == 0) return null;
        int len = User32.GetWindowTextLength(hwnd);
        var buf = new char[Math.Max(len + 1, 1)];
        int got = User32.GetWindowText(hwnd, buf, buf.Length);
        string title = new string(buf, 0, Math.Max(got, 0));
        User32.GetWindowThreadProcessId(hwnd, out uint pid);
        string process;
        try { process = Process.GetProcessById((int)pid).ProcessName; }
        catch (Exception) { process = $"pid {pid}"; }
        return new TargetWindow(hwnd, title, process);
    }

    public bool IsWindow(nint hwnd) => User32.IsWindow(hwnd);

    public bool Activate(nint hwnd)
    {
        User32.SetForegroundWindow(hwnd);
        for (int i = 0; i < 20 && User32.GetForegroundWindow() != hwnd; i++)
            Thread.Sleep(25);
        return User32.GetForegroundWindow() == hwnd;
    }

    public bool Send(IReadOnlyList<KeyStroke> keys)
    {
        var inputs = new User32.INPUT[keys.Count * 2];
        for (int i = 0; i < keys.Count; i++)
        {
            var k = keys[i];
            uint flags = k.VirtualKey == 0 ? User32.KEYEVENTF_UNICODE : 0;
            ushort scan = k.VirtualKey == 0 ? k.Char : (ushort)0;
            inputs[2 * i] = Key(k.VirtualKey, scan, flags);
            inputs[2 * i + 1] = Key(k.VirtualKey, scan, flags | User32.KEYEVENTF_KEYUP);
        }
        int size = System.Runtime.InteropServices.Marshal.SizeOf<User32.INPUT>();
        uint sent = User32.SendInput((uint)inputs.Length, inputs, size);
        Array.Clear(inputs);
        return sent == inputs.Length;
    }

    private static User32.INPUT Key(ushort vk, ushort scan, uint flags) => new()
    {
        type = User32.INPUT_KEYBOARD,
        u = new User32.InputUnion { ki = new User32.KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags } },
    };
}
