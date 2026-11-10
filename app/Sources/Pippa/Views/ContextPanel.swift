import AppKit
import PippaCore
import SwiftUI

/// "About this answer": what the latest answer read, did and checked, and how full the conversation is. Facts from
/// tool calls and Pi, never from the model's text. Which AI answered and where the data stays sits pinned at the bottom.
struct ContextPanel: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel

    private var answer: ChatMessage? { chat.current?.messages.last { $0.role == .assistant } }
    private var running: Bool { chat.isAnswering && chat.answeringID == chat.currentID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                Text(T("About this answer", table: "App"))
                    .font(Typo.callout.weight(.semibold)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if answer == nil {
                    intro
                } else {
                    facts
                }
            }
            .padding(.horizontal, Space.xl).padding(.top, 18).padding(.bottom, Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The inspector already sits below the window's bar; without this the bar's height is left out a second time
        // and the panel starts ~50 pt lower than the conversation. Now its heading shares the row with the title.
        .ignoresSafeArea(.container, edges: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .background(Theme.sideTint)
    }

    /// No answer yet: what the panel will show, instead of empty sections.
    private var intro: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(T("After each answer you see here what Pippa read, what she changed on your Mac and which dates she checked.", table: "App"))
                .font(Typo.footnote).foregroundStyle(Theme.ink2).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.s) {
                introRow("doc.text", T("Read", table: "App"))
                introRow("checklist", T("Done", table: "App"))
                introRow("checkmark.circle", T("Dates checked", table: "App"))
            }
        }
    }

    private func introRow(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol).font(Typo.caption).foregroundStyle(Theme.ink3).frame(width: 16)
            Text(title).font(Typo.footnote).foregroundStyle(Theme.ink3)
        }
    }

    @ViewBuilder private var facts: some View {
            section(T("Read", table: "App")) {
                if let sources = answer?.sources, !sources.isEmpty {
                    ForEach(sources, id: \.self) { source in
                        PanelRow(symbol: SourceChips.symbol(source.kind), title: source.name, detail: source.detail,
                                 action: source.location.isEmpty ? nil : { SourceChips.open(source) })
                    }
                } else {
                    empty(running ? T("Nothing yet", table: "App") : T("Nothing read for this answer", table: "App"))
                }
            }
            section(T("Done", table: "App")) {
                if let receipts = answer?.receipts, !receipts.isEmpty {
                    ForEach(Array(receipts.enumerated()), id: \.offset) { _, receipt in
                        PanelRow(symbol: ReceiptRow.symbol(receipt), title: ReceiptRow.title(receipt),
                                 detail: receipt.name.isEmpty ? nil : receipt.name,
                                 tint: receipt.outcome == "done" ? Theme.ok : Theme.need,
                                 action: ReceiptRow.openAction(receipt))
                    }
                } else {
                    empty(T("Nothing changed on your Mac", table: "App"))
                }
            }
            let checked = answer?.checkedDates ?? [], unsupported = answer?.unsupportedDates ?? []
            if !checked.isEmpty || !unsupported.isEmpty {
                section(T("Dates checked", table: "App")) {
                    ForEach(checked, id: \.self) {
                        PanelRow(symbol: "checkmark.circle", title: $0, detail: T("In what I read", table: "App"), tint: Theme.ok)
                    }
                    ForEach(unsupported, id: \.self) {
                        PanelRow(symbol: "exclamationmark.triangle", title: $0, detail: T("Worked out, please check", table: "App"), tint: Theme.need)
                    }
                }
            }
            if let usage = chat.current?.messages.last(where: { $0.context != nil })?.context {
                section(T("Conversation memory", table: "App")) { memory(usage) }
            }
    }

    private func memory(_ usage: ContextUsage) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill2)
                    Capsule().fill(usage.fraction > 0.8 ? Theme.need : Theme.accent)
                        .frame(width: max(5, geometry.size.width * min(1, usage.fraction)))
                }
            }
            .frame(height: 5)
            .animation(Theme.arrive, value: usage.fraction)
            Text(T("%lld %% full", table: "App", Int((usage.fraction * 100).rounded())))
                .font(Typo.caption).foregroundStyle(Theme.ink2).monospacedDigit()
                .contentTransition(.numericText())
                .animation(Theme.quick, value: usage.fraction)
            if usage.fraction > 0.8 {
                Text(T("Almost full: Pippa will soon summarize the start. A new conversation is faster.", table: "App"))
                    .font(Typo.caption).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .help(T("%@ of %@ tokens", table: "App", usage.tokens.formatted(), usage.window.formatted()))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.s) {
                Image(systemName: setup.usesOnlineAI ? "cloud" : "laptopcomputer").font(Typo.caption)
                Text(setup.usesOnlineAI ? AIBadge.label(setup) : "\(SettingsView.localModelName) · \(AIBadge.label(setup))")
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(Theme.ink2)
            Text(setup.usesOnlineAI ? T("Your conversation goes to this online AI.", table: "App") : T("Nothing leaves this Mac.", table: "App"))
                .foregroundStyle(Theme.ink3)
        }
        .font(Typo.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xl).padding(.vertical, Space.l)
        .background { Rectangle().fill(.bar).overlay(Theme.sideTint) }
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(Typo.caption.weight(.semibold)).tracking(0.5).textCase(.uppercase)
                .foregroundStyle(Theme.ink3)
                .padding(.bottom, Space.xxs)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Typo.footnote).foregroundStyle(Theme.ink3)
    }
}

/// One fact in the panel; with an action it highlights on hover and shows where the click leads.
private struct PanelRow: View {
    var symbol: String
    var title: String
    var detail: String?
    var tint: Color = Theme.ink3
    var action: (() -> Void)?
    private let hoverState = State(initialValue: false)

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
                .pointerStyle(.link)
                .help(T("Open", table: "App"))
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol).font(Typo.footnote).foregroundStyle(tint).frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.footnote).foregroundStyle(Theme.ink).lineLimit(2).truncationMode(.middle)
                if let detail { Text(detail).font(Typo.caption).foregroundStyle(Theme.ink3).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: "arrow.up.forward").font(Typo.caption.weight(.semibold)).imageScale(.small).foregroundStyle(Theme.ink3)
                    .padding(.top, 2)
                    .opacity(hoverState.wrappedValue ? 1 : 0)
            }
        }
        .padding(.horizontal, Space.s).padding(.vertical, 5)
        .background(hoverState.wrappedValue ? Theme.rowHover : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .padding(.horizontal, -Space.s)
        .contentShape(Rectangle())
    }
}
