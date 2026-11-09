import PiRPC
import SwiftUI

/// A question Pi asks during an answer ("May Pippa search the web?"), right in the conversation instead of a window
/// (`Approvals`): what she wants to do, the exact details below, and the answers. Nothing is pre-selected, so Return
/// never allows by accident; Escape says no or cancels.
struct QuestionCard: View {
    var question: Approvals.Question
    /// Only the oldest open question takes Escape and Return.
    var handlesKeys: Bool
    private let textState: State<String>
    @FocusState private var fieldFocused: Bool

    init(question: Approvals.Question, handlesKeys: Bool) {
        self.question = question
        self.handlesKeys = handlesKeys
        textState = State(initialValue: question.request.prefill ?? "")
    }

    private var request: PiUIRequest { question.request }
    /// Escape says no or cancels, on the oldest question only.
    private var escape: KeyboardShortcut? { handlesKeys ? .cancelAction : nil }

    /// Pi's `select` has no message, only a title and answers; "question\n\nsentence" may come in the title.
    private var text: (title: String, paragraphs: [String]) {
        var title = request.title, message = request.message
        if request.method == "select", message.isEmpty, let cut = title.range(of: "\n\n") {
            message = String(title[cut.upperBound...])
            title = String(title[..<cut.lowerBound])
        }
        let paragraphs = message.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (title.isEmpty ? T("May Pippa do this?", table: "App") : title, paragraphs)
    }

    var body: some View {
        let text = self.text
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Image(systemName: "hand.raised.fill")
                    .font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    .accessibilityHidden(true)
                Text(text.title).font(Typo.headline).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let first = text.paragraphs.first {
                Text(first).font(Typo.callout).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // What exactly would happen (the search words, the address): quiet, and selectable to check.
            if text.paragraphs.count > 1 {
                Text(text.paragraphs.dropFirst().joined(separator: "\n\n"))
                    .font(Typo.footnote).foregroundStyle(Theme.ink2).lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.ml).padding(.vertical, Space.m)
                    .background(Theme.chatInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            answers
        }
        .padding(Space.xl)
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .raised(Radius.card)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var answers: some View {
        switch request.method {
        case "confirm":
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                ActionPill(title: T("Don’t Allow", table: "App"), shortcut: escape) { answer(.confirmed(false)) }
                ActionPill(title: T("Allow", table: "App")) { answer(.confirmed(true)) }
            }
        case "select" where request.options.count <= 3:
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                ForEach(request.options, id: \.self) { option in
                    ActionPill(title: option) { answer(.value(option)) }
                }
            }
            .background { if handlesKeys { CancelKey { answer(.cancelled) } } }
        case "select":
            HStack(spacing: Space.m) {
                Menu {
                    ForEach(request.options, id: \.self) { option in
                        Button(option) { answer(.value(option)) }
                    }
                } label: {
                    Text(T("Choose…", table: "Views"))
                }
                .fixedSize()
                Spacer(minLength: 0)
                ActionPill(title: T("Cancel", table: "App"), shortcut: escape) { answer(.cancelled) }
            }
        default:
            VStack(alignment: .trailing, spacing: Space.m) {
                TextField(text: textState.projectedValue, prompt: request.placeholder.map { Text($0) },
                          axis: request.method == "editor" ? .vertical : .horizontal) { EmptyView() }
                    .textFieldStyle(.plain).font(Typo.body)
                    .lineLimit(request.method == "editor" ? 3...10 : 1...1)
                    .focused($fieldFocused)
                    .onSubmit { answer(.value(textState.wrappedValue)) }
                    .padding(.horizontal, Space.ml).padding(.vertical, Space.m)
                    .background(Theme.chatInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
                    .onAppear { if handlesKeys { fieldFocused = true } }
                HStack(spacing: Space.m) {
                    ActionPill(title: T("Cancel", table: "App"), shortcut: escape) { answer(.cancelled) }
                    ActionPill(title: T("OK", table: "App"), primary: true) { answer(.value(textState.wrappedValue)) }
                }
            }
        }
    }

    private func answer(_ response: PiUIResponse) {
        withAnimation(Theme.leave) { Approvals.shared.answer(question.id, response) }
    }
}

/// Escape for a question whose answers are all choices: no visible button, only the key.
private struct CancelKey: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
