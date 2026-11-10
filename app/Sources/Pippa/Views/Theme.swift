import AppKit
import SwiftUI

// Pippa's colors, type, motion and surfaces. Everything else uses system controls and system fonts.

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
    // Zustand
    static let ok = dynamic(light: hex(0x0D712C), dark: hex(0x45D97F))
    static let okTint = dynamic(light: hex(0x0D712C, 0.11), dark: hex(0x45D97F, 0.14))
    static let need = dynamic(light: hex(0x8A4600), dark: hex(0xFFB340))
    static let needTint = dynamic(light: hex(0xFF9F0A, 0.17), dark: hex(0xFF9F0A, 0.12))
    // Same red as the figure's sad face (MarkPalette.destructive), so face and sign match.
    static let bad = dynamic(light: hex(0xC4001D), dark: hex(0xF89DA4))
    static let badTint = dynamic(light: hex(0xC4001D, 0.10), dark: hex(0xF89DA4, 0.14))
    // Calm chat surfaces. Color marks interaction, not the whole work area. Dark is almost black, like Pippa Island:
    // the window and the island read as one thing, and the blue of her mark stands out.
    static let chatTint = dyn(hex(0xFCFBF9, 1), hex(0x0B0B0C, 1))
    /// The conversation list and "About this answer" in dark: a step deeper than the chat. Light keeps the system's own.
    static let sideTint = dynamic(light: .clear, dark: hex(0x050506))
    // Neutral like the window around it: a blue cast here made the composer, step chips and receipts look bluish.
    static let chatCard = dynamic(light: hex(0xFFFFFF), dark: hex(0x17171A))
    /// Code blocks and table heads: neutral like the cards (the old blue cast is gone).
    static let chatInset = dynamic(light: hex(0xF3F2EF), dark: hex(0x121214))
    static let chatUser = dynamic(light: hex(0xEEEDEA), dark: hex(0x1F1F23))
    // Surface edges and row states (T3-style: hairlines, not borders; hover is a quiet fill, never a border colour).
    /// The 1 pt edge of a raised surface.
    static let hairline = dynamic(light: hex(0x000000, 0.08), dark: NSColor(white: 1, alpha: 0.09))
    /// Light catching the top edge of a raised surface in dark mode.
    static let topLight = dynamic(light: .clear, dark: NSColor(white: 1, alpha: 0.04))
    static let rowHover = whiteA(0.045, 0.055)
    static let rowSelected = dynamic(light: hex(0xFFFFFF), dark: NSColor(white: 1, alpha: 0.08))
    static let sendDisabled = whiteA(0.12, 0.12)

    // Motion: short and soft; nothing moves with Reduce Motion on.
    @MainActor static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Hover, press and focus changes.
    @MainActor static var quick: Animation? { reduceMotion ? nil : .timingCurve(0.24, 1, 0.4, 1, duration: 0.125) }
    /// Something appears (a drawer, a button, an expanded list).
    @MainActor static var arrive: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }
    /// Something goes away.
    @MainActor static var leave: Animation? { reduceMotion ? nil : .easeOut(duration: 0.14) }
    /// A new question or the start of an answer settles into the conversation: a soft spring, a few points up.
    @MainActor static var message: Animation? { reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82) }
    /// Cards under an answer follow each other by this much.
    static let stagger: Double = 0.06
    /// How far a message or card travels while it arrives.
    static let arrivalOffset: CGFloat = 8

    /// Liquid Glass. Snapshots turn it off: drawing a window into an image can't show glass (a tinted one blanks the
    /// whole view), so they show solid surfaces instead.
    @MainActor static var drawsGlass = true
}

/// The chat's type scale: the system font at fixed sizes, like the rest of macOS. Numbers that change (seconds,
/// percentages, counts) add `.monospacedDigit()` so they don't jitter.
enum Typo {
    /// The welcome's question.
    static let title = Font.system(size: 22, weight: .semibold)
    /// Card and section titles.
    static let headline = Font.system(size: 14.5, weight: .semibold)
    /// Questions and answers.
    static let body = Font.system(size: 14)
    /// Controls, rows and secondary text.
    static let callout = Font.system(size: 13)
    static let footnote = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let code = Font.system(size: 12.5, design: .monospaced)
    /// Extra space between the lines of reading text.
    static let reading: CGFloat = 5

    static func heading(_ level: Int) -> Font {
        .system(size: level <= 1 ? 17 : level == 2 ? 15.5 : 14.5, weight: .semibold)
    }
}

/// Corner radii, from the innermost chip to the composer.
enum Radius {
    static let inner: CGFloat = 4
    static let row: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 12
    /// The setup card, the drop target and the composer's file drawer.
    static let panel: CGFloat = 16
    static let bubble: CGFloat = 18
    static let chat: CGFloat = 20
}

/// Spacing steps.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let ml: CGFloat = 10
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let x3: CGFloat = 24
    static let x4: CGFloat = 32
}

/// Widths of the chat window's parts. (Not SwiftUI's `Layout` protocol: that one is `SwiftUI.Layout` here.)
enum Layout {
    /// The reading column of the conversation and the composer.
    static let column: CGFloat = 736
    /// Space left and right of the column.
    static let gutter: CGFloat = 20
    static let inspector: CGFloat = 280
    static let sidebarIdeal: CGFloat = 248
    static let cardMax: CGFloat = 560
}

extension Font {
    /// The card views' text style: system font at a fixed size.
    static func scaled(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: design)
    }
}

extension View {
    /// The frame of a result card under an answer.
    func resultCard() -> some View {
        frame(maxWidth: Layout.cardMax, alignment: .leading).raised(Radius.card)
    }

    /// A raised surface: the card colour, a 1 pt hairline inside the edge and a soft shadow. `lifted` (hover, focus)
    /// deepens the shadow and brightens the edge a little.
    func raised(_ radius: CGFloat, lifted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Theme.chatCard, in: shape)
            .overlay {
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
                    .overlay { if lifted { shape.strokeBorder(Theme.hairline, lineWidth: 1) } }
                    .overlay { shape.strokeBorder(LinearGradient(colors: [Theme.topLight, .clear], startPoint: .top, endPoint: .center), lineWidth: 1) }
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(lifted ? 0.10 : 0.05), radius: lifted ? 12 : 6, y: lifted ? 4 : 2)
    }

    /// A floating control or bar (the composer, Send, "Jump to the latest"): Liquid Glass, reacting to the pointer when
    /// `interactive`; the raised card surface in snapshots. Content (answers, cards, tables) stays on solid surfaces,
    /// where it reads best.
    @ViewBuilder func glass(_ radius: CGFloat, interactive: Bool = false, lifted: Bool = false) -> some View {
        if Theme.drawsGlass {
            glassEffect(interactive ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            raised(radius, lifted: lifted)
        }
    }

    /// A round glass button filled with a colour (Send), or `fallback` drawn as a plain circle in snapshots.
    @ViewBuilder func glassCircle(tint: Color?, fallback: Color) -> some View {
        if Theme.drawsGlass {
            glassEffect(.regular.tint(tint).interactive(), in: Circle())
        } else {
            background(fallback, in: Circle())
        }
    }

    /// Fades in and rises a few points the first time it appears while `active`; with Reduce Motion it is simply there.
    func arrives(_ active: Bool, delay: Double = 0) -> some View {
        modifier(Arrival(active: active, delay: delay))
    }
}

private struct Arrival: ViewModifier {
    var active: Bool
    var delay: Double
    private let shownState = State(initialValue: false)

    func body(content: Content) -> some View {
        let hidden = active && !shownState.wrappedValue
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? Theme.arrivalOffset : 0)
            .onAppear {
                guard active else { return }
                withAnimation(Theme.message?.delay(delay)) { shownState.wrappedValue = true }
            }
    }
}

/// The head of every result card: a small tinted symbol badge, the title and a quiet detail.
struct CardHeader: View {
    var symbol: String
    var title: String
    var detail: String?

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .accessibilityHidden(true)
            Text(title).font(Typo.headline).foregroundStyle(Theme.ink).lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail).font(Typo.footnote).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, Space.l).padding(.bottom, Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A clickable row inside a result card: an inset rounded hover fill and the pointing hand. The label keeps 14 pt
/// from the card's edge, like the header.
struct CardRowButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: Label
    private let hoverState = State(initialValue: false)

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, Space.ml).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hoverState.wrappedValue ? Theme.rowHover : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.xs)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .pointerStyle(.link)
    }
}

/// A crisp 2/3-arc spinner that stays visible in static snapshots and rotates smoothly in live mode.
struct SpinRing: View {
    var size: CGFloat = 12
    var lineWidth: CGFloat = 1.6
    var color: Color = Theme.accent
    private let spinningState = State(initialValue: false)

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle().trim(from: 0, to: 0.68)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinningState.wrappedValue ? 270 : -90))
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !Theme.reduceMotion else { return }
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                spinningState.wrappedValue = true
            }
        }
    }
}

/// A compact action pill button ("Open Reminders", "Show in Finder", "Try Again", or primary CTA in `SetupCard`)
/// that stays crisp in dark mode and unfocused windows instead of collapsing to macOS's flat inactive grey.
struct ActionPill: View {
    var title: String
    var primary = false
    /// Escape for the button that says no (a question in the conversation).
    var shortcut: KeyboardShortcut? = nil
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: primary ? Radius.control : Radius.row, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(primary ? Typo.callout.weight(.semibold) : Typo.footnote.weight(.medium))
                .foregroundStyle(primary ? Color.white : Theme.ink)
                .padding(.horizontal, primary ? Space.l : Space.ml)
                .frame(height: primary ? 28 : 24)
                .background(primary ? (hoverState.wrappedValue ? Theme.accentPress : Theme.accentFill)
                                    : (hoverState.wrappedValue ? Theme.fill2 : Theme.fill), in: shape)
                .overlay { if !primary { shape.strokeBorder(Theme.hairline, lineWidth: 1) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .fixedSize()
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
    }
}

/// Chips that wrap onto the next line.
struct FlowRow: SwiftUI.Layout {
    var spacing: CGFloat = 6
    /// No chip grows wider than this (long names truncate).
    var maxItemWidth: CGFloat = 170
    /// Rows end at the right edge (the files above a question, which sits on the right).
    var trailing = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 400, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = layout.frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(1, width)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowStart = 0
        func endRow() {
            guard trailing, rowStart < frames.count else { return }
            let shift = width - (frames[frames.count - 1].maxX)
            for index in rowStart..<frames.count { frames[index].origin.x += max(0, shift) }
        }
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: min(maxItemWidth, width), height: nil))
            if x > 0 && x + size.width > width {
                endRow()
                rowStart = frames.count
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        endRow()
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}
