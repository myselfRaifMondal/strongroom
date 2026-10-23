using System.Globalization;

namespace Strongroom.Core.Services;

/// <summary>
/// Platform signals for <c>UnlockGate.check</c>. Reboot detection compares the
/// boot time recorded at the last password unlock with the current one.
/// </summary>
public sealed class UnlockSignals
{
    // Boot time derived from uptime jitters by a few ms per read; anything
    // within this tolerance is the same boot.
    private static readonly TimeSpan Tolerance = TimeSpan.FromMinutes(2);

    private readonly string _stateFile;
    private readonly Func<DateTimeOffset> _bootTime;

    public UnlockSignals(string stateFile, Func<DateTimeOffset>? bootTime = null)
    {
        _stateFile = stateFile;
        _bootTime = bootTime ?? CurrentBootTime;
    }

    public static DateTimeOffset CurrentBootTime() =>
        DateTimeOffset.UtcNow - TimeSpan.FromMilliseconds(Environment.TickCount64);

    /// <summary>True when no password unlock has been recorded during the current boot (fails safe).</summary>
    public bool RebootedSinceLastPassword()
    {
        try
        {
            var text = File.ReadAllText(_stateFile).Trim();
            var recorded = DateTimeOffset.FromUnixTimeMilliseconds(long.Parse(text, CultureInfo.InvariantCulture));
            return (recorded - _bootTime()).Duration() > Tolerance;
        }
        catch (Exception)
        {
            return true;
        }
    }

    public void RecordPasswordUnlock() =>
        File.WriteAllText(_stateFile, _bootTime().ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture));

    /// <summary>
    /// Windows offers desktop apps no API to observe Hello enrollment
    /// changes; see OPEN-QUESTIONS OQ-W3. Always false.
    /// </summary>
    public bool EnrollmentChanged() => false;
}
