import AppKit
import PippaCore
import SwiftUI
import UniformTypeIdentifiers

/// The one window: conversations on the left (`Sidebar`), the chat in the middle, "About this answer" on the right
/// (`ContextPanel`).
struct ChatView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    private let searchState = State(initialValue: "")
    @ObservedObject private var dropFeedback = DropFeedback.chat
    /// Keep the conversation spacious by default; remember an explicit choice to show the inspector.
    private let panelState = State(initialValue: UserDefaults.standard.object(forKey: "contextPanel") as? Bool ?? false)

    var body: some View {
        NavigationSplitView {
            Sidebar(chat: chat, search: searchState.projectedValue)
                .navigationSplitViewColumnWidth(min: 200, ideal: Layout.sidebarIdeal, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let conversation = chat.current, !conversation.messages.isEmpty {
                    Transcript(chat: chat, setup: setup, conversation: conversation)
                    Composer(chat: chat, setup: setup)
                } else {
                    Welcome(chat: chat, setup: setup)
                }
            }
            .background(Color(nsColor: Theme.chatTint))
            .overlay { if dropFeedback.targeted { DropOverlay() } }
            .navigationTitle(chat.current?.title ?? "Pippa")
            .navigationSubtitle(AIBadge.label(setup))
            .inspector(isPresented: panelState.projectedValue) {
                ContextPanel(chat: chat, setup: setup)
                    .inspectorColumnWidth(min: 240, ideal: Layout.inspector, max: 340)
            }
            .onChange(of: panelState.wrappedValue) { _, open in UserDefaults.standard.set(open, forKey: "contextPanel") }
            .toolbar {
                ToolbarItem {
                    Button { panelState.wrappedValue.toggle() } label: {
                        Label { Text(T("Context", table: "App")) } icon: {
                            Image(systemName: "sidebar.right")
                                .overlay(alignment: .topTrailing) {
                                    if contextCount > 0 && !panelState.wrappedValue {
                                        Text(verbatim: "\(min(contextCount, 99))")
                                            .font(.system(size: 8, weight: .bold)).monospacedDigit()
                                            .foregroundStyle(Theme.ink2)
                                            .padding(.horizontal, 3)
                                            .frame(minWidth: 12, minHeight: 12)
                                            .background(Theme.fill3, in: Capsule())
                                            .offset(x: 7, y: -6)
                                    }
                                }
                        }
                    }
                    .help(T("Show or hide what Pippa read and did", table: "App"))
                }
            }
        }
    }

    /// What the latest answer read and did: shown on the panel button while the panel is closed.
    private var contextCount: Int {
        guard let answer = chat.current?.messages.last(where: { $0.role == .assistant }) else { return 0 }
        return (answer.sources?.count ?? 0) + answer.receipts.count
    }
}

/// Snapshots only: every "Worked for …" row starts open, to check the steps and the thinking.
private struct ExpandsWorkKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var expandsWork: Bool {
        get { self[ExpandsWorkKey.self] }
        set { self[ExpandsWorkKey.self] = newValue }
    }
}

// MARK: Empty state

private struct Welcome: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    private let suggestions: [(symbol: String, text: String)] = [
        ("calendar", T("What’s on my calendar this week?", table: "App")),
        ("doc.text.magnifyingglass", T("Find my lease and tell me the notice period", table: "App")),
        ("envelope", T("Which mails still need an answer from me?", table: "App")),
        ("folder", T("What’s new in my Downloads folder?", table: "App")),
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Space.x3) {
                    greeting
                    if setup.needsAttention {
                        SetupCard(setup: setup)
                            .frame(maxWidth: 480)
                            .padding(.horizontal, Layout.gutter)
                    }
                    Composer(chat: chat, setup: setup)
                    if !setup.needsAttention {
                        suggestionsGrid
                    }
                }
                .padding(.vertical, Space.x4)
                .frame(maxWidth: .infinity)
                // Center the complete introduction when there is room; shorter windows scroll naturally.
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
        }
    }

    private var greeting: some View {
        VStack(spacing: Space.xl) {
            PippaMark(size: 48, state: .ruht)
            VStack(spacing: Space.s) {
                Text(T("What can I do for you?", table: "App"))
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(T("Ask, or drop files here. I work on your Mac with Mail, Calendar, Reminders, Photos and your files.", table: "App"))
                    .font(.system(size: 13.5)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, Space.x4)
    }

    private var suggestionsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Space.ml)], spacing: Space.ml) {
            ForEach(suggestions, id: \.text) { suggestion in
                SuggestionButton(symbol: suggestion.symbol, text: suggestion.text) {
                    chat.draft = suggestion.text
                    if setup.canAnswer && !chat.isAnswering { chat.send() }
                }
            }
        }
        .frame(maxWidth: Layout.cardMax)
        .padding(.horizontal, Layout.gutter)
    }

}

private struct SuggestionButton: View {
    var symbol: String
    var text: String
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.ml) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 18)
                    .padding(.top, 1)
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background {
                if hoverState.wrappedValue {
                    Color.clear.raised(Radius.card, lifted: true)
                } else {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Theme.fill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
    }
}

// MARK: Transcript

private struct Transcript: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    var conversation: Conversation
    /// The end of the conversation is in view: new words keep it there. Scrolled up, they don't pull the person down.
    private let atBottomState = State(initialValue: true)
    /// The person is scrolling (wheel, trackpad, scroll bar); only then may "at the bottom" turn off. Content growing
    /// under a programmatic scroll never does.
    private let userScrollingState = State(initialValue: false)

    private var answeringHere: Bool { chat.isAnswering && chat.answeringID == conversation.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if setup.needsAttention { SetupCard(setup: setup).padding(.bottom, 28) }
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                        let last = message.id == conversation.messages.last?.id
                        MessageView(chat: chat, message: message, live: answeringHere && last, isLast: last)
                            .padding(.top, index == 0 ? 0 : message.role == .assistant ? 12 : 28)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.top, Space.xxl).padding(.bottom, Space.l)
                .frame(maxWidth: Layout.column, alignment: .leading)
                .padding(.horizontal, Layout.gutter)
                .frame(maxWidth: .infinity)
            }
            // Open at the end of the conversation, not at its top and then a jump.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollPhaseChange { _, phase in
                userScrollingState.wrappedValue = phase == .interacting || phase == .tracking || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 48
            } action: { _, atBottom in
                if atBottom { atBottomState.wrappedValue = true }
                else if userScrollingState.wrappedValue { atBottomState.wrappedValue = false }
            }
            .onAppear {
                proxy.scrollTo("end", anchor: .bottom)
                // Once more after the first layout: lazy rows only know their real height then.
                Task { @MainActor in proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: conversation.id) { _, _ in
                atBottomState.wrappedValue = true
                proxy.scrollTo("end", anchor: .bottom)
            }
            // A new question: always to the end, also from further up.
            .onChange(of: conversation.messages.count) { old, new in
                guard new > old else { return }
                atBottomState.wrappedValue = true
                withAnimation(Theme.arrive) { proxy.scrollTo("end", anchor: .bottom) }
            }
            // Words, steps and cards coming in: follow only while the end is in view.
            .onChange(of: conversation.messages.last) { _, _ in
                if atBottomState.wrappedValue { proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !atBottomState.wrappedValue {
                    JumpToLatest(answering: answeringHere) {
                        atBottomState.wrappedValue = true
                        withAnimation(Theme.arrive) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .padding(.bottom, Space.ml)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                }
            }
            .animation(Theme.arrive, value: atBottomState.wrappedValue)
            .overlay(alignment: .top) { BarFade() }
        }
    }
}

/// The window's bar is transparent (one calm surface): words scrolled up would run into the title. They fade out under
/// it into the chat's own colour instead.
private struct BarFade: View {
    var body: some View {
        GeometryReader { geometry in
            let bar = geometry.safeAreaInsets.top, solid = bar + Space.s, fade = Space.xxl
            let tint = Color(nsColor: Theme.chatTint)
            LinearGradient(stops: [.init(color: tint, location: 0), .init(color: tint, location: solid / max(1, solid + fade)),
                                   .init(color: tint.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(width: geometry.size.width, height: solid + fade)
                .offset(y: -bar)
        }
        .frame(height: Space.s + Space.xxl)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Scrolled up: a small round button back to the end; while an answer comes in it says so.
private struct JumpToLatest: View {
    var answering: Bool
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if answering {
                    Text(T("New answer", table: "App")).font(.system(size: 12.5, weight: .medium))
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, answering ? 14 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .raised(16, lifted: hoverState.wrappedValue || answering)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .animation(Theme.arrive, value: answering)
        .help(T("Jump to the latest", table: "App"))
        .accessibilityLabel(answering ? T("New answer", table: "App") : T("Jump to the latest", table: "App"))
    }
}

private struct MessageView: View {
    @ObservedObject var chat: ChatModel
    var message: ChatMessage
    /// The answer that is coming in right now.
    var live: Bool
    var isLast: Bool
    private let hoverState = State(initialValue: false)

    private var hover: Bool { hoverState.wrappedValue }

    var body: some View {
        Group {
            switch message.role {
            case .user: user
            case .assistant: assistant
            }
        }
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
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
                        .disabled(chat.isAnswering)
                }
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
                if !message.text.isEmpty {
                    FractionalWidth(fraction: 0.78) {
                        Text(message.text)
                            .font(.system(size: 14)).foregroundStyle(Theme.ink).lineSpacing(4)
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
        VStack(alignment: .leading, spacing: Space.l) {
            if live || !message.steps.isEmpty || !(message.thinking ?? "").isEmpty || message.stopped == true {
                WorkView(message: message, live: live, started: chat.answerStarted)
            }
            if !message.text.isEmpty {
                MarkdownText(text: message.text, highlights: live ? [] : message.unsupportedDates ?? [])
            }
            if !live, let dates = message.unsupportedDates, !dates.isEmpty { DateNote(dates: dates) }
            if !message.cards.isEmpty { ResultCardsView(cards: message.cards) }
            if !message.receipts.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(Array(message.receipts.enumerated()), id: \.offset) { _, receipt in ReceiptRow(receipt: receipt) }
                }
            }
            if let error = message.error {
                ErrorBox(text: error, retry: isLast && !chat.isAnswering ? { chat.retry() } : nil)
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
                            .disabled(chat.isAnswering)
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

/// What Pippa did on the way to the answer, as one row. While she works: her mark, what she is doing right now and the
/// seconds. Afterwards: "Worked for 18 s · 3 steps". A click opens the steps and her thinking.
private struct WorkView: View {
    var message: ChatMessage
    var live: Bool
    var started: Date?
    @Environment(\.expandsWork) private var expandsWork
    private let openState = State(initialValue: false)
    private let hoverState = State(initialValue: false)

    private var open: Bool { openState.wrappedValue }
    private var thinking: String? {
        guard let text = message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    private var canOpen: Bool { !message.steps.isEmpty || thinking != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Button { withAnimation(Theme.arrive) { openState.wrappedValue.toggle() } } label: { header }
                .buttonStyle(.plain)
                .disabled(!canOpen)
                .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering && canOpen } }
                .onAppear { if expandsWork && canOpen { openState.wrappedValue = true } }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(message.steps) { step in stepRow(step) }
                    if let thinking {
                        Text(thinking)
                            .font(.system(size: 12.5)).foregroundStyle(Theme.ink3).lineSpacing(3)
                            .textSelection(.enabled)
                            .lineLimit(live ? 6 : nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Space.ml)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.fill3).frame(width: 2) }
                            .padding(.top, message.steps.isEmpty ? Space.xs : Space.s).padding(.bottom, Space.xs)
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 7) {
            if live {
                PippaMark(size: 16, state: .arbeitet).frame(width: 16, height: 16)
                Text(nowLabel).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                    .contentTransition(.opacity)
                if let started {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(started))
                        if seconds >= 1 { Text(T("%lld s", table: "App", seconds)).monospacedDigit().foregroundStyle(Theme.ink3) }
                    }
                }
            } else {
                Text(summary).foregroundStyle(hoverState.wrappedValue ? Theme.ink2 : Theme.ink3).lineLimit(1)
                if message.steps.contains(where: \.failed) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.need)
                }
            }
            if canOpen {
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.ink3)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, Space.m)
        .frame(height: 28)
        .background(hoverState.wrappedValue ? Theme.rowHover : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .padding(.leading, -Space.m)
    }

    private func stepRow(_ step: ChatStep) -> some View {
        HStack(spacing: Space.m) {
            Group {
                if !step.done && live { SpinRing(size: 11, lineWidth: 1.5) }
                else if step.failed { Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.need) }
                else { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.ink3) }
            }
            .frame(width: 14, height: 14)
            Text(step.label).lineLimit(1).truncationMode(.middle).foregroundStyle(step.done || !live ? Theme.ink3 : Theme.ink2)
        }
        .font(.system(size: 12.5))
        .frame(height: 24)
    }

    /// What she is doing right now: the running step, else thinking or writing.
    private var nowLabel: String {
        if let step = message.steps.last(where: { !$0.done }) { return step.label }
        return message.text.isEmpty ? T("Thinking…", table: "App") : T("Writing…", table: "App")
    }

    private var summary: String {
        if message.stopped == true { return T("Stopped", table: "App") }
        let count = message.steps.count
        guard let duration = message.duration else {
            if count == 0 { return T("Thought it through", table: "App") }
            return count == 1 ? T("1 step", table: "App") : T("%lld steps", table: "App", count)
        }
        let time = Self.time(duration)
        switch count {
        case 0: return T("Thought for %@", table: "App", time)
        case 1: return T("Worked for %@ · 1 step", table: "App", time)
        default: return T("Worked for %@ · %lld steps", table: "App", time, count)
        }
    }

    /// "18 s", "2 min 5 s".
    static func time(_ duration: TimeInterval) -> String {
        let seconds = max(1, Int(duration.rounded()))
        if seconds < 60 { return T("%lld s", table: "App", seconds) }
        return T("%lld min %lld s", table: "App", seconds / 60, seconds % 60)
    }
}

private struct ErrorBox: View {
    var text: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.ml) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: Space.m)
            if let retry { ActionPill(title: T("Try Again", table: "App"), action: retry) }
        }
        .padding(Space.l)
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .background(Theme.badTint, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// A quiet text button under a message: no frame, a soft fill on hover.
private struct GhostButton: View {
    var title: String
    var symbol: String
    /// Only the symbol (the title goes to the tooltip).
    var compact = false
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                if !compact { Text(title) }
            }
            .font(.system(size: 12))
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

private struct CopyButton: View {
    var text: String
    var compact = false
    private let copiedState = State(initialValue: false)

    var body: some View {
        GhostButton(title: copiedState.wrappedValue ? T("Copied", table: "App") : T("Copy", table: "App"),
                    symbol: copiedState.wrappedValue ? "checkmark" : "doc.on.doc", compact: compact) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedState.wrappedValue = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copiedState.wrappedValue = false }
        }
    }
}

/// What the answer read, as chips; a click opens the file or the page.
struct SourceChips: View {
    var sources: [ChatSource]
    private let shown = 3

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(sources.prefix(shown), id: \.self) { source in SourceChip(source: source) }
            if sources.count > shown {
                Text(verbatim: "+\(sources.count - shown)").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
            }
        }
    }

    /// Long names shortened in the middle, so a chip keeps its own width.
    static func short(_ name: String, limit: Int = 30) -> String {
        guard name.count > limit else { return name }
        return name.prefix(limit / 2 - 1) + "…" + name.suffix(limit / 2 - 1)
    }

    static func symbol(_ kind: ChatSource.Kind) -> String {
        switch kind {
        case .file: "doc.text"
        case .mail: "envelope"
        case .web: "globe"
        }
    }

    static func open(_ source: ChatSource) {
        switch source.kind {
        case .file: NSWorkspace.shared.open(URL(fileURLWithPath: source.location))
        case .web: if let url = URL(string: source.location), ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
        case .mail: break
        }
    }
}

private struct SourceChip: View {
    var source: ChatSource
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button { SourceChips.open(source) } label: {
            HStack(spacing: 5) {
                Image(systemName: SourceChips.symbol(source.kind)).font(.system(size: 10.5))
                Text(SourceChips.short(source.name)).lineLimit(1)
            }
            .fixedSize()
            .font(.system(size: 11.5)).foregroundStyle(hoverState.wrappedValue ? Theme.ink : Theme.ink2)
            .padding(.horizontal, Space.m).frame(height: 24)
            .background(hoverState.wrappedValue ? Theme.rowHover : .clear, in: Capsule())
            .overlay(Capsule(style: .circular).inset(by: 0.5).stroke(Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(source.location.isEmpty)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering && !source.location.isEmpty } }
        .help(source.detail.map { "\(source.name) · \($0)" } ?? source.name)
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
        .font(.system(size: 12.5))
        .padding(.horizontal, Space.ml).padding(.vertical, Space.s)
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .background(Theme.needTint.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// What a writing tool did: added to Calendar, a reminder, a Mail draft. Done ones open the app.
struct ReceiptRow: View {
    var receipt: PippaMCPWriteReceipt
    private var done: Bool { receipt.outcome == "done" }

    var body: some View {
        HStack(spacing: Space.ml) {
            Image(systemName: Self.symbol(receipt))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(done ? Theme.ok : Theme.need)
                .frame(width: 28, height: 28)
                .background(done ? Theme.okTint : Theme.needTint, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(receipt)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                if !receipt.name.isEmpty {
                    Text(receipt.name).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(2)
                }
            }
            Spacer(minLength: Space.m)
            if let open = Self.openAction(receipt), let label = Self.openLabel(receipt) {
                ActionPill(title: label, action: open)
            }
        }
        .padding(Space.ml)
        .frame(maxWidth: Layout.cardMax, alignment: .leading)
        .raised(Radius.card)
    }

    static func symbol(_ receipt: PippaMCPWriteReceipt) -> String {
        switch receipt.action {
        case "calendarAdd": return "calendar.badge.plus"
        case "reminderAdd": return "checklist"
        case "mailDraft": return "envelope"
        default: return "checkmark"
        }
    }

    static func title(_ receipt: PippaMCPWriteReceipt) -> String {
        let done = receipt.outcome == "done"
        switch receipt.action {
        case "calendarAdd": return done ? T("Added to Calendar", table: "App") : T("Not added to Calendar", table: "App")
        case "reminderAdd": return done ? T("Reminder added", table: "App") : T("No reminder added", table: "App")
        case "mailDraft": return done ? T("Draft in Mail, not sent", table: "App") : T("No Mail draft", table: "App")
        default: return receipt.name
        }
    }

    private static func openLabel(_ receipt: PippaMCPWriteReceipt) -> String? {
        switch receipt.action {
        case "calendarAdd": return T("Open Calendar", table: "App")
        case "reminderAdd": return T("Open Reminders", table: "App")
        case "mailDraft": return T("Open Mail", table: "App")
        default: return nil
        }
    }

    /// Brings the app with what was added to the front; `nil` when nothing was added.
    static func openAction(_ receipt: PippaMCPWriteReceipt) -> (() -> Void)? {
        guard receipt.outcome == "done" else { return nil }
        switch receipt.action {
        case "mailDraft": return { Task { await PippaMCPService.showMail() } }
        case "calendarAdd": return { bringForward(.calendar) }
        case "reminderAdd": return { bringForward(.reminders) }
        default: return nil
        }
    }

    /// With PIPPA_DEMO=1 nothing (no real apps).
    private static func bringForward(_ integration: Integration) {
        guard ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1",
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: integration.bundleIdentifier) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: config)
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
            .font(.system(size: 12.5)).foregroundStyle(Theme.ink)
            .padding(.horizontal, Space.ml).frame(height: 30)
            .raised(Radius.control, lifted: hoverState.wrappedValue)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .help(url.path)
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.accentTint)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
            .overlay {
                VStack(spacing: Space.m) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 32, weight: .medium))
                    Text(T("Drop files for Pippa", table: "App")).font(.title3.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            }
            .padding(Space.l)
            .allowsHitTesting(false)
    }
}
