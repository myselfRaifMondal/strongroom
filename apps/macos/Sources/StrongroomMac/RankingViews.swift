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
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(priority.color.opacity(0.22), in: Capsule())
            .foregroundStyle(.primary)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack {
                    Toggle("Only due for a change", isOn: $dueOnly).toggleStyle(.checkbox)
                    Spacer()
                    Text("\(model.ranking.dueCount) due").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
        .navigationTitle("Security Ranking")
    }

    private var visible: [RankedItem] { model.ranking.items.filter { !dueOnly || $0.due } }

    @ViewBuilder private var rankingList: some View {
        Section {
            ForEach(visible) { r in
                if let s = model.summary(r.id) {
                    RankingRow(summary: s, ranked: r).tag(r.id)
                        .contextMenu {
                            Button("Change Password…") { model.requestChangePassword(r.id) }
                            Divider()
                            ItemContextMenu(itemId: r.id)
                        }
                }
            }
            if visible.isEmpty && !model.ranking.items.isEmpty {
                Label("Nothing is due for a change.", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        } header: {
            Text("Worst first")
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
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Label("Same password on \(c.itemIDs.count) accounts", systemImage: "arrow.triangle.2.circlepath")
                                .symbolRenderingMode(.multicolor)
                            if c.maxImportance == .critical {
                                Text("Includes critical accounts").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One ranked password. The whole row selects the item; "Change…" opens the
/// editor with the generator ready.
struct RankingRow: View {
    @EnvironmentObject var model: AppModel
    let summary: ItemSummary
    let ranked: RankedItem

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s + 2) {
            Text("\(ranked.risk)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(minWidth: 30)
                .padding(.vertical, 3)
                .background(ranked.priority.color.opacity(0.2), in: RoundedRectangle(cornerRadius: DS.Radius.small))
                .help("Risk score \(ranked.risk) of 100")
                .accessibilityLabel("Risk \(ranked.risk)")
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text(summary.title).lineLimit(1).layoutPriority(1)
                    if ranked.inputs.importance == .critical {
                        Image(systemName: "exclamationmark.shield.fill").font(.caption).foregroundStyle(.red)
                            .help("Critical account (email, finance or developer)")
                            .accessibilityLabel("Critical account")
                    }
                }
                HStack(spacing: DS.Space.xs) {
                    PriorityBadge(priority: ranked.priority)
                    Text(reasons).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.xs)
            Button("Change…") { model.requestChangePassword(ranked.id) }
                .controlSize(.small)
                .help("Change password: opens the item with the generator ready")
                .fixedSize()
        }
        .padding(.vertical, DS.Space.xxs)
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

/// The detail pane of Security Ranking before an item is chosen: the summary
/// and what to do next.
struct RankingOverview: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Label("Security Ranking", systemImage: "list.number").font(.paneTitle)
                    HintText("Every password scored 0–100 from strength, reuse, age and a missing one-time code, weighted by how important the account is. Fix the top of the list first.")
                }
                LazyVGrid(columns: StatTile.columns, alignment: .leading, spacing: DS.Space.m) {
                    if let score = model.health?.securityScore {
                        StatTile(value: "\(score)", label: "Security score", tint: HealthView.color(for: score))
                    }
                    StatTile(value: "\(model.ranking.dueCount)", label: "Due for a change", tint: model.ranking.dueCount > 0 ? .orange : .green)
                    StatTile(value: "\(model.ranking.sharedCount)", label: "Share a password", tint: model.ranking.sharedCount > 0 ? .orange : .green)
                }
                SectionBox(title: "By priority", symbol: "chart.bar") {
                    ForEach(RiskPriority.allCases.reversed(), id: \.self) { p in
                        HStack {
                            Circle().fill(p.color).frame(width: 9, height: 9).accessibilityHidden(true)
                            Text(p.label)
                            Spacer()
                            Text("\(model.ranking.count(p))").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if let top = model.ranking.items.first, let s = model.summary(top.id) {
                    SectionBox(title: "Start here", symbol: "arrow.right.circle") {
                        HStack(spacing: DS.Space.m) {
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(s.title).font(.headline)
                                Text("Risk \(top.risk) · \(top.priority.label) priority").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show") { model.selection = top.id }
                            Button("Change Password…") { model.requestChangePassword(top.id) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                HintText("“Change Password…” opens the item with the generator ready. Nothing is replaced until you save. Tag an item priority:critical or priority:low to change its importance.")
            }
            .readableWidth()
            .panePadding()
        }
    }
}

/// A large number with a caption (overview panes).
struct StatTile: View {
    /// Tiles share a row when there is room and wrap when there is not.
    static let columns = [GridItem(.adaptive(minimum: 140), spacing: DS.Space.m, alignment: .top)]

    let value: String
    let label: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(value).font(.largeTitle.weight(.bold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.separator.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: rotation banner

struct RotationBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: DS.Space.s + 2) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange).accessibilityHidden(true)
            Text(RotationReminder.bannerText(count: model.ranking.dueCount)).font(.callout).lineLimit(1)
            Spacer(minLength: DS.Space.s)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s) { review; snooze }
                review
            }
            IconButton("Dismiss", systemImage: "xmark", help: "Dismiss until next unlock") { model.showRotationBanner = false }
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(.orange.opacity(0.12))
    }

    private var review: some View {
        Button("Review") {
            UserDefaults.standard.set(true, forKey: "ranking.dueOnly")
            model.sidebar = .ranking
            model.selection = nil
            model.showRotationBanner = false
        }
    }

    private var snooze: some View {
        Button("Snooze 7 Days") { model.snoozeRotation() }
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
        let folderCount = Set(effective.map(\.newFolder)).count
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(request.headline).font(.sheetTitle)
                HintText("Files logins into folders by the website they belong to. Only the folder and the title change; passwords and every other field stay as they are. You can undo this until you lock.")
                if request.ids == nil {
                    Picker("Items", selection: $allItems) {
                        Text("Only items without a folder").tag(false)
                        Text("All items").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }
            }
            .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.xl).padding(.bottom, DS.Space.m)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Changes").font(.sectionTitle).padding(.horizontal, DS.Space.m).padding(.top, DS.Space.s)
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
                    .overlay {
                        if full.isEmpty {
                            ContentUnavailableView(items.isEmpty ? "Loading…" : "Nothing to organize",
                                                   systemImage: "checkmark.circle",
                                                   description: Text(items.isEmpty ? "" : "These items are already filed by service."))
                        }
                    }
                }
                .frame(minWidth: 300, idealWidth: 460)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Proposed folders").font(.sectionTitle).padding(.horizontal, DS.Space.m).padding(.top, DS.Space.s)
                    List(Organizer.proposedTree(effective), children: \.children) { node in
                        HStack {
                            Label(node.name, systemImage: "folder")
                            Spacer()
                            Text("\(node.totalCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minWidth: 200, idealWidth: 260)
            }
            .frame(minHeight: 160, idealHeight: 380)
            Divider()
            HStack(spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("\(effective.count) change\(effective.count == 1 ? "" : "s") into \(folderCount) folder\(folderCount == 1 ? "" : "s")")
                    if effective.contains(where: \.isPromotion) {
                        Text("Includes items already filed that move into a service folder")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.s)
                Button(request.ids == nil ? "Cancel" : "Not Now", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Organize \(effective.count) Item\(effective.count == 1 ? "" : "s")") {
                    model.applyOrganize(effective)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(effective.isEmpty)
            }
            .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m)
        }
        .frame(minWidth: 560, idealWidth: DS.Sheet.wide.width, maxWidth: 1100,
               minHeight: DS.Sheet.minHeight + 60, idealHeight: DS.Sheet.wide.height)
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
                Text("left as it is").font(.caption).foregroundStyle(.secondary)
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
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Weekly reminder", isOn: binding(\.weeklyReminder))
            if model.rotation.weeklyReminder {
                Picker("Day", selection: binding(\.weekday)) {
                    ForEach(1 ... 7, id: \.self) { Text(Self.weekdays[$0 - 1]).tag($0) }
                }
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                LabeledContent("Notifications", value: reminders.status.description)
                if !reminders.status.canNotify {
                    Text("The reminder after unlock still appears.").font(.callout).foregroundStyle(.secondary)
                }
                Text("The notification only says how many passwords are due, never which ones: it can show on the lock screen.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
