import SwiftUI

/// Before the first question: Pippa's mark, one question, the composer and a few things to try. While the AI is not
/// set up yet, the setup card takes the place of the suggestions, right above the composer.
struct Welcome: View {
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
                            .frame(maxWidth: Layout.cardMax)
                            .padding(.horizontal, Layout.gutter)
                            .transition(.opacity)
                    }
                    Composer(chat: chat, setup: setup)
                    if !setup.needsAttention {
                        suggestionsGrid.transition(.opacity)
                    }
                }
                .animation(Theme.arrive, value: setup.needsAttention)
                .padding(.vertical, Space.x4)
                .frame(maxWidth: .infinity)
                // Center the complete introduction when there is room; shorter windows scroll naturally.
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var greeting: some View {
        VStack(spacing: Space.xl) {
            PippaMark(size: 64, state: .ruht)
                .arrives(true)
            VStack(spacing: Space.s) {
                Text(T("What can I do for you?", table: "App"))
                    .font(Typo.title).foregroundStyle(Theme.ink)
                Text(T("Ask, or drop files here. I work on your Mac with Mail, Calendar, Reminders, Photos and your files.", table: "App"))
                    .font(Typo.callout).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, Space.x4)
    }

    private var suggestionsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Space.ml)], spacing: Space.ml) {
            ForEach(Array(suggestions.enumerated()), id: \.element.text) { index, suggestion in
                SuggestionButton(symbol: suggestion.symbol, text: suggestion.text) {
                    chat.draft = suggestion.text
                    if setup.canAnswer && !chat.isAnswering { chat.send() }
                }
                .arrives(true, delay: Double(index + 1) * Theme.stagger)
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
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.ml) {
                Image(systemName: symbol).font(Typo.callout.weight(.medium)).foregroundStyle(Theme.accent).frame(width: 18)
                    .padding(.top, 1)
                Text(text).font(Typo.callout).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background {
                if hoverState.wrappedValue {
                    Color.clear.raised(Radius.card, lifted: true)
                } else {
                    shape.fill(Theme.fill)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
    }
}
