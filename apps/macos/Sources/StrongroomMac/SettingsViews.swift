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
        VStack(alignment: .leading, spacing: 14) {
            switch request {
            case .export:
                Text("Export vault").font(.title2.bold())
                Text("The VTF file is encrypted with your master password and Secret Key. Anyone who has the file and both of them can read it. Re-enter them to confirm.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case let .importFile(url, info):
                Text("Import \(url.lastPathComponent)").font(.title2.bold())
                if let info {
                    Text("VTF v\(info.version) · \(info.passwordSlots) password slot(s) · \(info.deviceSlots) device slot(s) · \(info.chunkCount) chunk(s)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This file could not be inspected; it may not be a VTF file.").font(.caption).foregroundStyle(.orange)
                }
                Text("Enter the master password and Secret Key of the vault that exported this file. Items are merged into this vault.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if (info?.deviceSlots ?? 0) > 0 {
                    Text("If it was sealed to this Mac, use Transfer › Import with This Mac's Key instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                SecureField("Master password", text: $password)
                SecureField("Secret Key (SR1-…)", text: $secretKey)
                if isExport {
                    Section {
                        if model.pairedDevices.isEmpty {
                            Text("No paired devices. Pair one under Transfer › Devices and Pairing to seal exports to it.")
                                .font(.caption).foregroundStyle(.secondary)
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
                        }
                        if DeviceCapabilities.secureEnclaveAvailable {
                            Toggle("This Mac (open later with Touch ID or the login password)", isOn: $includeThisMac)
                        }
                    } header: {
                        Text("Also seal to devices")
                    } footer: {
                        Text("Each chosen device can open the file with its own hardware key, without the master password. Up to 15.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
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
        .padding(20)
        .frame(width: 500)
    }

    private var isExport: Bool {
        if case .export = request { return true }
        return false
    }
}

// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var trusted = AutoType.isTrusted
    @State private var confirmTravel: Bool?
    @State private var showSecondVault = false
    @State private var showDevices = false
    @State private var pendingCount = 0
    @StateObject private var loginItem = LoginItem()

    var body: some View {
        Form {
            Section("Touch ID") {
                if model.deviceUnlockSupported {
                    Toggle("Unlock with Touch ID", isOn: Binding(
                        get: { model.touchIDEnrolled },
                        set: { on in Task { await model.setTouchID(enabled: on) } }))
                        .disabled(!model.isUnlocked)
                    Text("The vault key is sealed to a Secure Enclave key that only works on this Mac and only with the fingerprints enrolled now. The master password is still required after a restart, after 5 failed attempts, every 7 days, and when fingerprints change.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Unavailable: this Mac has no Secure Enclave or no enrolled Touch ID fingerprint. Password unlock only.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Travel mode") {
                Toggle("Travel mode", isOn: Binding(
                    get: { model.travelModeOn },
                    set: { on in
                        pendingCount = on ? model.notTravelSafeCount : 0
                        confirmTravel = on
                    }))
                    .disabled(!model.isUnlocked)
                Text("Before crossing a border: travel mode deletes from this Mac every item that is not marked “Travel safe”. They are not hidden; they are gone from this Mac until you import an export or a backup made beforehand. Turning travel mode off does not bring them back.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Backups and devices") {
                HStack {
                    Button("Back Up Vault…") { Task { await model.backup() } }.disabled(!model.isUnlocked)
                    Button("Devices and Pairing…") { showDevices = true }.disabled(!model.isUnlocked)
                }
                Text("A backup is an encrypted copy that opens with the same master password and Secret Key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.isUnlocked && !model.secondVaultExists {
                Section("Additional vault") {
                    Button("Create an Additional Vault…") { showSecondVault = true }
                    Text("A second vault with its own master password. The unlock screen opens whichever vault matches the password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            RotationSettingsSection(reminders: model.reminders)
            Section("Locking") {
                Toggle("Lock when the screen locks or the screen saver starts", isOn: $model.lockSettings.lockOnScreenLock)
                Picker("Lock after inactivity", selection: $model.lockSettings.idleLock) {
                    ForEach(IdleLockInterval.allCases) { Text($0.label).tag($0) }
                }
                Text("Strongroom always locks before the Mac sleeps, on fast user switching, at logout and when it quits. Inactivity counts from your last use of Strongroom. While unlocked in the background, the vault key stays in this app's memory.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Background") {
                Toggle("Open at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                LabeledContent("Status", value: loginItem.statusText)
                if loginItem.status == .requiresApproval {
                    Text("macOS needs your approval: turn Strongroom on in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items Settings") { loginItem.openLoginItemsSettings() }
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("Closing the window keeps Strongroom running in the menu bar, so ⌥⌘\\ always works. Quit it from the menu-bar icon.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Quick access") {
                LabeledContent("Global shortcut", value: "⌥⌘\\")
                if !model.hotKeyRegistered {
                    Text("The shortcut could not be registered (another app may be using it).").foregroundStyle(.orange)
                }
                LabeledContent("Clipboard", value: "cleared after \(Int(SecureClipboard.defaultClearAfter)) s; hidden from clipboard history")
            }
            Section("Auto-type") {
                LabeledContent("Accessibility permission", value: trusted ? "Granted" : "Not granted")
                if !trusted {
                    Text("Without it Strongroom will not type anything.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Privacy & Security Settings") { AutoType.openAccessibilitySettings() }
                }
            }
            Section("Privacy") {
                Text("No network access. Strongroom windows are excluded from screenshots and screen sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 520)
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
}
