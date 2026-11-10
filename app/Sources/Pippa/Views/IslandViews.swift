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
    /// Width of the camera housing; nil under the menu bar. The shape reaches into it up to 6 pt from its right edge.
    var housingWidth: CGFloat?

    var body: some View {
        let status = island.status
        Group {
            if let housingWidth {
                HStack(spacing: IslandStyle.wingGap) {
                    IslandMark(status: status, size: IslandStatus.markSize)
                    if status.showsCompact { IslandLine(status: status).transition(.opacity) }
                }
                .padding(.leading, IslandStyle.wingInset)
                .padding(.trailing, IslandStyle.wingGap + housingWidth - 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.18), value: status.showsCompact)
            } else {
                HStack(spacing: 7) {
                    IslandMark(status: status, size: IslandStatus.markSize)
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

/// Pippa's mark, or her handwriting while words of the answer come in.
struct IslandMark: View {
    let status: IslandStatus
    let size: CGFloat

    var body: some View {
        ZStack {
            if status.writing {
                Scribble(size: size).transition(.opacity)
            } else {
                PippaMark(size: size, state: status.markState).transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.18), value: status.writing)
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
    /// At the notch: the menu bar row beside the housing, where the header stays. Nil under the menu bar symbol.
    var menuBarRow: MenuBarRow?
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var drop = DropFeedback.island

    struct MenuBarRow: Equatable {
        var height: CGFloat
        /// From the housing's left edge to the panel's right edge: the part of the row the header must leave free.
        var besideHousing: CGFloat
    }

    var body: some View {
        VStack(spacing: 0) {
            if let menuBarRow {
                // Mark and line stay in the menu bar, left of the camera; the panel only grows below it.
                header(markSize: IslandStatus.markSize)
                    .padding(.leading, IslandStyle.padding)
                    .padding(.trailing, IslandStyle.wingGap + menuBarRow.besideHousing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: menuBarRow.height)
                    // As on the closed island, a click on the mark's row closes it.
                    .contentShape(Rectangle())
                    .onTapGesture { island.compactClicked() }
            }
            Group {
                if island.dropMode { dropTray } else { content }
            }
            .padding(.horizontal, IslandStyle.padding).padding(.top, menuBarRow == nil ? 10 : 6).padding(.bottom, IslandStyle.padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { if island.wantsFocus { fieldFocused = true } }
        .onChange(of: island.focusToken) { fieldFocused = true }
        // The field stays usable while she answers, so it keeps the keyboard after Return; this brings it back if
        // something else took it.
        .onChange(of: chat.isAnswering) { _, answering in if !answering && island.isOpen { fieldFocused = true } }
    }

    /// While files are dragged toward the island: one large target that lights up when they are over it.
    private var dropTray: some View {
        let over = drop.targeted
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(over ? IslandStyle.accent : IslandStyle.white(IslandStyle.secondary))
                .offset(y: over ? 2 : 0)
            Text(T("Drop here for Pippa", table: "Island"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(IslandStyle.white(IslandStyle.primary))
            Text(T("Then just ask what to do with it.", table: "Island"))
                .font(.system(size: 12)).foregroundStyle(IslandStyle.white(IslandStyle.secondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(shape.fill(over ? IslandStyle.accent.opacity(0.14) : IslandStyle.white(0.04)))
        .overlay(shape.strokeBorder(over ? IslandStyle.accent : IslandStyle.white(0.22),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .scaleEffect(over ? 1.02 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: over)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if menuBarRow == nil { header(markSize: 22) }
            if let question = approvals.questions.first {
                IslandQuestionView(question: question).id(question.id)
            } else if chat.isAnswering {
                steps
            } else if let progress = setupProgress {
                download(progress)
            } else if setupNeedsYou {
                setupAction
            } else if let error = lastAnswer?.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 13)).foregroundStyle(IslandStyle.white(IslandStyle.primary - 0.1))
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let text = lastAnswer?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The answer as in the chat (bold, lists, headings, tables), scrolling inside the island when it is long.
                ScrollView {
                    MarkdownText(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Room under the last line: the fade below only ever covers text that scrolls on.
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, -6)
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                    }
                }
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
    }

    private func header(markSize: CGFloat) -> some View {
        HStack(spacing: markSize < 20 ? IslandStyle.wingGap : 10) {
            IslandMark(status: island.status, size: markSize)
            // In the menu bar row just her name and the sign: the panel below says what she does or asks.
            Text(island.status.tone == .rest || markSize < 20 ? "Pippa" : island.status.label)
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(IslandStyle.white(IslandStyle.primary))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            // Beside the notch the row has room for the name only; the panel below shows the question or the answer.
            if markSize >= 20, let symbol = island.status.symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(IslandStyle.tint(island.status.tone))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// While she works: her steps as a chain, newest at the bottom, and what she is doing right now at its end: her
    /// thinking or the answer as it is written, the last few lines of it.
    private var steps: some View {
        let message = chat.answering?.messages.last
        let all = message?.steps ?? []
        let shown = Array(all.suffix(4))
        let now = IslandChain.now(message: message, writing: chat.isWriting)
        // A running step is what she does right now: the chain ends on it.
        let running = all.contains { !$0.done }
        return VStack(alignment: .leading, spacing: 0) {
            if all.count > shown.count {
                IslandChainRow(node: .earlier, isFirst: true, isLast: false) {
                    Text(T("%lld earlier steps", table: "Island", all.count - shown.count))
                        .foregroundStyle(IslandStyle.white(IslandStyle.tertiary))
                }
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, step in
                IslandChainRow(node: step.failed ? .failed : step.done ? .done : .running,
                               isFirst: index == 0 && all.count == shown.count, isLast: running && index == shown.count - 1) {
                    Text(step.label).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(IslandStyle.white(step.done ? IslandStyle.secondary : IslandStyle.primary))
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !running {
                IslandChainRow(node: now.writing ? .writing : .thinking, isFirst: all.isEmpty, isLast: true) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(now.writing ? T("Writing…", table: "App")
                                         : chat.startingAI && all.isEmpty ? T("Starting my AI…", table: "App") : T("Thinking…", table: "App"))
                            .foregroundStyle(IslandStyle.white(IslandStyle.primary))
                            .contentTransition(.opacity)
                        if let tail = now.tail {
                            Text(tail)
                                .font(.system(size: 12)).italic(!now.writing)
                                .foregroundStyle(IslandStyle.white(now.writing ? IslandStyle.secondary + 0.1 : IslandStyle.secondary))
                                .lineSpacing(2).lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .font(.system(size: 12))
        .animation(.easeOut(duration: 0.2), value: all.map(\.id))
        .animation(.easeOut(duration: 0.18), value: now.writing)
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

    /// The last answer of the conversation in view (or the latest one).
    private var lastAnswer: ChatMessage? {
        let conversation = chat.current ?? chat.conversations.max { $0.updated < $1.updated }
        return conversation?.messages.last(where: { $0.role == .assistant })
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

/// The working state's chain: nodes on a thin line, one row per step.
enum IslandChain {
    enum Node { case earlier, done, running, failed, thinking, writing }

    /// What she is doing right now and the last words of it (thinking, or the answer as it comes in).
    @MainActor
    static func now(message: ChatMessage?, writing: Bool) -> (writing: Bool, tail: String?) {
        let running = message?.steps.contains { !$0.done } ?? false
        if writing && !running { return (true, tail(message?.text, plain: true)) }
        return (false, running ? nil : tail(message?.thinking, plain: false))
    }

    /// The last ~150 characters on one flowing line, starting at a word: enough for three lines in the island.
    static func tail(_ text: String?, plain: Bool, limit: Int = 150) -> String? {
        guard var text = text else { return nil }
        if plain { text = text.replacingOccurrences(of: #"[*#`>|_]+"#, with: "", options: .regularExpression) }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        var cut = String(text.suffix(limit))
        if let space = cut.firstIndex(of: " ") { cut = String(cut[cut.index(after: space)...]) }
        return "…" + cut
    }
}

struct IslandChainRow<Label: View>: View {
    let node: IslandChain.Node
    let isFirst: Bool
    let isLast: Bool
    @ViewBuilder var label: Label

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            nodeView
                .frame(width: 14, height: 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .top) {
                    // The line through the nodes: from the row above into the one below.
                    VStack(spacing: 0) {
                        Rectangle().fill(isFirst ? .clear : IslandStyle.white(0.16)).frame(width: 1, height: 3)
                        Spacer(minLength: 0).frame(height: 10)
                        Rectangle().fill(isLast ? .clear : IslandStyle.white(0.16)).frame(width: 1)
                    }
                }
            label
                .frame(minHeight: 16, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 6)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var nodeView: some View {
        switch node {
        case .earlier:
            Circle().fill(IslandStyle.white(0.22)).frame(width: 4, height: 4)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                .foregroundStyle(IslandStyle.white(IslandStyle.secondary))
                .frame(width: 12, height: 12).background(Circle().fill(IslandStyle.white(0.1)))
        case .running:
            SpinRing(size: 11, lineWidth: 1.5, color: IslandStyle.accent)
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 8, weight: .bold)).foregroundStyle(IslandStyle.bad)
                .frame(width: 12, height: 12).background(Circle().fill(IslandStyle.bad.opacity(0.16)))
        case .thinking:
            PippaMark(size: 14, state: .arbeitet)
        case .writing:
            Scribble(size: 14)
        }
    }
}
