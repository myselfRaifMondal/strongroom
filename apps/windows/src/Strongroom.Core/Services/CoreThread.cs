using System.Runtime.ExceptionServices;

namespace Strongroom.Core.Services;

/// <summary>
/// Runs calls into strongroom_ffi on a dedicated thread with a large stack.
/// Windows threads default to a 1 MB stack (Linux: 8 MB). A precaution only:
/// the stack overflow seen with the core-vault build (OPEN-QUESTIONS OQ-W6)
/// also happens on large stacks and must be fixed in the core.
/// </summary>
public static class CoreThread
{
    public const int StackSize = 16 * 1024 * 1024;

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
