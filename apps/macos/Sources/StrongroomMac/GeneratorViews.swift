import StrongroomKit
import SwiftUI

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

