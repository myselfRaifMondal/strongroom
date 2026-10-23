using Strongroom.Core.Native;

namespace Strongroom.Core.Platform;

/// <summary>System-wide hotkey (default Ctrl+Shift+Space) for the quick-access overlay.</summary>
public sealed class GlobalHotkey : IDisposable
{
    public const uint DefaultModifiers = User32.MOD_CONTROL | User32.MOD_SHIFT;
    public const uint VK_SPACE = 0x20;

    private readonly MessageWindow _window;
    private readonly int _id;
    private bool _registered;

    /// <summary>Raised on a background thread; marshal to the UI thread before touching UI.</summary>
    public event Action? Pressed;

    public GlobalHotkey(MessageWindow window, uint modifiers = DefaultModifiers, uint virtualKey = VK_SPACE, int id = 0x5352)
    {
        _window = window;
        _id = id;
        int error = 0;
        _window.Invoke(() =>
        {
            _registered = User32.RegisterHotKey(_window.Handle, _id, modifiers | User32.MOD_NOREPEAT, virtualKey);
            if (!_registered)
                error = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
        });
        if (!_registered)
            throw new System.ComponentModel.Win32Exception(error, "RegisterHotKey failed (is the combination already in use?)");
        _window.Hotkey += OnHotkey;
    }

    private void OnHotkey(int id)
    {
        if (id == _id)
            Pressed?.Invoke();
    }

    public void Dispose()
    {
        _window.Hotkey -= OnHotkey;
        if (_registered)
        {
            _window.Invoke(() => User32.UnregisterHotKey(_window.Handle, _id));
            _registered = false;
        }
    }
}
