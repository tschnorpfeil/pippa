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
    /// Keep the conversation spacious by default; remember an explicit choice to show the inspector.
    private let panelState: State<Bool>

    /// `inspector`: snapshots show or hide "About this answer" whatever the saved choice is.
    init(chat: ChatModel, setup: SetupModel, inspector: Bool? = nil) {
        self.chat = chat
        self.setup = setup
        panelState = State(initialValue: inspector ?? UserDefaults.standard.object(forKey: "contextPanel") as? Bool ?? false)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(chat: chat, search: searchState.projectedValue)
                .navigationSplitViewColumnWidth(min: 200, ideal: Layout.sidebarIdeal, max: 340)
        } detail: {
            Group {
                if let conversation = chat.current, !conversation.messages.isEmpty {
                    Transcript(chat: chat, setup: setup, conversation: conversation)
                } else {
                    Welcome(chat: chat, setup: setup)
                }
            }
            .background(Color(nsColor: Theme.chatTint))
            .overlay { if dropFeedback.targeted { DropOverlay() } }
            // The conversation's title only: which AI answers is said once, in the composer.
            .navigationTitle(chat.current?.title ?? "Pippa")
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
