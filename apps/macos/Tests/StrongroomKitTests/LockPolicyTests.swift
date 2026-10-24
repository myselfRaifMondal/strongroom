import AppKit
import Foundation
@testable import StrongroomKit
import Testing

/// Stand-in for the app model: holds an "open vault" plus the derived secret
/// state the real model keeps (ranking, reuse map, strength cache).
@MainActor
private final class FakeSession: LockableSession {
    var vaultOpen = true
    var ranking: [String: Int] = ["a": 90, "b": 10]
    var reused: Set<String> = ["a", "b"]
    var strengthCache = VaultAnalysis.StrengthCache()
    var lockCalls: [LockEvent] = []

    var isSessionUnlocked: Bool { vaultOpen }

    func lockSession(reason: LockEvent) {
        lockCalls.append(reason)
        vaultOpen = false
        ranking = [:]
        reused = []
        strengthCache.clear()
    }
}

private final class TestClock {
    var t = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) }
}

private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("strongroom-lock-test-\(UUID().uuidString)"))
}

@MainActor @Suite struct LockPolicyTests {
    @Test func defaults() {
        let s = LockSettings.defaults
        #expect(s.lockOnScreenLock)
        #expect(s.idleLock == .never)
    }

    @Test func alwaysOnEventsLockWhateverTheSettings() {
        let off = LockSettings(lockOnScreenLock: false, idleLock: .never)
        for e in [LockEvent.systemSleep, .sessionResigned, .appTerminating, .manual] {
            #expect(off.shouldLock(on: e), "\(e) must always lock")
        }
    }

    @Test func screenLockAndScreensaverFollowTheToggle() {
        let on = LockSettings(lockOnScreenLock: true)
        let off = LockSettings(lockOnScreenLock: false)
        #expect(on.shouldLock(on: .screenLocked))
        #expect(on.shouldLock(on: .screensaverStarted))
        #expect(!off.shouldLock(on: .screenLocked))
        #expect(!off.shouldLock(on: .screensaverStarted))
    }

    @Test func idleLocksOnlyWithAnInterval() {
        #expect(!LockSettings(idleLock: .never).shouldLock(on: .idleTimeout))
        #expect(LockSettings(idleLock: .fiveMinutes).shouldLock(on: .idleTimeout))
    }

    @Test func intervalsOffered() {
        #expect(IdleLockInterval.allCases.map(\.rawValue) == [0, 300, 900, 1800, 3600, 14400])
        #expect(IdleLockInterval.never.seconds == nil)
        #expect(IdleLockInterval.fourHours.seconds == 14400)
    }

    @Test func settingsRoundTripThroughUserDefaults() throws {
        let name = "strongroom-lock-test-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        #expect(LockSettings.load(store) == .defaults)
        LockSettings(lockOnScreenLock: false, idleLock: .thirtyMinutes).save(store)
        #expect(LockSettings.load(store) == LockSettings(lockOnScreenLock: false, idleLock: .thirtyMinutes))
        // Unknown stored value falls back to Never.
        store.set(42, forKey: "lock.idleSeconds")
        #expect(LockSettings.load(store).idleLock == .never)
    }

    @Test func coordinatorLocksSessionRunsCleanupAndClearsClipboard() {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let clipboard = SecureClipboard(pasteboard: pb)
        let session = FakeSession()
        let c = LockCoordinator(settings: .defaults, clipboard: clipboard)
        c.session = session
        var cleaned: [LockEvent] = []
        c.onLock = { e in
            // The session is already locked when the UI clean-up runs.
            #expect(!session.vaultOpen)
            cleaned.append(e)
        }

        clipboard.copy("hunter2-secret", clearAfter: 3600)
        #expect(pb.string(forType: .string) == "hunter2-secret")

        #expect(c.handle(.systemSleep))
        #expect(session.lockCalls == [.systemSleep])
        #expect(cleaned == [.systemSleep])
        #expect(!session.vaultOpen)
        #expect(session.ranking.isEmpty)
        #expect(session.reused.isEmpty)
        // Cleared immediately, not after the 25 s timeout.
        #expect(pb.string(forType: .string) == nil)
        #expect(c.lastLockEvent == .systemSleep)
    }

    @Test func disabledEventDoesNothing() {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let clipboard = SecureClipboard(pasteboard: pb)
        let session = FakeSession()
        let c = LockCoordinator(settings: LockSettings(lockOnScreenLock: false), clipboard: clipboard)
        c.session = session
        var cleaned = 0
        c.onLock = { _ in cleaned += 1 }
        clipboard.copy("s3cret", clearAfter: 3600)

        #expect(!c.handle(.screenLocked))
        #expect(!c.handle(.screensaverStarted))
        #expect(session.vaultOpen)
        #expect(session.lockCalls.isEmpty)
        #expect(cleaned == 0)
        #expect(pb.string(forType: .string) == "s3cret")

        // Sleep still locks.
        #expect(c.handle(.systemSleep))
        #expect(!session.vaultOpen)
    }

    @Test func screenLockLocksByDefault() {
        let session = FakeSession()
        let c = LockCoordinator(settings: .defaults, clipboard: nil)
        c.session = session
        #expect(c.handle(.screenLocked))
        #expect(session.lockCalls == [.screenLocked])
    }

    @Test func lockingWhenAlreadyLockedIsHarmless() {
        let session = FakeSession()
        session.vaultOpen = false
        let c = LockCoordinator(settings: .defaults, clipboard: nil)
        c.session = session
        #expect(c.handle(.sessionResigned))
        #expect(!session.vaultOpen)
    }

    @Test func idleTimerUsesInjectedClock() {
        let clock = TestClock()
        let session = FakeSession()
        let c = LockCoordinator(settings: LockSettings(idleLock: .fiveMinutes), clipboard: nil, now: { clock.t })
        c.session = session

        clock.advance(299)
        #expect(!c.checkIdle())
        #expect(session.vaultOpen)

        // Interaction restarts the countdown.
        c.noteActivity()
        clock.advance(299)
        #expect(!c.checkIdle())
        #expect(c.idleDeadline == clock.t.addingTimeInterval(1))

        clock.advance(1)
        #expect(c.checkIdle())
        #expect(session.lockCalls == [.idleTimeout])
        #expect(!session.vaultOpen)

        // Already locked: no second lock.
        clock.advance(10_000)
        #expect(!c.checkIdle())
        #expect(session.lockCalls == [.idleTimeout])
    }

    @Test func idleNeverDoesNotLock() {
        let clock = TestClock()
        let session = FakeSession()
        let c = LockCoordinator(settings: .defaults, clipboard: nil, now: { clock.t })
        c.session = session
        clock.advance(30 * 24 * 3600)
        #expect(c.idleDeadline == nil)
        #expect(!c.checkIdle())
        #expect(session.vaultOpen)
    }

    @Test func changingTheIntervalCountsFromNow() {
        let clock = TestClock()
        let session = FakeSession()
        let c = LockCoordinator(settings: .defaults, clipboard: nil, now: { clock.t })
        c.session = session
        clock.advance(3 * 3600)
        c.update(LockSettings(idleLock: .fiveMinutes))
        #expect(!c.checkIdle())
        clock.advance(300)
        #expect(c.checkIdle())
    }

    @Test func menuBarIconsAreTemplates() {
        for locked in [false, true] {
            let img = MenuBarIcon.image(locked: locked)
            #expect(img.isTemplate)
            #expect(img.size == NSSize(width: 18, height: 18))
        }
    }
}
