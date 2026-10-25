import AppKit
import StrongroomKit
import SwiftUI

/// Floating, non-activating panel opened by the global hotkey. Being
/// non-activating, it takes keyboard focus without making Strongroom the
/// active app, so the app the user was in stays the auto-type target.
final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
final class QuickAccessController: ObservableObject {
    private let model: AppModel
    private var panel: QuickAccessPanel?
    @Published var target: AutoType.Target?
    @Published var openCount = 0
    /// Last unlock failure shown in the overlay (never contains a secret).
    @Published var unlockError: String?
    /// Opens (or re-creates) the main window; set by the app delegate.
    var openMainWindowHandler: (() -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// "search" when unlocked; otherwise how the overlay offers to unlock.
    var modeDescription: String {
        if model.isUnlocked { return "search" }
        guard model.phase == .locked else { return "unavailable" }
        return model.touchIDAvailableNow ? "unlock-touchid" : "unlock-password"
    }

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // Capture the target before the panel takes focus.
        target = AutoType.captureFrontmost()
        unlockError = nil
        model.refreshGate()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        openCount += 1
        WindowPrivacy.protect(panel)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        AppLog.info("overlay shown mode=\(modeDescription)")
        // Locked: Touch ID first when the gate allows it; the password and
        // Secret Key fields stay available as the fallback.
        if model.phase == .locked && model.touchIDAvailableNow && !model.busy {
            Task { await unlockWithTouchID() }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func unlockWithTouchID() async {
        unlockError = await model.unlockWithTouchID(inline: true)
    }

    func unlock(password: String, secretKey: String) async {
        unlockError = await model.unlock(password: password, secretKey: secretKey, inline: true)
    }

    func openMainWindow() {
        hide()
        if let openMainWindowHandler { openMainWindowHandler(); return }
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue.contains("main") == true || w.title == "Strongroom" {
            w.makeKeyAndOrderFront(nil)
        }
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: QuickAccessView(controller: self).environmentObject(model))
        return panel
    }
}

struct QuickAccessView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: QuickAccessController
    @State private var query = ""
    @State private var selected = 0
    @State private var status: String?
    @State private var password = ""
    @State private var secretKey = ""
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case search, password, secretKey }

    /// The list scrolls, so this only bounds the work per keystroke.
    static let maxResults = 200

    private var results: [ItemSummary] {
        Array(model.search(query).prefix(Self.maxResults))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isUnlocked {
                unlocked
            } else if model.phase == .locked {
                locked
            } else {
                unavailable
            }
        }
        .padding(16)
        .frame(width: 560, height: 380, alignment: .top)
        .onChange(of: controller.openCount) {
            query = ""
            selected = 0
            status = nil
            password = ""
            secretKey = ""
            focus = model.isUnlocked ? .search : .password
        }
        .onChange(of: model.isUnlocked) {
            // Unlocked: straight into quick search. Locked: forget anything typed.
            query = ""
            selected = 0
            password = ""
            secretKey = ""
            focus = model.isUnlocked ? .search : .password
        }
        .onAppear { focus = model.isUnlocked ? .search : .password }
    }

    /// Unlock state. Shows no item data: only the lock, Touch ID and the
    /// password + Secret Key fallback.
    private var locked: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("Strongroom is locked").font(.title3.bold())
            if model.touchIDAvailableNow {
                Button { Task { await controller.unlockWithTouchID() } } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                }
                .disabled(model.busy)
            } else if model.touchIDEnrolled {
                Text(DeviceUnlock.explain(model.gateReason))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Form {
                SecureField("Master password", text: $password)
                    .focused($focus, equals: .password)
                    .onSubmit { focus = .secretKey }
                SecureField("Secret Key (SR1-…)", text: $secretKey)
                    .focused($focus, equals: .secretKey)
                    .onSubmit(submitPassword)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 420)
            .scrollDisabled(true)
            HStack(spacing: 12) {
                Button("Open Strongroom") { controller.openMainWindow() }
                Button("Unlock", action: submitPassword)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || secretKey.isEmpty || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let error = controller.unlockError {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("Open Strongroom to set up your vault.").foregroundStyle(.secondary)
            Button("Open Strongroom") { controller.openMainWindow() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitPassword() {
        guard !password.isEmpty, !secretKey.isEmpty, !model.busy else { return }
        let p = password, k = secretKey
        password = ""
        Task {
            await controller.unlock(password: p, secretKey: k)
            if model.isUnlocked { secretKey = "" } else { focus = .password }
        }
    }

    private var unlocked: some View {
        let list = results
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Strongroom", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focus, equals: .search)
                    .onSubmit { copy(list, field: .password) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onChange(of: query) { selected = 0 }
            }
            Divider()
            if list.isEmpty {
                Text(query.isEmpty ? "No items" : "No matches").foregroundStyle(.secondary).padding(.top, 20)
                    .frame(maxWidth: .infinity)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
                            HStack {
                                Image(systemName: item.kind.symbolName).frame(width: 20).foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(item.title).lineLimit(1)
                                    if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                if idx == selected {
                                    Button("Password") { selected = idx; copy(list, field: .password) }
                                    Button("Username") { selected = idx; copy(list, field: .username) }
                                    if item.hasTotp { Button("Code") { selected = idx; copy(list, field: .totp) } }
                                    Button("Type…") { selected = idx; autoType(list) }
                                }
                            }
                            .controlSize(.small)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(idx == selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { selected = idx }
                            .id(idx)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                // Keep the arrow-key selection in view.
                .onChange(of: selected) { proxy.scrollTo(selected) }
                .onChange(of: query) { proxy.scrollTo(0, anchor: .top) }
            }
            HStack {
                Text(status ?? "↩ copy password · copied values clear after \(Int(SecureClipboard.defaultClearAfter)) s · esc closes")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let t = controller.target { Text("Target: \(t.appName)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private enum Field { case password, username, totp }

    private func copy(_ list: [ItemSummary], field: Field) {
        guard selected < list.count, let item = model.item(list[selected].id) else { return }
        switch field {
        case .password:
            guard let p = item.data.password else { status = "This item has no password."; return }
            SecureClipboard.shared.copy(p)
        case .username:
            guard let u = item.data.username else { status = "This item has no username."; return }
            SecureClipboard.shared.copy(u)
        case .totp:
            guard let code = model.totp(item.id) else { status = "No one-time code."; return }
            SecureClipboard.shared.copy(code.code)
        }
        controller.hide()
    }

    private func autoType(_ list: [ItemSummary]) {
        guard selected < list.count, let item = model.item(list[selected].id) else { return }
        guard let p = item.data.password else { status = "This item has no password."; return }
        AutoType.confirmAndType(p, itemTitle: item.data.title, target: controller.target) { controller.hide() }
    }
}
