import AppKit
import SwiftUI

/// The conversations: "New Conversation" on top, then pinned and by day. One line per conversation; a running answer,
/// an unseen answer or a pin shows at the end of its row, and on hover the row's menu takes that place.
struct Sidebar: View {
    @ObservedObject var chat: ChatModel
    var search: Binding<String>
    /// The conversation whose title is being edited right in its row.
    private let renamingState = State<String?>(initialValue: nil)

    private var query: String { search.wrappedValue.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        List {
            NewConversationRow { chat.newConversation() }
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { conversation in
                        ConversationRow(conversation: conversation,
                                        selected: conversation.id == chat.currentID,
                                        answering: chat.isAnswering && chat.answeringID == conversation.id,
                                        unseen: chat.unseenIDs.contains(conversation.id),
                                        snippet: query.isEmpty ? nil : Self.snippet(conversation, query: query),
                                        canDelete: !(chat.isAnswering && chat.answeringID == conversation.id),
                                        renaming: renamingState.wrappedValue == conversation.id,
                                        open: { chat.select(conversation.id) },
                                        rename: { renamingState.wrappedValue = conversation.id },
                                        commitRename: { name in
                                            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                            if !name.isEmpty, name != conversation.title { chat.rename(conversation.id, to: name) }
                                            renamingState.wrappedValue = nil
                                        },
                                        cancelRename: { renamingState.wrappedValue = nil },
                                        togglePin: { chat.togglePin(conversation.id) },
                                        delete: { chat.delete(conversation.id) })
                            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    }
                }
            }
        }
        .searchable(text: search, placement: .sidebar, prompt: T("Search", table: "App"))
        .overlay {
            if groups.isEmpty { emptyState.padding(.top, 44) }
        }
        .toolbar {
            ToolbarItem {
                Button { chat.newConversation() } label: { Label(T("New Conversation", table: "App"), systemImage: "square.and.pencil") }
                    .help(T("New Conversation", table: "App") + " (⌘N)")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.ml) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 24, weight: .regular)).foregroundStyle(Theme.ink3)
            Text(query.isEmpty ? T("Your conversations appear here.", table: "App") : T("Nothing found", table: "App"))
                .font(.callout).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
            if !query.isEmpty {
                Button(T("Clear Search", table: "App")) { search.wrappedValue = "" }.controlSize(.small)
            }
        }
        .padding(Space.x3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groups: [(title: String, items: [Conversation])] {
        let query = query
        let found = query.isEmpty ? chat.conversations : chat.conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func title(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return T("Today", table: "App") }
            if calendar.isDateInYesterday(date) { return T("Yesterday", table: "App") }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            if days < 7 { return T("Previous 7 Days", table: "App") }
            if days < 30 { return T("Previous 30 Days", table: "App") }
            return T("Older", table: "App")
        }
        let pinned = found.filter { $0.pinned == true }
        var result: [(title: String, items: [Conversation])] = pinned.isEmpty ? [] : [(T("Pinned", table: "App"), pinned)]
        for conversation in found where conversation.pinned != true {
            let name = title(conversation.updated)
            if result.last?.title == name { result[result.count - 1].items.append(conversation) } else { result.append((name, [conversation])) }
        }
        return result
    }

    /// While searching: the words around the first match in the conversation, on one line.
    static func snippet(_ conversation: Conversation, query: String) -> String? {
        for message in conversation.messages {
            guard let range = message.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = message.text.index(range.lowerBound, offsetBy: -24, limitedBy: message.text.startIndex) ?? message.text.startIndex
            var text = String(message.text[start...].prefix(120))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"[\*_`#]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if start != message.text.startIndex { text = "…" + text }
            return text
        }
        let preview = conversation.preview
        return preview.isEmpty ? nil : preview
    }
}

/// The first row: a new conversation, with its shortcut.
private struct NewConversationRow: View {
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink2)
                    .frame(width: 18)
                Text(T("New Conversation", table: "App"))
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                Spacer(minLength: Space.xs)
                Text(verbatim: "⌘N").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, Space.m)
            .frame(height: 34)
            .background(hoverState.wrappedValue ? Theme.rowHover : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .help(T("New Conversation", table: "App") + " (⌘N)")
    }
}

/// One conversation on one line: what it was about, its title, and at the end its state or (on hover) its menu.
private struct ConversationRow: View {
    var conversation: Conversation
    var selected: Bool
    var answering: Bool
    var unseen: Bool
    /// While searching: where the words were found.
    var snippet: String?
    var canDelete: Bool
    /// The title is a text field: Return or clicking elsewhere keeps the new name, Escape keeps the old one.
    var renaming: Bool
    var open: () -> Void
    var rename: () -> Void
    var commitRename: (String) -> Void
    var cancelRename: () -> Void
    var togglePin: () -> Void
    var delete: () -> Void
    private let hoverState = State(initialValue: false)
    private let nameState = State(initialValue: "")
    private let finishedState = State(initialValue: false)
    @FocusState private var nameFocused: Bool

    private var hover: Bool { hoverState.wrappedValue }
    private var active: Bool { hover || selected }
    private var title: String { conversation.title.isEmpty ? T("New conversation", table: "App") : conversation.title }

    var body: some View {
        HStack(spacing: Space.xs) {
            if renaming {
                label
            } else {
                Button(action: open) { label }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            trailing.frame(width: 20, height: 20).opacity(renaming ? 0 : 1).allowsHitTesting(!renaming)
        }
        .padding(.leading, Space.m).padding(.trailing, Space.xs)
        .frame(minHeight: 36)
        .background {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            if renaming {
                shape.fill(Theme.chatCard).overlay { shape.strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5) }
            } else if selected {
                shape.fill(Theme.rowSelected).overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 0.5)
            } else if hover {
                shape.fill(Theme.rowHover)
            }
        }
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .help(conversation.preview)
        .contextMenu { menuItems }
    }

    private var label: some View {
        HStack(spacing: Space.m) {
            Image(systemName: conversation.symbol)
                .font(.system(size: 12.5)).foregroundStyle(active ? Theme.ink2 : Theme.ink3)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    nameField
                } else {
                    Text(title)
                        .font(.system(size: 13.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(active ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                    if let snippet {
                        Text(snippet).font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// The title in place, ready to type over.
    private var nameField: some View {
        TextField(T("Rename Conversation", table: "App"), text: nameState.projectedValue)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
            .focused($nameFocused)
            .onSubmit { finish(keep: true) }
            .onExitCommand { finish(keep: false) }
            .onAppear {
                finishedState.wrappedValue = false
                nameState.wrappedValue = conversation.title
                nameFocused = true
            }
            .onChange(of: nameFocused) { _, focused in
                // Clicking elsewhere keeps what was typed, like Finder.
                if !focused { finish(keep: true) }
            }
            .accessibilityLabel(T("Rename Conversation", table: "App"))
    }

    /// Ends editing once: Return, Escape and the focus leaving afterwards all land here.
    private func finish(keep: Bool) {
        guard !finishedState.wrappedValue else { return }
        finishedState.wrappedValue = true
        if keep { commitRename(nameState.wrappedValue) } else { cancelRename() }
    }

    /// What the row shows at its end: answering, a new answer, pinned; on hover the menu instead.
    private var trailing: some View {
        ZStack {
            Group {
                if answering {
                    SpinRing(size: 12, lineWidth: 1.6)
                        .accessibilityLabel(T("Answering…", table: "App"))
                } else if unseen {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                        .accessibilityLabel(T("New answer", table: "App"))
                } else if conversation.pinned == true {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                        .accessibilityLabel(T("Pinned", table: "App"))
                }
            }
            .opacity(hover ? 0 : 1)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hover ? 1 : 0)
            .allowsHitTesting(hover)
            .help(T("More", table: "App"))
            .accessibilityLabel(T("More", table: "App"))
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button(T("Rename…", table: "App"), action: rename)
        Button(conversation.pinned == true ? T("Unpin", table: "App") : T("Pin", table: "App"), action: togglePin)
        Divider()
        Button(T("Delete", table: "App"), role: .destructive, action: delete).disabled(!canDelete)
    }
}
