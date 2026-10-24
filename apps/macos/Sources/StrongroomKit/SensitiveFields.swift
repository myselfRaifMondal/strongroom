import Foundation

/// Naming convention for the per-account sensitive sections. They are plain
/// custom fields (no format or FFI change), so every Strongroom client and
/// every export shows them as readable "name: value" pairs, and the macOS app
/// groups them into sections by name. Matching is case-insensitive and
/// tolerant of extra spaces.
///
/// | Section             | Field name                         | Concealed |
/// |---------------------|------------------------------------|-----------|
/// | Recovery codes      | `Recovery code 1`, `Recovery code 2`, … (also `Backup code N`) | yes |
/// | used recovery code  | `[used] Recovery code 3`           | yes |
/// | Security questions  | `Security question 1` + `Security answer 1`, … | yes |
/// | 2FA / backup notes  | `2FA backup note` (also `2FA note`, `Backup note`) | yes |
/// | PINs                | `PIN`, `PIN (ATM)`, `Transaction PIN`, … | yes |
/// | Seed phrase words   | `Seed word 1` … `Seed word 24`     | yes |
///
/// "Used" is a prefix on the field **name**, never on the value: the code
/// itself is never altered, so copying a used code still copies exactly what
/// the service issued, other clients show `[used] Recovery code 3`, and
/// marking a code unused again restores the original name. A prefix (not a
/// suffix) keeps the marker visible even when another client truncates long
/// names.
public enum SensitiveField: Equatable, Sendable {
    case recoveryCode(number: Int?, used: Bool)
    case securityQuestion(number: Int)
    case securityAnswer(number: Int)
    case twoFactorNote
    case pin
    case seedWord(number: Int)
    case other

    public static let usedPrefix = "[used] "
    public static let recoveryCodeBase = "Recovery code"
    public static let securityQuestionBase = "Security question"
    public static let securityAnswerBase = "Security answer"
    public static let twoFactorNoteName = "2FA backup note"
    public static let pinName = "PIN"
    public static let seedWordBase = "Seed word"

    public static func recoveryCodeName(_ number: Int, used: Bool = false) -> String {
        (used ? usedPrefix : "") + "\(recoveryCodeBase) \(number)"
    }

    public static func securityQuestionName(_ number: Int) -> String { "\(securityQuestionBase) \(number)" }
    public static func securityAnswerName(_ number: Int) -> String { "\(securityAnswerBase) \(number)" }
    public static func seedWordName(_ number: Int) -> String { "\(seedWordBase) \(number)" }

    /// Collapses runs of whitespace and lowercases.
    private static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// "recovery code 12" with base "recovery code" -> (matched, 12);
    /// "recovery code" -> (matched, nil); "recovery codes" -> no match.
    private static func numbered(_ n: String, base: String) -> (Bool, Int?) {
        guard n.hasPrefix(base) else { return (false, nil) }
        let rest = n.dropFirst(base.count)
        if rest.isEmpty { return (true, nil) }
        guard rest.first == " " else { return (false, nil) }
        let digits = rest.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let v = Int(digits), v >= 0 else { return (false, nil) }
        return (true, v)
    }

    public static func classify(_ name: String) -> SensitiveField {
        var n = normalize(name)
        var used = false
        let marker = normalize(usedPrefix)  // "[used]"
        if n.hasPrefix(marker) {
            used = true
            n = String(n.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        for base in ["recovery code", "backup code"] {
            let (ok, num) = numbered(n, base: base)
            if ok { return .recoveryCode(number: num, used: used) }
        }
        if used { return .other }
        if case let (true, num) = numbered(n, base: "security question") { return .securityQuestion(number: num ?? 0) }
        if case let (true, num) = numbered(n, base: "security answer") { return .securityAnswer(number: num ?? 0) }
        if case let (true, num?) = numbered(n, base: "seed word") { return .seedWord(number: num) }
        if ["2fa backup note", "2fa note", "backup note", "2fa backup notes"].contains(n) { return .twoFactorNote }
        if n == "pin" || n.hasPrefix("pin ") || n.hasPrefix("pin(") || n.hasSuffix(" pin") { return .pin }
        return .other
    }

    public var isRecoveryCode: Bool {
        if case .recoveryCode = self { return true }
        return false
    }

    /// Name with the used marker set or cleared. Names that are not recovery
    /// codes are returned unchanged.
    public static func settingUsed(_ name: String, _ used: Bool) -> String {
        guard case let .recoveryCode(_, isUsed) = classify(name) else { return name }
        if isUsed == used { return name }
        if used { return usedPrefix + name.trimmingCharacters(in: .whitespaces) }
        // Strip the marker however it was spelled ("[USED]  Recovery code 1").
        var s = Substring(name.trimmingCharacters(in: .whitespaces))
        s = s.dropFirst(6) // "[used]"
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Recovery-code helpers over a field list.
public enum RecoveryCodes {
    public struct Entry: Equatable, Sendable {
        public let index: Int
        public let number: Int?
        public let used: Bool
    }

    public static func entries(_ names: [String]) -> [Entry] {
        names.enumerated().compactMap { i, n in
            if case let .recoveryCode(num, used) = SensitiveField.classify(n) { return Entry(index: i, number: num, used: used) }
            return nil
        }
    }

    /// Codes that are not marked used and have a value.
    public static func unusedCount(_ fields: [CustomField]) -> Int {
        entries(fields.map(\.name)).filter { !$0.used && !fields[$0.index].value.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    public static func totalCount(_ fields: [CustomField]) -> Int {
        entries(fields.map(\.name)).filter { !fields[$0.index].value.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// Marks the field at `index` used/unused (no-op for other fields).
    public static func setUsed(_ fields: [CustomField], index: Int, used: Bool) -> [CustomField] {
        guard fields.indices.contains(index) else { return fields }
        var out = fields
        out[index] = CustomField(name: SensitiveField.settingUsed(fields[index].name, used),
                                 value: fields[index].value, concealed: fields[index].concealed)
        return out
    }

    /// Splits pasted codes: one per line, or separated by commas/semicolons;
    /// on a single line, by whitespace. Numbering like "1." or "1)" is removed.
    public static func parse(_ pasted: String) -> [String] {
        let lines = pasted.components(separatedBy: CharacterSet(charactersIn: "\n\r,;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tokens: [String]
        if lines.count == 1, let only = lines.first, only.contains(" ") {
            // "abcd-efgh ijkl-mnop": whitespace separated on one line, unless
            // it looks like one code written in groups ("1234 5678").
            let parts = only.split(separator: " ").map(String.init)
            tokens = parts.allSatisfy { $0.count >= 6 } ? parts : [only]
        } else {
            tokens = lines
        }
        return tokens.map { t in
            var s = Substring(t)
            if let r = s.range(of: #"^\d{1,3}[.)]\s*"#, options: .regularExpression) { s = s[r.upperBound...] }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// The next free code number in a field list.
    public static func nextNumber(_ names: [String]) -> Int {
        (entries(names).compactMap(\.number).max() ?? 0) + 1
    }

    /// Fields for newly pasted codes, numbered after the existing ones.
    public static func newFields(for codes: [String], existingNames: [String]) -> [CustomField] {
        let start = nextNumber(existingNames)
        return codes.enumerated().map { i, c in
            CustomField(name: SensitiveField.recoveryCodeName(start + i), value: c, concealed: true)
        }
    }
}

/// How the editor and the detail view group an item's fields.
public struct FieldGroups: Equatable, Sendable {
    public struct SecurityPair: Equatable, Sendable {
        public let number: Int
        public var question: Int?
        public var answer: Int?
    }

    /// Fields named by the item's template, in template order.
    public var template: [Int] = []
    public var recoveryCodes: [Int] = []
    public var securityPairs: [SecurityPair] = []
    public var twoFactorNotes: [Int] = []
    public var pins: [Int] = []
    /// Ordered by word number.
    public var seedWords: [Int] = []
    public var other: [Int] = []

    public init() {}

    /// Template field names win over the section convention (a card template's
    /// "PIN" shows with the card fields, not in a separate PIN section).
    public static func group(names: [String], template: ItemTemplate?) -> FieldGroups {
        var g = FieldGroups()
        var templateSlots: [String: Int] = [:]
        if let template {
            for (i, f) in template.fields.enumerated() where templateSlots[f.name.lowercased()] == nil {
                templateSlots[f.name.lowercased()] = i
            }
        }
        var templateHits: [(slot: Int, index: Int)] = []
        var seed: [(Int, Int)] = []
        var claimed = Set<Int>()
        for (i, name) in names.enumerated() {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if let slot = templateSlots[key], !claimed.contains(slot) {
                claimed.insert(slot)
                templateHits.append((slot, i))
                continue
            }
            switch SensitiveField.classify(name) {
            case .recoveryCode: g.recoveryCodes.append(i)
            case let .securityQuestion(n):
                if let k = g.securityPairs.firstIndex(where: { $0.number == n && $0.question == nil }) {
                    g.securityPairs[k].question = i
                } else { g.securityPairs.append(SecurityPair(number: n, question: i, answer: nil)) }
            case let .securityAnswer(n):
                if let k = g.securityPairs.firstIndex(where: { $0.number == n && $0.answer == nil }) {
                    g.securityPairs[k].answer = i
                } else { g.securityPairs.append(SecurityPair(number: n, question: nil, answer: i)) }
            case .twoFactorNote: g.twoFactorNotes.append(i)
            case .pin: g.pins.append(i)
            case let .seedWord(n): seed.append((n, i))
            case .other: g.other.append(i)
            }
        }
        g.template = templateHits.sorted { $0.slot < $1.slot }.map(\.index)
        g.seedWords = seed.sorted { $0.0 < $1.0 }.map(\.1)
        g.securityPairs.sort { $0.number < $1.number }
        return g
    }
}

/// Seed-phrase words are stored as `Seed word N` fields; empty words are not
/// stored, so positions come from the numbers, not from the field order.
public enum SeedPhrase {
    public static let standardLengths = [12, 15, 18, 21, 24]

    public static func highestWordNumber(_ names: [String]) -> Int {
        names.compactMap { n -> Int? in
            if case let .seedWord(num) = SensitiveField.classify(n) { return num }
            return nil
        }.max() ?? 0
    }

    /// Words 1...highest, with "" for positions that are not stored.
    public static func words(_ fields: [CustomField]) -> [String] {
        var byNumber: [Int: String] = [:]
        for f in fields {
            if case let .seedWord(n) = SensitiveField.classify(f.name), n >= 1, n <= 48 { byNumber[n] = f.value }
        }
        guard let top = byNumber.keys.max() else { return [] }
        return (1 ... top).map { byNumber[$0] ?? "" }
    }
}
