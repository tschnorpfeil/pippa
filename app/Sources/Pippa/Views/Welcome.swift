import AppKit
import PippaCore
import SwiftUI
import UniformTypeIdentifiers

/// Before the first question: Pippa's mark, one question, the composer and a few things to try. While the AI is not
/// set up yet and cannot answer, the setup card and immediate One PDF drop card replace the composer and suggestions
/// so first-run users never see a dead input box.
struct Welcome: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    @ObservedObject private var proactivity = ProactivityCoordinator.shared
    private let suggestions: [(symbol: String, text: String)] = [
        ("calendar", T("What’s on my calendar this week?", table: "App")),
        ("doc.text.magnifyingglass", T("Find my lease and tell me the notice period", table: "App")),
        ("envelope", T("Which mails still need an answer from me?", table: "App")),
        ("folder", T("What’s new in my Downloads folder?", table: "App")),
    ]

    /// First run with no AI ready yet: hide the dead composer and keep the One PDF file-drop path prominent instead.
    private var hidesComposer: Bool { setup.needsAttention && !setup.canAnswer }

    /// What Pippa prepared, shown under the composer only while calm notices are on and something waits.
    private var showsReady: Bool {
        proactivity.settings.enabled && !proactivity.openMatters.isEmpty && !setup.needsAttention
    }

    private var isDownloading: Bool {
        if case .downloading = setup.state { return true }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Space.x3) {
                    greeting
                    if setup.needsAttention {
                        SetupCard(setup: setup, showsPDFHint: !hidesComposer)
                            .frame(maxWidth: Layout.cardMax)
                            .padding(.horizontal, Layout.gutter)
                            .transition(.opacity)
                    }
                    if hidesComposer {
                        firstRunPDFCard
                            .frame(maxWidth: Layout.cardMax)
                            .padding(.horizontal, Layout.gutter)
                            .transition(.opacity)
                    } else {
                        Composer(chat: chat, setup: setup)
                    }
                    if showsReady {
                        ReadyStrip(matters: Array(proactivity.openMatters.prefix(2)), coordinator: proactivity)
                            .frame(maxWidth: Layout.cardMax)
                            .padding(.horizontal, Layout.gutter)
                            .transition(.opacity)
                    }
                    if !setup.needsAttention {
                        suggestionsGrid.transition(.opacity)
                    }
                }
                .animation(Theme.arrive, value: setup.needsAttention)
                .animation(Theme.arrive, value: hidesComposer)
                .animation(Theme.arrive, value: chat.attachments.isEmpty)
                .animation(Theme.arrive, value: showsReady)
                .padding(.vertical, Space.x4)
                .frame(maxWidth: .infinity)
                // Center the complete introduction when there is room; shorter windows scroll naturally.
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .scrollIndicators(.never)
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

    /// Immediate One PDF drop target shown while no AI is ready yet: lets users drop or pick photos/PDFs and build
    /// one PDF right away without an inactive text field below the setup card.
    private var firstRunPDFCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .center, spacing: Space.ml) {
                Image(systemName: "doc.richtext")
                    .font(Typo.body.weight(.semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 30, height: 30)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityHidden(true)
                Text(isDownloading
                     ? T("Meanwhile, drop photos or PDFs here to make one PDF.", table: "Views")
                     : T("Works right away, without any AI: drop photos or PDFs here to make one PDF.", table: "Views"))
                    .font(Typo.callout)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.s)
                ActionPill(title: T("Add Files…", table: "App")) { addFiles() }
                    .disabled(chat.isAnswering)
            }
            if !chat.attachments.isEmpty {
                HStack(spacing: Space.m) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.s) {
                            ForEach(chat.attachments, id: \.self) { url in
                                FirstRunFileChip(url: url) {
                                    withAnimation(Theme.leave) { chat.attachments.removeAll { $0 == url } }
                                }
                            }
                        }
                    }
                    if chat.canMakePDF && !chat.isAnswering {
                        ActionPill(title: T("One PDF", table: "App"), primary: true) { chat.makePDF() }
                            .help(T("Make one PDF from these files, right here on your Mac", table: "App"))
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !chat.attachments.contains(url) { chat.attachments.append(url) }
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

/// "Ready for you" under the composer: the newest prepared items with Open and Done, and the way to the rest.
private struct ReadyStrip: View {
    var matters: [ProactiveMatter]
    var coordinator: ProactivityCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Text(T("Ready for you", table: "Views")).font(Typo.callout.weight(.semibold)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.m)
                Button(T("See all in For You", table: "Views")) { coordinator.openDesk() }
                    .pippa(.quiet).font(Typo.footnote.weight(.medium))
            }
            .padding(.horizontal, Space.card).padding(.top, Space.l).padding(.bottom, Space.s)
            ForEach(matters) { matter in
                SettingsDivider()
                HStack(spacing: Space.ml) {
                    Image(systemName: RoutineUI.kindIcon(matter.kind))
                        .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.accent).frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(matter.title).font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        if !matter.summary.isEmpty {
                            Text(matter.summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? matter.summary)
                                .font(Typo.footnote).foregroundStyle(Theme.ink2).lineLimit(1)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: Space.m)
                    ActionPill(title: T("Open", table: "Views"), primary: true) {
                        coordinator.openInChat(matter, autoSend: false, surface: .panel)
                    }
                    ActionPill(title: T("Done", table: "Views")) { coordinator.markDone(matter, surface: .panel) }
                }
                .padding(.horizontal, Space.card).padding(.vertical, Space.ml)
                .accessibilityElement(children: .contain)
            }
        }
        .raised(Radius.card)
    }
}

/// A dropped or chosen file waiting to be combined into One PDF before an AI is set up.
private struct FirstRunFileChip: View {
    var url: URL
    var remove: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            NativeFilePreviewButton(url: url) {
                HStack(spacing: Space.s) {
                    NativeFileThumbnail(url: url, size: CGSize(width: 36, height: 36))
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            Button(action: remove) {
                Image(systemName: "xmark").font(Typo.caption.weight(.bold)).imageScale(.small).foregroundStyle(Theme.ink3)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("Remove", table: "App"))
            .accessibilityLabel(T("Remove", table: "App") + ": " + url.lastPathComponent)
        }
        .font(Typo.footnote).foregroundStyle(Theme.ink)
        .padding(.horizontal, Space.xs).padding(.vertical, Space.xs)
        .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
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
