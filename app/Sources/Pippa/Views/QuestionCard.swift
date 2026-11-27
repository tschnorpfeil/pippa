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
    private let selectedOptionState = State<String?>(initialValue: nil)
    @FocusState private var fieldFocused: Bool

    init(question: Approvals.Question, handlesKeys: Bool) {
        self.question = question
        self.handlesKeys = handlesKeys
        textState = State(initialValue: question.request.prefill ?? "")
    }

    private var request: PiUIRequest { question.request }
    /// Escape says no or cancels, on the oldest question only.
    private var escape: KeyboardShortcut? { handlesKeys ? .cancelAction : nil }

    private var text: ApprovalPresentation { ApprovalPresentation.parse(request) }
    private var parsedChoices: ApprovalChoices { ApprovalChoices.parse(request.options) }
    private var validatedText: String? { ApprovalChoices.validatedText(textState.wrappedValue) }
    private var selectPayload: String? { validatedText ?? selectedOptionState.wrappedValue }
    private var canSubmitSelect: Bool { selectPayload != nil }
    private var canSubmitInput: Bool { validatedText != nil }

    var body: some View {
        let text = self.text
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                CardSymbol(symbol: request.method == "select" ? "questionmark.circle" : "hand.raised.fill")
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Text(text.title).font(Typo.headline).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let first = text.summary {
                Text(ApprovalPresentation.formatted(first, baseFont: Typo.callout, valueFont: Typo.callout.weight(.semibold),
                                                    labelColor: Theme.ink2, valueColor: Theme.ink))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // What exactly would happen (the search words, the address): right on the card, selectable to check.
            if let detail = text.detail {
                let shown = Text(ApprovalPresentation.formatted(detail, baseFont: Typo.callout.weight(.medium),
                                                                valueFont: Typo.callout.weight(.semibold),
                                                                labelColor: Theme.ink2, valueColor: Theme.ink))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A long text (a whole mail) scrolls inside the card, so the buttons stay in reach; nothing is cut.
                if detail.count > Self.scrollsAfter {
                    ScrollView { shown.padding(.trailing, Space.m) }.frame(maxHeight: Self.detailHeight)
                } else {
                    shown
                }
            }
            answers
        }
        .padding(Space.card)
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .raised(Radius.card)
        .accessibilityElement(children: .contain)
    }

    static let scrollsAfter = 700
    static let detailHeight: CGFloat = 280

    @ViewBuilder private var answers: some View {
        switch request.method {
        case "confirm":
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                // A card may name its buttons in plain words (no, yes): "Don’t Send", "Send".
                let labels = Confirmations.confirmLabels(request)
                ActionPill(title: labels.no, shortcut: escape) { answer(.confirmed(false)) }
                ActionPill(title: labels.yes, primary: true) { answer(.confirmed(true)) }
            }
        case "select":
            let choices = parsedChoices
            VStack(alignment: .leading, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(choices.options, id: \.self) { option in
                        let selected = selectedOptionState.wrappedValue == option && validatedText == nil
                        SelectOptionRow(title: option, selected: selected) {
                            handleOptionTap(option)
                        }
                    }
                }
                if choices.allowsCustomText {
                    let active = fieldFocused || validatedText != nil
                    TextField(text: textState.projectedValue,
                              prompt: Text(T("Or type your own answer…", table: "Views")).foregroundStyle(Theme.ink3),
                              axis: .horizontal) { EmptyView() }
                        .textFieldStyle(.plain).font(Typo.callout).foregroundStyle(Theme.ink)
                        .lineLimit(1...1)
                        .focused($fieldFocused)
                        .onChange(of: textState.wrappedValue) { _, newValue in
                            if !newValue.isEmpty, selectedOptionState.wrappedValue != nil {
                                withAnimation(Theme.quick) { selectedOptionState.wrappedValue = nil }
                            }
                        }
                        .onSubmit { submitSelect() }
                        .padding(.horizontal, Space.ml).padding(.vertical, Space.m)
                        .background(Theme.chatInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(active ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: 1)
                        }
                        .accessibilityLabel(T("Or type your own answer…", table: "Views"))
                }
                HStack(spacing: Space.m) {
                    Spacer(minLength: 0)
                    ActionPill(title: T("Cancel", table: "App"), shortcut: escape) { answer(.cancelled) }
                    ActionPill(
                        title: validatedText != nil ? T("Send", table: "App") : T("Choose", table: "Views"),
                        primary: true,
                        shortcut: handlesKeys && canSubmitSelect ? .defaultAction : nil
                    ) {
                        submitSelect()
                    }
                    .disabled(!canSubmitSelect)
                    .opacity(canSubmitSelect ? 1 : 0.45)
                }
            }
        default:
            VStack(alignment: .trailing, spacing: Space.m) {
                TextField(text: textState.projectedValue, prompt: request.placeholder.map { Text($0) },
                          axis: request.method == "editor" ? .vertical : .horizontal) { EmptyView() }
                    .textFieldStyle(.plain).font(Typo.body)
                    .lineLimit(request.method == "editor" ? 3...10 : 1...1)
                    .focused($fieldFocused)
                    .onSubmit { submitInput() }
                    .padding(.horizontal, Space.ml).padding(.vertical, Space.m)
                    .background(Theme.chatInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
                    .onAppear { if handlesKeys { fieldFocused = true } }
                HStack(spacing: Space.m) {
                    ActionPill(title: T("Cancel", table: "App"), shortcut: escape) { answer(.cancelled) }
                    ActionPill(title: T("OK", table: "App"), primary: true) { submitInput() }
                        .disabled(!canSubmitInput)
                        .opacity(canSubmitInput ? 1 : 0.45)
                }
            }
        }
    }

    private func handleOptionTap(_ option: String) {
        withAnimation(Theme.quick) {
            selectedOptionState.wrappedValue = option
            if !textState.wrappedValue.isEmpty { textState.wrappedValue = "" }
        }
        fieldFocused = false
    }

    private func submitSelect() {
        guard let value = selectPayload else { return }
        answer(.value(value))
    }

    private func submitInput() {
        guard let value = validatedText else { return }
        answer(.value(value))
    }

    private func answer(_ response: PiUIResponse) {
        withAnimation(Theme.leave) { Approvals.shared.answer(question.id, response) }
    }
}

/// One full-width selectable option row inside `QuestionCard`.
private struct SelectOptionRow: View {
    var title: String
    var selected: Bool
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(Typo.callout)
                    .foregroundStyle(selected ? Theme.accent : Theme.ink3)
                    .accessibilityHidden(true)
                Text(title)
                    .font(selected ? Typo.callout.weight(.medium) : Typo.callout)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Space.ml)
            .padding(.vertical, Space.m)
            .background(selected ? Theme.accentTint : (hoverState.wrappedValue ? Theme.fill2 : Theme.fill), in: shape)
            .overlay {
                shape.strokeBorder(selected ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// A compact, dimmed read-only record of a question Pi asked and how the person answered or cancelled it.
struct AnsweredQuestionRow: View {
    var item: AnsweredQuestion

    private var symbol: String {
        switch item.outcome {
        case .allowed, .answered: "checkmark.circle"
        case .declined: "xmark.circle"
        case .cancelled: "minus.circle"
        }
    }

    private var symbolColor: Color {
        switch item.outcome {
        case .allowed, .answered: Theme.ok.opacity(0.8)
        case .declined, .cancelled: Theme.ink3
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: symbol)
                .font(Typo.footnote.weight(.medium))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(item.title)
                    .font(Typo.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Typo.caption)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.displayAnswer)
                .font(Typo.caption.weight(.medium))
                .foregroundStyle(item.outcome == .cancelled || item.outcome == .declined ? Theme.ink3 : Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.xxs)
                .background(Theme.fill2, in: Capsule())
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.ml)
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .background(Theme.chatInset, in: shape)
        .overlay {
            shape.strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
        }
        .opacity(0.86)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title): \(item.displayAnswer)")
    }
}
