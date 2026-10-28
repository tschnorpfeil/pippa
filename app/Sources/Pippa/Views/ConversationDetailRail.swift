import AppKit
import PippaCore
import SwiftUI

/// Right rail of the open conversation: the files it works with, what Pippa made here and the pages she read.
/// Lists come from Pippa's own records (ConversationController.artifacts), never from answer text. Prepared files open
/// only through the tray's check, like their card in the conversation. Rows get plain values, so typing in the
/// composer doesn't redraw them.
struct ConversationDetailRail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chat: ConversationController

    var body: some View {
        let artifacts = chat.artifacts
        let busy = model.isActiveWork
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(T("Files in use", table: "Views"), count: artifacts.filesInUse.count + (artifacts.selectedText == nil ? 0 : 1)) {
                    if artifacts.filesInUse.isEmpty && artifacts.selectedText == nil {
                        empty(T("Drop files on Pippa or onto this window to work with them here.", table: "Views"))
                    }
                    ForEach(artifacts.filesInUse) { file in RailFileInUseRow(file: file, busy: busy, model: model) }
                    if let text = artifacts.selectedText { selectedTextRow(text, busy: busy) }
                }
                section(T("Made here", table: "Views"), count: artifacts.made.count) {
                    if artifacts.made.isEmpty {
                        empty(T("Files, drafts and entries Pippa makes in this conversation show up here.", table: "Views"))
                    }
                    ForEach(artifacts.made) { item in RailMadeRow(item: item, job: job(item.receipt), model: model) }
                }
                section(T("Sources", table: "Views"), count: artifacts.sources.count) {
                    if artifacts.sources.isEmpty {
                        empty(T("Web pages Pippa reads for this conversation show up here.", table: "Views"))
                    }
                    ForEach(artifacts.sources) { source in RailSourceRow(source: source, model: model) }
                }
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .background(Theme.fill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Details", table: "App"))
    }

    /// The journal job behind an entry, while it is among the recent jobs (AppModel.refreshJobs keeps 30).
    private func job(_ id: UUID?) -> JobReceipt? {
        guard let id else { return nil }
        return model.recentJobs.first(where: { $0.id == id })
    }

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.scaled(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                if count > 0 {
                    Text(verbatim: "\(count)").font(.scaled(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.bottom, 2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.scaled(size: 12)).foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
    }

    private func selectedTextRow(_ text: String, busy: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.quote").font(.scaled(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                .frame(width: 20, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(T("Selected Text", table: "Views")).font(.scaled(size: 13)).foregroundStyle(Theme.ink)
                Text(verbatim: String(text.prefix(140))).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(2)
                LinkButton(title: T("Stop using selected text", table: "Views"), icon: nil) { model.removeSelectedTextContext() }
                    .disabled(busy)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }
}

private struct RailFileInUseRow: View {
    var file: ConversationArtifacts.FileInUse
    var busy: Bool
    let model: AppModel

    var body: some View {
        let name = file.url.lastPathComponent
        HStack(alignment: .top, spacing: 10) {
            FileThumbnail(url: file.url, width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Button { NSWorkspace.shared.open(file.url) } label: {
                    Text(verbatim: name).font(.scaled(size: 13)).foregroundStyle(Theme.ink)
                        .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).help(file.url.path)
                if file.pending {
                    Text(T("Waiting for your message", table: "Views")).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3)
                }
                LinkButton(title: T("Show in Finder", table: "Views"), icon: nil) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            }
            Spacer(minLength: 0)
            Button { model.removeConversationAttachment(file.url) } label: {
                Image(systemName: "xmark").font(.scaled(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(busy)
            .help(T("Stop using %@", table: "Views", name))
            .accessibilityLabel(T("Stop using %@", table: "Views", name))
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }
}

private struct RailMadeRow: View {
    var item: ConversationArtifacts.Made
    var job: JobReceipt?
    let model: AppModel
    private let problemState = State<String?>(initialValue: nil)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Button { model.showInConversation(item.messageID) } label: {
                    Text(verbatim: title).font(.scaled(size: 13)).foregroundStyle(Theme.ink)
                        .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).help(T("Show in Conversation", table: "Views"))
                Text(Self.label(item.kind)).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                HStack(spacing: 12) { actions }
                if let problem = problemState.wrappedValue {
                    Text(problem).font(.scaled(size: 11.5)).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .contextMenu {
            Button(T("Show in Conversation", table: "Views")) { model.showInConversation(item.messageID) }
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if item.kind == .mailDraft, item.title.isEmpty { return T("Email without subject", table: "Views") }
        return item.title
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .prepared, .found:
            FileThumbnail(url: item.file, width: 20)
        case .created, .updated:
            DocIcon(kind: DocIcon.kind(for: URL(fileURLWithPath: item.title, isDirectory: false)), width: 20)
        default:
            Image(systemName: Self.symbol(item.kind))
                .font(.scaled(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                .frame(width: 20, height: 24).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var actions: some View {
        switch item.kind {
        case .prepared:
            if let file = item.file, let card = item.preparedCard {
                LinkButton(title: T("Open", table: "Views"), icon: nil) { actOnPrepared(.open, card: card, file: file) }
                LinkButton(title: T("Show in Finder", table: "Views"), icon: nil) { actOnPrepared(.finder, card: card, file: file) }
            }
        case .found:
            if let file = item.file {
                LinkButton(title: T("Open", table: "Views"), icon: nil) { NSWorkspace.shared.open(file) }
                LinkButton(title: T("Show in Finder", table: "Views"), icon: nil) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        case .created, .updated:
            if let reveal = job?.revealURL {
                LinkButton(title: T("Open", table: "Views"), icon: nil) { openCreated(near: reveal) }
                LinkButton(title: T("Show in Finder", table: "Views"), icon: nil) {
                    AppModel.reveal(ConversationArtifacts.file(named: item.title, near: reveal) ?? reveal)
                }
            }
        case .result:
            if let integration = job?.integration {
                LinkButton(title: T("Open", table: "Views"), icon: nil) { AppModel.openApp(integration) }
            } else if let reveal = job?.revealURL {
                LinkButton(title: T("Show in Finder", table: "Views"), icon: nil) { AppModel.reveal(reveal) }
            }
        case .draftInMail:
            LinkButton(title: T("Open", table: "Views"), icon: nil) { model.conversations.openMailDraft() }
        case .calendarEvent:
            LinkButton(title: T("Open", table: "Views"), icon: nil) { AppModel.openApp(.calendar) }
        case .reminder:
            LinkButton(title: T("Open", table: "Views"), icon: nil) { model.conversations.openReminders() }
        case .mailDraft:
            EmptyView()
        }
    }

    /// A created file Pippa knows by name: the file next to its answer's reveal location, else that location.
    private func openCreated(near reveal: URL) {
        guard let file = ConversationArtifacts.file(named: item.title, near: reveal) else { return AppModel.reveal(reveal) }
        NSWorkspace.shared.open(file)
    }

    /// Same path as the card in the conversation: the tray checks the journal before anything opens.
    private func actOnPrepared(_ action: PreparedFileAction, card: PreparedFilesCard, file: URL) {
        problemState.wrappedValue = nil
        model.tray.actOnPreparedFile(action, card: card, file: file) { message in problemState.wrappedValue = message }
    }

    static func label(_ kind: ConversationArtifacts.Made.Kind) -> String {
        switch kind {
        case .prepared: T("Prepared file", table: "Views")
        case .found: T("Found on this Mac", table: "Views")
        case .created: T("Created by Pippa", table: "Views")
        case .updated: T("Changed by Pippa", table: "Views")
        case .result: T("Task result", table: "Views")
        case .mailDraft: T("Email draft · not sent", table: "Views")
        case .draftInMail: T("Draft in Mail · not sent", table: "Views")
        case .calendarEvent: T("In Calendar", table: "Views")
        case .reminder: T("In Reminders", table: "Views")
        }
    }

    static func symbol(_ kind: ConversationArtifacts.Made.Kind) -> String {
        switch kind {
        case .mailDraft, .draftInMail: "envelope"
        case .calendarEvent: "calendar"
        case .reminder: "checklist"
        case .result: "checkmark.circle"
        default: "doc"
        }
    }
}

private struct RailSourceRow: View {
    var source: ConversationArtifacts.Source
    let model: AppModel

    var body: some View {
        Button { NSWorkspace.shared.open(source.url) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "globe").font(.scaled(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20).background(Theme.accentTint, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: source.host).font(.scaled(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let path = source.path {
                        Text(verbatim: path).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source.url.absoluteString)
        .contextMenu {
            Button(T("Open", table: "Views")) { NSWorkspace.shared.open(source.url) }
            Button(T("Copy Link", table: "Views")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.url.absoluteString, forType: .string)
            }
            Button(T("Show in Conversation", table: "Views")) { model.showInConversation(source.messageID) }
        }
    }
}
