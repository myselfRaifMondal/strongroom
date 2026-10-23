using Strongroom.Ffi;

namespace Strongroom.Core.Services;

/// <summary>Turns core errors into user-facing text. Never reveals which unlock factor was wrong.</summary>
public static class CoreErrors
{
    public static string Describe(Exception e) => e switch
    {
        StrongroomException.UnlockFailed => "Unlock failed. Check the master password and Secret Key.",
        StrongroomException.FormatRejected f => $"The file was rejected ({f.@check}).",
        StrongroomException.InvalidInput i => $"Invalid input: {i.@reason}",
        StrongroomException.NotFound => "Not found.",
        StrongroomException.Locked => "The vault is locked.",
        StrongroomException.Unsupported u => $"Not available: {u.@reason}",
        StrongroomException.Storage s => $"Storage error: {s.@reason}",
        StrongroomException.Internal => "Internal error.",
        DllNotFoundException => "strongroom_ffi.dll was not found next to the application.",
        _ => e.Message,
    };

    public static bool IsUnsupported(Exception e) => e is StrongroomException.Unsupported;
}
