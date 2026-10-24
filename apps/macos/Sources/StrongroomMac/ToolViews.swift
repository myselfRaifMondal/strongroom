import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import StrongroomKit
import SwiftUI

// MARK: password health

struct HealthView: View {
    @EnvironmentObject var model: AppModel

    static func color(for score: UInt8) -> Color {
        switch score {
        case 80...: return .green
        case 50 ..< 80: return .orange
        default: return .red
        }
    }

    var body: some View {
        List(selection: $model.selection) {
            if let h = model.health {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().stroke(.quaternary, lineWidth: 8)
                            Circle().trim(from: 0, to: CGFloat(h.securityScore) / 100)
                                .stroke(Self.color(for: h.securityScore), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(h.securityScore)").font(.title.bold().monospacedDigit())
                        }
                        .frame(width: 76, height: 76)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Security score").font(.headline)
                            Text("The share of passwords that are strong, unique and changed within a year.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                    .selectionDisabled()
                }
                group("Reused passwords", "Used by more than one item. Change each to a unique password.",
                      symbol: "arrow.triangle.2.circlepath", ids: h.reusedItemIds)
                group("Weak passwords", "Easy to guess. Replace them with generated ones.",
                      symbol: "exclamationmark.triangle", ids: h.weakItemIds)
                group("Old passwords", "Not changed for more than a year.",
                      symbol: "calendar.badge.clock", ids: h.oldItemIds)
            } else {
                Text("Password health is not available.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Password Health")
    }

    @ViewBuilder
    private func group(_ title: String, _ help: String, symbol: String, ids: [String]) -> some View {
        Section {
            if ids.isEmpty {
                Label("None", systemImage: "checkmark.circle").foregroundStyle(.green).selectionDisabled()
            } else {
                ForEach(ids, id: \.self) { id in
                    if let s = model.summary(id) {
                        ItemRow(item: s, showFolder: true).tag(id)
                    }
                }
            }
        } header: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(ids.count)").monospacedDigit()
            }
        } footer: {
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: trash

struct TrashView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmPurge = false

    var body: some View {
        List {
            ForEach(model.trash, id: \.item.id) { entry in
                HStack(spacing: 10) {
                    Image(systemName: ItemPresentation.symbol(kind: entry.item.kind, tags: entry.item.tags))
                        .frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.item.title).lineLimit(1)
                        Text("Deleted \(Self.date(entry.deletedAt)) · removed for good \(Self.date(entry.purgeAt))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let folder = entry.item.folder {
                            Text(FolderPath.components(folder).joined(separator: " › ")).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("Restore") { model.restoreFromTrash(entry.item.id) }
                }
                .padding(.vertical, 2)
                .contextMenu { Button("Restore") { model.restoreFromTrash(entry.item.id) } }
            }
        }
        .overlay {
            if model.trash.isEmpty {
                ContentUnavailableView("The trash is empty", systemImage: "trash")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Items are deleted for good 180 days after they were trashed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete Expired") { confirmPurge = true }
                        .controlSize(.small)
                        .disabled(model.trash.isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider()
            }
            .background(.bar)
        }
        .navigationTitle("Trash")
        .confirmationDialog("Delete expired items for good?", isPresented: $confirmPurge) {
            Button("Delete Expired Items", role: .destructive) { model.purgeExpiredTrash() }
        } message: {
            Text("Only items trashed more than 180 days ago are deleted. This also happens automatically on unlock.")
        }
    }

    static func date(_ t: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(t)).formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: CSV import

extension CsvSource: CaseIterable, Identifiable {
    public static var allCases: [CsvSource] { [.bitwarden, .onePassword, .lastPass, .chrome] }
    public var id: String { name }
    var name: String {
        switch self {
        case .bitwarden: return "Bitwarden"
        // Apple Passwords exports the same columns 1Password does
        // (Title, URL, Username, Password, Notes, OTPAuth).
        case .onePassword: return "Apple Passwords / 1Password"
        case .lastPass: return "LastPass"
        case .chrome: return "Chrome / Chromium browsers"
        }
    }
    var howTo: String {
        switch self {
        case .bitwarden: return "Bitwarden: Tools › Export vault › File format .csv."
        case .onePassword: return "Apple Passwords: open the Passwords app › File › Export All Passwords to File…. 1Password: File › Export › choose the account › CSV."
        case .lastPass: return "LastPass: Account options › Advanced › Export › LastPass CSV file."
        case .chrome: return "Chrome: Settings › Passwords › ⋮ › Export passwords."
        }
    }
}

struct CSVImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: CsvSource = .bitwarden
    @State private var file: URL?
    @State private var summary: ImportSummary?
    @State private var trashed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from another password manager").font(.title2.bold())
            if let summary, let file {
                Label(AppModel.describe(summary, prefix: "Imported"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                deleteWarning
                HStack {
                    Button(trashed ? "Moved to the Trash" : "Move “\(file.lastPathComponent)” to the Trash") {
                        NSWorkspace.shared.recycle([file]) { _, error in
                            DispatchQueue.main.async {
                                if error == nil { trashed = true } else { model.errorMessage = "Could not move the file to the Trash." }
                            }
                        }
                    }
                    .disabled(trashed)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                if trashed {
                    Text("Now empty the Trash in Finder so the file is really gone.").font(.caption).foregroundStyle(.secondary)
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Form {
                    Picker("Exported from", selection: $source) {
                        ForEach(CsvSource.allCases) { Text($0.name).tag($0) }
                    }
                    Text(source.howTo).font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                deleteWarning
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Choose CSV File and Import…") {
                        guard let url = model.chooseCSV() else { return }
                        Task {
                            if let s = await model.importCSV(source: source, url: url) {
                                file = url
                                summary = s
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var deleteWarning: some View {
        Label {
            Text("A CSV export holds every password in plain text. Delete it as soon as the import is done, empty the Trash, and remove any copy in Downloads or a synced folder.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: devices and pairing

enum QRCode {
    /// CoreImage CIQRCodeGenerator; error correction M.
    static func image(for text: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

struct DevicesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var info: AppModel.PairingInfo?
    @State private var infoError: String?
    @State private var newName = ""
    @State private var newPayload = ""
    @State private var parsed: PairedDevice?
    @State private var parseError: String?
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Devices and pairing").font(.title2.bold())
            HStack(alignment: .top, spacing: 20) {
                thisMac.frame(width: 260)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    addDevice
                    Divider()
                    pairedList
                }
            }
            Text("Pairing only exchanges public keys. Exports can then be sealed to paired devices as well as to your master password; a paired device opens them with its own hardware key.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 760)
        .onAppear {
            switch model.thisMacPairing() {
            case let .success(i): info = i
            case let .failure(e): infoError = CoreErrors.describe(e)
            }
        }
    }

    private var thisMac: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Mac").font(.headline)
            if let info {
                if let img = QRCode.image(for: info.payload) {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Pairing QR code")
                }
                LabeledContent("Fingerprint") {
                    Text(info.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Text(info.payload).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(4)
                Button("Copy Pairing Text") { model.copy(info.payload, label: "Pairing text") }
                Text("Scan the code or paste the text on the other device, then check that both show the same fingerprint.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let infoError {
                Text("Pairing is unavailable: \(infoError)").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    private var addDevice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a device").font(.headline)
            TextField("Name (e.g. Pixel 8)", text: $newName).textFieldStyle(.roundedBorder)
            TextField("Pairing text from the other device (SR1PAIR:…)", text: $newPayload, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2 ... 4)
                .onChange(of: newPayload) { _, text in
                    confirmed = false
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { parsed = nil; parseError = nil; return }
                    do { parsed = try parsePairingPayload(payload: t); parseError = nil } catch {
                        parsed = nil
                        parseError = "Not a valid pairing text."
                    }
                }
            if let parsed {
                HStack {
                    Text("Fingerprint:").foregroundStyle(.secondary)
                    Text(parsed.fingerprint).font(.system(.title3, design: .monospaced).weight(.semibold))
                }
                Toggle("The other device shows exactly this fingerprint", isOn: $confirmed).toggleStyle(.checkbox)
            } else if let parseError {
                Text(parseError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Add Device") {
                    if model.addPairedDevice(name: newName, payload: newPayload) {
                        newName = ""; newPayload = ""; parsed = nil; confirmed = false
                    }
                }
                .disabled(parsed == nil || !confirmed)
            }
        }
    }

    private var pairedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired devices").font(.headline)
            if model.pairedDevices.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            }
            ForEach(model.pairedDevices) { d in
                HStack {
                    Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(d.name)
                        Text(d.fingerprint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { model.removePairedDevice(d.fingerprint) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove")
                }
            }
        }
    }
}

// MARK: second vault

/// Neutral wording on purpose: nothing here or elsewhere says which vault is
/// open.
struct SecondVaultSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var useNewKey = false
    @State private var secretKey = ""
    @State private var generated: String?
    @State private var created = false
    @State private var stored = false

    private var canCreate: Bool {
        password.count >= 10 && password == confirm && (useNewKey || !secretKey.isEmpty) && !model.busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Additional vault").font(.title2.bold())
            if created {
                Text("The additional vault is ready. Lock Strongroom and unlock with its password to fill it.")
                    .fixedSize(horizontal: false, vertical: true)
                if let generated {
                    Text("Its Secret Key (shown once):").font(.callout)
                    Text(generated).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Button("Copy Secret Key") { model.copy(generated, label: "Secret Key") }
                    Toggle("I have stored this Secret Key", isOn: $stored)
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(generated != nil && !stored) }
            } else {
                Text("Creates a second vault on this Mac with a different master password. The unlock screen opens whichever vault matches the password you type, the same way and in the same time for both.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Form {
                    SecureField("Master password for the additional vault", text: $password)
                    StrengthMeter(password: password)
                    SecureField("Confirm", text: $confirm)
                    if !confirm.isEmpty && confirm != password {
                        Text("The passwords do not match.").font(.caption).foregroundStyle(.red)
                    }
                    Toggle("Generate a new Secret Key for it", isOn: $useNewKey)
                    if !useNewKey {
                        SecureField("Secret Key to use (SR1-…)", text: $secretKey)
                        Text("Using your usual Secret Key means only the password differs at the unlock screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                DataLossWarning()
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        let sk = useNewKey ? generateSecretKey() : secretKey
                        Task {
                            if await model.createSecondVault(password: password, secretKey: sk) {
                                generated = useNewKey ? sk : nil
                                password = ""; confirm = ""; secretKey = ""
                                created = true
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
