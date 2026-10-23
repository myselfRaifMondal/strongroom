using Strongroom.Core.Native;

namespace Strongroom.Core.Platform;

public enum CaptureProtection { None, ExcludedFromCapture, BlackedOutOnMonitor }

/// <summary>Keeps secret-bearing windows out of screenshots, recordings and screen sharing.</summary>
public static class CaptureExclusion
{
    /// <summary>
    /// WDA_EXCLUDEFROMCAPTURE (Windows 10 2004+). Falls back to WDA_MONITOR,
    /// which shows the window black in captures, on older builds.
    /// </summary>
    public static CaptureProtection Apply(nint hwnd)
    {
        if (User32.SetWindowDisplayAffinity(hwnd, User32.WDA_EXCLUDEFROMCAPTURE))
            return CaptureProtection.ExcludedFromCapture;
        if (User32.SetWindowDisplayAffinity(hwnd, User32.WDA_MONITOR))
            return CaptureProtection.BlackedOutOnMonitor;
        return CaptureProtection.None;
    }

    public static uint Current(nint hwnd) =>
        User32.GetWindowDisplayAffinity(hwnd, out uint a) ? a : uint.MaxValue;
}
