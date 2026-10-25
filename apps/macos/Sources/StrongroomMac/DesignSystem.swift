import SwiftUI

/// Spacing, sizes and type shared by every Strongroom screen, so screens line
/// up with each other at any window size. Fonts are text styles (they follow
/// the system text size); widths are caps for readability, not fixed frames.
enum DS {
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let card: CGFloat = 10
        static let panel: CGFloat = 14
    }

    enum Width {
        /// Item details and other reading panes.
        static let readable: CGFloat = 760
        /// Grids of cards (folder overview, template picker).
        static let grid: CGFloat = 1180
        /// Onboarding, unlock and other single-column forms.
        static let form: CGFloat = 520
        /// The label column of a field row.
        static let label: CGFloat = 120
        /// Panes narrower than this stack labels above values.
        static let compact: CGFloat = 500
    }

    /// NavigationSplitView columns. The three minimums plus dividers fit the
    /// smallest window (760 points); the maximums keep the sidebar and list
    /// from growing on large screens, so the extra room goes to the detail.
    enum Column {
        static let sidebarMin: CGFloat = 190
        static let sidebarIdeal: CGFloat = 220
        static let sidebarMax: CGFloat = 300
        static let listMin: CGFloat = 240
        static let listIdeal: CGFloat = 300
        static let listMax: CGFloat = 420
        static let detailMin: CGFloat = 320
    }

    /// Sheet sizes: the minimum fits the smallest window; the ideal is what a
    /// sheet opens at. Content beyond that scrolls.
    enum Sheet {
        static let small = CGSize(width: 440, height: 0)
        static let medium = CGSize(width: 540, height: 0)
        static let large = CGSize(width: 680, height: 640)
        static let wide = CGSize(width: 820, height: 600)
        static let minHeight: CGFloat = 300
    }
}

extension Font {
    /// Onboarding and unlock headlines.
    static let heroTitle = Font.largeTitle.weight(.bold)
    /// The title of a pane (item, folder, tool).
    static let paneTitle = Font.title2.weight(.bold)
    /// The title of a sheet.
    static let sheetTitle = Font.title3.weight(.semibold)
    /// A section heading inside a pane or sheet.
    static let sectionTitle = Font.headline
    /// Explanations and hints under controls.
    static let hint = Font.callout
    /// Secret values, codes and keys.
    static let secret = Font.body.monospaced()
}

// MARK: layout helpers

extension View {
    /// Caps the width for reading and centres the block in wider panes.
    func readableWidth(_ max: CGFloat = DS.Width.readable, alignment: Alignment = .leading) -> some View {
        frame(maxWidth: max, alignment: alignment).frame(maxWidth: .infinity)
    }

    /// Standard padding around the content of a pane.
    func panePadding() -> some View {
        padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.l)
    }

    /// Measures this view's width and tells its content whether it is narrow
    /// (`isCompactPane`), so rows can stack labels above values.
    func adaptivePane(breakpoint: CGFloat = DS.Width.compact) -> some View {
        modifier(AdaptivePane(breakpoint: breakpoint))
    }
}

private struct CompactPaneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the enclosing pane is narrower than its breakpoint.
    var isCompactPane: Bool {
        get { self[CompactPaneKey.self] }
        set { self[CompactPaneKey.self] = newValue }
    }
}

private struct AdaptivePane: ViewModifier {
    let breakpoint: CGFloat
    @State private var width: CGFloat = .infinity

    func body(content: Content) -> some View {
        content
            .environment(\.isCompactPane, width < breakpoint)
            .background {
                GeometryReader { g in
                    Color.clear
                        .onAppear { width = g.size.width }
                        .onChange(of: g.size.width) { _, w in width = w }
                }
            }
    }
}

// MARK: building blocks

/// Secondary explanatory text that wraps instead of truncating.
struct HintText: View {
    let text: String
    var font: Font = .hint

    init(_ text: String, font: Font = .hint) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A tinted box with an icon for warnings and notes. One look for every
/// warning in the app (data loss, plain-text CSV, seed phrase, weak password).
struct Callout: View {
    enum Style {
        case info, warning, danger, success

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: return .accentColor
            case .warning: return .orange
            case .danger: return .red
            case .success: return .green
            }
        }
    }

    let style: Style
    let text: String
    var title: String? = nil

    init(_ style: Style, _ text: String, title: String? = nil) {
        self.style = style
        self.text = text
        self.title = title
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                if let title { Text(title).font(.callout.weight(.semibold)) }
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(style.tint.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }
}

/// An icon-only button with a spoken label and a tooltip.
struct IconButton: View {
    let title: String
    let systemImage: String
    var help: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void

    init(_ title: String, systemImage: String, help: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(help ?? title)
    }
}

/// The standard sheet: a header, content that scrolls when the sheet is
/// short, and a footer with the actions (Cancel, then the default action on
/// the right). Sizes come from `DS.Sheet`.
struct SheetScaffold<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var size: CGSize = DS.Sheet.medium
    /// false for short forms that never need to scroll.
    var scrolls = true
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(title).font(.sheetTitle).fixedSize(horizontal: false, vertical: true)
                    if let subtitle { HintText(subtitle) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.xl)
            .padding(.bottom, DS.Space.m)
            Group {
                if scrolls {
                    ScrollView {
                        content
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Space.xl)
                            .padding(.bottom, DS.Space.l)
                    }
                } else {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.xl)
                        .padding(.bottom, DS.Space.l)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            HStack(spacing: DS.Space.s) { footer }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.m)
        }
        .frame(minWidth: min(size.width, 420), idealWidth: size.width, maxWidth: max(size.width, 1000),
               minHeight: size.height > 0 ? DS.Sheet.minHeight : nil,
               idealHeight: size.height > 0 ? size.height : nil)
    }
}

/// A rounded group of rows with an optional heading, used for the sections
/// of an item and of the overview.
struct SectionBox<Content: View>: View {
    let title: String?
    var symbol: String? = nil
    var trailing: String? = nil
    @ViewBuilder let content: Content

    init(title: String?, symbol: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let title {
                HStack(spacing: DS.Space.s) {
                    if let symbol {
                        Label(title, systemImage: symbol)
                    } else {
                        Text(title)
                    }
                    Spacer(minLength: DS.Space.s)
                    if let trailing { Text(trailing).font(.callout).foregroundStyle(.secondary) }
                }
                .font(.sectionTitle)
                .padding(.horizontal, DS.Space.xs)
            }
            VStack(alignment: .leading, spacing: DS.Space.m) { content }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.separator.opacity(0.6)))
        }
    }
}

/// A capsule label (counts, states). The text stays in the primary colour so
/// it is readable on the tint; the icon carries the colour.
struct Badge: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).foregroundStyle(.primary).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, DS.Space.s).padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// A card that reacts to the pointer (folder, item and template cards).
struct CardBackground: ViewModifier {
    var minHeight: CGFloat = 0
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(hover ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.2)))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .onHover { hover = $0 }
    }
}

extension View {
    func card(minHeight: CGFloat = 0) -> some View { modifier(CardBackground(minHeight: minHeight)) }
}

/// Vertically centres `content` when there is room and scrolls when there is
/// not (onboarding, unlock, empty states in short windows).
struct CenteredScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { g in
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: g.size.height)
            }
        }
    }
}
