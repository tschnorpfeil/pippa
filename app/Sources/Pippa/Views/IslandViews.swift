import PiRPC
import PippaCore
import SwiftUI

extension IslandStyle {
    static func white(_ opacity: Double) -> Color { Color.white.opacity(opacity) }
    static let accent = Color(red: 0x80 / 255, green: 0xB8 / 255, blue: 0xFF / 255)
    static let ok = Color(red: 0x45 / 255, green: 0xD9 / 255, blue: 0x7F / 255)
    static let bad = Color(red: 0xF8 / 255, green: 0x9D / 255, blue: 0xA4 / 255)

    static func tint(_ tone: IslandStatus.Tone) -> Color {
        switch tone {
        case .done: ok
        case .failed: bad
        case .needsYou: accent
        case .rest, .working: white(secondary)
        }
    }
}

/// Left of the notch: Pippa's blue mark, and while she works her line beside it. Or the capsule under the menu bar
/// symbol.
struct IslandCompactView: View {
    @ObservedObject var island: Island
    /// Width of the camera housing; nil under the menu bar. The shape reaches into its left half.
    var housingWidth: CGFloat?

    var body: some View {
        let status = island.status
        Group {
            if let housingWidth {
                HStack(spacing: IslandStyle.wingGap) {
                    PippaMark(size: IslandStatus.markSize, state: status.markState)
                    if status.showsCompact { IslandLine(status: status).transition(.opacity) }
                }
                .padding(.leading, IslandStyle.wingInset)
                .padding(.trailing, IslandStyle.wingGap + housingWidth / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.18), value: status.showsCompact)
            } else {
                HStack(spacing: 7) {
                    PippaMark(size: IslandStatus.markSize, state: status.markState)
                    IslandLine(status: status)
                }
                .padding(.leading, 6).padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

/// One line and its sign or progress ring.
struct IslandLine: View {
    let status: IslandStatus

    var body: some View {
        HStack(spacing: 6) {
            Text(status.label)
                .font(Font(IslandStatus.font as CTFont))
                .foregroundStyle(status.tone == .working ? IslandStyle.white(IslandStyle.secondary + 0.2) : IslandStyle.white(IslandStyle.primary))
                .lineLimit(1).truncationMode(.middle)
                .contentTransition(.opacity)
            if let progress = status.progress {
                IslandRing(progress: progress)
            } else if let symbol = status.symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(IslandStyle.tint(status.tone))
                    .frame(width: 12)
            }
        }
    }
}

struct IslandRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(IslandStyle.white(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(IslandStyle.white(IslandStyle.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }
}

/// The open island: what Pippa is doing or said last, a question if she has one, and a field for a quick question.
struct IslandPanelView: View {
    @ObservedObject var island: Island
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    @ObservedObject var approvals: Approvals
    var onHeight: (CGFloat) -> Void = { _ in }
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let question = approvals.questions.first {
                IslandQuestionView(question: question).id(question.id)
            } else if chat.isAnswering {
                steps
            } else if let progress = setupProgress {
                download(progress)
            } else if setupNeedsYou {
                setupAction
            } else if let preview {
                Text(preview)
                    .font(.system(size: 13)).foregroundStyle(IslandStyle.white(IslandStyle.primary - 0.1))
                    .lineLimit(4).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(T("Ask me anything, or drop a file here.", table: "Island"))
                    .font(.system(size: 13)).foregroundStyle(IslandStyle.white(IslandStyle.secondary))
            }
            if !chat.attachments.isEmpty { files }
            field
            HStack {
                Spacer()
                Button { island.openChat() } label: {
                    HStack(spacing: 6) {
                        Text(T("Open Pippa", table: "Island"))
                        Text("⌘↩").foregroundStyle(IslandStyle.white(IslandStyle.tertiary))
                    }
                }
                .buttonStyle(IslandButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, IslandStyle.padding).padding(.top, 10).padding(.bottom, IslandStyle.padding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { if island.wantsFocus { fieldFocused = true } }
        .onChange(of: island.focusToken) { fieldFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PippaMark(size: 22, state: island.status.markState)
            Text(island.status.tone == .rest ? "Pippa" : island.status.label)
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(IslandStyle.white(IslandStyle.primary))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let symbol = island.status.symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(IslandStyle.tint(island.status.tone))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var steps: some View {
        let running = chat.answering?.messages.last?.steps.suffix(3) ?? []
        return VStack(alignment: .leading, spacing: 6) {
            if running.isEmpty {
                Text(T("Thinking…", table: "App")).foregroundStyle(IslandStyle.white(IslandStyle.secondary))
            }
            ForEach(Array(running)) { step in
                HStack(spacing: 8) {
                    Image(systemName: step.failed ? "exclamationmark.circle" : step.done ? "checkmark.circle" : "circle.dotted")
                        .foregroundStyle(step.failed ? IslandStyle.bad : IslandStyle.white(step.done ? IslandStyle.tertiary : IslandStyle.secondary))
                    Text(step.label).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(IslandStyle.white(step.done ? IslandStyle.secondary : IslandStyle.primary))
                }
            }
        }
        .font(.system(size: 12))
    }

    private var setupProgress: Double? {
        guard !setup.usesOnlineAI, case .downloading(let progress, _) = setup.state else { return nil }
        return progress
    }

    private var setupNeedsYou: Bool {
        guard !setup.usesOnlineAI else { return false }
        switch setup.state {
        case .askDownload, .failed: return true
        default: return false
        }
    }

    private func download(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: min(max(progress, 0), 1)).progressViewStyle(.linear).tint(IslandStyle.white(IslandStyle.primary))
            Text(T("Loading my AI · %lld %%", table: "App", Int(progress * 100)))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(IslandStyle.white(IslandStyle.secondary))
        }
    }

    private var setupAction: some View {
        Button { island.openChat() } label: { Text(T("Set up my AI", table: "App")) }
            .buttonStyle(IslandButtonStyle(prominent: true))
    }

    /// The beginning of the last answer as plain text; a failed answer shows its error.
    private var preview: String? {
        let conversation = chat.current ?? chat.conversations.max { $0.updated < $1.updated }
        guard let message = conversation?.messages.last(where: { $0.role == .assistant }) else { return nil }
        if let error = message.error, !error.isEmpty { return error }
        let text = IslandText.plain(message.text)
        return text.isEmpty ? nil : text
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(chat.attachments, id: \.self) { url in
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(IslandStyle.white(IslandStyle.secondary))
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(IslandStyle.white(IslandStyle.primary))
                    Spacer(minLength: 0)
                    Button { chat.attachments.removeAll { $0 == url } } label: {
                        Image(systemName: "xmark").foregroundStyle(IslandStyle.white(IslandStyle.secondary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(T("Remove", table: "App"))
                }
                .font(.system(size: 12))
            }
        }
    }

    private var field: some View {
        TextField(chat.isAnswering ? T("Pippa is answering…", table: "Island") : T("Ask Pippa…", table: "App"), text: $chat.draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(IslandStyle.white(IslandStyle.primary))
            .focused($fieldFocused)
            .disabled(chat.isAnswering)
            .onSubmit { island.send() }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IslandStyle.white(0.1)))
    }
}

/// A question from Pi (`Approvals`): Allow / Don't Allow, a choice, or a text. Nothing is pre-selected and Return never
/// allows; Escape declines (IslandPresenter).
struct IslandQuestionView: View {
    let question: Approvals.Question
    private let textState: State<String>

    init(question: Approvals.Question) {
        self.question = question
        textState = State(initialValue: question.request.prefill ?? "")
    }

    private var request: PiUIRequest { question.request }

    /// Pi's `select` has no message, only a title and answers; "question\n\nsentence" may come in the title.
    private var parts: (title: String, message: String, detail: String) {
        var title = request.title, message = request.message
        if request.method == "select", message.isEmpty, let cut = title.range(of: "\n\n") {
            message = String(title[cut.upperBound...]); title = String(title[..<cut.lowerBound])
        }
        let paragraphs = message.components(separatedBy: "\n\n")
        return (title.isEmpty ? T("May Pippa do this?", table: "App") : title, paragraphs.first ?? message,
                paragraphs.dropFirst().joined(separator: "\n\n"))
    }

    var body: some View {
        let parts = parts
        VStack(alignment: .leading, spacing: 8) {
            Text(parts.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(IslandStyle.white(IslandStyle.primary))
                .fixedSize(horizontal: false, vertical: true)
            if !parts.message.isEmpty {
                Text(parts.message).font(.system(size: 12)).foregroundStyle(IslandStyle.white(IslandStyle.secondary + 0.1))
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
            }
            if !parts.detail.isEmpty {
                // In full, as on the chat's card: the command or address the person allows (bounded by its sender).
                Text(parts.detail).font(.system(size: 12, weight: .medium)).foregroundStyle(IslandStyle.white(IslandStyle.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            answers.padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IslandStyle.white(0.08)))
    }

    @ViewBuilder private var answers: some View {
        switch request.method {
        case "confirm":
            HStack(spacing: 8) {
                Spacer()
                button(T("Don’t Allow", table: "App"), .confirmed(false))
                button(T("Allow", table: "App"), .confirmed(true))
            }
        case "select" where !request.options.isEmpty && request.options.count <= 3:
            HStack(spacing: 8) {
                Spacer()
                button(T("Cancel", table: "App"), .cancelled)
                ForEach(request.options, id: \.self) { option in button(option, .value(option)) }
            }
        case "select":
            HStack(spacing: 8) {
                Menu(T("Choose…", table: "Island")) {
                    ForEach(request.options, id: \.self) { option in
                        Button(option) { Approvals.shared.answer(question.id, .value(option)) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                button(T("Cancel", table: "App"), .cancelled)
            }
        default:
            VStack(alignment: .trailing, spacing: 8) {
                TextField(request.placeholder ?? "", text: textState.projectedValue)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit { Approvals.shared.answer(question.id, .value(textState.wrappedValue)) }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(IslandStyle.white(0.1)))
                HStack(spacing: 8) {
                    button(T("Cancel", table: "App"), .cancelled)
                    Button(T("OK", table: "App")) { Approvals.shared.answer(question.id, .value(textState.wrappedValue)) }
                        .buttonStyle(IslandButtonStyle(prominent: true))
                }
            }
        }
    }

    private func button(_ title: String, _ response: PiUIResponse) -> some View {
        Button(title) { Approvals.shared.answer(question.id, response) }.buttonStyle(IslandButtonStyle())
    }
}

/// Capsule buttons that read on black.
struct IslandButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : IslandStyle.white(IslandStyle.primary))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(prominent ? IslandStyle.white(configuration.isPressed ? 0.75 : IslandStyle.primary)
                                                 : IslandStyle.white(configuration.isPressed ? 0.24 : 0.14)))
            .contentShape(Capsule())
    }
}

/// The start of an answer without Markdown marks, for a few lines in the island.
enum IslandText {
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("|") || line.hasPrefix("```") || line.allSatisfy({ "-*_ ".contains($0) }) { continue }
            while line.hasPrefix("#") { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            lines.append(line.trimmingCharacters(in: .whitespaces))
            if lines.count == 4 { break }
        }
        return lines.joined(separator: "\n")
    }
}
