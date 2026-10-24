import CryptoKit
import Foundation
import LocalAuthentication

/// A device this Mac can seal exports to. Only public data.
public struct PairedDeviceRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String { fingerprint }
    public var name: String
    /// "SR1PAIR:…" as pasted from the other device.
    public var payload: String
    public var fingerprint: String
    public var addedAt: Int64

    public init(name: String, payload: String, fingerprint: String, addedAt: Int64) {
        self.name = name
        self.payload = payload
        self.fingerprint = fingerprint
        self.addedAt = addedAt
    }

    /// 65-byte SEC1 public key, via the core's parser.
    public func publicKey() throws -> Data { try parsePairingPayload(payload: payload).publicKey }
}

/// Paired devices in a JSON file in the app data directory (0600). The file
/// holds public keys only; it is not secret, but it is still private.
public struct PairedDeviceStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }
    public init(dir: DataDirectory) { url = dir.pairedDevicesPath }

    public func load() -> [PairedDeviceRecord] {
        guard let data = SecureFile.read(url),
              let list = try? JSONDecoder().decode([PairedDeviceRecord].self, from: data) else { return [] }
        return list
    }

    public func save(_ list: [PairedDeviceRecord]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.write(try enc.encode(list), to: url)
    }

    /// Parses the payload with the core (rejects anything malformed), then
    /// adds or renames by fingerprint.
    @discardableResult
    public func add(name: String, payload: String, now: Int64) throws -> PairedDeviceRecord {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try parsePairingPayload(payload: trimmed)
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = PairedDeviceRecord(name: label.isEmpty ? "Device \(parsed.fingerprint.prefix(4))" : label,
                                        payload: trimmed, fingerprint: parsed.fingerprint, addedAt: now)
        var list = load().filter { $0.fingerprint != record.fingerprint }
        list.append(record)
        try save(list)
        return record
    }

    public func remove(fingerprint: String) throws {
        try save(load().filter { $0.fingerprint != fingerprint })
    }
}

/// This Mac's transfer key: a Secure Enclave P-256 key that needs user
/// presence for every use. Its public key is the pairing payload; exports
/// that list it as a recipient open with "Import with this Mac's key".
public enum TransferKey {
    public static func exists(_ dir: DataDirectory) -> Bool { SecureFile.exists(dir.transferKeyBlobPath) }

    /// Creating the key does not prompt.
    public static func loadOrCreate(_ dir: DataDirectory, reason: String = "import a file sealed to this Mac") throws -> SecureEnclaveDeviceKey {
        guard SecureEnclave.isAvailable else {
            throw StrongroomError.Unsupported(reason: "this Mac has no Secure Enclave")
        }
        if let blob = SecureFile.read(dir.transferKeyBlobPath),
           let key = try? SecureEnclaveDeviceKey(blob: blob, reason: reason, policy: .deviceOwnerAuthentication) {
            return key
        }
        let (blob, _) = try SecureEnclaveDeviceKey.createTransferKey()
        try SecureFile.write(blob, to: dir.transferKeyBlobPath)
        return try SecureEnclaveDeviceKey(blob: blob, reason: reason, policy: .deviceOwnerAuthentication)
    }
}

/// Software P-256 key that lives only in memory. Used to find out which
/// vault file an unlocked `Vault` came from without asking the core for its
/// path (the contract has no such call).
final class EphemeralSoftwareKey: DeviceKeyAgreement, @unchecked Sendable {
    private let key = P256.KeyAgreement.PrivateKey()
    func publicKey() -> Data { key.publicKey.x963Representation }
    func agree(peerPublicKey: Data) throws -> Data {
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey),
              let secret = try? key.sharedSecretFromKeyAgreement(with: peer) else { throw StrongroomError.UnlockFailed }
        return secret.withUnsafeBytes { Data($0) }
    }
}

public enum VaultIdentity {
    /// True when the unlocked `vault` is the one stored at `path`: wraps its
    /// key to a throwaway in-memory key and tries to open `path` with it. The
    /// wrap binds the vault id, so another vault's file refuses it. No
    /// Argon2id, no prompt; the probe handle is locked at once.
    public static func isVault(_ vault: Vault, storedAt path: URL) -> Bool {
        guard SecureFile.exists(path) else { return false }
        let probe = EphemeralSoftwareKey()
        guard let wrapped = try? vault.wrapVaultKeyForDevice(devicePublicKey: probe.publicKey()) else { return false }
        guard let opened = try? Vault.unlockWithDeviceKey(path: path.path, deviceWrappedKey: wrapped, device: probe) else {
            return false
        }
        opened.lock()
        return true
    }
}

/// "Back up vault…": `backup_to` refuses to overwrite, so it writes to a
/// temporary name in the destination folder and then renames both files
/// (`X` and `X.hdr`) into place, replacing an older backup the user chose to
/// overwrite in the save panel.
public enum VaultBackup {
    public static func write(_ vault: Vault, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let tmpHdr = URL(fileURLWithPath: tmp.path + ".hdr")
        let hdr = URL(fileURLWithPath: url.path + ".hdr")
        do {
            try vault.backupTo(path: tmp.path)
            try? SecureFile.chmod(tmp, 0o600)
            try? SecureFile.chmod(tmpHdr, 0o600)
            guard rename(tmpHdr.path, hdr.path) == 0 else { throw SecureFile.Failure.posix("rename", errno) }
            guard rename(tmp.path, url.path) == 0 else { throw SecureFile.Failure.posix("rename", errno) }
        } catch {
            SecureFile.remove(tmp)
            SecureFile.remove(tmpHdr)
            throw error
        }
    }
}
