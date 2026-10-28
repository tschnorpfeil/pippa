import PippaCore
import SwiftUI

/// The open conversation as one window: the header across the top, then the conversation rail, the conversation
/// (ConversationWorkspace) and the detail rail. Without room for a rail, and in every scripted capture except `rails`,
/// it is exactly the plain conversation: same header, size, resize grip and drop frame as before the rails.
struct ConversationWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chat: ConversationController
    var mode: ShellMode
    var measuring: Bool

    var body: some View {
        let layout = ConversationRailLayout.resolve(width: model.conversationSize.width, rails: model.activeRails, scale: Theme.widthScale)
        VStack(spacing: 0) {
            header(layout)
            Theme.hair.frame(height: 0.5)
            HStack(spacing: 0) {
                if layout.showsSessions && !measuring {
                    ConversationSessionRail(model: model, chat: chat)
                        .frame(width: layout.sessionWidth)
                        .overlay(alignment: .trailing) { Theme.hair.frame(width: 0.5) }
                }
                ConversationWorkspace(model: model, chat: chat, mode: mode, measuring: measuring)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if layout.showsDetails && !measuring {
                    ConversationDetailRail(model: model, chat: chat)
                        .frame(width: layout.detailWidth)
                        .overlay(alignment: .leading) { Theme.hair.frame(width: 0.5) }
                }
            }
        }
        .frame(width: model.conversationSize.width, height: model.conversationSize.height)
        .overlay(alignment: .bottomTrailing) { resizeGrip.padding(4) }
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 26).stroke(Theme.accent, lineWidth: 2)
                    .overlay {
                        Label(model.isActiveWork ? T("Drop here · I’ll add it next", table: "Views") : T("Add to Conversation", table: "Views"), systemImage: "plus.circle.fill")
                            .font(Fonts.head).padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .padding(6).allowsHitTesting(false)
            }
        }
    }

    private func header(_ layout: ConversationRailLayout) -> some View {
        let toggles = layout.showsToggles && DevSnapshot.showsRails
        return HStack(spacing: 10) {
            MarkSlot(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pippa").font(Fonts.head)
                // Only a real topic: "New Conversation" says nothing (the empty chat shows that already).
                if let title = chat.current?.title, title != ConversationStore.defaultTitle {
                    Text(title).font(Fonts.hint).foregroundStyle(Theme.ink3).lineLimit(1)
                }
            }
            Spacer()
            // With room for a rail: its switches (⌃⌘S, ⌥⌘I). Narrower, the plain header; history is also in the menu bar.
            if toggles {
                if !layout.showsSessions {
                    RailToggle(symbol: "square.and.pencil", on: false, label: T("New Conversation", table: "App"), shortcut: "⌘N") {
                        model.startNewConversation()
                    }
                    .disabled(model.isActiveWork)
                }
                RailToggle(symbol: "sidebar.left", on: layout.showsSessions,
                           label: layout.showsSessions ? T("Hide Conversations", table: "Views") : T("Show Conversations", table: "Views"),
                           shortcut: "⌃⌘S") { model.toggleRail(.sessions) }
                RailToggle(symbol: "sidebar.right", on: layout.showsDetails,
                           label: layout.showsDetails ? T("Hide Details", table: "Views") : T("Show Details", table: "Views"),
                           shortcut: "⌥⌘I") { model.toggleRail(.details) }
            }
            CloseButton { model.collapse() }
        }.foregroundStyle(Theme.ink).padding(.horizontal, 20).frame(height: 64)
            .contentShape(Rectangle())
            // The conversation can be moved by its header.
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { _ in if !measuring { model.shell?.dragWorkspace(resize: false) } }
                .onEnded { _ in model.shell?.endWorkspaceDrag() })
    }

    /// Handle at the bottom right of the whole window: resize.
    private var resizeGrip: some View {
        // Invisible, like any Mac window: in the rounded corner an arrow symbol looked like a stray mouse pointer.
        Color.clear
            .frame(width: 22, height: 22).contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in if !measuring { model.shell?.dragWorkspace(resize: true) } }
                .onEnded { _ in model.shell?.endWorkspaceDrag() })
            .help(T("Resize", table: "Views"))
            .accessibilityHidden(true)
    }
}

/// A header switch: 26 pt high like the close button, tinted while its rail shows.
private struct RailToggle: View {
    var symbol: String
    var on: Bool
    var label: String
    var shortcut: String
    var action: () -> Void
    private let hoverState = State(initialValue: false)
    private var hover: Bool { get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue } }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.scaled(size: 13, weight: .medium))
                .foregroundStyle(on ? Theme.accent : hover ? Theme.ink2 : Theme.ink3)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Theme.accentTint : hover ? Theme.fill2 : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label + "  " + shortcut)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
