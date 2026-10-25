import ServiceManagement
import StrongroomKit
import SwiftUI

// MARK: export / import

struct TransferSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.TransferRequest
    @State private var password = ""
    @State private var secretKey = ""
    @State private var recipients: Set<String> = []
    @State private var includeThisMac = false

    var body: some View {
        SheetScaffold(title: title, subtitle: subtitle, symbol: isExport ? "square.and.arrow.up" : "square.and.arrow.down",
                      size: DS.Sheet.medium) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if case let .importFile(_, info) = request {
                    if let info {
                        Label("VTF v\(info.version) · \(info.passwordSlots) password slot(s) · \(info.deviceSlots) device slot(s) · \(info.chunkCount) chunk(s)",
                              systemImage: "doc")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Callout(.warning, "This file could not be inspected; it may not be a VTF file.")
                    }
                    if (info?.deviceSlots ?? 0) > 0 {
                        HintText("If it was sealed to this Mac, use Import and Export › Import with This Mac's Key instead.")
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SecureField("Master password", text: $password, prompt: Text("Master password"))
                        .textFieldStyle(.roundedBorder)
                    SecureField("Secret Key", text: $secretKey, prompt: Text("Secret Key (SR1-…)"))
                        .textFieldStyle(.roundedBorder)
                }
                if isExport {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Also seal to devices").font(.sectionTitle)
                        if model.pairedDevices.isEmpty {
                            HintText("No paired devices. Pair one under Import and Export › Devices and Pairing to seal exports to it.")
                        }
                        ForEach(model.pairedDevices) { d in
                            Toggle(isOn: Binding(
                                get: { recipients.contains(d.fingerprint) },
                                set: { if $0 { recipients.insert(d.fingerprint) } else { recipients.remove(d.fingerprint) } })
                            ) {
                                VStack(alignment: .leading) {
                                    Text(d.name)
                                    Text(d.fingerprint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        if DeviceCapabilities.secureEnclaveAvailable {
                            Toggle("This Mac (open later with Touch ID or the login password)", isOn: $includeThisMac)
                                .toggleStyle(.checkbox)
                        }
                        HintText("Each chosen device can open the file with its own hardware key, without the master password. Up to 15.")
                    }
                }
            }
        } footer: {
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(isExport ? "Choose Location and Export…" : "Import") {
                Task {
                    let ok: Bool
                    switch request {
                    case .export:
                        let chosen = model.pairedDevices.filter { recipients.contains($0.fingerprint) }
                        ok = await model.export(password: password, secretKey: secretKey, recipients: chosen, includeThisMac: includeThisMac)
                    case let .importFile(url, _):
                        ok = await model.importFile(url, password: password, secretKey: secretKey)
                    }
                    if ok { dismiss() }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(password.isEmpty || secretKey.isEmpty || model.busy || recipients.count + (includeThisMac ? 1 : 0) > 15)
        }
    }

    private var title: String {
        switch request {
        case .export: return "Export vault"
        case let .importFile(url, _): return "Import \(url.lastPathComponent)"
        }
    }

    private var subtitle: String {
        switch request {
        case .export:
            return "The VTF file is encrypted with your master password and Secret Key. Anyone who has the file and both of them can read it. Re-enter them to confirm."
        case .importFile:
            return "Enter the master password and Secret Key of the vault that exported this file. Items are merged into this vault."
        }
    }

    private var isExport: Bool {
        if case .export = request { return true }
        return false
    }
}

// MARK: settings

/// The Settings window, in tabs so each page fits without long scrolling.
struct SettingsView: View {
    enum Tab: String, CaseIterable { case general, security, vault, reminders }

    @EnvironmentObject var model: AppModel
    @State private var tab: Tab
    @State private var trusted = AutoType.isTrusted
    @State private var confirmTravel: Bool?
    @State private var showSecondVault = false
    @State private var showDevices = false
    @State private var pendingCount = 0
    @StateObject private var loginItem = LoginItem()

    init(initialTab: Tab = .general) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            page { general }
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            page { security }
                .tabItem { Label("Security", systemImage: "lock.shield") }
                .tag(Tab.security)
            page { vault }
                .tabItem { Label("Vault", systemImage: "externaldrive") }
                .tag(Tab.vault)
            page { RotationSettingsSection(reminders: model.reminders) }
                .tabItem { Label("Reminders", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.reminders)
        }
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 720, minHeight: 360, idealHeight: 520)
        .onAppear {
            trusted = AutoType.isTrusted
            model.refreshTravelMode()
            loginItem.refresh()
        }
        .onChange(of: model.isUnlocked) {
            // Locked: close anything that works on the open vault.
            if !model.isUnlocked {
                showSecondVault = false
                showDevices = false
                confirmTravel = nil
            }
        }
        .confirmationDialog(confirmTravel == true ? "Turn on travel mode?" : "Turn off travel mode?",
                            isPresented: Binding(get: { confirmTravel != nil }, set: { if !$0 { confirmTravel = nil } })) {
            if confirmTravel == true {
                Button("Delete \(pendingCount) Item\(pendingCount == 1 ? "" : "s") from This Mac", role: .destructive) {
                    model.setTravelMode(true)
                }
            } else {
                Button("Turn Off Travel Mode") { model.setTravelMode(false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if confirmTravel == true {
                Text("\(pendingCount) item\(pendingCount == 1 ? " is" : "s are") not marked travel safe and will be deleted from this Mac, with their history. They come back only by importing an export or a backup you made before. Make sure you have one.")
            } else {
                Text("Items removed by travel mode do not come back by themselves. Import your export or backup to restore them.")
            }
        }
        .sheet(isPresented: $showSecondVault) { SecondVaultSheet() }
        .sheet(isPresented: $showDevices) { DevicesSheet() }
    }

    private func page<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        Form { content() }.formStyle(.grouped)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: pages

    @ViewBuilder private var general: some View {
        Section("Background") {
            Toggle("Open at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
            LabeledContent("Status", value: loginItem.statusText)
            if loginItem.status == .requiresApproval {
                Text("macOS needs your approval: turn Strongroom on in System Settings › General › Login Items.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items Settings") { loginItem.openLoginItemsSettings() }
            }
            if let error = loginItem.lastError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            footnote("Closing the window keeps Strongroom running in the menu bar, so ⌥⌘\\ always works. Quit it from the menu-bar icon.")
        }
        Section("Quick access") {
            LabeledContent("Global shortcut", value: "⌥⌘\\")
            if !model.hotKeyRegistered {
                Text("The shortcut could not be registered (another app may be using it).").foregroundStyle(.orange)
            }
            LabeledContent("Clipboard", value: "Cleared after \(Int(SecureClipboard.defaultClearAfter)) s; hidden from clipboard history")
        }
        Section("Auto-type") {
            LabeledContent("Accessibility permission", value: trusted ? "Granted" : "Not granted")
            if !trusted {
                footnote("Without it Strongroom will not type anything.")
                Button("Open Privacy & Security Settings") { AutoType.openAccessibilitySettings() }
            }
        }
        Section("Organize") {
            Toggle("Suggest folders for new items", isOn: Binding(get: { model.rotation.suggestFolders },
                                                                 set: { v in model.updateRotation { $0.suggestFolders = v } }))
            footnote("New logins get a folder and title from their website (you can change both), and imports offer to organize the new items.")
        }
        Section("Privacy") {
            footnote("No network access. Strongroom windows are excluded from screenshots and screen sharing.")
        }
    }

    @ViewBuilder private var security: some View {
        Section("Touch ID") {
            if model.deviceUnlockSupported {
                Toggle("Unlock with Touch ID", isOn: Binding(
                    get: { model.touchIDEnrolled },
                    set: { on in Task { await model.setTouchID(enabled: on) } }))
                    .disabled(!model.isUnlocked)
                footnote("The vault key is sealed to a Secure Enclave key that only works on this Mac and only with the fingerprints enrolled now. The master password is still required after a restart, after 5 failed attempts, every 7 days, and when fingerprints change.")
            } else {
                footnote("Unavailable: this Mac has no Secure Enclave or no enrolled Touch ID fingerprint. Password unlock only.")
            }
        }
        Section("Locking") {
            Toggle("Lock when the screen locks or the screen saver starts", isOn: $model.lockSettings.lockOnScreenLock)
            Picker("Lock after inactivity", selection: $model.lockSettings.idleLock) {
                ForEach(IdleLockInterval.allCases) { Text($0.label).tag($0) }
            }
            footnote("Strongroom always locks before the Mac sleeps, on fast user switching, at logout and when it quits. Inactivity counts from your last use of Strongroom. While unlocked in the background, the vault key stays in this app's memory.")
        }
        Section("Travel mode") {
            Toggle("Travel mode", isOn: Binding(
                get: { model.travelModeOn },
                set: { on in
                    pendingCount = on ? model.notTravelSafeCount : 0
                    confirmTravel = on
                }))
                .disabled(!model.isUnlocked)
            footnote("Before crossing a border: travel mode deletes from this Mac every item that is not marked “Travel safe”. They are not hidden; they are gone from this Mac until you import an export or a backup made beforehand. Turning travel mode off does not bring them back.")
        }
    }

    @ViewBuilder private var vault: some View {
        Section("Backups and devices") {
            HStack {
                Button("Back Up Vault…") { Task { await model.backup() } }.disabled(!model.isUnlocked)
                Button("Devices and Pairing…") { showDevices = true }.disabled(!model.isUnlocked)
            }
            footnote("A backup is an encrypted copy that opens with the same master password and Secret Key.")
        }
        if model.isUnlocked && !model.secondVaultExists {
            Section("Additional vault") {
                Button("Create an Additional Vault…") { showSecondVault = true }
                footnote("A second vault with its own master password. The unlock screen opens whichever vault matches the password.")
            }
        }
        if !model.isUnlocked {
            Section {
                footnote("Unlock Strongroom to back up the vault or pair devices.")
            }
        }
    }
}
