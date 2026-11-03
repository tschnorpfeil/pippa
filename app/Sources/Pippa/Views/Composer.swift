import AppKit
import PippaCore
import SwiftUI

/// Where the person asks: one raised body (the words on top, a footer row below) and, with files attached, a drawer
/// tucked behind its top edge that holds them.
struct Composer: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    @FocusState private var focused: Bool

    /// How far the drawer reaches under the body.
    private let tuck: CGFloat = 16

    private var hasContent: Bool {
        !(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.attachments.isEmpty)
    }
    private var canSend: Bool { setup.canAnswer && !chat.isAnswering && hasContent }

    var body: some View {
        VStack(spacing: 0) {
            if !chat.attachments.isEmpty {
                drawer
                    .padding(.bottom, -tuck)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            card.zIndex(1)
        }
        .animation(Theme.arrive, value: chat.attachments.isEmpty)
        .frame(maxWidth: Layout.column)
        .padding(.horizontal, Layout.gutter).padding(.top, Space.s).padding(.bottom, Space.xl)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
    }

    private var drawer: some View {
        HStack(spacing: Space.m) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(chat.attachments, id: \.self) { url in
                        Chip(url: url) {
                            withAnimation(Theme.leave) { chat.attachments.removeAll { $0 == url } }
                        }
                    }
                }
            }
            if chat.canMakePDF && !chat.isAnswering {
                Button { chat.makePDF() } label: {
                    Label(T("One PDF", table: "App"), systemImage: "doc.richtext").font(.system(size: 12, weight: .medium))
                }
                .controlSize(.small)
                .fixedSize()
                .help(T("Make one PDF from these files, right here on your Mac", table: "App"))
            }
        }
        .padding(.horizontal, Space.ml).padding(.top, Space.ml).padding(.bottom, Space.ml + tuck)
        .background(Theme.fill, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: Radius.chat,
                                                           bottomTrailingRadius: Radius.chat, topTrailingRadius: 16,
                                                           style: .continuous))
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: Radius.chat, bottomTrailingRadius: Radius.chat,
                                   topTrailingRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Space.ml) {
            TextField(T("Ask Pippa…", table: "App"), text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineSpacing(4).lineLimit(1...10)
                .focused($focused)
                .onChange(of: chat.draft) { _, text in
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        PiSession.shared.prewarmForInput()
                    }
                }
                .onSubmit { if canSend { chat.send() } }
                .padding(.horizontal, Space.xs)
            HStack(spacing: Space.m) {
                Button { addFiles() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2)
                        .frame(width: 28, height: 28)
                        .background(Theme.rowHover, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(T("Add Files…", table: "App"))
                .accessibilityLabel(T("Add Files…", table: "App"))
                Spacer(minLength: Space.m)
                AIBadge(setup: setup)
                sendButton
            }
        }
        .padding(.horizontal, Space.ml).padding(.top, 13).padding(.bottom, Space.ml)
        .raised(Radius.chat, lifted: focused)
        .animation(Theme.quick, value: focused)
    }

    /// One 32 pt circle in one place: Send, or Stop while the answer here runs.
    @ViewBuilder private var sendButton: some View {
        if chat.isAnsweringHere {
            Button { chat.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 32, height: 32)
                    .background(Theme.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help(T("Stop", table: "App") + " (⌘.)")
            .accessibilityLabel(T("Stop", table: "App"))
        } else {
            Button { chat.send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Theme.ink3)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Theme.accentFill : Theme.sendDisabled, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .animation(Theme.quick, value: canSend)
            .help(chat.isAnswering ? T("Pippa is still answering in another conversation.", table: "App") : T("Send", table: "App") + " (↩)")
            .accessibilityLabel(T("Send", table: "App"))
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !chat.attachments.contains(url) { chat.attachments.append(url) }
    }
}

/// Which AI answers: on this Mac, or the online one chosen in Settings. A click opens Settings.
struct AIBadge: View {
    @ObservedObject var setup: SetupModel

    var body: some View {
        Button { SettingsWindow.shared.show() } label: {
            HStack(spacing: Space.xs) {
                if case .preparing = setup.state, !setup.usesOnlineAI { ProgressView().controlSize(.mini) }
                else { Image(systemName: setup.usesOnlineAI ? "cloud" : "laptopcomputer").font(.system(size: 10.5, weight: .medium)) }
                Text(Self.label(setup)).lineLimit(1)
            }
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink2)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Theme.rowHover, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(T("Change in Settings", table: "App"))
    }

    /// Which AI answers: on this Mac, ChatGPT or the connected model. From the settings in memory, never from disk:
    /// the window header and the composer ask for it on every redraw.
    @MainActor static func label(_ setup: SetupModel) -> String {
        let settings = SettingsModel.shared.inferenceSettings
        if let selected = settings.activePiModel { return selected.providerName + " · " + selected.modelID }
        if let connection = PiOnlineProvider.activeConnection(settings) { return connection.modelID }
        switch setup.state {
        case .ready: return T("On this Mac", table: "App")
        case .preparing: return T("Getting ready…", table: "App")
        case .downloading: return T("Loading AI…", table: "App")
        default: return T("Not set up", table: "App")
        }
    }
}

/// A file attached to the next question, in the composer's drawer.
private struct Chip: View {
    var url: URL
    var remove: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            NativeFilePreviewButton(url: url) {
                HStack(spacing: Space.s) {
                    NativeFileThumbnail(url: url, size: CGSize(width: 42, height: 42))
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("Remove", table: "App"))
            .accessibilityLabel(T("Remove", table: "App") + ": " + url.lastPathComponent)
        }
        .font(.system(size: 12)).foregroundStyle(Theme.ink)
        .padding(.leading, Space.xs).padding(.trailing, Space.xs).padding(.vertical, Space.xs)
        .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
    }
}
