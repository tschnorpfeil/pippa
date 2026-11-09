import AppKit
import SwiftUI

/// A quiet text button under a message: no frame, a soft fill on hover.
struct GhostButton: View {
    var title: String
    var symbol: String
    /// Only the symbol (the title goes to the tooltip).
    var compact = false
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: symbol).font(Typo.caption.weight(.medium))
                    .contentTransition(.symbolEffect(.replace))
                if !compact { Text(title) }
            }
            .font(Typo.footnote)
            .foregroundStyle(hoverState.wrappedValue ? Theme.ink2 : Theme.ink3)
            .padding(.horizontal, compact ? 0 : 7)
            .frame(minWidth: 24, minHeight: 24)
            .background(hoverState.wrappedValue ? Theme.rowHover : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Copy, then a check mark for a moment.
struct CopyButton: View {
    var text: String
    var compact = false
    private let copiedState = State(initialValue: false)

    var body: some View {
        GhostButton(title: copiedState.wrappedValue ? T("Copied", table: "App") : T("Copy", table: "App"),
                    symbol: copiedState.wrappedValue ? "checkmark" : "doc.on.doc", compact: compact) {
            CopyButton.copy(text, flag: copiedState)
        }
    }

    /// Puts `text` on the pasteboard and shows the check mark on `flag` for 1.5 s.
    static func copy(_ text: String, flag: State<Bool>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(Theme.quick) { flag.wrappedValue = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(Theme.quick) { flag.wrappedValue = false }
        }
    }
}
