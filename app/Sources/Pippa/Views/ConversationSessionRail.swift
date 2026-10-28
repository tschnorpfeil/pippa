import PippaCore
import SwiftUI

/// Left rail of the open conversation: a new conversation, then every conversation by day of its last change.
/// Switching waits while Pippa works (AppModel.selectConversation); rename and delete ask in a small window, like
/// deleting from the menu bar. The menu bar's Recent Conversations stays as a second way in.
struct ConversationSessionRail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chat: ConversationController

    var body: some View {
        let sections = ConversationRailGroups.sections(chat.history, current: chat.current?.id, now: Date(), calendar: .autoupdatingCurrent)
        let busy = model.isActiveWork
        VStack(alignment: .leading, spacing: 0) {
            Button { model.startNewConversation() } label: {
                Label(T("New Conversation", table: "App"), systemImage: "square.and.pencil")
                    .font(.scaled(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill2))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(T("New Conversation", table: "App") + "  ⌘N")
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(sections) { section in
                        Text(Self.title(section.group))
                            .font(Fonts.sill).foregroundStyle(Theme.ink3)
                            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.items) { summary in
                            let selected = summary.id == chat.current?.id
                            ConversationRailRow(summary: summary, selected: selected, working: selected && busy, busy: busy,
                                                select: { model.selectConversation(summary.id) },
                                                rename: { model.renameConversation(summary.id) },
                                                delete: { model.deleteConversation(summary.id) })
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 14)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.fill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Conversations", table: "Views"))
    }

    static func title(_ group: ConversationRailGroup) -> String {
        switch group {
        case .today: T("Today", table: "Views")
        case .yesterday: T("Yesterday", table: "Views")
        case .previousWeek: T("Previous 7 Days", table: "Views")
        case .older: T("Older", table: "Views")
        }
    }
}

/// One conversation: its title, the open one highlighted, a quiet spinner while Pippa works in it.
private struct ConversationRailRow: View {
    var summary: ConversationSummary
    var selected: Bool
    var working: Bool
    /// Pippa works (in the open conversation): others can't be opened or deleted until she is done.
    var busy: Bool
    var select: () -> Void
    var rename: () -> Void
    var delete: () -> Void
    private let hoverState = State<Bool>(initialValue: false)
    private var hover: Bool { get { hoverState.wrappedValue } nonmutating set { hoverState.wrappedValue = newValue } }

    var body: some View {
        let locked = busy && !selected
        // Not `.disabled`: the context menu stays usable; a locked row ignores the click instead.
        Button { if !selected && !locked { select() } } label: {
            HStack(spacing: 8) {
                Text(verbatim: summary.title)
                    .font(.scaled(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if working {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.accentTint : hover && !locked ? Theme.fill2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(locked ? 0.55 : 1)
        .onHover { hover = $0 }
        .help(locked ? T("You can switch when Pippa is done.", table: "Views") : summary.title)
        .contextMenu {
            Button(T("Rename…", table: "Views"), action: rename).disabled(summary.messageCount == 0)
            Button(T("Delete…", table: "Views"), role: .destructive, action: delete).disabled(busy)
        }
        .accessibilityLabel(summary.title)
        .accessibilityValue(working ? T("Pippa is working", table: "Views") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
