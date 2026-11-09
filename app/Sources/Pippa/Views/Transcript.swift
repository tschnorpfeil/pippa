import SwiftUI

/// The conversation: questions and answers in one reading column, Pi's open questions under the running answer, and
/// the composer floating at the bottom.
struct Transcript: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    var conversation: Conversation
    @ObservedObject private var approvals = Approvals.shared
    /// The end of the conversation is in view: new words keep it there. Scrolled up, they don't pull the person down.
    private let atBottomState = State(initialValue: true)
    /// The person is scrolling (wheel, trackpad, scroll bar); only then may "at the bottom" turn off. Content growing
    /// under a programmatic scroll never does.
    private let userScrollingState = State(initialValue: false)
    /// Messages before this one were on screen already; later ones arrive with a little motion.
    private let settledState = State(initialValue: Settled(id: "", count: 0))

    private struct Settled: Equatable {
        var id: String
        var count: Int
    }

    /// What may move the end of the conversation while an answer comes in: cheap to compare on every new word,
    /// unlike the whole message.
    private struct Progress: Equatable {
        var text = 0, thinking = 0, steps = 0, cards = 0, receipts = 0
        var failed = false
    }

    private var answeringHere: Bool { chat.isAnswering && chat.answeringID == conversation.id }

    private var progress: Progress {
        guard let last = conversation.messages.last else { return Progress() }
        return Progress(text: last.text.utf8.count, thinking: last.thinking?.utf8.count ?? 0, steps: last.steps.count,
                        cards: last.cards.count, receipts: last.receipts.count, failed: last.error != nil)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if setup.needsAttention { SetupCard(setup: setup).padding(.bottom, 28) }
                    let settled = settledState.wrappedValue
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                        let last = index == conversation.messages.count - 1
                        let arrives = settled.id == conversation.id && index >= settled.count
                        MessageView(chat: chat, message: message, live: answeringHere && last, isLast: last,
                                    answering: chat.isAnswering, started: answeringHere && last ? chat.answerStarted : nil,
                                    undoing: chat.undoing)
                            .equatable()
                            .arrives(arrives, delay: message.role == .assistant ? Theme.stagger : 0)
                            .padding(.top, index == 0 ? 0 : message.role == .assistant ? 12 : 28)
                            .id(message.id)
                    }
                    // Pi's questions wait right under the answer that asked; from another conversation they show here
                    // too, so a question is never hidden.
                    ForEach(Array(approvals.questions.enumerated()), id: \.element.id) { index, question in
                        QuestionCard(question: question, handlesKeys: index == 0)
                            .padding(.top, Space.l)
                            .arrives(true)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.top, Space.xxl).padding(.bottom, Space.l)
                .frame(maxWidth: Layout.column, alignment: .leading)
                .padding(.horizontal, Layout.gutter)
                .frame(maxWidth: .infinity)
            }
            // Open at the end of the conversation, not at its top and then a jump.
            .scrollIndicators(.hidden)
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
                // Opened mid-answer (or the first question just went out): the question and the answer still arrive.
                settledState.wrappedValue = Settled(id: conversation.id,
                                                    count: answeringHere ? max(0, conversation.messages.count - 2) : conversation.messages.count)
                // Pippa Island shows a new question without taking the keyboard from the app in front; only without
                // the island does the chat come forward for it.
                Approvals.shared.present("chat", reveal: { if !Island.shared.isShown { ChatWindow.shared.show() } })
                proxy.scrollTo("end", anchor: .bottom)
                // Once more after the first layout: lazy rows only know their real height then.
                Task { @MainActor in proxy.scrollTo("end", anchor: .bottom) }
            }
            .onDisappear { Approvals.shared.dismiss("chat") }
            .onChange(of: conversation.id) { _, id in
                settledState.wrappedValue = Settled(id: id, count: conversation.messages.count)
                atBottomState.wrappedValue = true
                proxy.scrollTo("end", anchor: .bottom)
            }
            .onChange(of: answeringHere) { _, answering in
                if !answering { settledState.wrappedValue = Settled(id: conversation.id, count: conversation.messages.count) }
            }
            // A new question or one from Pi: always to the end, also from further up.
            .onChange(of: conversation.messages.count + approvals.questions.count) { old, new in
                guard new > old else { return }
                atBottomState.wrappedValue = true
                withAnimation(Theme.arrive) { proxy.scrollTo("end", anchor: .bottom) }
            }
            // Words, steps and cards coming in: follow only while the end is in view.
            .onChange(of: progress) { _, _ in
                if atBottomState.wrappedValue { proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !atBottomState.wrappedValue {
                    JumpToLatest(answering: answeringHere) {
                        atBottomState.wrappedValue = true
                        withAnimation(Theme.arrive) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .padding(.bottom, Space.ml)
                    .transition(Theme.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                }
            }
            .animation(Theme.arrive, value: atBottomState.wrappedValue)
            .overlay(alignment: .top) { BarFade() }
            .softBottomEdge()
            .safeAreaInset(edge: .bottom, spacing: 0) { Composer(chat: chat, setup: setup).floatingBar() }
        }
    }
}

private extension View {
    /// The conversation scrolls on under the glass composer and softly fades out behind it; in snapshots the composer
    /// sits on the chat's own colour.
    @ViewBuilder func softBottomEdge() -> some View {
        if Theme.drawsGlass { scrollEdgeEffectStyle(.soft, for: .bottom) } else { self }
    }

    @ViewBuilder func floatingBar() -> some View {
        if Theme.drawsGlass { self } else { background(Color(nsColor: Theme.chatTint)) }
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

/// Scrolled up: a small round glass button back to the end; while an answer comes in it says so.
private struct JumpToLatest: View {
    var answering: Bool
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                if answering {
                    Text(T("New answer", table: "App")).font(Typo.footnote.weight(.medium))
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                Image(systemName: "arrow.down").font(Typo.footnote.weight(.semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, answering ? 14 : 0)
            .frame(minWidth: 32, minHeight: 32)
            .glass(16, interactive: true, lifted: hoverState.wrappedValue || answering)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .animation(Theme.arrive, value: answering)
        .help(T("Jump to the latest", table: "App"))
        .accessibilityLabel(answering ? T("New answer", table: "App") : T("Jump to the latest", table: "App"))
    }
}
