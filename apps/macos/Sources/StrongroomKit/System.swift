import Darwin
import Foundation

/// The core never reads the wall clock; callers pass Unix seconds.
public enum Clock {
    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
}

/// Reboot detection for `UnlockGate`: compares `kern.boottime` with the value
/// recorded at the last password unlock.
public enum BootTime {
    /// Seconds since the epoch at which the kernel booted.
    public static func current() -> Int64? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Int64(tv.tv_sec)
    }

    /// kern.boottime is derived from the wall clock and can shift by a few
    /// seconds after NTP corrections without a reboot.
    public static let tolerance: Int64 = 60

    /// True when there is no record or the boot time differs from the recorded
    /// one (fails safe: unknown means "rebooted", which demands the password).
    public static func rebootedSince(recorded: Int64?, current: Int64?) -> Bool {
        guard let recorded, let current else { return true }
        return abs(current - recorded) > tolerance
    }

    public static func load(_ dir: DataDirectory) -> Int64? {
        guard let data = SecureFile.read(dir.bootTimePath),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func recordCurrent(_ dir: DataDirectory) throws {
        guard let now = current() else { return }
        try SecureFile.write(Data(String(now).utf8), to: dir.bootTimePath)
    }

    public static func rebootedSinceLastPassword(_ dir: DataDirectory) -> Bool {
        rebootedSince(recorded: load(dir), current: current())
    }
}

/// Runs core calls on a thread with a large stack. Dispatch worker threads
/// have 512 KiB stacks; the core (SQLCipher, Argon2id) is happier with more,
/// as the Windows port found out.
public enum CoreThread {
    public static let stackSize = 16 << 20

    public static func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let thread = Thread {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
            thread.stackSize = stackSize
            thread.name = "strongroom-core"
            thread.start()
        }
    }

    /// Synchronous variant for the CLI.
    public static func runBlocking<T>(_ body: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try body() }
            done.signal()
        }
        thread.stackSize = stackSize
        thread.name = "strongroom-core"
        thread.start()
        done.wait()
        return try result.get()
    }
}

public enum CoreErrors {
    /// Human-readable text for a core error. Never includes secret material
    /// (the core never puts any in errors) and never says which unlock factor
    /// was wrong.
    public static func describe(_ error: Error) -> String {
        guard let e = error as? StrongroomError else { return error.localizedDescription }
        switch e {
        case .UnlockFailed: return "Unlock failed. Check the master password and Secret Key."
        case let .FormatRejected(check): return "The file was rejected (\(check))."
        case let .InvalidInput(reason): return "Invalid input: \(reason)."
        case .NotFound: return "Not found."
        case .Locked: return "The vault is locked."
        case let .Unsupported(reason): return "Not supported: \(reason)."
        case let .Storage(reason): return "Storage error: \(reason)."
        case .Internal: return "Internal error."
        }
    }

    public static func isUnsupported(_ error: Error) -> Bool {
        if case .Unsupported = error as? StrongroomError { return true }
        return false
    }
}
