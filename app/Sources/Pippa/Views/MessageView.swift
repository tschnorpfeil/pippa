import AppKit
import PippaCore
import SwiftUI

/// One question (a bubble on the right, its files above it) or one answer (what Pippa did, the text, cards, what she
/// changed, and Copy and Ask Again). It reads the chat only through its inputs, so a new word in the running answer
/// redraws that answer and not every message before it.
struct MessageView: View, Equatable {
    let chat: ChatModel
    var message: ChatMessage
    /// The answer that is coming in right now.
    var live: Bool
    var isLast: Bool
    /// An answer runs somewhere: Edit and Ask Again wait.
    var answering: Bool
    var started: Date?
    var undoing: Set<String>
    private let hoverState = State(initialValue: false)
    /// Cards and receipts already there when the answer came on screen; ones that come later arrive one by one.
    private let seenState = State<(cards: Int, receipts: Int)?>(initialValue: nil)

    private var hover: Bool { hoverState.wrappedValue }

    nonisolated static func == (a: MessageView, b: MessageView) -> Bool {
        a.message == b.message && a.live == b.live && a.isLast == b.isLast && a.answering == b.answering
            && a.started == b.started && a.undoing == b.undoing
    }

    var body: some View {
        Group {
            switch message.role {
            case .user: user
            case .assistant: assistant
            }
        }
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .onAppear { seenState.wrappedValue = (message.cards.count, message.receipts.count) }
    }

    private var user: some View {
        VStack(alignment: .trailing, spacing: Space.s) {
            if !message.files.isEmpty {
                FlowRow(spacing: Space.s, maxItemWidth: 240, trailing: true) {
                    ForEach(message.files, id: \.self) { path in FileChip(url: URL(fileURLWithPath: path)) }
                }
                .padding(.leading, 64)
            }
            HStack(alignment: .bottom, spacing: Space.xs) {
                // Quiet actions beside the bubble, shown on hover: no space taken below it.
                HStack(spacing: Space.xxs) {
                    if !message.text.isEmpty { CopyButton(text: message.text, compact: true) }
                    GhostButton(title: T("Edit", table: "App"), symbol: "pencil", compact: true) { chat.edit(message) }
                        .disabled(answering)
                }
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
                if !message.text.isEmpty {
                    FractionalWidth(fraction: 0.78) {
                        Text(message.text)
                            .font(Typo.body).foregroundStyle(Theme.ink).lineSpacing(4)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, Space.ml)
                            .background(Theme.chatUser, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistant: some View {
        let seen = seenState.wrappedValue
        return VStack(alignment: .leading, spacing: Space.l) {
            if live || !message.steps.isEmpty || !(message.thinking ?? "").isEmpty || message.stopped == true {
                WorkView(message: message, live: live, started: started)
            }
            if !message.text.isEmpty {
                MarkdownText(text: message.text, highlights: live ? [] : message.unsupportedDates ?? [])
            }
            if !live, let dates = message.unsupportedDates, !dates.isEmpty { DateNote(dates: dates) }
            if !message.cards.isEmpty { ResultCardsView(cards: message.cards, arrivingFrom: seen?.cards) }
            if !message.receipts.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(Array(message.receipts.enumerated()), id: \.offset) { index, receipt in
                        ReceiptRow(receipt: receipt, undoing: undoing.contains(ChatModel.undoKey(message.id, index)),
                                   undo: live ? nil : { chat.undo(receiptAt: index, in: message.id) })
                            .arrives(seen.map { index >= $0.receipts } ?? false,
                                     delay: Double(message.cards.count + index) * Theme.stagger)
                    }
                }
            }
            if let error = message.error {
                ErrorBox(text: error, retry: isLast && !answering ? { chat.retry() } : nil)
                    .arrives(isLast)
            }
            if !live { footer }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// What the answer read on the left, Copy and Ask Again on the right (always on the last answer, on hover else).
    @ViewBuilder private var footer: some View {
        let sources = message.sources ?? []
        let showsActions = hover || isLast
        if !sources.isEmpty || !message.text.isEmpty {
            HStack(spacing: Space.m) {
                if !sources.isEmpty { SourceChips(sources: sources) }
                Spacer(minLength: Space.m)
                HStack(spacing: Space.xxs) {
                    if !message.text.isEmpty { CopyButton(text: message.text) }
                    if isLast && message.error == nil {
                        GhostButton(title: T("Ask Again", table: "App"), symbol: "arrow.clockwise") { chat.retry() }
                            .disabled(answering)
                    }
                }
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
            }
            .padding(.top, -Space.xs)
        }
    }
}

/// Proposes a share of the offered width to its one child and puts it at the trailing edge (the question bubble).
private struct FractionalWidth: SwiftUI.Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width.map { $0 * fraction }
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        child.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

private struct ErrorBox: View {
    var text: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.ml) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
            Text(text).font(Typo.callout).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: Space.m)
            if let retry { ActionPill(title: T("Try Again", table: "App"), action: retry) }
        }
        .padding(Space.l)
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .background(Theme.badTint, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// Dates in the answer that nothing Pippa read shows (`DateEvidence`): the model worked them out itself.
private struct DateNote: View {
    var dates: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(Theme.need)
            Text(T("Not in what I read: %@. I worked this out myself, so please check it.", table: "App",
                   dates.formatted(.list(type: .and))))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typo.footnote)
        .padding(.horizontal, Space.ml).padding(.vertical, Space.s)
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .background(Theme.needTint.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// A file the person added to a question; a click opens it.
private struct FileChip: View {
    var url: URL
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: Space.s) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
            .font(Typo.footnote).foregroundStyle(Theme.ink)
            .padding(.horizontal, Space.ml).frame(height: 30)
            .raised(Radius.control, lifted: hoverState.wrappedValue)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .help(url.path)
    }
}
