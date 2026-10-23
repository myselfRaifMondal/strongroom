import StrongroomKit
import SwiftUI

struct ItemEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let itemId: String?
    @State var draft: ItemDraft
    @State private var showGenerator = false
    @State private var revealPassword = false

    init(itemId: String?, draft: ItemDraft) {
        self.itemId = itemId
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Kind", selection: Binding(get: { draft.kind }, set: { draft.changeKind(to: $0) })) {
                        ForEach(ItemKind.allCases) { Label($0.displayName, systemImage: $0.symbolName).tag($0) }
                    }
                    TextField("Title", text: $draft.title)
                }
                if draft.kind.usesUsername || draft.kind.usesPassword {
                    Section {
                        if draft.kind.usesUsername {
                            TextField("Username", text: $draft.username)
                        }
                        if draft.kind.usesPassword {
                            HStack {
                                if revealPassword {
                                    TextField(draft.kind.passwordLabel, text: $draft.password)
                                        .font(.system(.body, design: .monospaced))
                                } else {
                                    SecureField(draft.kind.passwordLabel, text: $draft.password)
                                }
                                Button { revealPassword.toggle() } label: { Image(systemName: revealPassword ? "eye.slash" : "eye") }
                                    .buttonStyle(.borderless)
                                Button { showGenerator = true } label: { Image(systemName: "wand.and.stars") }
                                    .buttonStyle(.borderless).help("Generate")
                                    .popover(isPresented: $showGenerator) {
                                        GeneratorView { value in
                                            draft.password = value
                                            showGenerator = false
                                        }
                                        .padding(16)
                                        .frame(width: 420)
                                    }
                            }
                            if !draft.password.isEmpty { StrengthMeter(password: draft.password) }
                        }
                    }
                }
                if draft.kind.usesTOTP {
                    Section {
                        TextField("One-time code secret (base32 or otpauth://)", text: $draft.totp)
                            .font(.system(.body, design: .monospaced))
                        if !draft.totp.trimmingCharacters(in: .whitespaces).isEmpty {
                            TOTPPreview(secret: draft.totp)
                        }
                    }
                }
                if draft.kind.usesURLs {
                    Section("Websites") {
                        ForEach(draft.urls.indices, id: \.self) { i in
                            HStack {
                                TextField("https://", text: Binding(
                                    get: { i < draft.urls.count ? draft.urls[i] : "" },
                                    set: { if i < draft.urls.count { draft.urls[i] = $0 } }))
                                Button { draft.urls.remove(at: i); if draft.urls.isEmpty { draft.urls = [""] } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add Website") { draft.urls.append("") }
                    }
                }
                Section("Fields") {
                    ForEach($draft.fields) { $field in
                        HStack {
                            TextField("Name", text: $field.name).frame(width: 140)
                            if field.concealed {
                                SecureField("Value", text: $field.value)
                            } else {
                                TextField("Value", text: $field.value)
                            }
                            Toggle("Hidden", isOn: $field.concealed).toggleStyle(.checkbox)
                            Button { draft.fields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Field") { draft.fields.append(.init(name: "", value: "", concealed: false)) }
                }
                Section {
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3 ... 10)
                    TextField("Folder", text: $draft.folder)
                    TextField("Tags (comma-separated)", text: $draft.tags)
                    Toggle("Travel safe (kept on this Mac in travel mode)", isOn: $draft.travelSafe)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(itemId == nil ? "Add" : "Save") {
                    if model.save(draft, id: itemId) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding(12)
        }
        .frame(width: 600, height: 640)
    }
}

struct TOTPPreview: View {
    let secret: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            switch Result(catching: { try totpCode(secret: secret.trimmingCharacters(in: .whitespacesAndNewlines), now: Clock.now()) }) {
            case let .success(code):
                Text("Current code: \(TOTPRow.grouped(code.code)) (\(code.secondsRemaining) s)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            case let .failure(error):
                Text(CoreErrors.describe(error)).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: generator

struct GeneratorView: View {
    @EnvironmentObject var model: AppModel
    /// When set, a "Use" button hands the value back (editor popover).
    let onUse: ((String) -> Void)?

    enum Mode: String, CaseIterable { case password = "Password", passphrase = "Passphrase" }

    @AppStorage("gen.mode") private var mode: Mode = .password
    @AppStorage("gen.length") private var length = 24.0
    @AppStorage("gen.lower") private var lowercase = true
    @AppStorage("gen.upper") private var uppercase = true
    @AppStorage("gen.digits") private var digits = true
    @AppStorage("gen.symbols") private var symbols = true
    @AppStorage("gen.ambiguous") private var avoidAmbiguous = true
    @AppStorage("gen.words") private var words = 5.0
    @AppStorage("gen.separator") private var separator = "-"
    @AppStorage("gen.capitalize") private var capitalize = false
    @AppStorage("gen.number") private var includeNumber = true
    @State private var value = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generator").font(.headline)
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(value.isEmpty ? " " : value)
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            StrengthMeter(password: value)

            if mode == .password {
                HStack {
                    Text("Length \(Int(length))").monospacedDigit().frame(width: 80, alignment: .leading)
                    Slider(value: $length, in: 8 ... 64, step: 1)
                }
                HStack {
                    Toggle("a–z", isOn: $lowercase)
                    Toggle("A–Z", isOn: $uppercase)
                    Toggle("0–9", isOn: $digits)
                    Toggle("!#$", isOn: $symbols)
                }
                .toggleStyle(.checkbox)
                Toggle("Avoid ambiguous characters", isOn: $avoidAmbiguous).toggleStyle(.checkbox)
            } else {
                HStack {
                    Text("Words \(Int(words))").monospacedDigit().frame(width: 80, alignment: .leading)
                    Slider(value: $words, in: 3 ... 12, step: 1)
                }
                HStack {
                    TextField("Separator", text: $separator).frame(width: 60)
                    Toggle("Capitalize", isOn: $capitalize)
                    Toggle("Include a number", isOn: $includeNumber)
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Button { regenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                Button { model.copy(value, label: "Generated value") } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(value.isEmpty)
                Spacer()
                if let onUse {
                    Button("Use") { onUse(value) }.disabled(value.isEmpty).keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear(perform: regenerate)
        .onChange(of: mode) { regenerate() }
        .onChange(of: length) { regenerate() }
        .onChange(of: lowercase) { regenerate() }
        .onChange(of: uppercase) { regenerate() }
        .onChange(of: digits) { regenerate() }
        .onChange(of: symbols) { regenerate() }
        .onChange(of: avoidAmbiguous) { regenerate() }
        .onChange(of: words) { regenerate() }
        .onChange(of: separator) { regenerate() }
        .onChange(of: capitalize) { regenerate() }
        .onChange(of: includeNumber) { regenerate() }
    }

    private func regenerate() {
        do {
            switch mode {
            case .password:
                value = try generatePassword(policy: PasswordPolicy(
                    length: UInt8(length), lowercase: lowercase, uppercase: uppercase,
                    digits: digits, symbols: symbols, avoidAmbiguous: avoidAmbiguous))
            case .passphrase:
                value = try generatePassphrase(policy: PassphrasePolicy(
                    words: UInt8(words), separator: separator, capitalize: capitalize, includeNumber: includeNumber))
            }
            error = nil
        } catch {
            value = ""
            self.error = CoreErrors.describe(error)
        }
    }
}

// MARK: export / import

struct TransferSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.TransferRequest
    @State private var password = ""
    @State private var secretKey = ""

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
            }
            Form {
                SecureField("Master password", text: $password)
                SecureField("Secret Key (SR1-…)", text: $secretKey)
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
                        case .export: ok = await model.export(password: password, secretKey: secretKey)
                        case let .importFile(url, _): ok = await model.importFile(url, password: password, secretKey: secretKey)
                        }
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || secretKey.isEmpty || model.busy)
            }
        }
        .padding(20)
        .frame(width: 480)
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
        .frame(width: 480)
        .onAppear { trusted = AutoType.isTrusted }
    }
}
