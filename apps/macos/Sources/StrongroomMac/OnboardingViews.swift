import StrongroomKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .needsVault: CreateVaultView()
            case let .showSecretKey(key): SecretKeyView(secretKey: key)
            case .locked: UnlockView()
            case .unlocked: VaultView()
            case let .fatal(message):
                ContentUnavailableView("Strongroom cannot start", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .alert("Strongroom", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The plain warning required at vault creation and when showing the key.
struct DataLossWarning: View {
    var body: some View {
        Label {
            Text("If you lose your master password or your Secret Key, your data is gone for good. There is no recovery, no reset and no server that keeps a copy.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StrengthMeter: View {
    let password: String

    var body: some View {
        let report = estimateStrength(password: password)
        HStack(spacing: 4) {
            ForEach(0 ..< 5) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i <= Int(report.score) && !password.isEmpty ? color(report.score) : Color.secondary.opacity(0.2))
                    .frame(height: 5)
            }
            Text(password.isEmpty ? "" : String(format: "%.0f bits", report.entropyBits))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private func color(_ score: UInt8) -> Color {
        switch score {
        case 0, 1: return .red
        case 2: return .orange
        case 3: return .yellow
        default: return .green
        }
    }
}

struct CreateVaultView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var confirm = ""

    private var canCreate: Bool { password.count >= 10 && password == confirm && !model.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create your vault").font(.largeTitle.bold())
            Text("Strongroom keeps everything on this Mac. Nothing is sent anywhere; vaults move between devices only as files you export.")
                .foregroundStyle(.secondary)
            DataLossWarning()
            Form {
                SecureField("Master password", text: $password)
                StrengthMeter(password: password)
                SecureField("Confirm master password", text: $confirm)
                if !confirm.isEmpty && confirm != password {
                    Text("The passwords do not match.").font(.caption).foregroundStyle(.red)
                }
                if !password.isEmpty && password.count < 10 {
                    Text("Use at least 10 characters.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Create Vault") {
                    Task { await model.createVault(password: password) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(32)
        .frame(maxWidth: 560)
    }
}

struct SecretKeyView: View {
    @EnvironmentObject var model: AppModel
    let secretKey: String
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Secret Key").font(.largeTitle.bold())
            Text("This is shown once. You need it together with your master password to unlock this vault on a new device and to open exported files.")
                .foregroundStyle(.secondary)
            Text(secretKey)
                .font(.system(.title2, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy Secret Key") { model.copy(secretKey, label: "Secret Key") }
                Text("Write it down or store it somewhere safe and offline.").font(.caption).foregroundStyle(.secondary)
            }
            DataLossWarning()
            Toggle("I have stored my Secret Key somewhere safe", isOn: $saved)
            HStack {
                Spacer()
                Button("Continue") { model.acknowledgeSecretKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!saved)
            }
        }
        .padding(32)
        .frame(maxWidth: 600)
    }
}

struct UnlockView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var secretKey = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.system(size: 54)).foregroundStyle(.tint)
            Text("Strongroom is locked").font(.title.bold())
            Form {
                SecureField("Master password", text: $password)
                SecureField("Secret Key (SR1-…)", text: $secretKey)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 440)
            HStack(spacing: 12) {
                if model.touchIDEnrolled && model.deviceUnlockSupported {
                    Button {
                        Task { await model.unlockWithTouchID() }
                    } label: {
                        Label("Unlock with Touch ID", systemImage: "touchid")
                    }
                    .disabled(!model.touchIDAvailableNow || model.busy)
                }
                Button("Unlock") {
                    Task {
                        await model.unlock(password: password, secretKey: secretKey)
                        if model.isUnlocked { password = ""; secretKey = "" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || secretKey.isEmpty || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
            if model.touchIDEnrolled && model.gateReason != .notRequired {
                Text(DeviceUnlock.explain(model.gateReason)).font(.callout).foregroundStyle(.secondary)
            } else if !model.deviceUnlockSupported {
                Text("Touch ID unlock is unavailable on this Mac (no Secure Enclave or no enrolled fingerprint). Password unlock only.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .task {
            model.refreshGate()
            // After an automatic lock (sleep, screen lock, idle) the window may
            // still be on screen: wait for the user rather than prompting
            // while nobody is there.
            if model.touchIDAvailableNow && !model.lockedAutomatically { await model.unlockWithTouchID() }
        }
        .onChange(of: model.touchIDPromptRequest) {
            // The user asked for the window (menu bar, overlay, Dock).
            model.refreshGate()
            if model.touchIDAvailableNow { Task { await model.unlockWithTouchID() } }
        }
        .onChange(of: model.phase) { password = ""; secretKey = "" }
    }
}
