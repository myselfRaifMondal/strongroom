import Foundation

/// How often a password should be changed.
public enum RotationInterval: Int, CaseIterable, Identifiable, Sendable {
    case days30 = 30, days60 = 60, days90 = 90, days180 = 180, days365 = 365, never = 0

    public var id: Int { rawValue }
    public var days: Int? { self == .never ? nil : rawValue }

    public var label: String {
        switch self {
        case .never: return "Never"
        case .days365: return "Every year"
        default: return "Every \(rawValue) days"
        }
    }
}

/// Rotation reminder settings. Not secret; stored in UserDefaults.
public struct RotationSettings: Equatable, Sendable {
    public var critical: RotationInterval = .days90
    public var other: RotationInterval = .days365
    public var weeklyReminder = true
    /// Calendar weekday, 1 = Sunday ... 7 = Saturday.
    public var weekday = 2
    public var hour = 10
    public var minute = 0
    /// Banner and notification are quiet until then (Unix seconds).
    public var snoozedUntil: Int64?
    /// Suggest folders and titles for new and imported items.
    public var suggestFolders = true

    public init() {}

    public enum Key {
        public static let critical = "rotation.criticalDays"
        public static let other = "rotation.otherDays"
        public static let weekly = "rotation.weeklyReminder"
        public static let weekday = "rotation.weekday"
        public static let hour = "rotation.hour"
        public static let minute = "rotation.minute"
        public static let snoozedUntil = "rotation.snoozedUntil"
        public static let suggestFolders = "organize.suggestFolders"
    }

    public static func load(_ d: UserDefaults = .standard) -> RotationSettings {
        var s = RotationSettings()
        if d.object(forKey: Key.critical) != nil { s.critical = RotationInterval(rawValue: d.integer(forKey: Key.critical)) ?? s.critical }
        if d.object(forKey: Key.other) != nil { s.other = RotationInterval(rawValue: d.integer(forKey: Key.other)) ?? s.other }
        if d.object(forKey: Key.weekly) != nil { s.weeklyReminder = d.bool(forKey: Key.weekly) }
        if d.object(forKey: Key.weekday) != nil { s.weekday = min(7, max(1, d.integer(forKey: Key.weekday))) }
        if d.object(forKey: Key.hour) != nil { s.hour = min(23, max(0, d.integer(forKey: Key.hour))) }
        if d.object(forKey: Key.minute) != nil { s.minute = min(59, max(0, d.integer(forKey: Key.minute))) }
        if let v = d.object(forKey: Key.snoozedUntil) as? NSNumber { s.snoozedUntil = v.int64Value }
        if d.object(forKey: Key.suggestFolders) != nil { s.suggestFolders = d.bool(forKey: Key.suggestFolders) }
        return s
    }

    public func save(_ d: UserDefaults = .standard) {
        d.set(critical.rawValue, forKey: Key.critical)
        d.set(other.rawValue, forKey: Key.other)
        d.set(weeklyReminder, forKey: Key.weekly)
        d.set(weekday, forKey: Key.weekday)
        d.set(hour, forKey: Key.hour)
        d.set(minute, forKey: Key.minute)
        if let snoozedUntil { d.set(NSNumber(value: snoozedUntil), forKey: Key.snoozedUntil) } else { d.removeObject(forKey: Key.snoozedUntil) }
        d.set(suggestFolders, forKey: Key.suggestFolders)
    }

    public func interval(for importance: Importance) -> RotationInterval {
        importance == .critical ? critical : other
    }

    public func isSnoozed(now: Int64) -> Bool { (snoozedUntil ?? 0) > now }

    public static let snoozeSeconds: Int64 = 7 * 86_400
}

public enum DueReason: String, Equatable, Sendable {
    case old, reused, weak

    public var label: String {
        switch self {
        case .old: return "older than the rotation policy"
        case .reused: return "used on another account"
        case .weak: return "weak"
        }
    }
}

/// "Due for change": age since the password changed reaches the policy, OR
/// the password is reused, OR it is weak (strength score <= 1).
public enum RotationPolicy {
    public static let weakScore: UInt8 = 1

    public static func dueReasons(_ x: RiskInputs, policy: RotationSettings) -> [DueReason] {
        var r: [DueReason] = []
        if let days = policy.interval(for: x.importance).days, x.ageDays >= days { r.append(.old) }
        if x.reusedWith > 0 { r.append(.reused) }
        if x.strength <= weakScore { r.append(.weak) }
        return r
    }

    public static func isDue(_ x: RiskInputs, policy: RotationSettings) -> Bool { !dueReasons(x, policy: policy).isEmpty }
}

/// Text of the weekly reminder and the unlock banner. Notifications show on
/// the lock screen, so the text carries a count and nothing else: no titles,
/// usernames, folders or domains. It takes only the count, by design.
public enum RotationReminder {
    public static let notificationID = "strongroom.rotation.weekly"
    public static let title = "Strongroom"

    public static func body(count: Int) -> String {
        count == 1
            ? "Strongroom: 1 password is due for a change."
            : "Strongroom: \(count) passwords are due for a change."
    }

    public static func bannerText(count: Int) -> String {
        count == 1 ? "1 password should be changed" : "\(count) passwords should be changed"
    }

    /// The first weekly slot (weekday, hour:minute) at or after `date`.
    public static func nextSlot(onOrAfter date: Date, weekday: Int, hour: Int, minute: Int,
                                calendar: Calendar = .current) -> Date {
        var c = DateComponents()
        c.weekday = weekday
        c.hour = hour
        c.minute = minute
        c.second = 0
        let start = date.addingTimeInterval(-1)
        return calendar.nextDate(after: start, matching: c, matchingPolicy: .nextTime) ?? date
    }
}
