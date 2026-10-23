using System.Collections.Concurrent;
using Strongroom.Core.Native;

namespace Strongroom.Core.Platform;

/// <summary>
/// A hidden message-only window on its own thread with a message loop. It
/// owns the clipboard data we place and receives WM_HOTKEY. Work that must
/// run on the window's thread (RegisterHotKey) is marshalled via Invoke.
/// </summary>
public sealed class MessageWindow : IDisposable
{
    private const uint WM_INVOKE = User32.WM_APP + 1;
    private static int s_classCounter;

    private readonly Thread _thread;
    private readonly ManualResetEventSlim _ready = new();
    private readonly ConcurrentQueue<Action> _work = new();
    private User32.WndProc? _wndProc; // kept alive for the window's lifetime
    private Exception? _startError;

    public nint Handle { get; private set; }

    /// <summary>Raised on the window thread for every WM_HOTKEY (argument: hotkey id).</summary>
    public event Action<int>? Hotkey;

    public MessageWindow()
    {
        _thread = new Thread(Run) { IsBackground = true, Name = "Strongroom message window" };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        _ready.Wait();
        if (_startError is not null)
            throw _startError;
    }

    public void Invoke(Action action)
    {
        if (Environment.CurrentManagedThreadId == _thread.ManagedThreadId)
        {
            action();
            return;
        }
        using var done = new ManualResetEventSlim();
        Exception? error = null;
        _work.Enqueue(() =>
        {
            try { action(); }
            catch (Exception e) { error = e; }
            finally { done.Set(); }
        });
        User32.PostMessage(Handle, WM_INVOKE, 0, 0);
        done.Wait();
        if (error is not null)
            throw error;
    }

    private void Run()
    {
        try
        {
            _wndProc = WndProc;
            var className = $"StrongroomMsgWnd{Environment.ProcessId}_{Interlocked.Increment(ref s_classCounter)}";
            var wc = new User32.WNDCLASSEX
            {
                cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<User32.WNDCLASSEX>(),
                lpfnWndProc = _wndProc,
                hInstance = Kernel32.GetModuleHandle(null),
                lpszClassName = className,
            };
            if (User32.RegisterClassEx(ref wc) == 0)
                throw new System.ComponentModel.Win32Exception();
            Handle = User32.CreateWindowEx(0, className, "Strongroom", 0, 0, 0, 0, 0, User32.HWND_MESSAGE, 0, wc.hInstance, 0);
            if (Handle == 0)
                throw new System.ComponentModel.Win32Exception();
        }
        catch (Exception e)
        {
            _startError = e;
            _ready.Set();
            return;
        }
        _ready.Set();

        while (User32.GetMessage(out var msg, 0, 0, 0) > 0)
        {
            User32.TranslateMessage(ref msg);
            User32.DispatchMessage(ref msg);
        }
    }

    private nint WndProc(nint hwnd, uint msg, nint wParam, nint lParam)
    {
        switch (msg)
        {
            case User32.WM_HOTKEY:
                Hotkey?.Invoke((int)wParam);
                return 0;
            case WM_INVOKE:
                while (_work.TryDequeue(out var action))
                    action();
                return 0;
            case User32.WM_DESTROY:
                User32.PostQuitMessage(0);
                return 0;
        }
        return User32.DefWindowProc(hwnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        if (Handle != 0)
        {
            Invoke(() => User32.DestroyWindow(Handle));
            Handle = 0;
            _thread.Join(TimeSpan.FromSeconds(2));
        }
    }
}
