import PiRPC
import PippaCore
import SwiftUI

/// "New conversation", the same wherever it shows: the pencil with ⌘N written beside it, since tooltips rarely show on
/// the island.
struct IslandNewConversationButton: View {
    @ObservedObject var island: Island

    var body: some View {
        Button { island.startsFresh = true } label: {
            // One line of text: the symbol sits on the same baseline as ⌘N (side by side in an HStack the pencil's box
            // hung below the letters).
            Text("\(Image(systemName: "square.and.pencil"))\u{2009}⌘N")
                .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(IslandStyle.white(IslandStyle.secondary))
            .padding(.horizontal, 4).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .help(T("New Conversation", table: "App") + " (⌘N)")
        .accessibilityLabel(T("New Conversation", table: "App"))
    }
}


/// Which AI answers, beside the field: on this Mac (a laptop) or online (a cloud), its name on hover and for VoiceOver,
/// as the chat's composer names it (`AIBadge`); a click opens Settings → AI. Only the symbol: with the name the field
/// had no room left.
struct IslandAIBadge: View {
    @ObservedObject var setup: SetupModel

    var body: some View {
        let name = AIBadge.label(setup)
        Button { SettingsWindow.shared.show(.ai) } label: {
            Image(systemName: AIBadge.symbol(setup))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandStyle.white(IslandStyle.secondary))
                .frame(width: 28, height: IslandStyle.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name + " · " + T("Change in Settings", table: "App"))
        .accessibilityLabel(name)
        .accessibilityHint(T("Change in Settings", table: "App"))
    }
}

/// "Open Pippa" (⌘↩). Beside a question it shows without the hint, so the shortcut cannot read as Allow's.
struct IslandOpenButton: View {
    var hint: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(T("Open Pippa", table: "Island"))
                if hint { Text("⌘↩").foregroundStyle(IslandStyle.white(IslandStyle.secondary)) }
            }
        }
        .buttonStyle(IslandButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
    }
}

/// A question from Pi (`Approvals`): what it asks, directly on the island's black. Pi's `select` has no message, only a
/// title and answers; "question\n\nsentence" may come in the title.
struct IslandQuestionText: View {
    let request: PiUIRequest
    /// More of the text lies below what shows (a long recipient list, a whole mail). No `@State`: no SwiftUI macros.
    private let continues = State(initialValue: false)

    private var parts: ApprovalPresentation { ApprovalPresentation.parse(request) }

    var body: some View {
        let parts = parts
        VStack(alignment: .leading, spacing: IslandStyle.buttonGap) {
            Text(parts.title).font(IslandStyle.title).foregroundStyle(IslandStyle.white(IslandStyle.primary))
                .fixedSize(horizontal: false, vertical: true)
            // Everything the person allows, never cut (recipients, a whole mail): a long text scrolls inside the island,
            // so the buttons below stay in reach.
            ScrollView {
                VStack(alignment: .leading, spacing: IslandStyle.buttonGap) {
                    if let message = parts.summary, !message.isEmpty {
                        Text(ApprovalPresentation.formatted(message, baseFont: IslandStyle.small, valueFont: IslandStyle.small.weight(.semibold),
                                                            labelColor: IslandStyle.white(IslandStyle.secondary),
                                                            valueColor: IslandStyle.white(IslandStyle.primary)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail = parts.detail, !detail.isEmpty {
                        // In full, as on the chat's card: the command or address the person allows (bounded by its sender).
                        Text(ApprovalPresentation.formatted(detail, baseFont: IslandStyle.detail, valueFont: IslandStyle.detail.weight(.semibold),
                                                            labelColor: IslandStyle.white(IslandStyle.secondary),
                                                            valueColor: IslandStyle.white(IslandStyle.primary)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height - $0.visibleRect.maxY > 1 } action: { _, more in continues.wrappedValue = more }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            // Until the end is in view, a fade and an arrow over the last line: the list never looks complete before
            // it is, even where macOS hides the scroll bar.
            .overlay(alignment: .bottom) { if continues.wrappedValue { IslandMoreBelow() } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "There is more below" over the bottom edge of a scrolling question text; clicks and VoiceOver pass through.
private struct IslandMoreBelow: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color.black.opacity(0), Color.black], startPoint: .top, endPoint: .bottom)
                .frame(height: 40)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(IslandStyle.white(IslandStyle.primary))
                .frame(width: 22, height: 22)
                .background(Circle().fill(IslandStyle.white(0.18)))
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The answers to a question: Allow / Don't Allow, a choice, or a text. Nothing is pre-selected and Return never
/// allows; Escape declines (IslandPresenter). "Open Pippa" sits at the left of Allow's or Cancel's row when it fits
/// there, on its own row otherwise and always under a text.
struct IslandQuestionAnswers: View {
    let question: Approvals.Question
    var onOpen: () -> Void
    private let textState: State<String>

    init(question: Approvals.Question, onOpen: @escaping () -> Void) {
        self.question = question
        self.onOpen = onOpen
        textState = State(initialValue: question.request.prefill ?? "")
    }

    private var request: PiUIRequest { question.request }

    var body: some View {
        if request.method == "confirm" {
            IslandButtonRow(lead: true) {
                IslandOpenButton(hint: false, action: onOpen)
                // The card's own words when it names them ("Don’t Send", "Send"), as in the chat.
                let labels = Confirmations.confirmLabels(request)
                button(labels.no, .confirmed(false))
                button(labels.yes, .confirmed(true), prominent: true)
            }
        } else if request.method == "select" {
            // Every choice in sight, one row each and in full: a pop-up menu hid them behind a click and opened over
            // the island. When `ask.ts` appends its "Something else…" sentinel, show an inline text field on the same card.
            let choices = ApprovalChoices.parse(request.options)
            let canSendCustom = ApprovalChoices.validatedText(textState.wrappedValue) != nil
            VStack(alignment: .leading, spacing: IslandStyle.gap) {
                VStack(spacing: 6) {
                    ForEach(choices.options, id: \.self) { option in
                        Button(option) { Approvals.shared.answer(question.id, .value(option)) }
                            .buttonStyle(IslandChoiceStyle())
                            .accessibilityLabel(option)
                    }
                }
                if choices.allowsCustomText {
                    HStack(spacing: IslandStyle.buttonGap) {
                        TextField(T("Or type your own answer…", table: "Island"), text: textState.projectedValue,
                                  prompt: Text(T("Or type your own answer…", table: "Island")).foregroundStyle(IslandStyle.white(IslandStyle.secondary)))
                            .textFieldStyle(.plain).font(IslandStyle.small)
                            .foregroundStyle(IslandStyle.white(IslandStyle.primary))
                            .onSubmit { submitText() }
                            .islandWell()
                            .accessibilityLabel(T("Or type your own answer…", table: "Island"))
                        Button(T("Send", table: "App")) { submitText() }
                            .buttonStyle(IslandButtonStyle(prominent: true))
                            .disabled(!canSendCustom)
                            .opacity(canSendCustom ? 1 : 0.45)
                    }
                }
                IslandButtonRow(lead: true) {
                    IslandOpenButton(hint: false, action: onOpen)
                    button(T("Cancel", table: "App"), .cancelled)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: IslandStyle.gap) {
                answers
                IslandOpenButton(hint: false, action: onOpen)
            }
        }
    }

    @ViewBuilder private var answers: some View {
        switch request.method {
        default:
            let canSubmit = ApprovalChoices.validatedText(textState.wrappedValue) != nil
            VStack(alignment: .leading, spacing: IslandStyle.buttonGap) {
                TextField(request.placeholder ?? "", text: textState.projectedValue,
                          prompt: Text(request.placeholder ?? "").foregroundStyle(IslandStyle.white(IslandStyle.secondary)))
                    .textFieldStyle(.plain).font(IslandStyle.body)
                    .foregroundStyle(IslandStyle.white(IslandStyle.primary))
                    .onSubmit { submitText() }
                    .islandWell()
                IslandButtonRow {
                    button(T("Cancel", table: "App"), .cancelled)
                    Button(T("OK", table: "App")) { submitText() }
                        .buttonStyle(IslandButtonStyle(prominent: true))
                        .disabled(!canSubmit)
                        .opacity(canSubmit ? 1 : 0.45)
                }
            }
        }
    }

    private func submitText() {
        guard let value = ApprovalChoices.validatedText(textState.wrappedValue) else { return }
        Approvals.shared.answer(question.id, .value(value))
    }

    private func button(_ title: String, _ response: PiUIResponse, prominent: Bool = false) -> some View {
        Button(title) { Approvals.shared.answer(question.id, response) }.buttonStyle(IslandButtonStyle(prominent: prominent))
    }
}

/// Capsule buttons on the right, 8 pt apart, wrapping onto another row instead of truncating. With `lead`, the first
/// one sits at the left of the same row when everything fits, otherwise on its own row below the others.
struct IslandButtonRow: SwiftUI.Layout {
    var lead = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in arrangement(width: bounds.width, subviews: subviews).frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let gap = IslandStyle.buttonGap
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let oneRow = sizes.map(\.width).reduce(0, +) + gap * CGFloat(max(0, sizes.count - 1))
        let width = width ?? oneRow
        let first = lead ? 1 : 0
        // The others in rows from the top, each row flush right.
        var rows: [[Int]] = [[]]
        var used: CGFloat = 0
        for index in first..<sizes.count {
            let needed = (rows[rows.count - 1].isEmpty ? 0 : gap) + sizes[index].width
            if !rows[rows.count - 1].isEmpty, used + needed > width {
                rows.append([index]); used = sizes[index].width
            } else {
                rows[rows.count - 1].append(index); used += needed
            }
        }
        let leadBeside = lead && rows.count == 1 && oneRow <= width
        if lead && !leadBeside { rows.append([0]) }
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        for (number, row) in rows.enumerated() where !row.isEmpty {
            let height = (row + (leadBeside && number == 0 ? [0] : [])).map { sizes[$0].height }.max() ?? 0
            if lead && row == [0] && !leadBeside {
                frames[0] = CGRect(origin: CGPoint(x: 0, y: y + (height - sizes[0].height) / 2), size: sizes[0])
            } else {
                var x = width
                for index in row.reversed() {
                    x -= sizes[index].width
                    frames[index] = CGRect(origin: CGPoint(x: x, y: y + (height - sizes[index].height) / 2), size: sizes[index])
                    x -= gap
                }
                if leadBeside && number == 0 {
                    frames[0] = CGRect(origin: CGPoint(x: 0, y: y + (height - sizes[0].height) / 2), size: sizes[0])
                }
            }
            y += height + gap
        }
        return (frames, CGSize(width: width, height: max(0, y - gap)))
    }
}
