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
                    HStack(spacing: DS.Space.m) {
                        ScoreRing(score: h.securityScore, size: 56)
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text("Security score").font(.headline)
                            Text("Strong, unique and changed within a year.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, DS.Space.xs)
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
                            .contextMenu {
                                Button("Change Password…") { model.requestChangePassword(id) }
                                Divider()
                                ItemContextMenu(itemId: id)
                            }
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

/// The score as a ring with the number inside.
struct ScoreRing: View {
    let score: UInt8
    var size: CGFloat = 76

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size / 9)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(HealthView.color(for: score), style: StrokeStyle(lineWidth: size / 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font((size > 64 ? Font.title : .headline).bold().monospacedDigit())
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Security score \(score) of 100")
    }
}

/// The detail pane of Password Health before an item is chosen.
struct HealthOverview: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Label("Password Health", systemImage: "checkmark.shield").font(.paneTitle)
                if let h = model.health {
                    HStack(alignment: .center, spacing: DS.Space.xl) {
                        ScoreRing(score: h.securityScore, size: 96)
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Text(verdict(h.securityScore)).font(.title3.weight(.semibold))
                            HintText("The share of passwords that are strong, unique and changed within a year.")
                        }
                    }
                    LazyVGrid(columns: StatTile.columns, alignment: .leading, spacing: DS.Space.m) {
                        StatTile(value: "\(h.reusedItemIds.count)", label: "Reused", tint: h.reusedItemIds.isEmpty ? .green : .orange)
                        StatTile(value: "\(h.weakItemIds.count)", label: "Weak", tint: h.weakItemIds.isEmpty ? .green : .orange)
                        StatTile(value: "\(h.oldItemIds.count)", label: "Over a year old", tint: h.oldItemIds.isEmpty ? .green : .orange)
                    }
                    SectionBox(title: "What to do", symbol: "lightbulb") {
                        Label("Select an item in the list to review it. Its header has a Change… button that opens the generator.", systemImage: "1.circle")
                        Label("Fix reused passwords first: one leak opens every account that shares it.", systemImage: "2.circle")
                        Label("Security Ranking orders every password by risk.", systemImage: "3.circle")
                        HStack {
                            Spacer()
                            Button("Open Security Ranking") { model.sidebar = .ranking; model.selection = nil }
                        }
                    }
                    .symbolRenderingMode(.hierarchical)
                } else {
                    HintText("Password health is not available.")
                }
            }
            .readableWidth()
            .panePadding()
        }
    }

    private func verdict(_ score: UInt8) -> String {
        switch score {
        case 80...: return "Good"
        case 50 ..< 80: return "Needs some work"
        default: return "Needs attention"
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
                HStack(spacing: DS.Space.s + 2) {
                    Image(systemName: ItemPresentation.symbol(kind: entry.item.kind, tags: entry.item.tags))
                        .frame(width: 22).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(entry.item.title).lineLimit(1)
                        Text("Deleted \(Self.date(entry.deletedAt)) · gone \(Self.date(entry.purgeAt))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let folder = entry.item.folder {
                            Text(FolderPath.components(folder).joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: DS.Space.xs)
                    Button("Restore") { model.restoreFromTrash(entry.item.id) }
                        .controlSize(.small)
                        .fixedSize()
                }
                .padding(.vertical, DS.Space.xxs)
                .contextMenu { Button("Restore") { model.restoreFromTrash(entry.item.id) } }
            }
        }
        .overlay {
            if model.trash.isEmpty {
                ContentUnavailableView("The trash is empty", systemImage: "trash",
                                       description: Text("Items you delete stay here for 180 days."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.s) {
                    Text("Deleted for good 180 days after trashing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DS.Space.xs)
                    Button("Delete Expired…") { confirmPurge = true }
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(model.trash.isEmpty)
                }
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
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
        SheetScaffold(title: "Import from another password manager",
                      subtitle: summary == nil ? "Export a CSV file from your old password manager, then choose it here." : nil,
                      symbol: "square.and.arrow.down", size: DS.Sheet.medium) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if let summary, let file {
                    Callout(.success, AppModel.describe(summary, prefix: "Imported"))
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
                        HintText("Now empty the Trash in Finder so the file is really gone.")
                    }
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Picker("Exported from", selection: $source) {
                            ForEach(CsvSource.allCases) { Text($0.name).tag($0) }
                        }
                        .fixedSize()
                        HintText(source.howTo)
                    }
                    deleteWarning
                }
            }
        } footer: {
            if summary != nil {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
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

    private var deleteWarning: some View {
        Callout(.warning, "A CSV export holds every password in plain text. Delete it as soon as the import is done, empty the Trash, and remove any copy in Downloads or a synced folder.")
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
        SheetScaffold(title: "Devices and pairing",
                      subtitle: "Pairing only exchanges public keys. Exports can then be sealed to paired devices as well as to your master password; a paired device opens them with its own hardware key.",
                      symbol: "laptopcomputer.and.iphone", size: DS.Sheet.wide) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.xl) {
                    thisMac.frame(width: 260)
                    Divider()
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        addDevice
                        Divider()
                        pairedList
                    }
                    .frame(minWidth: 320)
                }
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    thisMac
                    Divider()
                    addDevice
                    Divider()
                    pairedList
                }
            }
        } footer: {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .onAppear {
            switch model.thisMacPairing() {
            case let .success(i): info = i
            case let .failure(e): infoError = CoreErrors.describe(e)
            }
        }
    }

    private var thisMac: some View {
        VStack(alignment: .leading, spacing: DS.Space.s + 2) {
            Text("This Mac").font(.sectionTitle)
            if let info {
                if let img = QRCode.image(for: info.payload) {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .padding(DS.Space.s).background(.white, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        .accessibilityLabel("Pairing QR code")
                }
                LabeledContent("Fingerprint") {
                    Text(info.fingerprint).font(.secret).textSelection(.enabled)
                }
                Text(info.payload).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(4)
                Button("Copy Pairing Text") { model.copy(info.payload, label: "Pairing text") }
                HintText("Scan the code or paste the text on the other device, then check that both show the same fingerprint.")
            } else if let infoError {
                Text("Pairing is unavailable: \(infoError)").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    private var addDevice: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Add a device").font(.sectionTitle)
            TextField("Name", text: $newName, prompt: Text("Name (e.g. Pixel 8)")).textFieldStyle(.roundedBorder)
            TextField("Pairing text", text: $newPayload, prompt: Text("Pairing text from the other device (SR1PAIR:…)"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.secret)
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
                Text(parseError).font(.callout).foregroundStyle(.red)
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
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Paired devices").font(.sectionTitle)
            if model.pairedDevices.isEmpty {
                HintText("None yet. Add one above.")
            }
            ForEach(model.pairedDevices) { d in
                HStack {
                    Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(d.name)
                        Text(d.fingerprint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    IconButton("Remove \(d.name)", systemImage: "minus.circle", help: "Remove", role: .destructive) {
                        model.removePairedDevice(d.fingerprint)
                    }
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
        SheetScaffold(title: "Additional vault",
                      subtitle: created ? nil : "Creates a second vault on this Mac with a different master password. The unlock screen opens whichever vault matches the password you type, the same way and in the same time for both.",
                      symbol: "square.stack.3d.up", size: DS.Sheet.medium) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if created {
                    Callout(.success, "The additional vault is ready. Lock Strongroom and unlock with its password to fill it.")
                    if let generated {
                        Text("Its Secret Key (shown once):").font(.callout)
                        Text(generated).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            .padding(DS.Space.s + 2).frame(maxWidth: .infinity)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        Button("Copy Secret Key") { model.copy(generated, label: "Secret Key") }
                        Toggle("I have stored this Secret Key", isOn: $stored).toggleStyle(.checkbox)
                    }
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        SecureField("Master password", text: $password, prompt: Text("Master password for the additional vault"))
                            .textFieldStyle(.roundedBorder)
                        StrengthMeter(password: password)
                        SecureField("Confirm", text: $confirm, prompt: Text("Confirm"))
                            .textFieldStyle(.roundedBorder)
                        if !confirm.isEmpty && confirm != password {
                            Text("The passwords do not match.").font(.callout).foregroundStyle(.red)
                        }
                    }
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Toggle("Generate a new Secret Key for it", isOn: $useNewKey).toggleStyle(.checkbox)
                        if !useNewKey {
                            SecureField("Secret Key", text: $secretKey, prompt: Text("Secret Key to use (SR1-…)"))
                                .textFieldStyle(.roundedBorder)
                            HintText("Using your usual Secret Key means only the password differs at the unlock screen.")
                        }
                    }
                    DataLossWarning()
                }
            }
        } footer: {
            if created {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(generated != nil && !stored)
            } else {
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
}
