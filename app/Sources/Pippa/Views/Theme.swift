import AppKit
import CoreText
import PippaCore
import SwiftUI

// Design: all colors, measures, fonts and building blocks come from here;
// the surfaces only assemble them.

// MARK: - Farben

enum Theme {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static func dynamic(light: NSColor, dark: NSColor) -> Color { Color(nsColor: dyn(light, dark)) }

    static func hex(_ v: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: alpha)
    }

    private static let inkL = 0x202735, inkD = 0xEDF1F7
    private static func inkA(_ l: CGFloat, _ d: CGFloat) -> Color { dynamic(light: hex(inkL, l), dark: hex(inkD, d)) }
    private static func whiteA(_ l: CGFloat, _ d: CGFloat) -> Color { dynamic(light: hex(inkL, l), dark: NSColor(white: 1, alpha: d)) }

    // Text
    static let ink = inkA(1, 1)
    static let ink2 = inkA(0.78, 0.72)
    /// Hints: >= 4.5:1 on every light surface (white 5.3, glass ECECEC 4.9, green well 4.9) and dark (5.5 to 6.1).
    static let ink3 = inkA(0.68, 0.60)
    // Surfaces
    static let hair = whiteA(0.10, 0.10)
    static let fill = whiteA(0.045, 0.055)
    static let fill2 = whiteA(0.075, 0.095)
    static let fill3 = whiteA(0.13, 0.16)
    // Akzent
    static let accent = dynamic(light: hex(0x005BCD), dark: hex(0x80B8FF))
    static let accentFill = dynamic(light: hex(0x005BCD), dark: hex(0x1F6FE0))
    static let accentPress = dynamic(light: hex(0x0049A6), dark: hex(0x2B7CF0))
    static let accentTint = dynamic(light: hex(0x005BCD, 0.10), dark: hex(0x80B8FF, 0.14))
    static let accentTint2 = dynamic(light: hex(0x005BCD, 0.16), dark: hex(0x80B8FF, 0.22))
    static let highlight = dynamic(light: hex(0x005BCD, 0.15), dark: hex(0x80B8FF, 0.26))
    // Zustand
    static let ok = dynamic(light: hex(0x0D712C), dark: hex(0x45D97F))
    static let okTint = dynamic(light: hex(0x0D712C, 0.11), dark: hex(0x45D97F, 0.14))
    static let need = dynamic(light: hex(0x8A4600), dark: hex(0xFFB340))
    static let needTint = dynamic(light: hex(0xFF9F0A, 0.17), dark: hex(0xFF9F0A, 0.12))
    static let needDot = dynamic(light: hex(0xE08600), dark: hex(0xFFB340))
    // Calm chat surfaces. Color marks interaction, not the whole work area.
    static let chatTint = dyn(hex(0xF7F8FB, 0.98), hex(0x191D25, 0.98))
    static let chatCard = dynamic(light: hex(0xFFFFFF), dark: hex(0x232833))
    static let chatInset = dynamic(light: hex(0xF2F5FA), dark: hex(0x1B202A))
    static let chatBorder = dynamic(light: hex(0x273D60, 0.09), dark: hex(0xB8C9E4, 0.12))
    static let chatUser = dynamic(light: hex(0xE5EEFF), dark: hex(0x243A5B))

    // Sage outside the chat
    static let well = dynamic(light: hex(0x86AD94, 0.20), dark: hex(0x86AD94, 0.11))
    static let wellEdge = dynamic(light: hex(0x10251A, 0.06), dark: NSColor(white: 0, alpha: 0.25))
    static let sill = dynamic(light: hex(0x86AD94, 0.13), dark: hex(0x86AD94, 0.08))
    // Papier
    static let paper = dynamic(light: hex(0xFFFFFF), dark: hex(0x252B36))
    static let paperInk = dynamic(light: hex(0x202735), dark: hex(0xEDF1F7))
    static let paper2 = dynamic(light: hex(0xF5F7FA), dark: hex(0x2C3441))
    static let sheet = dynamic(light: hex(0xFFFFFF), dark: hex(0xD3D9D5))
    static let monoTile = dynamic(light: hex(0x86AD94, 0.32), dark: hex(0x86AD94, 0.24))
    static let monoInk = dynamic(light: hex(0x22402F), dark: hex(0xCFE3D6))
    static let folderA = dynamic(light: hex(0x79B8F3), dark: hex(0x3F8FE0))
    static let folderB = dynamic(light: hex(0xA4D0FA), dark: hex(0x69AAF0))
    static let shadowInk = dynamic(light: hex(0x162238), dark: NSColor.black)

    // Material tint over the glass
    static let materialTint = dyn(NSColor(srgbRed: 249 / 255, green: 250 / 255, blue: 248 / 255, alpha: 0.74),
                                  NSColor(srgbRed: 30 / 255, green: 35 / 255, blue: 32 / 255, alpha: 0.70))
    static let materialTintSolid = dyn(NSColor(srgbRed: 250 / 255, green: 251 / 255, blue: 249 / 255, alpha: 0.92),
                                       NSColor(srgbRed: 30 / 255, green: 34 / 255, blue: 32 / 255, alpha: 0.90))

    // Breiten
    static let inputWidth: CGFloat = 440
    static let panelWidth: CGFloat = 420
    static let wideWidth: CGFloat = 440
    static let workWidth: CGFloat = 400
    static let toastWidth: CGFloat = 360
    static let welcomeWidth: CGFloat = 560
    static let conversationWidth: CGFloat = 760
    static let sheetWidth: CGFloat = 720
}

extension MarkPalette {
    static func nsColor(_ c: [Double]) -> NSColor { NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1) }
}

// MARK: - Schrift

enum Fonts {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .rounded) }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func serif(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .monospaced) }

    static let resultXL = rounded(28, .bold)
    static let resultL = rounded(22, .bold)
    static let head = rounded(14, .semibold)
    static let headSheet = rounded(17, .semibold)
    static let body = text(13.5)
    static let lead = text(14.5)
    static let hint = text(12)
    static let sill = text(11.5, .medium)
    /// Welcome: Bagel Fat One (bundled, OFL); if missing, SF Rounded Heavy.
    @MainActor static var display: Font {
        DisplayFont.register()
        return DisplayFont.available ? .custom(DisplayFont.name, size: 44) : rounded(44, .heavy)
    }
}

/// Bagel Fat One from Resources/Fonts, registered for this process on first use.
@MainActor
enum DisplayFont {
    static let name = "BagelFatOne-Regular"
    private(set) static var available = false
    private static var tried = false

    static func register() {
        guard !tried else { return }
        tried = true
        guard let url = Bundle.module.url(forResource: "BagelFatOne-Regular", withExtension: "ttf", subdirectory: "Fonts") else { return }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) || NSFont(name: name, size: 12) != nil {
            available = NSFont(name: name, size: 12) != nil
        }
    }
}

// MARK: - Shape, motion of the shell

/// Shape and motion of the shell. Everything that makes the shell look the way it does comes from here.
enum ShellTokens {
    // Measures
    static let pillHeight: CGFloat = 46
    static let hotHeight: CGFloat = 54
    static let screenInset: CGFloat = 8
    static let edgeMagnet: CGFloat = 26
    static let workspaceMax = CGSize(width: max(Theme.sheetWidth, Theme.conversationWidth), height: 700)
    /// Smallest conversation window when dragging the corner (the views are checked down to 400 pt).
    static let workspaceMin = CGSize(width: 400, height: 440)

    // Radien (kontinuierliche Ecken)
    static func radius(_ shape: ShellMode.Shape, height: CGFloat) -> CGFloat {
        switch shape {
        case .pill, .target: height / 2
        case .input, .panel: 28
        case .sheet: 26
        }
    }
    static let toastRadius: CGFloat = 24

    // Material
    static let material: NSVisualEffectView.Material = .popover
    static let sheetMaterial: NSVisualEffectView.Material = .popover
    /// Lichtkante (1 pt innen).
    static let edgeLight = NSColor(white: 1, alpha: 0.55)
    static let edgeDark = NSColor(white: 1, alpha: 0.12)
    static let edgeWidth: CGFloat = 1

    // Shadows (only outside the shape): outline plus soft falloff.
    static let shadowColor = NSColor(srgbRed: 22 / 255, green: 34 / 255, blue: 56 / 255, alpha: 1)
    static let shadowOpacity: Float = 0.34
    static let shadowOpacityDark: Float = 0.7
    static let shadowRadius: CGFloat = 26
    static let shadowOffset = CGSize(width: 0, height: -16)
    static let contourOpacity: Float = 0.12
    static let contourOpacityDark: Float = 0.55

    // Springs: tight. Opening with a tiny overshoot (zeta~0.83), closing without (zeta~1).
    struct Spring { var mass: CGFloat; var stiffness: CGFloat; var damping: CGFloat }
    // Measured (+-1 px at 400 px, see DevSnapshot timings.txt):
    // opening 95% after 164 ms, settled after 266 ms, overshoot 0.14%.
    // closing 95% after 115 ms, settled after 196 ms, overshoot 0.06% (< 0.3 px).
    static let expand = Spring(mass: 1, stiffness: 600, damping: 44)
    static let collapse = Spring(mass: 1, stiffness: 1300, damping: 66)
    static let resize = Spring(mass: 1, stiffness: 1300, damping: 66)

    // Inhalt
    static let fadeOut: CFTimeInterval = 0.07
    static let fadeOutScale: CGFloat = 0.98
    static let fadeOutBlur: CGFloat = 3
    static let contentRevealAt: Double = 0.45       // share of the shape motion after which new content appears
    static let contentRevealWorking: Double = 0.7   // input → working: only once the shape has almost settled
    static let contentFadeIn: CFTimeInterval = 0.12
    static let staggerStep: Double = 0.015
    static let staggerDuration: Double = 0.12
    static let reducedFade: CFTimeInterval = 0.14
}

/// Where the wandering figure sits in the current form (in the "shell" coordinate space).
struct MarkSlotKey: PreferenceKey {
    static let defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        if value.isNull { value = nextValue() }
    }
}

/// Placeholder where the wandering figure of the shell sits.
struct MarkSlot: View {
    var size: CGFloat
    var body: some View {
        Color.clear.frame(width: size, height: size)
            .background(GeometryReader { g in
                Color.clear.preference(key: MarkSlotKey.self, value: g.frame(in: .named("shell")))
            })
            .accessibilityHidden(true)
    }
}

/// Drives the staggered fade-in of new content after the shape change.
@MainActor
final class RevealState: ObservableObject {
    @Published var shown = true
    /// Old content that stays while fading out (otherwise the content follows the model).
    @Published var frozen: ShellMode?
    /// Slow motion for developer review of the transitions.
    var slowdown: Double = 1
}

private struct RevealKey: EnvironmentKey {
    static let defaultValue: RevealState? = nil
}

extension EnvironmentValues {
    var reveal: RevealState? {
        get { self[RevealKey.self] }
        set { self[RevealKey.self] = newValue }
    }
}

private struct StaggerModifier: ViewModifier {
    @Environment(\.reveal) private var reveal
    var index: Int
    var moves: Bool

    func body(content: Content) -> some View {
        if let reveal {
            content.modifier(StaggerObserving(reveal: reveal, index: index, moves: moves))
        } else {
            content
        }
    }
}

private struct StaggerObserving: ViewModifier {
    @ObservedObject var reveal: RevealState
    var index: Int
    var moves: Bool

    func body(content: Content) -> some View {
        content
            .opacity(reveal.shown ? 1 : 0)
            .offset(y: reveal.shown || !moves ? 0 : 4)
            .animation(reveal.shown && !MarkHub.shared.reduced
                       ? .easeOut(duration: ShellTokens.staggerDuration * reveal.slowdown)
                           .delay(Double(index) * ShellTokens.staggerStep * reveal.slowdown)
                       : nil,
                       value: reveal.shown)
    }
}

extension View {
    /// Result first (0), well (+60 ms = 4), actions and base (+120 ms = 8); rows in between.
    func stagger(_ index: Int, moves: Bool = true) -> some View { modifier(StaggerModifier(index: min(index, 16), moves: moves)) }
}

// MARK: - Grain (linoleum of the website)

enum Grain {
    /// Rauschen 180 pt, einmal erzeugt, gekachelt.
    @MainActor static let image: NSImage = {
        let size = 180
        var rng = SystemRandomNumberGenerator()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = rep.bitmapData!
        for i in 0..<(size * size) {
            let a = Double(UInt8.random(in: 0...255, using: &rng)) / 255
            let alpha = UInt8(max(0, min(255, a * a * 0.5 * 0.55 * 255)))
            data[i * 4 + 0] = UInt8(0.05 * Double(alpha))
            data[i * 4 + 1] = UInt8(0.12 * Double(alpha))
            data[i * 4 + 2] = UInt8(0.08 * Double(alpha))
            data[i * 4 + 3] = alpha
        }
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }()
}

/// File names as in Finder: without extension.
enum FileName {
    static func display(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        let ext = name[name.index(after: dot)...]
        guard (1...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return name }
        return String(name[..<dot])
    }
}

// MARK: - Base surfaces

/// Well: sage with grain, radius 18, inner shadow.
struct Well<Content: View>: View {
    @Environment(\.embeddedWorkflow) private var embedded
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                ZStack {
                    if embedded {
                        shape.fill(Theme.chatInset)
                        shape.strokeBorder(Theme.chatBorder, lineWidth: 0.5)
                    } else {
                        shape.fill(Theme.well)
                        Image(nsImage: Grain.image).resizable(resizingMode: .tile).opacity(0.5).clipShape(shape)
                        shape.strokeBorder(Theme.wellEdge, lineWidth: 0.5)
                        shape.stroke(Theme.wellEdge, lineWidth: 2).blur(radius: 1).offset(y: 1).clipShape(shape)
                    }
                }
                .accessibilityHidden(true)
            }
    }
}

/// Paper: preview surface with paper shadow.
struct PaperBackground: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.paper)
                    .shadow(color: Theme.shadowInk.opacity(0.08), radius: 0.5)
                    .shadow(color: Theme.shadowInk.opacity(0.10), radius: 0.5, y: 1)
                    .shadow(color: Theme.shadowInk.opacity(0.28), radius: 9, y: 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func paper(radius: CGFloat = 12) -> some View { modifier(PaperBackground(radius: radius)) }
}

// MARK: - Kopf, Ergebnis, Sockel

/// Header: figure · context (+ meta) · close. No subline announcing a preview.
struct PanelHead: View {
    @Environment(\.embeddedWorkflow) private var embedded
    var title: String
    var meta: String?
    var markSize: CGFloat = 32
    var sheet = false
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if !embedded { MarkSlot(size: markSize) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(embedded ? Fonts.text(sheet ? 15 : 14, .semibold) : sheet ? Fonts.headSheet : Fonts.head)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .font(Fonts.hint.monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !embedded, let onClose { CloseButton(action: onClose) }
        }
        .padding(.leading, embedded ? 20 : sheet ? 22 : 20)
        .padding(.trailing, sheet ? 18 : 16)
        .padding(.top, sheet ? 18 : 16)
        .frame(minHeight: embedded ? nil : sheet ? 60 : 56, alignment: .bottom)
        .stagger(0, moves: false)
    }
}

/// Result large: XL (28) or L (22), Rounded Bold, left-aligned, at most three lines.
struct ResultTitle: View {
    @Environment(\.embeddedWorkflow) private var embedded
    var text: String
    var large = true
    var body: some View {
        Text(text)
            .font(embedded ? Fonts.text(large ? 20 : 16, large ? .semibold : .medium) : large ? Fonts.resultXL : Fonts.resultL)
            .tracking(embedded ? 0 : large ? -0.3 : -0.15)
            .foregroundStyle(Theme.ink)
            .lineLimit(3)
            .lineSpacing(large ? 1 : 0)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .stagger(0)
    }
}

struct Lead: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Fonts.lead)
            .foregroundStyle(Theme.ink2)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Trust base: always at the bottom, always built the same way.
struct TrustSill: View {
    @Environment(\.embeddedWorkflow) private var embedded
    enum Right { case none, text(String, icon: String?) }
    var left: String = T("Runs on your Mac", table: "Views")
    var leftIcon: String? = "lock"
    var right: Right = .text(T("Undo with one click", table: "Views"), icon: "arrow.uturn.backward")

    static let readOnly = TrustSill(right: .text(T("Read only", table: "Views"), icon: "eye"))

    var body: some View {
        if !embedded { sill }
    }

    private var sill: some View {
        HStack(spacing: 12) {
            label(left, leftIcon)
            Spacer(minLength: 8)
            switch right {
            case .none: EmptyView()
            case .text(let t, let icon): label(t, icon)
            }
        }
        .font(Fonts.sill)
        .foregroundStyle(Theme.ink2)
        .padding(.horizontal, 20)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(Theme.sill)
        .overlay(alignment: .top) { Theme.hair.frame(height: 0.5) }
        .stagger(8, moves: false)
    }

    private func label(_ text: String, _ icon: String?) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink3)
            }
            Text(text).lineLimit(1)
        }
    }
}

/// Aktionsleiste: 20 oben, 20 seitlich, 18 unten.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .stagger(8)
    }
}

// MARK: - Buttons

enum ButtonKind { case primary, secondary, tinted, quiet }

struct PippaButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, kind: kind, large: large, enabled: enabled)
    }

    private struct ButtonBody: View {
        let configuration: Configuration
        let kind: ButtonKind
        let large: Bool
        let enabled: Bool
        private let hoverState = State(initialValue: false)
    private var hover: Bool { get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue } }

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .labelStyle(ButtonLabelStyle())
                .font(.system(size: large ? 14.5 : 13.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .quiet ? 12 : (large ? 20 : 16))
                .frame(height: large ? 40 : 34)
                .background {
                    Capsule().fill(background(pressed: pressed))
                        .shadow(color: kind == .primary ? Theme.hex(0x00286E, 0.25).swiftUI : .clear, radius: 1, y: 1)
                        .shadow(color: kind == .primary ? Theme.hex(0x003CA0, 0.35).swiftUI : .clear, radius: 5, y: 4)
                        .overlay(alignment: .top) {
                            if kind == .primary {
                                Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                            }
                        }
                }
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hover = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: .white
            case .secondary: Theme.ink
            case .tinted: Theme.accent
            case .quiet: hover ? Theme.ink : Theme.ink2
            }
        }

        private func background(pressed: Bool) -> Color {
            switch kind {
            case .primary: pressed || hover ? Theme.accentPress : Theme.accentFill
            case .secondary: hover || pressed ? Theme.fill3 : Theme.fill2
            case .tinted: pressed ? Theme.accentTint2 : Theme.accentTint
            case .quiet: hover || pressed ? Theme.fill2 : .clear
            }
        }
    }
}

private struct ButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.font(.system(size: 13, weight: .semibold))
            configuration.title
        }
    }
}

extension NSColor {
    var swiftUI: Color { Color(nsColor: self) }
}

extension View {
    func pippa(_ kind: ButtonKind, large: Bool = false) -> some View { buttonStyle(PippaButtonStyle(kind: kind, large: large)) }
}

/// Close: 26 pt round, filled only on hover.
struct CloseButton: View {
    var action: () -> Void
    private let hoverState = State(initialValue: false)
    private var hover: Bool { get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue } }
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Theme.ink2 : Theme.ink3)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover ? Theme.fill2 : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(T("Close", table: "Views"))
    }
}

/// Link in Akzent („Warum so?“).
struct LinkButton: View {
    var title: String
    var icon: String?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
                Text(title)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chips, Zeilen, Aufgaben

struct Chip: View {
    enum Kind { case neutral, need, ok, accent }
    var text: String
    var kind: Kind = .neutral
    var icon: String?

    init(text: String, kind: Kind = .neutral, icon: String? = nil) { self.text = text; self.kind = kind; self.icon = icon }

    var body: some View {
        HStack(spacing: 5) {
            if kind == .need { Circle().fill(Theme.needDot).frame(width: 7, height: 7) }
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(fg)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(bg))
    }

    private var fg: Color {
        switch kind { case .neutral: Theme.ink2; case .need: Theme.need; case .ok: Theme.ok; case .accent: Theme.accent }
    }
    private var bg: Color {
        switch kind { case .neutral: Theme.fill2; case .need: Theme.needTint; case .ok: Theme.okTint; case .accent: Theme.accentTint }
    }
}

/// Symbol-Kachel.
struct Tile: View {
    var icon: String
    var size: CGFloat = 30
    var filled = false
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(filled ? Color.white : Theme.accent)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size > 32 ? 11 : 9, style: .continuous).fill(filled ? Theme.accentFill : Theme.accentTint))
    }
}

/// Task: >= 62 high, tile 38, title + line, chevron. Preselected tinted.
struct TaskButton: View {
    var icon: String
    var title: String
    var subtitle: String?
    var preselected = false
    var enabled = true
    var order = 4
    var action: () -> Void
    private let hoverState = State(initialValue: false)
    private var hover: Bool { get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue } }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Tile(icon: icon, size: 38, filled: preselected && enabled)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 62)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                shape.fill(preselected && enabled ? Theme.accentTint : (hover ? Theme.fill2 : Theme.fill))
                    .overlay { if preselected && enabled { shape.strokeBorder(Theme.accentTint2, lineWidth: 1) } }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
        .onHover { hover = $0 }
        .accessibilityLabel(subtitle.map { "\(title). \($0)" } ?? title)
        .stagger(order)
    }
}

// MARK: - Quelle, Zitat

/// PDF-Blatt 16×19, rot beschriftet.
struct DocIcon: View {
    enum Kind { case pdf, image, sheet, generic }
    var kind: Kind = .pdf
    var width: CGFloat = 16

    static func kind(for url: URL?) -> Kind {
        switch url?.pathExtension.lowercased() ?? "" {
        case "pdf": .pdf
        case "jpg", "jpeg", "png", "heic", "tiff", "gif": .image
        case "xlsx", "csv", "numbers": .sheet
        default: .generic
        }
    }

    var body: some View {
        let h = width * 1.2
        ZStack(alignment: .bottom) {
            DogEar().fill(Theme.sheet).overlay(DogEar().stroke(Color.black.opacity(0.18), lineWidth: 0.6))
            switch kind {
            case .pdf:
                Text("PDF").font(.system(size: width * 0.28, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: width * 0.68, height: h * 0.22)
                    .background(RoundedRectangle(cornerRadius: 1.4).fill(Theme.hex(0xD94A3D).swiftUI))
                    .padding(.bottom, h * 0.17)
            case .image:
                RoundedRectangle(cornerRadius: 1.5).fill(LinearGradient(colors: [Theme.hex(0x8FC4E8).swiftUI, Theme.hex(0x4F8E57).swiftUI], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.7, height: h * 0.42).padding(.bottom, h * 0.17)
            case .sheet:
                RoundedRectangle(cornerRadius: 1.4).fill(Theme.hex(0x1F8A4C).swiftUI)
                    .frame(width: width * 0.68, height: h * 0.22).padding(.bottom, h * 0.17)
            case .generic:
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(Color.black.opacity(0.18)).frame(width: width * 0.55, height: 1.4) }
                }.padding(.bottom, h * 0.22)
            }
        }
        .frame(width: width, height: h)
        .accessibilityHidden(true)
    }
}

private struct DogEar: Shape {
    func path(in r: CGRect) -> Path {
        let ear = r.width * 0.3
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + ear))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 2))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 2, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 2), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 2))
        p.addQuadCurve(to: CGPoint(x: r.minX + 2, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Source chip: capsule 28 high, paper, file · name · page · arrow. A click opens the spot.
struct SourceChip: View {
    var name: String
    var location: String?
    var mail = false
    var tinted = false
    var url: URL?
    var action: () -> Void
    private let hoverState = State(initialValue: false)
    private var hover: Bool { get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue } }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if mail {
                    Image(systemName: "envelope").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 16)
                } else {
                    DocIcon(kind: DocIcon.kind(for: url))
                }
                Text(FileName.display(name)).lineLimit(1).truncationMode(.tail).foregroundStyle(tinted ? Theme.accent : Theme.ink)
                if let location { Text(Self.page(location)).foregroundStyle(tinted ? Theme.accent.opacity(0.75) : Theme.ink3).monospacedDigit().fixedSize() }
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background {
                Capsule().fill(tinted ? Theme.accentTint : Theme.paper)
                    .shadow(color: tinted ? .clear : Theme.shadowInk.opacity(0.10), radius: 0.5)
                    .shadow(color: tinted ? .clear : Theme.shadowInk.opacity(0.06), radius: 1, y: 1)
                    .overlay { if hover { Capsule().strokeBorder(Theme.accent, lineWidth: 1.5) } }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(spoken)
    }

    /// For VoiceOver: "Name, page 4, open".
    private var spoken: String {
        var text = FileName.display(name)
        if let location { text += ", " + Self.page(location) }
        return T("%@, open", table: "Views", text)
    }

    /// "S. 4" -> "Seite 4" (PippaCore writes the citation as "S. 4").
    static func page(_ location: String) -> String {
        location.replacingOccurrences(of: "S. ", with: T("Page", table: "Views") + " ")
    }
}

/// Quote: serif, 20 indented, hanging quote mark in accent; highlighted passage tinted.
struct QuoteText: View {
    var text: String
    var mark: String? = nil
    var size: CGFloat = 15
    var color: Color = Theme.paperInk

    var body: some View {
        Text(attributed)
            .font(Fonts.serif(size))
            .foregroundStyle(color)
            .lineSpacing(size * 0.4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.leading, 20)
            .overlay(alignment: .topLeading) {
                Text("„")
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(Theme.accent.opacity(0.55))
                    .offset(x: -2, y: -16)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var s = AttributedString(text)
        let target = mark ?? text
        if let r = s.range(of: target) {
            s[r].backgroundColor = Theme.highlight
        }
        return s
    }
}

// MARK: - Monogramm, Kalenderblatt, Kontrollen

struct SenderMark: View {
    var name: String
    var round = false
    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: 14, weight: .heavy, design: .rounded))
            .tracking(0.3)
            .foregroundStyle(Theme.monoInk)
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: round ? 20 : 12, style: .continuous).fill(Theme.monoTile))
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter }).filter { $0.count > 1 }
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased().nonEmpty ?? String(name.prefix(2)).uppercased()
    }
}

// Calendar names for the UI, translated (table "Views"). The name stays: callers are in other files too.
// Data from documents is read by PippaCore, not by these names.
enum GermanDate {
    static var months: [String] {
        [T("January", table: "Views"), T("February", table: "Views"), T("March", table: "Views"), T("April", table: "Views"), T("May", table: "Views"), T("June", table: "Views"), T("July", table: "Views"), T("August", table: "Views"), T("September", table: "Views"), T("October", table: "Views"), T("November", table: "Views"), T("December", table: "Views")]
    }
    static var monthsShort: [String] {
        [T("JAN", table: "Views"), T("FEB", table: "Views"), T("MAR", table: "Views"), T("APR", table: "Views"), T("MAY", table: "Views"), T("JUN", table: "Views"), T("JUL", table: "Views"), T("AUG", table: "Views"), T("SEP", table: "Views"), T("OCT", table: "Views"), T("NOV", table: "Views"), T("DEC", table: "Views")]
    }
    static var weekdays: [String] {
        [T("Sunday", table: "Views"), T("Monday", table: "Views"), T("Tuesday", table: "Views"), T("Wednesday", table: "Views"), T("Thursday", table: "Views"), T("Friday", table: "Views"), T("Saturday", table: "Views")]
    }
    static var weekdaysShort: [String] {
        [T("Sun", table: "Views"), T("Mon", table: "Views"), T("Tue", table: "Views"), T("Wed", table: "Views"), T("Thu", table: "Views"), T("Fri", table: "Views"), T("Sat", table: "Views")]
    }

    static func date(_ d: DayDate) -> Date {
        var c = DateComponents(); c.year = d.year; c.month = d.month; c.day = d.day; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }
    static func weekday(_ d: DayDate) -> Int { Calendar(identifier: .gregorian).component(.weekday, from: date(d)) - 1 }
    /// „Donnerstag, 15. Oktober“ / “Thursday, October 15”
    static func long(_ d: DayDate) -> String {
        let dayName = weekdays[weekday(d)]
        let month = months[d.month - 1]
        return T("%1$@, %2$@ %3$lld", table: "Views", dayName, month, d.day)
    }
    /// „Do., 15.10.2026“
    static func short(_ d: DayDate) -> String {
        let dayName = weekdaysShort[weekday(d)]
        return T("%1$@., %2$@", table: "Views", dayName, d.german)
    }
    /// „Di., 13. Okt.“ / “Tue., Oct. 13”
    static func compact(_ d: DayDate) -> String {
        let dayName = weekdaysShort[weekday(d)]
        let month = String(months[d.month - 1].prefix(3))
        return T("%1$@., %2$@. %3$lld", table: "Views", dayName, month, d.day)
    }
    /// „in 10 Tagen“, „heute“, „morgen“, „vor 3 Tagen“
    static func relative(_ d: DayDate, today: DayDate = DayDate(Date())) -> String {
        let n = Calendar(identifier: .gregorian).dateComponents([.day], from: date(today), to: date(d)).day ?? 0
        switch n {
        case 0: return T("today", table: "Views")
        case 1: return T("tomorrow", table: "Views")
        case 2...: return T("in %lld days", table: "Views", n)
        case -1: return T("yesterday", table: "Views")
        default: return T("%lld days ago", table: "Views", -n)
        }
    }
}

/// Calendar leaf: 72 wide, band with month, day large, weekday.
struct DateTile: View {
    var date: DayDate
    var body: some View {
        VStack(spacing: 0) {
            Text(GermanDate.monthsShort[date.month - 1])
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background(Theme.accentFill)
            Text("\(date.day)")
                .font(.system(size: 36, weight: .heavy, design: .rounded).monospacedDigit())
                .tracking(-0.7)
                .foregroundStyle(Theme.paperInk)
                .padding(.top, 8)
                .padding(.bottom, 2)
            Text(GermanDate.weekdaysShort[GermanDate.weekday(date)])
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink3)
                .padding(.bottom, 9)
        }
        .frame(width: 72)
        .paper(radius: 14)
        .accessibilityElement()
        .accessibilityLabel(GermanDate.long(date))
    }
}

/// Checkbox 17/5 (on, off, mixed).
struct CheckBox: View {
    enum State { case on, off, mixed }
    var state: State
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state == .off ? Theme.paper : Theme.accentFill)
                    .overlay { if state == .off { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.fill3, lineWidth: 1.5) } }
                switch state {
                case .on: Image(systemName: "checkmark").font(.system(size: 9.5, weight: .black)).foregroundStyle(.white)
                case .mixed: Capsule().fill(.white).frame(width: 8, height: 2)
                case .off: EmptyView()
                }
            }
            .frame(width: 17, height: 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(spokenState)
    }

    private var spokenState: String {
        switch state {
        case .on: T("on", table: "Views")
        case .off: T("off", table: "Views")
        case .mixed: T("mixed", table: "Views")
        }
    }
}

/// Segment: capsule 28, selection on paper.
// The type parameter is not named `T`: that would shadow the translation function `T(_:table:)` in the body.
struct Segment<Value: Hashable>: View {
    var options: [(value: Value, title: String, icon: String?)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.value == selection
                Button { selection = o.value } label: {
                    HStack(spacing: 6) {
                        if let icon = o.icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
                        Text(o.title)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(on ? Theme.ink : Theme.ink2)
                    .padding(.horizontal, 13)
                    .frame(height: 26)
                    .background {
                        if on {
                            Capsule().fill(Theme.paper).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fill2))
    }
}

/// Ordner (macOS-Anmutung), 52×40.
struct FolderArt: View {
    var width: CGFloat = 52
    var body: some View {
        let s = width / 52
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 4 * s, topTrailingRadius: 4 * s)
                .fill(Theme.folderA)
                .frame(width: 48 * s, height: 12 * s)
                .offset(x: 2 * s, y: 2 * s)
            RoundedRectangle(cornerRadius: 4 * s, style: .continuous)
                .fill(Theme.folderB)
                .frame(width: 48 * s, height: 29 * s)
                .overlay(alignment: .top) { Color.white.opacity(0.45).frame(height: 1).padding(.top, 4 * s) }
                .offset(x: 2 * s, y: 9 * s)
        }
        .frame(width: width, height: 40 * s, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// Note sheet with lines (illustration).
struct SheetArt: View {
    var lines = true
    var euro = false
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Theme.sheet)
            .overlay(alignment: .topLeading) {
                if lines {
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(Theme.hex(0x14211A, 0.22).swiftUI).frame(width: 16, height: 2)
                        Capsule().fill(Theme.hex(0x14211A, 0.14).swiftUI).frame(width: 20, height: 2)
                        Capsule().fill(Theme.hex(0x14211A, 0.14).swiftUI).frame(width: 18, height: 2)
                    }
                    .padding(.top, 6).padding(.leading, 5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if euro { Text("€").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent).padding(3) }
            }
            .shadow(color: .black.opacity(0.08), radius: 0.5)
            .shadow(color: .black.opacity(0.22), radius: 2, y: 2)
    }
}

struct EnvelopeArt: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.sheet)
            .overlay {
                GeometryReader { g in
                    Path { p in
                        p.move(to: .zero)
                        p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height * 0.5))
                        p.addLine(to: CGPoint(x: g.size.width, y: 0))
                    }
                    .stroke(Theme.hex(0x14211A, 0.2).swiftUI, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 0.5)
            .shadow(color: .black.opacity(0.22), radius: 2, y: 2)
    }
}

struct PhotoArt: View {
    var variant = 0
    var body: some View {
        let gradients: [[Color]] = [
            [Theme.hex(0x9FD2F2).swiftUI, Theme.hex(0x2F7F88).swiftUI, Theme.hex(0x1F5F86).swiftUI],
            [Theme.hex(0xFFD29A).swiftUI, Theme.hex(0xF08A5D).swiftUI, Theme.hex(0x3C5F86).swiftUI],
            [Theme.hex(0xCFE9FB).swiftUI, Theme.hex(0x8AA6B8).swiftUI, Theme.hex(0x5B9A4B).swiftUI],
        ]
        Rectangle()
            .fill(LinearGradient(colors: gradients[variant % 3], startPoint: .top, endPoint: .bottom))
            .padding(EdgeInsets(top: 2.5, leading: 2.5, bottom: 6, trailing: 2.5))
            .background(Theme.sheet)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
    }
}

// MARK: - Fortschritt

/// Native progress tracks the available width and handles indeterminate work.
struct ThinProgress: View {
    var value: Double?
    var height: CGFloat = 10

    var body: some View {
        ProgressView(value: value.map { min(1, max(0, $0)) }, total: 1)
            .progressViewStyle(.linear)
            .id(value == nil)
            .tint(Theme.accentFill)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .accessibilityLabel(T("Progress", table: "Views"))
    }
}

/// Preview approval is distinct from sending a chat message with Return.
struct ApprovalLabel: View {
    var title: String
    var icon: String
    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon)
            Text("⌘↵").font(.system(size: 12, weight: .medium))
                .opacity(0.8).accessibilityHidden(true)
        }
        .help(T("%@ (⌘ Return)", table: "Views", title))
    }
}
