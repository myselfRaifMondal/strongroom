import Darwin
import Foundation

/// Where the app keeps its data: ~/Library/Application Support/Strongroom
/// (0700). `STRONGROOM_DATA_DIR` overrides it (CI, tests, smoke launches).
public struct DataDirectory: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func standard() throws -> DataDirectory {
        if let override = ProcessInfo.processInfo.environment["STRONGROOM_DATA_DIR"], !override.isEmpty {
            return try DataDirectory(prepared: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try DataDirectory(prepared: base.appendingPathComponent("Strongroom", isDirectory: true))
    }

    /// Creates the directory if needed and forces it to 0700.
    public init(prepared url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SecureFile.chmod(url, 0o700)
        self.url = url
    }

    public var vaultPath: URL { url.appendingPathComponent("vault.srdb") }
    public var unlockGateStatePath: URL { url.appendingPathComponent("unlock-gate.state") }
    /// Secure Enclave key blob (`dataRepresentation`): encrypted by the SE,
    /// usable only on this Mac.
    public var deviceKeyBlobPath: URL { url.appendingPathComponent("device-key.se") }
    /// Output of `wrap_vault_key_for_device` (HPKE-sealed to the SE key).
    public var deviceWrappedKeyPath: URL { url.appendingPathComponent("device-wrapped-vault-key.bin") }
    /// Biometry domain-state hash captured when the device key was created.
    public var biometryStatePath: URL { url.appendingPathComponent("biometry-state.bin") }
    /// kern.boottime recorded at the last password unlock.
    public var bootTimePath: URL { url.appendingPathComponent("last-password-boot.txt") }
    /// Optional second vault (decoy). The unlock screen always passes both
    /// paths to `unlock_first_matching`, whether or not this file exists, so
    /// timing and errors do not depend on it.
    public var secondVaultPath: URL { url.appendingPathComponent("vault-2.srdb") }
    /// Every vault path the unlock screen tries, in order.
    public var unlockCandidatePaths: [URL] { [vaultPath, secondVaultPath] }
    /// Which vault the Touch ID wrapped key belongs to ("1" or "2"). Not secret.
    public var deviceUnlockTargetPath: URL { url.appendingPathComponent("device-unlock-target.txt") }
    /// Secure Enclave key (user presence) used for device-to-device transfer:
    /// its public key is this Mac's pairing payload.
    public var transferKeyBlobPath: URL { url.appendingPathComponent("transfer-key.se") }
    /// Public keys of paired devices (JSON, not secret, 0600).
    public var pairedDevicesPath: URL { url.appendingPathComponent("paired-devices.json") }
}

/// Files written with 0600 permissions, atomically (temp file + rename).
public enum SecureFile {
    public enum Failure: Error, CustomStringConvertible {
        case posix(String, Int32)
        public var description: String {
            switch self {
            case let .posix(op, code): return "\(op): \(String(cString: strerror(code)))"
            }
        }
    }

    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.posix("open", errno) }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    let e = errno
                    close(fd)
                    throw Failure.posix("write", e)
                }
                offset += n
            }
        }
        if fsync(fd) != 0 {
            let e = errno
            close(fd)
            throw Failure.posix("fsync", e)
        }
        close(fd)
        guard rename(tmp.path, url.path) == 0 else { throw Failure.posix("rename", errno) }
        ok = true
    }

    public static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    public static func remove(_ url: URL) {
        unlink(url.path)
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else { throw Failure.posix("chmod", errno) }
    }

    /// Permission bits of a file (for tests and diagnostics).
    public static func mode(_ url: URL) -> mode_t? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return st.st_mode & 0o777
    }
}
