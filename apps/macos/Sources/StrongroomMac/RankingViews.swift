import AppKit
import StrongroomKit
import SwiftUI

// MARK: security ranking

extension RiskPriority {
    var color: Color {
        switch self {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .green
        }
    }
}

struct PriorityBadge: View {
    let priority: RiskPriority
    var body: some View {
        Text(priority.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(priority.color.opacity(0.18), in: Capsule())
            .foregroundStyle(priority == .medium ? Color.primary : priority.color)
            .accessibilityLabel("\(priority.label) priority")
    }
}

/// Opens an item's first web URL in the default browser. The app itself
/// makes no request; only http(s) URLs are opened.
enum WebsiteOpener {
    static func url(_ urls: [String]) -> URL? {
        for raw in urls {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            let full = s.contains("://") ? s : "https://" + s
            if let u = URL(string: full), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil {
                return u
            }
        }
        return nil
    }

    static func open(_ urls: [String]) {
        if let u = url(urls) { NSWorkspace.shared.open(u) }
    }
}

struct RankingView: View {
    @EnvironmentObject var model: AppModel
    enum Mode: String, CaseIterable { case list = "Ranking", groups = "Same password" }
    @AppStorage("ranking.mode") private var mode: Mode = .list
    @AppStorage("ranking.dueOnly") private var dueOnly = false

    var body: some View {
        List(selection: $model.selection) {
            header.selectionDisabled()
            switch mode {
            case .list: rankingList
            case .groups: groupList
            }
        }
        .overlay {
            if model.ranking.items.isEmpty {
                ContentUnavailableView("No passwords to rank", systemImage: "list.number",
                                       description: Text("Items with a password appear here, worst first."))
            }
        }
        .navigationTitle("Security Ranking")
    }

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                if let score = model.health?.securityScore {
                    VStack(spacing: 2) {
                        Text("\(score)").font(.title.bold().monospacedDigit()).foregroundStyle(HealthView.color(for: score))
                        Text("Security score").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 84)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(RiskPriority.allCases.reversed(), id: \.self) { p in
                            HStack(spacing: 3) {
                                Circle().fill(p.color).frame(width: 7, height: 7)
                                Text("\(model.ranking.count(p)) \(p.label)").font(.caption.monospacedDigit())
                            }
                        }
                    }
                    let shared = model.ranking.sharedCount
                    Text(shared == 0 ? "No password is used on more than one account."
                         : "\(shared) account\(shared == 1 ? "" : "s") share a password with another account.")
                        .font(.caption).foregroundStyle(shared == 0 ? Color.secondary : Color.orange)
                    Text("\(model.ranking.dueCount) due for a change")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Toggle("Due for change", isOn: $dueOnly).toggleStyle(.checkbox)
            }
        }
    }

    private var visible: [RankedItem] { model.ranking.items.filter { !dueOnly || $0.due } }

    @ViewBuilder private var rankingList: some View {
        Section {
            ForEach(visible) { r in
                if let s = model.summary(r.id) {
                    RankingRow(summary: s, ranked: r).tag(r.id)
                        .contextMenu { ItemContextMenu(itemId: r.id) }
                }
            }
            if visible.isEmpty && !model.ranking.items.isEmpty {
                Label("Nothing is due for a change.", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        } header: {
            Text("Worst first")
        } footer: {
            Text("Score 0–100 from strength, reuse, age and a missing one-time code, weighted by how important the account is. Tag an item priority:critical or priority:low to change its importance.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var groupList: some View {
        if model.ranking.clusters.isEmpty {
            Label("No password is shared between accounts.", systemImage: "checkmark.circle").foregroundStyle(.green)
        }
        ForEach(model.ranking.clusters) { c in
            let members = c.itemIDs.compactMap { id in model.ranking.item(id) }.filter { !dueOnly || $0.due }
            if !members.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(members) { r in
                            if let s = model.summary(r.id) {
                                RankingRow(summary: s, ranked: r).tag(r.id)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                            Text("Same password used on \(c.itemIDs.count) accounts")
                            Spacer()
                            if c.maxImportance == .critical {
                                Text("includes critical accounts").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct RankingRow: View {
    @EnvironmentObject var model: AppModel
    let summary: ItemSummary
    let ranked: RankedItem

    var body: some View {
        HStack(spacing: 10) {
            Text("\(ranked.risk)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(ranked.priority.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.title).lineLimit(1)
                    PriorityBadge(priority: ranked.priority)
                    if ranked.inputs.importance == .critical {
                        Image(systemName: "exclamationmark.shield.fill").font(.caption2).foregroundStyle(.red)
                            .help("Critical account (email, finance or developer)")
                    }
                }
                Text(reasons).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Change password…") { model.requestChangePassword(ranked.id) }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var reasons: String {
        var parts: [String] = []
        let x = ranked.inputs
        parts.append(["very weak", "weak", "fair", "good", "strong"][Int(min(x.strength, 4))])
        if x.reusedWith > 0 { parts.append("used on \(x.reusedWith) other account\(x.reusedWith == 1 ? "" : "s")") }
        parts.append(x.ageDays >= 365 ? "\(x.ageDays / 365) yr old" : "\(x.ageDays) d old")
        if !x.hasTOTP { parts.append("no one-time code") }
        if ranked.due { parts.append("due") }
        let folder = FolderPath.components(summary.folder).joined(separator: " › ")
        if !folder.isEmpty { parts.append(folder) }
        return parts.joined(separator: " · ")
    }
}

// MARK: rotation banner

struct RotationBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
            Text("\(RotationReminder.bannerText(count: model.ranking.dueCount)) — ").font(.callout)
                + Text("Review").font(.callout.weight(.semibold))
            Spacer()
            Button("Review") {
                UserDefaults.standard.set(true, forKey: "ranking.dueOnly")
                model.sidebar = .ranking
                model.selection = nil
                model.showRotationBanner = false
            }
            .controlSize(.small)
            Button("Snooze 7 Days") { model.snoozeRotation() }.controlSize(.small)
            Button { model.showRotationBanner = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Dismiss until next unlock")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.orange.opacity(0.12))
    }
}

// MARK: organize preview

struct OrganizeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.OrganizeRequest
    @State private var items: [OrganizeItem] = []
    @State private var allItems = false
    @State private var excludedCategories: Set<ServiceCategory> = []
    @State private var excludedIDs: Set<String> = []
    @State private var expanded: Set<ServiceCategory> = []

    private var scope: OrganizeScope {
        if let ids = request.ids { return .ids(ids) }
        return allItems ? .all : .unfiled
    }

    /// Every possible change, ticked or not (for the list).
    private var full: [OrganizeChange] { Organizer.plan(items: items, scope: scope) }
    /// What "Organize" will do.
    private var effective: [OrganizeChange] {
        Organizer.plan(items: items, scope: scope, excludedCategories: excludedCategories, excludedIDs: excludedIDs)
    }

    var body: some View {
        let full = self.full
        let effective = self.effective
        let byID = Dictionary(effective.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 12) {
            Text(request.headline).font(.title2.bold())
            Text("Files logins into folders by the website they belong to. Only the folder and the title change; passwords and every other field stay as they are. You can undo this until you lock.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if request.ids == nil {
                Picker("Items", selection: $allItems) {
                    Text("Only items without a folder").tag(false)
                    Text("All items").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            HStack(alignment: .top, spacing: 14) {
                List {
                    ForEach(categories(full), id: \.self) { cat in
                        let rows = full.filter { $0.category == cat }
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(cat) },
                                                            set: { if $0 { expanded.insert(cat) } else { expanded.remove(cat) } })) {
                            ForEach(rows) { c in
                                Toggle(isOn: Binding(get: { !excludedIDs.contains(c.id) },
                                                     set: { if $0 { excludedIDs.remove(c.id) } else { excludedIDs.insert(c.id) } })) {
                                    changeLabel(c, applied: byID[c.id])
                                }
                                .toggleStyle(.checkbox)
                                .disabled(excludedCategories.contains(cat))
                            }
                        } label: {
                            Toggle(isOn: Binding(get: { !excludedCategories.contains(cat) },
                                                 set: { if $0 { excludedCategories.remove(cat) } else { excludedCategories.insert(cat) } })) {
                                Label("\(cat.folderName) (\(effective.filter { $0.category == cat }.count))", systemImage: cat.symbol)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(minWidth: 400)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Proposed folders").font(.headline)
                    List(Organizer.proposedTree(effective), children: \.children) { node in
                        HStack {
                            Label(node.name, systemImage: "folder")
                            Spacer()
                            Text("\(node.totalCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 260)
            }
            .frame(height: 380)
            if full.isEmpty {
                Text(items.isEmpty ? "Loading…" : "Nothing to organize: these items are already filed by service.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("\(effective.count) change\(effective.count == 1 ? "" : "s") into \(Set(effective.map(\.newFolder)).count) folder\(Set(effective.map(\.newFolder)).count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                if effective.contains(where: \.isPromotion) {
                    Text("· includes items already filed that move into a service folder")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(request.ids == nil ? "Cancel" : "Not Now", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Organize \(effective.count) Item\(effective.count == 1 ? "" : "s")") {
                    model.applyOrganize(effective)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(effective.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onAppear { items = model.organizeItems() }
    }

    private func categories(_ changes: [OrganizeChange]) -> [ServiceCategory] {
        let present = Set(changes.map(\.category))
        return ServiceCategory.allCases.filter { present.contains($0) }
    }

    @ViewBuilder private func changeLabel(_ c: OrganizeChange, applied: OrganizeChange?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(c.oldTitle).lineLimit(1)
            if let a = applied {
                Text("→ \(FolderPath.components(a.newFolder).joined(separator: " › ")) · “\(a.newTitle)”\(a.isPromotion ? " (already filed)" : "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("left as it is").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: settings

struct RotationSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var reminders: ReminderScheduler

    private static let weekdays = Calendar.current.weekdaySymbols

    var body: some View {
        Section("Password rotation") {
            Picker("Critical accounts", selection: binding(\.critical)) {
                ForEach(RotationInterval.allCases) { Text($0.label).tag($0) }
            }
            Picker("Other accounts", selection: binding(\.other)) {
                ForEach(RotationInterval.allCases) { Text($0.label).tag($0) }
            }
            Text("A password is due for a change when it is older than this, used on another account, or weak. Critical accounts: email and identity, finance, developer and cloud, or tagged priority:critical.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Weekly reminder", isOn: binding(\.weeklyReminder))
            if model.rotation.weeklyReminder {
                Picker("Day", selection: binding(\.weekday)) {
                    ForEach(1 ... 7, id: \.self) { Text(Self.weekdays[$0 - 1]).tag($0) }
                }
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                LabeledContent("Notifications", value: reminders.status.description)
                if !reminders.status.canNotify {
                    Text("The reminder after unlock still appears.").font(.caption).foregroundStyle(.secondary)
                }
                Text("The notification only says how many passwords are due, never which ones: it can show on the lock screen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let until = model.rotation.snoozedUntil, model.rotation.isSnoozed(now: Clock.now()) {
                HStack {
                    Text("Snoozed until \(Date(timeIntervalSince1970: TimeInterval(until)).formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    Button("Resume") { model.resumeRotation() }
                }
            } else {
                Button("Snooze Reminders for 7 Days") { model.snoozeRotation() }
            }
        }
        Section("Organize") {
            Toggle("Suggest folders for new items", isOn: binding(\.suggestFolders))
            Text("New logins get a folder and title from their website (you can change both), and imports offer to organize the new items.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await reminders.refreshStatus() }
    }

    private func binding<T>(_ kp: WritableKeyPath<RotationSettings, T>) -> Binding<T> {
        Binding(get: { model.rotation[keyPath: kp] }, set: { v in model.updateRotation { $0[keyPath: kp] = v } })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(from: DateComponents(hour: model.rotation.hour, minute: model.rotation.minute)) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            model.updateRotation { $0.hour = c.hour ?? 10; $0.minute = c.minute ?? 0 }
        })
    }
}
