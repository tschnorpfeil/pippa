import PiRPC
import PippaCore
import SwiftUI

extension IslandStyle {
    static func white(_ opacity: Double) -> Color { Color.white.opacity(opacity) }
    static let accent = Color(red: 0x80 / 255, green: 0xB8 / 255, blue: 0xFF / 255)
    static let ok = Color(red: 0x45 / 255, green: 0xD9 / 255, blue: 0x7F / 255)
    static let bad = Color(red: 0xF8 / 255, green: 0x9D / 255, blue: 0xA4 / 255)
    /// The one primary button's fill, `Theme.accentFill` in dark mode: white text on it reads at 4.5:1.
    static let accentFill = Color(red: 0x1F / 255, green: 0x6F / 255, blue: 0xE0 / 255)

    // Type: SF Pro Rounded in four sizes (the wing's line is `IslandStatus.font`, 12 semibold).
    static let title = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 13, design: .rounded)
    /// A question's quoted detail, and the buttons.
    static let detail = Font.system(size: 13, weight: .medium, design: .rounded)
    static let small = Font.system(size: 12, design: .rounded)
    static let caption = Font.system(size: 11, design: .rounded)

    // Motion: critically damped like the island's own springs (`IslandSpring`), so nothing overshoots.
    static let arrive = Animation.spring(response: 0.32, dampingFraction: 1)
    static let fade = Animation.easeOut(duration: 0.2)

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
                    .frame(width: 12).transition(.opacity)
            }
        }
        // A new label crossfades while the wing's width follows its spring (IslandPresenter).
        .animation(IslandStyle.fade, value: status.label)
        .animation(IslandStyle.fade, value: status.symbol)
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

/// While the open panel's height springs to fit new content (`IslandPresenter`), how far its lower edge still is from
/// where the content ends: negative while it grows, positive while it shrinks, 0 at rest. Set on every frame.
@MainActor
final class IslandEdge: ObservableObject {
    @Published var lag: CGFloat = 0
}

/// The panel's last rows ride on its moving lower edge (`rides`), and what is above them is cut off where they begin
/// (`above`), so the two never overlap. Only this small view follows the edge on every frame, not what it wraps.
struct IslandEdgeFollow<Content: View>: View {
    enum Role { case above, rides }
    @ObservedObject var edge: IslandEdge
    let role: Role
    @ViewBuilder var content: Content

    var body: some View {
        switch role {
        case .rides: content.offset(y: edge.lag)
        case .above: content.mask(alignment: .top) { Rectangle().padding(.bottom, max(0, -edge.lag)) }
        }
    }
}

/// The open island: what Pippa is doing or said last, a question if she has one, and a field for a quick question.
struct IslandPanelView: View {
    @ObservedObject var island: Island
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    @ObservedObject var approvals: Approvals
    var edge: IslandEdge
    var onHeight: (CGFloat) -> Void = { _ in }
    /// At the notch: the menu bar row beside the housing, where the header stays. Nil under the menu bar symbol.
    var menuBarRow: MenuBarRow?
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var drop = DropFeedback.island
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct MenuBarRow: Equatable {
        var height: CGFloat
        /// From the housing's left edge to the panel's right edge: the part of the row the header must leave free.
        var besideHousing: CGFloat
    }

    /// What the panel shows above its field: one at a time, crossfading.
    private enum Phase: Hashable { case question(String), working, download, setup, failed, answer, empty }

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
            ZStack(alignment: .topLeading) {
                if island.dropMode { dropTray.transition(.opacity) } else { content.transition(.opacity) }
            }
            .animation(IslandStyle.fade, value: island.dropMode)
            .padding(.horizontal, IslandStyle.padding)
            .padding(.top, menuBarRow == nil ? IslandStyle.padding : IslandStyle.notchTop)
            .padding(.bottom, IslandStyle.padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .fontDesign(.rounded)
        .environment(\.colorScheme, .dark)
        .onAppear { if island.wantsFocus { focusField() } }
        .onChange(of: island.focusToken) { focusField() }
        // The field stays usable while she answers, so it keeps the keyboard after Return; this brings it back if
        // something else took it.
        .onChange(of: chat.isAnswering) { _, answering in if !answering && island.isOpen { focusField() } }
        // The field comes back once a question is answered, with the keyboard if it was asked for.
        .onChange(of: approvals.questions.isEmpty) { _, empty in if empty && island.isOpen && island.wantsFocus { focusField() } }
    }

    /// While a question waits the field is hidden, and nothing asks for the keyboard there.
    private func focusField() {
        if approvals.questions.isEmpty { fieldFocused = true }
    }

    /// While files are dragged toward the island: one large target that lights up when they are over it.
    private var dropTray: some View {
        let over = drop.targeted
        let shape = RoundedRectangle(cornerRadius: IslandStyle.wellRadius, style: .continuous)
        return VStack(spacing: IslandStyle.buttonGap) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(over ? IslandStyle.accent : IslandStyle.white(IslandStyle.secondary))
            Text(T("Drop here for Pippa", table: "Island"))
                .font(IslandStyle.title).foregroundStyle(IslandStyle.white(IslandStyle.primary))
            Text(T("Then just ask what to do with it.", table: "Island"))
                .font(IslandStyle.small).foregroundStyle(IslandStyle.white(IslandStyle.secondary))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, IslandStyle.padding)
        .background(shape.fill(over ? IslandStyle.accent.opacity(0.14) : IslandStyle.white(0.06)))
        .overlay(shape.strokeBorder(IslandStyle.accent.opacity(over ? 1 : 0), lineWidth: 1))
        .animation(IslandStyle.fade, value: over)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: IslandStyle.gap) {
            if menuBarRow == nil { header(markSize: 22) }
            IslandEdgeFollow(edge: edge, role: .above) {
                ZStack(alignment: .topLeading) {
                    main.transition(.opacity)
                }
                .animation(IslandStyle.fade, value: phase)
            }
            IslandEdgeFollow(edge: edge, role: .rides) { below }
        }
    }

    private var phase: Phase {
        if let question = approvals.questions.first { return .question(question.id) }
        if chat.isAnswering { return .working }
        if setupProgress != nil { return .download }
        if setupNeedsYou { return .setup }
        if let error = lastAnswer?.error, !error.isEmpty { return .failed }
        if let text = lastAnswer?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .answer }
        return .empty
    }

    @ViewBuilder private var main: some View {
        switch phase {
        case .question:
            if let question = approvals.questions.first { IslandQuestionText(request: question.request).id(question.id) }
        case .working:
            steps
        case .download:
            download(setupProgress ?? 0)
        case .setup:
            setupAction
        case .failed:
            Text(lastAnswer?.error ?? "")
                .font(IslandStyle.body).foregroundStyle(IslandStyle.white(IslandStyle.primary - 0.1))
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .answer:
            // The answer as in the chat (bold, lists, headings, tables), scrolling inside the island when it is long.
            ScrollView {
                MarkdownText(text: lastAnswer?.text ?? "", style: .island)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Room under the last line: the fade below only ever covers text that scrolls on.
                    .padding(.bottom, IslandStyle.gap)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, -6)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: IslandStyle.gap)
                }
            }
        case .empty:
            Text(T("Ask me anything, or drop a file here.", table: "Island"))
                .font(IslandStyle.body).foregroundStyle(IslandStyle.white(IslandStyle.secondary))
        }
    }

    /// Under what she says: the answers to a question, or any dropped files and the field beside "Open Pippa".
    @ViewBuilder private var below: some View {
        if let question = approvals.questions.first {
            IslandQuestionAnswers(question: question, onOpen: island.openChat).id(question.id)
        } else {
            VStack(alignment: .leading, spacing: IslandStyle.gap) {
                if !chat.attachments.isEmpty { files }
                HStack(spacing: IslandStyle.buttonGap) {
                    field
                    IslandOpenButton(hint: true, action: island.openChat)
                }
            }
        }
    }

    private func header(markSize: CGFloat) -> some View {
        HStack(spacing: markSize < 20 ? IslandStyle.wingGap : 10) {
            IslandMark(status: island.status, size: markSize)
            // In the menu bar row just her name and the sign: the panel below says what she does or asks.
            Text(island.status.tone == .rest || markSize < 20 ? "Pippa" : island.status.label)
                .font(IslandStyle.title).monospacedDigit()
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
        // A new step fades in and rises into place; the ones before it move up instead of jumping.
        let arrival = AnyTransition.asymmetric(insertion: .opacity.combined(with: .offset(y: IslandStyle.rise)), removal: .opacity)
        return VStack(alignment: .leading, spacing: 0) {
            if all.count > shown.count {
                IslandChainRow(node: .earlier, isFirst: true, isLast: false) {
                    Text(T("%lld earlier steps", table: "Island", all.count - shown.count))
                        .font(IslandStyle.caption).monospacedDigit()
                        .foregroundStyle(IslandStyle.white(IslandStyle.secondary))
                }
                .transition(.opacity)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, step in
                IslandChainRow(node: step.failed ? .failed : step.done ? .done : .running,
                               isFirst: index == 0 && all.count == shown.count, isLast: running && index == shown.count - 1) {
                    Text(step.label).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(IslandStyle.white(step.done ? IslandStyle.secondary : IslandStyle.primary))
                }
                .transition(arrival)
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
                                .italic(!now.writing)
                                .foregroundStyle(IslandStyle.white(now.writing ? IslandStyle.secondary + 0.1 : IslandStyle.secondary))
                                .lineSpacing(2).lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .transition(arrival)
            }
        }
        .font(IslandStyle.small)
        // Reduce Motion: the chain changes at once.
        .animation(reduceMotion ? nil : IslandStyle.arrive, value: all.map(\.id))
        .animation(reduceMotion ? nil : IslandStyle.arrive, value: running)
        .animation(IslandStyle.fade, value: now.writing)
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
                .font(IslandStyle.small).monospacedDigit().foregroundStyle(IslandStyle.white(IslandStyle.secondary))
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
                .font(IslandStyle.small)
            }
        }
    }

    /// The quick question; it grows, "Open Pippa" beside it keeps its size.
    private var field: some View {
        let prompt = chat.isAnswering ? T("Pippa is answering…", table: "Island") : T("Ask Pippa…", table: "App")
        return TextField(prompt, text: $chat.draft, prompt: Text(prompt).foregroundStyle(IslandStyle.white(IslandStyle.secondary)))
            .textFieldStyle(.plain)
            .font(IslandStyle.body)
            .foregroundStyle(IslandStyle.white(IslandStyle.primary))
            .focused($fieldFocused)
            .onSubmit { island.send() }
            .islandWell()
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
        VStack(alignment: .leading, spacing: IslandStyle.buttonGap) {
            Text(parts.title).font(IslandStyle.title).foregroundStyle(IslandStyle.white(IslandStyle.primary))
                .fixedSize(horizontal: false, vertical: true)
            if !parts.message.isEmpty {
                Text(parts.message).font(IslandStyle.small).foregroundStyle(IslandStyle.white(IslandStyle.secondary))
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
            }
            if !parts.detail.isEmpty {
                // In full, as on the chat's card: the command or address the person allows (bounded by its sender).
                Text(parts.detail).font(IslandStyle.detail).foregroundStyle(IslandStyle.white(IslandStyle.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The answers to a question: Allow / Don't Allow, a choice, or a text. Nothing is pre-selected and Return never
/// allows; Escape declines (IslandPresenter). "Open Pippa" sits at the left of Allow's row when it fits there, on its
/// own row otherwise and always under a choice or a text.
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
                button(T("Don’t Allow", table: "App"), .confirmed(false))
                button(T("Allow", table: "App"), .confirmed(true), prominent: true)
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
        // Up to three choices are buttons; a choice wider than one row of the panel goes into the menu.
        case "select" where !request.options.isEmpty && request.options.count <= 3 && request.options.allSatisfy(Self.fitsRow):
            IslandButtonRow {
                button(T("Cancel", table: "App"), .cancelled)
                ForEach(request.options, id: \.self) { option in button(option, .value(option)) }
            }
        case "select":
            HStack(spacing: IslandStyle.buttonGap) {
                Menu(T("Choose…", table: "Island")) {
                    ForEach(request.options, id: \.self) { option in
                        Button(option) { Approvals.shared.answer(question.id, .value(option)) }
                    }
                }
                .menuStyle(.borderlessButton).font(IslandStyle.detail).fixedSize()
                Spacer(minLength: 0)
                button(T("Cancel", table: "App"), .cancelled)
            }
        default:
            VStack(alignment: .leading, spacing: IslandStyle.buttonGap) {
                TextField(request.placeholder ?? "", text: textState.projectedValue,
                          prompt: Text(request.placeholder ?? "").foregroundStyle(IslandStyle.white(IslandStyle.secondary)))
                    .textFieldStyle(.plain).font(IslandStyle.body)
                    .foregroundStyle(IslandStyle.white(IslandStyle.primary))
                    .onSubmit { Approvals.shared.answer(question.id, .value(textState.wrappedValue)) }
                    .islandWell()
                IslandButtonRow {
                    button(T("Cancel", table: "App"), .cancelled)
                    button(T("OK", table: "App"), .value(textState.wrappedValue), prominent: true)
                }
            }
        }
    }

    /// A button with this title fits one row of the panel: its text in the buttons' size (a touch heavier, so the
    /// measure errs wide) plus the capsule's padding.
    private static func fitsRow(_ title: String) -> Bool {
        let rounded = NSFont.systemFont(ofSize: 13, weight: .semibold).fontDescriptor.withDesign(.rounded)
        let font = rounded.flatMap { NSFont(descriptor: $0, size: 13) } ?? .systemFont(ofSize: 13, weight: .semibold)
        let text = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return text + 2 * IslandStyle.gap <= IslandGeometry.openWidth - 2 * IslandStyle.padding
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

/// Capsule buttons that read on black: quiet, or the one primary action in Pippa's blue with white text.
struct IslandButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IslandStyle.detail)
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : IslandStyle.white(IslandStyle.primary))
            .padding(.horizontal, IslandStyle.gap)
            .frame(height: IslandStyle.controlHeight)
            .background(Capsule().fill(prominent ? IslandStyle.accentFill.opacity(configuration.isPressed ? 0.8 : 1)
                                                 : IslandStyle.white(configuration.isPressed ? 0.24 : 0.14)))
            .contentShape(Capsule())
            .fixedSize()
    }
}

extension View {
    /// A text field's quiet well on the island, as tall as the buttons beside it.
    func islandWell() -> some View {
        padding(.horizontal, 10)
            .frame(height: IslandStyle.controlHeight)
            .background(RoundedRectangle(cornerRadius: IslandStyle.wellRadius, style: .continuous).fill(IslandStyle.white(0.1)))
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
