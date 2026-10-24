import Foundation
import StrongroomKit
import UserNotifications

/// The weekly rotation reminder through UserNotifications. The notification
/// carries only a count (`RotationReminder.body`): it shows on the lock
/// screen, so no title, username, folder or domain ever goes into it.
/// When notifications are unavailable or denied, the unlock banner is the
/// only reminder and Settings says so.
@MainActor
final class ReminderScheduler: ObservableObject {
    enum Status: Equatable {
        case unknown
        case notDetermined
        case authorized
        case denied
        case unavailable(String)

        var description: String {
            switch self {
            case .unknown: return "Checking…"
            case .notDetermined: return "Not asked yet"
            case .authorized: return "Allowed"
            case .denied: return "Not allowed in System Settings › Notifications. Only the banner after unlock reminds you."
            case let .unavailable(why): return "Unavailable (\(why)). Only the banner after unlock reminds you."
            }
        }

        var canNotify: Bool { self == .authorized }
    }

    @Published private(set) var status: Status = .unknown
    /// A refused authorization request (UNErrorDomain 1 for an ad-hoc signed
    /// build on macOS) stays the answer for this session.
    private var refusal: String?

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == UNErrorDomain && ns.code == UNError.Code.notificationsNotAllowed.rawValue {
            return "macOS does not allow notifications for this build (ad-hoc signed)"
        }
        return "\(ns.domain) \(ns.code)"
    }

    /// UNUserNotificationCenter aborts the process outside an app bundle
    /// (swift run, tests), so it is only touched from a bundled app.
    static var bundleOK: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter? { Self.bundleOK ? UNUserNotificationCenter.current() : nil }

    func refreshStatus() async {
        guard let center else { status = .unavailable("not running from the app bundle"); return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: status = .authorized
        case .denied: status = .denied
        case .notDetermined: status = refusal.map { .unavailable($0) } ?? .notDetermined
        default: status = .unavailable("status \(settings.authorizationStatus.rawValue)")
        }
    }

    /// Asks once (the first time the weekly toggle is on). Returns whether
    /// notifications may be shown.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { status = .unavailable("not running from the app bundle"); return false }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshStatus()
            return granted
        } catch {
            refusal = Self.describe(error)
            status = .unavailable(refusal!)
            return false
        }
    }

    /// Replaces the pending reminder: one repeating weekly notification with
    /// `count`, or none when the count is 0, the toggle is off or permission
    /// is missing. While snoozed, a single notification at the first weekly
    /// slot after the snooze ends.
    func schedule(count: Int, settings: RotationSettings) async {
        guard let center else { return }
        center.removePendingNotificationRequests(withIdentifiers: [RotationReminder.notificationID])
        guard settings.weeklyReminder, count > 0 else { return }
        await refreshStatus()
        if status == .notDetermined {
            _ = await requestAuthorization()
        }
        guard status.canNotify else { return } // the unlock banner remains

        let content = UNMutableNotificationContent()
        content.title = RotationReminder.title
        content.body = RotationReminder.body(count: count)
        content.sound = .default

        let trigger: UNCalendarNotificationTrigger
        if let until = settings.snoozedUntil, settings.isSnoozed(now: Clock.now()) {
            let slot = RotationReminder.nextSlot(onOrAfter: Date(timeIntervalSince1970: TimeInterval(until)),
                                                 weekday: settings.weekday, hour: settings.hour, minute: settings.minute)
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: slot)
            trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: false)
        } else {
            var c = DateComponents()
            c.weekday = settings.weekday
            c.hour = settings.hour
            c.minute = settings.minute
            trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: true)
        }
        let request = UNNotificationRequest(identifier: RotationReminder.notificationID, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            refusal = Self.describe(error)
            status = .unavailable(refusal!)
        }
    }

    func removeAll() {
        center?.removePendingNotificationRequests(withIdentifiers: [RotationReminder.notificationID])
    }

    /// `STRONGROOM_NOTIFICATION_PROBE=1`: reports whether this bundle may post
    /// notifications, then quits. Used to check an ad-hoc signed build. Prints
    /// no vault data (none is open).
    static func runProbe() async -> Never {
        let s = ReminderScheduler()
        print("PROBE bundle=\(Bundle.main.bundleIdentifier ?? "nil") bundled=\(bundleOK)")
        await s.refreshStatus()
        print("PROBE status-before=\(s.status)")
        let granted = await s.requestAuthorization()
        print("PROBE requestAuthorization granted=\(granted) status-after=\(s.status)")
        if granted {
            var settings = RotationSettings()
            settings.weeklyReminder = true
            await s.schedule(count: 3, settings: settings)
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            for p in pending {
                print("PROBE pending id=\(p.identifier) body=\(p.content.body) repeats=\((p.trigger as? UNCalendarNotificationTrigger)?.repeats ?? false)")
            }
            s.removeAll()
            print("PROBE removed pending=\(await UNUserNotificationCenter.current().pendingNotificationRequests().count)")
        }
        fflush(stdout)
        exit(0)
    }
}
