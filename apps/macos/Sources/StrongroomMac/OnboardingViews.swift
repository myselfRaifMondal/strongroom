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
        Callout(.warning,
                "If you lose your master password or your Secret Key, your data is gone for good. There is no recovery, no reset and no server that keeps a copy.",
                title: "Nobody can recover your vault")
    }
}

struct StrengthMeter: View {
    let password: String

    var body: some View {
        let report = estimateStrength(password: password)
        HStack(spacing: DS.Space.xs) {
            ForEach(0 ..< 5) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i <= Int(report.score) && !password.isEmpty ? color(report.score) : Color.secondary.opacity(0.2))
                    .frame(height: 5)
            }
            Text(password.isEmpty ? "" : "\(label(report.score)) · \(String(format: "%.0f", report.entropyBits)) bits")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 100, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(password.isEmpty ? "No password" : "Strength: \(label(report.score))")
    }

    private func label(_ score: UInt8) -> String {
        switch score {
        case 0: return "Very weak"
        case 1: return "Weak"
        case 2: return "Fair"
        case 3: return "Good"
        default: return "Strong"
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

/// The card the first-run and unlock screens sit on: centred, capped in
/// width, scrolling in short windows.
struct WelcomeCard<Content: View>: View {
    var width: CGFloat = DS.Width.form
    @ViewBuilder let content: Content

    var body: some View {
        CenteredScroll {
            VStack(alignment: .leading, spacing: DS.Space.l) { content }
                .padding(DS.Space.xl)
                .frame(maxWidth: width, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(.separator.opacity(0.6)))
                .padding(DS.Space.xl)
        }
    }
}

/// "Step 1 of 2" above the first-run screens.
struct StepLabel: View {
    let step: Int
    let of: Int
    let title: String

    var body: some View {
        Text("Step \(step) of \(of) · \(title)".uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Step \(step) of \(of): \(title)")
    }
}

struct CreateVaultView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var confirm = ""

    private var canCreate: Bool { password.count >= 10 && password == confirm && !model.busy }

    var body: some View {
        WelcomeCard {
            StepLabel(step: 1, of: 2, title: "Master password")
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Create your vault").font(.heroTitle)
                HintText("Strongroom keeps everything on this Mac. Nothing is sent anywhere; vaults move between devices only as files you export.")
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Label("You choose a master password now. Remember it; it is never stored.", systemImage: "1.circle.fill")
                Label("Strongroom then shows your Secret Key once. Write it down and keep it safe.", systemImage: "2.circle.fill")
                Label("You need both to unlock the vault on a new device and to open exported files.", systemImage: "key.fill")
            }
            .font(.callout)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.primary)
            DataLossWarning()
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SecureField("Master password", text: $password, prompt: Text("At least 10 characters"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Master password")
                StrengthMeter(password: password)
                SecureField("Confirm master password", text: $confirm, prompt: Text("Type it again"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Confirm master password")
                if !confirm.isEmpty && confirm != password {
                    Text("The passwords do not match.").font(.callout).foregroundStyle(.red)
                } else if !password.isEmpty && password.count < 10 {
                    HintText("Use at least 10 characters. A few unrelated words make a strong, memorable password.")
                }
            }
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Create Vault") {
                    Task { await model.createVault(password: password) }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!canCreate)
            }
        }
    }
}

struct SecretKeyView: View {
    @EnvironmentObject var model: AppModel
    let secretKey: String
    @State private var saved = false

    var body: some View {
        WelcomeCard(width: DS.Width.form + 60) {
            StepLabel(step: 2, of: 2, title: "Secret Key")
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Save your Secret Key").font(.heroTitle)
                HintText("This is shown once. You need it together with your master password to unlock this vault on a new device and to open exported files.")
            }
            Text(secretKey)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .accessibilityLabel("Secret Key \(secretKey)")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.m) {
                    Button { model.copy(secretKey, label: "Secret Key") } label: { Label("Copy Secret Key", systemImage: "doc.on.doc") }
                    HintText("Write it on paper or store it in a safe, offline place.")
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Button { model.copy(secretKey, label: "Secret Key") } label: { Label("Copy Secret Key", systemImage: "doc.on.doc") }
                    HintText("Write it on paper or store it in a safe, offline place.")
                }
            }
            DataLossWarning()
            Toggle("I have stored my Secret Key somewhere safe", isOn: $saved)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Continue") { model.acknowledgeSecretKey() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!saved)
            }
        }
    }
}

struct UnlockView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var secretKey = ""

    var body: some View {
        WelcomeCard(width: 460) {
            VStack(spacing: DS.Space.s) {
                Image(systemName: "lock.shield.fill")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Strongroom is locked").font(.title.bold())
                HintText("Enter your master password and Secret Key.")
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SecureField("Master password", text: $password, prompt: Text("Master password"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Master password")
                SecureField("Secret Key", text: $secretKey, prompt: Text("Secret Key (SR1-…)"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Secret Key")
                HintText("The Secret Key was shown when the vault was created. It starts with SR1-.", font: .caption)
            }
            VStack(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Button {
                        Task {
                            await model.unlock(password: password, secretKey: secretKey)
                            if model.isUnlocked { password = ""; secretKey = "" }
                        }
                    } label: {
                        Text("Unlock").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(password.isEmpty || secretKey.isEmpty || model.busy)
                }
                if model.touchIDEnrolled && model.deviceUnlockSupported {
                    Button {
                        Task { await model.unlockWithTouchID() }
                    } label: {
                        Label("Unlock with Touch ID", systemImage: "touchid").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(!model.touchIDAvailableNow || model.busy)
                }
            }
            if model.touchIDEnrolled && model.gateReason != .notRequired {
                HintText(DeviceUnlock.explain(model.gateReason)).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            } else if !model.deviceUnlockSupported {
                HintText("Touch ID unlock is unavailable on this Mac (no Secure Enclave or no enrolled fingerprint). Password unlock only.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
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
