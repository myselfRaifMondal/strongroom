using System.Runtime.InteropServices;
using Strongroom.Core.Native;

namespace Strongroom.Core.Platform;

/// <summary>Minimal clipboard surface so the auto-clear policy can be unit-tested.</summary>
public interface ISystemClipboard
{
    /// <summary>Places text, marked as excluded from history, cloud clipboard and monitors.</summary>
    void SetSecretText(string text);
    uint SequenceNumber { get; }
    void Clear();
}

/// <summary>
/// Copies secrets with Windows clipboard-history / cloud-clipboard / monitor
/// exclusion and clears them after a timeout (default 25 s, allowed 20-30 s)
/// unless something else has replaced the clipboard contents since.
/// </summary>
public sealed class SecureClipboard : IDisposable
{
    public static readonly TimeSpan MinClear = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan MaxClear = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan DefaultClear = TimeSpan.FromSeconds(25);

    private readonly ISystemClipboard _clipboard;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly object _gate = new();
    private CancellationTokenSource? _pending;
    private uint? _ourSequence;

    public TimeSpan ClearAfter { get; }

    /// <summary>Raised after an automatic clear actually emptied the clipboard.</summary>
    public event Action? Cleared;

    public SecureClipboard(ISystemClipboard clipboard, TimeSpan? clearAfter = null, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        var after = clearAfter ?? DefaultClear;
        if (after < MinClear || after > MaxClear)
            throw new ArgumentOutOfRangeException(nameof(clearAfter), "clipboard auto-clear must be 20-30 seconds");
        _clipboard = clipboard;
        ClearAfter = after;
        _delay = delay ?? Task.Delay;
    }

    /// <summary>Copies the secret and schedules the clear. Returns the clear task (for tests).</summary>
    public Task Copy(string secret)
    {
        CancellationTokenSource cts;
        lock (_gate)
        {
            _pending?.Cancel();
            _clipboard.SetSecretText(secret);
            _ourSequence = _clipboard.SequenceNumber;
            cts = _pending = new CancellationTokenSource();
        }
        return ClearLater(cts.Token);
    }

    private async Task ClearLater(CancellationToken token)
    {
        try
        {
            await _delay(ClearAfter, token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (ClearIfOurs())
            Cleared?.Invoke();
    }

    /// <summary>Clears now if the clipboard still holds what we put there (used on lock/exit).</summary>
    public bool ClearIfOurs()
    {
        lock (_gate)
        {
            if (_ourSequence is null)
                return false;
            bool ours = _clipboard.SequenceNumber == _ourSequence;
            _ourSequence = null;
            if (ours)
                _clipboard.Clear();
            return ours;
        }
    }

    public void Dispose()
    {
        lock (_gate)
            _pending?.Cancel();
        ClearIfOurs();
    }
}

/// <summary>Win32 clipboard implementation.</summary>
public sealed class Win32Clipboard : ISystemClipboard
{
    // https://learn.microsoft.com/windows/win32/dataxchg/clipboard-formats#cloud-clipboard-and-clipboard-history-formats
    public const string ExcludeFromMonitorFormat = "ExcludeClipboardContentFromMonitorProcessing";
    public const string CanIncludeInHistoryFormat = "CanIncludeInClipboardHistory";
    public const string CanUploadToCloudFormat = "CanUploadToCloudClipboard";

    private readonly nint _owner;

    /// <param name="owner">Window that owns the clipboard data (EmptyClipboard with a null owner makes SetClipboardData fail).</param>
    public Win32Clipboard(nint owner) => _owner = owner;

    public uint SequenceNumber => User32.GetClipboardSequenceNumber();

    public void SetSecretText(string text)
    {
        WithClipboard(() =>
        {
            if (!User32.EmptyClipboard())
                throw new System.ComponentModel.Win32Exception();
            SetDword(User32.RegisterClipboardFormat(ExcludeFromMonitorFormat), 0);
            SetDword(User32.RegisterClipboardFormat(CanIncludeInHistoryFormat), 0);
            SetDword(User32.RegisterClipboardFormat(CanUploadToCloudFormat), 0);
            SetUnicode(text);
        });
    }

    public void Clear() => WithClipboard(() => User32.EmptyClipboard());

    /// <summary>Reads CF_UNICODETEXT (diagnostics and tests only).</summary>
    public string? ReadText()
    {
        string? result = null;
        WithClipboard(() =>
        {
            nint h = User32.GetClipboardData(User32.CF_UNICODETEXT);
            if (h == 0) return;
            nint p = Kernel32.GlobalLock(h);
            try { result = Marshal.PtrToStringUni(p); }
            finally { Kernel32.GlobalUnlock(h); }
        });
        return result;
    }

    /// <summary>Whether the three exclusion formats are present on the clipboard.</summary>
    public bool ExclusionFormatsPresent()
    {
        bool all = false;
        WithClipboard(() =>
        {
            all = User32.IsClipboardFormatAvailable(User32.RegisterClipboardFormat(ExcludeFromMonitorFormat))
               && User32.IsClipboardFormatAvailable(User32.RegisterClipboardFormat(CanIncludeInHistoryFormat))
               && User32.IsClipboardFormatAvailable(User32.RegisterClipboardFormat(CanUploadToCloudFormat));
        });
        return all;
    }

    private void WithClipboard(Action action)
    {
        // Another process may hold the clipboard briefly; retry a few times.
        for (int attempt = 0; ; attempt++)
        {
            if (User32.OpenClipboard(_owner))
                break;
            if (attempt >= 10)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "OpenClipboard failed");
            Thread.Sleep(20);
        }
        try { action(); }
        finally { User32.CloseClipboard(); }
    }

    private static void SetDword(uint format, uint value)
    {
        nint h = Kernel32.GlobalAlloc(User32.GMEM_MOVEABLE, 4);
        if (h == 0) throw new OutOfMemoryException();
        nint p = Kernel32.GlobalLock(h);
        Marshal.WriteInt32(p, (int)value);
        Kernel32.GlobalUnlock(h);
        if (User32.SetClipboardData(format, h) == 0)
        {
            Kernel32.GlobalFree(h);
            throw new System.ComponentModel.Win32Exception();
        }
    }

    private static void SetUnicode(string text)
    {
        int bytes = (text.Length + 1) * 2;
        nint h = Kernel32.GlobalAlloc(User32.GMEM_MOVEABLE, (nuint)bytes);
        if (h == 0) throw new OutOfMemoryException();
        nint p = Kernel32.GlobalLock(h);
        unsafe
        {
            var dst = new Span<char>((void*)p, text.Length + 1);
            text.AsSpan().CopyTo(dst);
            dst[text.Length] = '\0';
        }
        Kernel32.GlobalUnlock(h);
        if (User32.SetClipboardData(User32.CF_UNICODETEXT, h) == 0)
        {
            Kernel32.GlobalFree(h);
            throw new System.ComponentModel.Win32Exception();
        }
    }
}
