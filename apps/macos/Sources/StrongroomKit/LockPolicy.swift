import Foundation

/// Something that happened to the Mac or the app that may lock the vault.
public enum LockEvent: String, CaseIterable, Sendable {
    /// `NSWorkspace.willSleepNotification`: before the Mac sleeps.
    case systemSleep
    /// `com.apple.screenIsLocked` (distributed notification).
    case screenLocked
    /// `com.apple.screensaver.didstart` (distributed notification).
    case screensaverStarted
    /// `NSWorkspace.sessionDidResignActiveNotification`: fast user switch,
    /// login window.
    case sessionResigned
    /// Logout, shutdown or quit (`willPowerOff`, `applicationWillTerminate`).
    case appTerminating
    /// No Strongroom interaction for the configured time.
    case idleTimeout
    /// "Lock Now" / "Lock Vault".
    case manual
}

/// Settings › Lock after inactivity.
public enum IdleLockInterval: Int, CaseIterable, Sendable, Identifiable {
    case never = 0
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case fourHours = 14400

    public var id: Int { rawValue }
    public var seconds: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }

    public var label: String {
        switch self {
        case .never: return "Never"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        }
    }
}

/// The user-adjustable part of the lock policy (UserDefaults; not secret).
public struct LockSettings: Equatable, Sendable {
    /// Lock when the screen locks or the screen saver starts. Default on.
    public var lockOnScreenLock: Bool
    /// Lock after this long without Strongroom interaction. Default never.
    public var idleLock: IdleLockInterval

    public init(lockOnScreenLock: Bool = true, idleLock: IdleLockInterval = .never) {
        self.lockOnScreenLock = lockOnScreenLock
        self.idleLock = idleLock
    }

    public static let defaults = LockSettings()

    static let screenLockKey = "lock.onScreenLock"
    static let idleKey = "lock.idleSeconds"

    public static func load(_ store: UserDefaults = .standard) -> LockSettings {
        var s = LockSettings()
        if store.object(forKey: screenLockKey) != nil { s.lockOnScreenLock = store.bool(forKey: screenLockKey) }
        if store.object(forKey: idleKey) != nil {
            s.idleLock = IdleLockInterval(rawValue: store.integer(forKey: idleKey)) ?? .never
        }
        return s
    }

    public func save(_ store: UserDefaults = .standard) {
        store.set(lockOnScreenLock, forKey: Self.screenLockKey)
        store.set(idleLock.rawValue, forKey: Self.idleKey)
    }

    /// Sleep, session switch, logout/quit and manual locks cannot be turned
    /// off; screen lock / screen saver follow the toggle; idle needs an interval.
    public func shouldLock(on event: LockEvent) -> Bool {
        switch event {
        case .systemSleep, .sessionResigned, .appTerminating, .manual: return true
        case .screenLocked, .screensaverStarted: return lockOnScreenLock
        case .idleTimeout: return idleLock != .never
        }
    }
}

/// Implemented by whatever holds the open vault (the app model). Must drop the
/// vault and everything derived from it, and be safe to call when locked.
@MainActor
public protocol LockableSession: AnyObject {
    var isSessionUnlocked: Bool { get }
    func lockSession(reason: LockEvent)
}

/// Decides which events lock, tracks the last Strongroom interaction for the
/// idle lock, and runs the lock: session first, then UI clean-up, then the
/// clipboard (cleared at once rather than after its timeout).
@MainActor
public final class LockCoordinator {
    public private(set) var settings: LockSettings
    public weak var session: LockableSession?
    /// UI clean-up after the session is locked (close the overlay, sheets,
    /// modal alerts, update the menu-bar icon).
    public var onLock: ((LockEvent) -> Void)?
    public private(set) var lastActivity: Date
    public private(set) var lastLockEvent: LockEvent?

    private let clipboard: SecureClipboard?
    private let now: () -> Date

    public init(settings: LockSettings = .load(), clipboard: SecureClipboard? = .shared,
                now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.clipboard = clipboard
        self.now = now
        self.lastActivity = now()
    }

    public func update(_ settings: LockSettings) {
        self.settings = settings
        // A newly chosen interval counts from now, not from long ago.
        noteActivity()
    }

    /// Returns true if the event locked (or would have locked) the vault.
    @discardableResult
    public func handle(_ event: LockEvent) -> Bool {
        guard settings.shouldLock(on: event) else { return false }
        session?.lockSession(reason: event)
        onLock?(event)
        clipboard?.clearNow()
        lastLockEvent = event
        return true
    }

    /// Any interaction with a Strongroom window, the overlay or the menu.
    public func noteActivity() {
        lastActivity = now()
    }

    /// When the idle lock fires, if it is on.
    public var idleDeadline: Date? {
        settings.idleLock.seconds.map { lastActivity.addingTimeInterval($0) }
    }

    /// Call periodically. Locks once the idle interval has passed since the
    /// last interaction, only while unlocked.
    @discardableResult
    public func checkIdle() -> Bool {
        guard let deadline = idleDeadline, session?.isSessionUnlocked == true, now() >= deadline else { return false }
        return handle(.idleTimeout)
    }
}
