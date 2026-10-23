using Strongroom.Core.Platform;
using Strongroom.Core.Services;
using Xunit;
using Xunit.Abstractions;

namespace Strongroom.Tests;

public class SecureClipboardTests
{
    private sealed class FakeClipboard : ISystemClipboard
    {
        public string? Text;
        public uint Seq = 1;
        public int Clears;
        public void SetSecretText(string text) { Text = text; Seq++; }
        public uint SequenceNumber => Seq;
        public void Clear() { Text = null; Seq++; Clears++; }
    }

    private sealed class ManualDelay
    {
        public readonly List<(TimeSpan delay, TaskCompletionSource tcs, CancellationToken token)> Pending = new();
        public Task Delay(TimeSpan d, CancellationToken token)
        {
            var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            token.Register(() => tcs.TrySetCanceled(token));
            Pending.Add((d, tcs, token));
            return tcs.Task;
        }
    }

    [Theory]
    [InlineData(19)]
    [InlineData(31)]
    public void RejectsClearTimesOutside20To30Seconds(int seconds) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => new SecureClipboard(new FakeClipboard(), TimeSpan.FromSeconds(seconds)));

    [Fact]
    public async Task ClearsAfterTimeoutWhenStillOurs()
    {
        var cb = new FakeClipboard();
        var delay = new ManualDelay();
        using var sc = new SecureClipboard(cb, delay: delay.Delay);
        var task = sc.Copy("s3cret");
        Assert.Equal("s3cret", cb.Text);
        Assert.Equal(TimeSpan.FromSeconds(25), delay.Pending.Single().delay);
        delay.Pending[0].tcs.SetResult();
        await task;
        Assert.Null(cb.Text);
        Assert.Equal(1, cb.Clears);
    }

    [Fact]
    public async Task DoesNotClearWhenUserCopiedSomethingElse()
    {
        var cb = new FakeClipboard();
        var delay = new ManualDelay();
        using var sc = new SecureClipboard(cb, delay: delay.Delay);
        var task = sc.Copy("s3cret");
        cb.Text = "user text"; cb.Seq++; // another app wrote to the clipboard
        delay.Pending[0].tcs.SetResult();
        await task;
        Assert.Equal("user text", cb.Text);
        Assert.Equal(0, cb.Clears);
    }

    [Fact]
    public async Task SecondCopyRestartsTimer()
    {
        var cb = new FakeClipboard();
        var delay = new ManualDelay();
        using var sc = new SecureClipboard(cb, delay: delay.Delay);
        var first = sc.Copy("one");
        var second = sc.Copy("two");
        await first; // cancelled quietly
        Assert.Equal("two", cb.Text);
        delay.Pending[1].tcs.SetResult();
        await second;
        Assert.Null(cb.Text);
    }

    [SkippableFact]
    public void Win32ClipboardSetsHistoryAndCloudExclusionFormats()
    {
        using var window = new MessageWindow();
        var clip = new Win32Clipboard(window.Handle);
        try
        {
            clip.SetSecretText("strongroom-clipboard-test");
        }
        catch (System.ComponentModel.Win32Exception e)
        {
            Skip.If(true, $"clipboard not accessible in this session: {e.Message}");
        }
        Assert.True(clip.ExclusionFormatsPresent());
        Assert.Equal("strongroom-clipboard-test", clip.ReadText());
        clip.Clear();
        Assert.Null(clip.ReadText());
    }
}

public class AutoTypeTests
{
    private sealed class FakeSink : IInputSink
    {
        public nint Fg = 42;
        public bool Exists = true;
        public bool CanActivate = true;
        public List<KeyStroke> Sent = new();
        public nint Foreground() => Fg;
        public TargetWindow? Describe(nint h) => h == 0 ? null : new TargetWindow(h, "Login - Example", "notepad");
        public bool IsWindow(nint h) => Exists;
        public bool Activate(nint h) { if (CanActivate) Fg = h; return CanActivate; }
        public bool Send(IReadOnlyList<KeyStroke> keys) { Sent.AddRange(keys); return true; }
    }

    [Fact]
    public void TypesUsernameTabPasswordOnceAfterConfirmation()
    {
        var sink = new FakeSink();
        var at = new AutoType(sink);
        var target = at.CaptureForeground()!;
        Assert.Equal("Login - Example (notepad)", target.ToString());
        var ok = at.Confirm(target);
        sink.Fg = 7; // Strongroom's own window has focus while confirming

        Assert.Equal(AutoTypeResult.Typed, at.Type(ok, new[] { "ab", "c" }));
        Assert.Equal(new[] { 'a', 'b', '\0', 'c' }, sink.Sent.Select(k => k.Char));
        Assert.Equal(0x09, sink.Sent[2].VirtualKey);

        // A confirmation is single-use: typing again needs a new explicit yes.
        Assert.Equal(AutoTypeResult.AlreadyUsed, at.Type(ok, new[] { "x" }));
        Assert.Equal(4, sink.Sent.Count);
    }

    [Fact]
    public void RefusesWhenTargetClosedOrFocusCannotBeRestored()
    {
        var sink = new FakeSink();
        var at = new AutoType(sink);
        var target = at.CaptureForeground()!;

        sink.Exists = false;
        Assert.Equal(AutoTypeResult.TargetGone, at.Type(at.Confirm(target), new[] { "x" }));

        sink.Exists = true;
        sink.CanActivate = false;
        Assert.Equal(AutoTypeResult.FocusNotRestored, at.Type(at.Confirm(target), new[] { "x" }));
        Assert.Empty(sink.Sent);
    }
}

public class UnlockSignalsTests
{
    [Fact]
    public void RequiresPasswordAfterReboot()
    {
        var file = Path.Combine(Path.GetTempPath(), $"sr-boot-{Guid.NewGuid():N}.txt");
        var boot = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        try
        {
            var s = new UnlockSignals(file, () => boot);
            Assert.True(s.RebootedSinceLastPassword()); // nothing recorded: fail safe
            s.RecordPasswordUnlock();
            Assert.False(new UnlockSignals(file, () => boot.AddMilliseconds(15)).RebootedSinceLastPassword());
            Assert.True(new UnlockSignals(file, () => boot.AddHours(3)).RebootedSinceLastPassword());
        }
        finally
        {
            File.Delete(file);
        }
    }
}

public class HotkeyTests
{
    private readonly ITestOutputHelper _out;
    public HotkeyTests(ITestOutputHelper output) => _out = output;

    [SkippableFact]
    public void RegistersAndUnregistersGlobalHotkey()
    {
        using var window = new MessageWindow();
        GlobalHotkey hk;
        try
        {
            // Unusual combination so it does not collide with anything on the runner.
            hk = new GlobalHotkey(window, GlobalHotkey.DefaultModifiers | 0x0001 /*Alt*/, 0x7B /*F12*/);
        }
        catch (System.ComponentModel.Win32Exception e)
        {
            _out.WriteLine(e.Message);
            Skip.If(true, $"RegisterHotKey unavailable: {e.Message}");
            return;
        }
        hk.Dispose();
    }
}
