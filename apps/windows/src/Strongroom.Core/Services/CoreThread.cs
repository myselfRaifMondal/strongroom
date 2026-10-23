using System.Runtime.ExceptionServices;

namespace Strongroom.Core.Services;

/// <summary>
/// Runs calls into strongroom_ffi on a dedicated thread with a large stack.
/// Windows threads default to a 1 MB stack (Linux: 8 MB); on CI the
/// core-vault build overflowed it inside <c>Vault.create</c> on a .NET
/// thread-pool thread. Until the core bounds its stack use, every
/// key-derivation call (create, unlock, export, import) goes through here.
/// </summary>
public static class CoreThread
{
    public const int StackSize = 512 * 1024 * 1024; // EXPERIMENT (integration branch only)

    public static T Run<T>(Func<T> func)
    {
        T result = default!;
        ExceptionDispatchInfo? error = null;
        var thread = new Thread(() =>
        {
            try { result = func(); }
            catch (Exception e) { error = ExceptionDispatchInfo.Capture(e); }
        }, StackSize)
        { IsBackground = true, Name = "Strongroom core call" };
        thread.Start();
        thread.Join();
        error?.Throw();
        return result;
    }

    public static void Run(Action action) => Run<object?>(() => { action(); return null; });

    public static Task<T> RunAsync<T>(Func<T> func) => Task.Run(() => Run(func));
}
