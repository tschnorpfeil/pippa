import SwiftUI

/// The head of every result card: a small neutral symbol badge, the title and a quiet detail.
struct CardHeader: View {
    var symbol: String
    var title: String
    var detail: String?

    var body: some View {
        HStack(spacing: Space.m) {
            CardSymbol(symbol: symbol)
            Text(title).font(Typo.headline).foregroundStyle(Theme.ink).lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail).font(Typo.footnote).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.card).padding(.top, Space.l).padding(.bottom, Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The symbol at the head of a card or a question: neutral, never blue, because colour marks what can be clicked.
struct CardSymbol: View {
    var symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.ink2)
            .frame(width: 22, height: 22)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The last line of a result card: where the facts come from, quiet.
struct CardFooter: View {
    var text: String

    var body: some View {
        Text(text).font(Typo.caption).foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.card).padding(.top, Space.m).padding(.bottom, Space.l)
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

/// The chat's button: a capsule of one height and one font ("Open Reminders", "Try Again", "Allow"). Secondary is a
/// quiet fill, like the island's capsules; `primary` (one per decision: Allow, setup's main action) is the accent with white text.
/// Drawn by hand so it stays crisp in dark mode and unfocused windows instead of macOS's flat inactive grey.
struct ActionPill: View {
    var title: String
    var primary = false
    /// Escape for the button that says no (a question in the conversation).
    var shortcut: KeyboardShortcut? = nil
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        let shape = Capsule()
        Button(action: action) {
            Text(title)
                .font(Typo.footnote.weight(.medium))
                .foregroundStyle(primary ? Color.white : Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, Space.ml)
                .frame(height: 26)
                .background(primary ? (hoverState.wrappedValue ? Theme.accentPress : Theme.accentFill)
                                    : (hoverState.wrappedValue ? Theme.fill3 : Theme.fill2), in: shape)
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
