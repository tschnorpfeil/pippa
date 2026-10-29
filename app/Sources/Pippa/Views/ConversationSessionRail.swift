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
        let onlyEmpty = sections.allSatisfy { $0.items.allSatisfy { $0.messageCount == 0 } }
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
                // First run: only the empty open conversation. A hint instead of a second "New Conversation".
                if onlyEmpty {
                    Text(T("Your conversations will show up here.", table: "Views"))
                        .font(.scaled(size: 12)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 12)
                } else {
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

/// One conversation: its title, the open one highlighted, a quiet spinner while Pippa works in it, and a "…" menu
/// with Rename and Delete under the pointer (VoiceOver gets them as actions).
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
                // One weight for every row: semibold is wider, so a cut-off title would jump when selected.
                Text(verbatim: summary.title)
                    .font(.scaled(size: 13))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                // A fixed slot for the spinner and the "…" button, so the title never runs under them.
                ZStack {
                    if working { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                }
                .frame(width: 22)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.accentTint2 : hover && !locked ? Theme.fill2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(locked ? 0.55 : 1)
        .help(locked ? T("You can switch when Pippa is done.", table: "Views") : summary.title)
        // On the row itself, not on the "…" button laid over it.
        .accessibilityLabel(summary.title)
        .accessibilityValue(working ? T("Pippa is working", table: "Views") : "")
        .accessibilityHint(locked ? T("You can switch when Pippa is done.", table: "Views") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityActions {
            if summary.messageCount > 0 { Button(T("Rename…", table: "Views"), action: rename) }
            if !busy { Button(T("Delete…", table: "Views"), action: delete) }
        }
        .overlay(alignment: .trailing) {
            if (hover || selected) && !working { more }
        }
        // Below the overlay, so pointing at the "…" button keeps it there.
        .onHover { hover = $0 }
        .contextMenu {
            Button(T("Rename…", table: "Views"), action: rename).disabled(summary.messageCount == 0)
            Button(T("Delete…", table: "Views"), role: .destructive, action: delete).disabled(busy)
        }
    }

    /// The same two commands as the context menu, where people can see them.
    private var more: some View {
        Menu {
            Button(T("Rename…", table: "Views"), action: rename).disabled(summary.messageCount == 0)
            Button(T("Delete…", table: "Views"), role: .destructive, action: delete).disabled(busy)
        } label: {
            Image(systemName: "ellipsis")
                .font(.scaled(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        // Plain style like the composer's "Files in use" menu: the label is drawn by SwiftUI.
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .padding(.trailing, 10)
        .help(T("More", table: "Views"))
        .accessibilityLabel(T("More", table: "Views"))
    }
}
