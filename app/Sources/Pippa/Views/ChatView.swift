import AppKit
import PippaCore
import SwiftUI

/// The one window: conversations on the left (`Sidebar`), the chat in the middle (`Transcript`, or `Welcome` before
/// the first question), "About this answer" on the right (`ContextPanel`).
struct ChatView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    private let searchState = State(initialValue: "")
    @ObservedObject private var dropFeedback = DropFeedback.chat
    /// Pippa's browser panel, a drawer on the right while open (closed by default and in snapshots).
    @ObservedObject private var browser = WKBrowserSession.shared
    /// Keep the conversation spacious by default; remember an explicit choice to show the inspector.
    private let panelState: State<Bool>
    @ObservedObject private var proactivity = ProactivityCoordinator.shared
    /// "For You" instead of the conversation in the middle.
    private let forYouState: State<Bool>
    /// Stable presenter for the routine editor sheet so `@Environment(\.openRoutineEditor)` stays `Equatable`
    /// across streaming tokens and never invalidates `MessageView.equatable()`.
    @StateObject private var editorPresenter = RoutineEditorPresenter()

    /// `inspector`: snapshots show or hide "About this answer" whatever the saved choice is. `showingForYou`: snapshots
    /// start on "For You".
    init(chat: ChatModel, setup: SetupModel, inspector: Bool? = nil, showingForYou: Bool = false) {
        self.chat = chat
        self.setup = setup
        panelState = State(initialValue: inspector ?? UserDefaults.standard.object(forKey: "contextPanel") as? Bool ?? false)
        forYouState = State(initialValue: showingForYou)
    }

    private var showingForYou: Bool { forYouState.wrappedValue }

    var body: some View {
        NavigationSplitView {
            Sidebar(chat: chat, search: searchState.projectedValue, showingForYou: forYouState.projectedValue)
                .navigationSplitViewColumnWidth(min: 200, ideal: Layout.sidebarIdeal, max: 340)
        } detail: {
            HStack(spacing: 0) {
                Group {
                    if showingForYou {
                        ProactiveDeskView(chat: chat, setup: setup)
                    } else if let conversation = chat.current, !conversation.messages.isEmpty {
                        Transcript(chat: chat, setup: setup, conversation: conversation)
                    } else {
                        Welcome(chat: chat, setup: setup)
                    }
                }
                .background(Color(nsColor: Theme.chatTint))
                .overlay { if dropFeedback.targeted { DropOverlay() } }
                if browser.isOpen {
                    Divider()
                    BrowserPanelView(browser: browser)
                        .frame(minWidth: 360, idealWidth: 480, maxWidth: 720)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(Theme.quick, value: browser.isOpen)
            // The conversation's title only: which AI answers is said once, in the composer.
            .navigationTitle(showingForYou ? T("For You", table: "App") : chat.current?.title ?? "Pippa")
            .inspector(isPresented: panelState.projectedValue) {
                ContextPanel(chat: chat, setup: setup)
                    .inspectorColumnWidth(min: 240, ideal: Layout.inspector, max: 340)
            }
            .onChange(of: panelState.wrappedValue) { _, open in UserDefaults.standard.set(open, forKey: "contextPanel") }
            .toolbar {
                ToolbarItem {
                    Button { browser.isOpen.toggle() } label: {
                        Label { Text(T("Browser", table: "App")) } icon: { Image(systemName: "globe") }
                    }
                    .help(T("Show or hide Pippa’s browser", table: "App"))
                }
                ToolbarItem {
                    Button { panelState.wrappedValue.toggle() } label: {
                        Label { Text(T("Context", table: "App")) } icon: {
                            Image(systemName: "sidebar.right")
                                .overlay(alignment: .topTrailing) {
                                    if contextCount > 0 && !panelState.wrappedValue {
                                        Text(verbatim: "\(min(contextCount, 99))")
                                            .font(.system(size: 8, weight: .bold)).monospacedDigit()
                                            .contentTransition(.numericText())
                                            .foregroundStyle(Theme.ink2)
                                            .padding(.horizontal, 3)
                                            .frame(minWidth: 12, minHeight: 12)
                                            .background(Theme.fill3, in: Capsule())
                                            .offset(x: 7, y: -6)
                                    }
                                }
                        }
                    }
                    .animation(Theme.quick, value: contextCount)
                    .help(T("Show or hide what Pippa read and did", table: "App"))
                }
            }
        }
        .sheet(isPresented: Binding(get: { chat.review != nil }, set: { if !$0 { chat.dismissReview() } })) {
            ShareReviewSheet(chat: chat)
        }
        .sheet(isPresented: $setup.showsOnlineSetup) {
            OnlineSetupSheet(settings: .shared, setup: setup) { setup.showsOnlineSetup = false }
        }
        .sheet(item: $editorPresenter.seed) { seed in
            RoutineEditorSheet(seed: seed) { editorPresenter.dismiss() }
        }
        .environment(\.openRoutineEditor, RoutineEditorAction(id: editorPresenter.id) { [weak editorPresenter] seed in
            editorPresenter?.open(seed)
        })
        .onReceive(proactivity.$openDeskRequested) { requested in
            guard requested else { return }
            forYouState.wrappedValue = true
            proactivity.openDeskRequested = false
        }
        // Any explicit chat activation (sidebar conversation, ⌘N, Open in Chat, Island, file drop) leaves "For You".
        .onChange(of: chat.currentID) { _, _ in forYouState.wrappedValue = false }
        .onChange(of: proactivity.openChatToken) { _, _ in forYouState.wrappedValue = false }
    }

    /// What the latest answer read and did: shown on the panel button while the panel is closed.
    private var contextCount: Int {
        guard let answer = chat.current?.messages.last(where: { $0.role == .assistant }) else { return 0 }
        return (answer.sources?.count ?? 0) + answer.receipts.count
    }
}

/// Snapshots only: every "Worked for …" row starts open, to check the steps and the thinking.
private struct ExpandsWorkKey: EnvironmentKey { static let defaultValue = false }

/// Stable presenter backing `RoutineEditorAction` so environment identity never churns during streaming.
@MainActor
private final class RoutineEditorPresenter: ObservableObject {
    @Published var seed: RoutineEditorSeed?
    let id = UUID()
    func open(_ seed: RoutineEditorSeed) { self.seed = seed }
    func dismiss() { self.seed = nil }
}

/// Opens the routine editor from anywhere in the chat window: "Save as routine…", "Make routine", the desk.
struct RoutineEditorAction: Equatable, Sendable {
    let id: UUID
    private let open: @MainActor @Sendable (RoutineEditorSeed) -> Void

    init(id: UUID = UUID(), open: @escaping @MainActor @Sendable (RoutineEditorSeed) -> Void) {
        self.id = id
        self.open = open
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    @MainActor func callAsFunction(_ seed: RoutineEditorSeed) { open(seed) }
}

private struct OpenRoutineEditorKey: EnvironmentKey {
    static let defaultValue = RoutineEditorAction(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) { _ in }
}

extension EnvironmentValues {
    var expandsWork: Bool {
        get { self[ExpandsWorkKey.self] }
        set { self[ExpandsWorkKey.self] = newValue }
    }

    var openRoutineEditor: RoutineEditorAction {
        get { self[OpenRoutineEditorKey.self] }
        set { self[OpenRoutineEditorKey.self] = newValue }
    }
}

/// Files over the window: a solid accent tint with a solid 1 pt accent edge, like Pippa Island's drop tray.
private struct DropOverlay: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        shape
            .fill(Theme.accentTint)
            .overlay(shape.strokeBorder(Theme.accent, lineWidth: 1))
            .overlay {
                VStack(spacing: Space.m) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 32, weight: .medium))
                    Text(T("Drop files for Pippa", table: "App")).font(Typo.headline)
                }
                .foregroundStyle(Theme.accent)
            }
            .padding(Space.l)
            .allowsHitTesting(false)
    }
}
