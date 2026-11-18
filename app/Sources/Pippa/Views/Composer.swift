import AppKit
import PhotosUI
import PippaCore
import SwiftUI

/// Where the person asks: one floating body (the words on top, a footer row below; Liquid Glass from macOS 26) and,
/// with files attached, a drawer tucked behind its top edge that holds them.
struct Composer: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    @FocusState private var focused: Bool
    /// The Photos picker for one picture to share (its text, read on this Mac).
    private let pickingPhoto = State(initialValue: false)
    private let pickedPhoto = State<PhotosPickerItem?>(initialValue: nil)

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
        .photosPicker(isPresented: pickingPhoto.projectedValue, selection: pickedPhoto.projectedValue, matching: .images,
                      preferredItemEncoding: .compatible)
        .onChange(of: pickedPhoto.wrappedValue) { _, item in
            guard let item else { return }
            pickedPhoto.wrappedValue = nil
            Task { @MainActor in
                let data = try? await item.loadTransferable(type: Data.self)
                chat.sharePhoto(data, type: item.supportedContentTypes.first)
            }
        }
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
                    Label(T("One PDF", table: "App"), systemImage: "doc.richtext").font(Typo.footnote.weight(.medium))
                }
                .controlSize(.small)
                .fixedSize()
                .help(T("Make one PDF from these files, right here on your Mac", table: "App"))
            }
        }
        .padding(.horizontal, Space.ml).padding(.top, Space.ml).padding(.bottom, Space.ml + tuck)
        .drawerSurface(UnevenRoundedRectangle(topLeadingRadius: Radius.panel, bottomLeadingRadius: Radius.chat,
                                              bottomTrailingRadius: Radius.chat, topTrailingRadius: Radius.panel,
                                              style: .continuous))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Space.ml) {
            if chat.review == nil, let parked = chat.parkedReview { parkedRow(parked) }
            TextField(T("Ask Pippa…", table: "App"), text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain).font(Typo.body).lineSpacing(4).lineLimit(1...10)
                .focused($focused)
                .onChange(of: chat.draft) { _, text in
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        PiSession.shared.prewarmForInput()
                    }
                }
                .onSubmit { if canSend { chat.send() } }
                .padding(.horizontal, Space.xs)
            if let problem = chat.problem {
                Text(problem).font(Typo.footnote).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
            }
            HStack(spacing: Space.m) {
                addButton
                Spacer(minLength: Space.m)
                if let recipient = chat.handoffDestination { askOnlineButton(recipient) }
                AIBadge(setup: setup)
                sendButton
            }
        }
        .padding(.horizontal, Space.ml).padding(.top, 13).padding(.bottom, Space.ml)
        .glass(Radius.chat, lifted: focused)
        .animation(Theme.quick, value: focused)
    }

    private var plus: some View {
        Image(systemName: "plus").font(Typo.callout.weight(.semibold)).foregroundStyle(Theme.ink2)
            .frame(width: 28, height: 28)
            .background(Theme.rowHover, in: Circle())
            .contentShape(Circle())
    }

    /// A review cancelled or not answered in this conversation, with every edit: continue it or let it go.
    private func parkedRow(_ parked: ShareReview) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: "cloud").foregroundStyle(Theme.ink2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(T("Your check for %@ is kept", table: "App", parked.plan.destination.provider)).font(Typo.footnote.weight(.medium))
                if let problem = parked.problem {
                    Text(problem).font(Typo.caption).foregroundStyle(Theme.need).lineLimit(2)
                }
            }
            Spacer(minLength: Space.m)
            Button(T("Continue Checking…", table: "App")) { chat.resumeReview() }
                .controlSize(.small).disabled(chat.isAnswering)
                .help(T("Open the check again with your edits; nothing is sent until you press Send", table: "App"))
            Button { chat.discardParkedReview() } label: {
                Image(systemName: "xmark").font(Typo.caption.weight(.bold)).imageScale(.small).foregroundStyle(Theme.ink3)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("Discard the check", table: "App"))
            .accessibilityLabel(T("Discard the check", table: "App"))
        }
        .font(Typo.footnote).foregroundStyle(Theme.ink)
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .contain)
    }

    /// Files, and with an online AI (or one for single questions) also what Pippa reads for it on this Mac first: each
    /// opens the review that names the provider. A source set to "Only on this Mac" is shown, but can't be chosen.
    @ViewBuilder private var addButton: some View {
        let settings = SettingsModel.shared.inferenceSettings
        if settings.usesOnlineAI || chat.handoffDestination != nil {
            let rules = settings.sharing
            Menu {
                Button(T("Add Files…", table: "App")) { addFiles() }
                Divider()
                if !settings.usesOnlineAI, let recipient = chat.handoffDestination {
                    Text(T("For one question to %@", table: "App", recipient.provider))
                }
                shareItem(T("Selected Email in Mail", table: "App"), .mail, rules)
                shareItem(T("Calendar, Next 7 Days", table: "App"), .calendar, rules)
                shareItem(T("Open Reminders", table: "App"), .reminders, rules)
                let photo = T("Photo from Photos…", table: "App")
                Button(rules.photos == .ask ? photo : T("%@ (only on this Mac)", table: "App", photo)) { pickingPhoto.wrappedValue = true }
                    .disabled(rules.photos != .ask)
            } label: { plus }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(chat.isAnswering)
            .help(T("Add files, or share something from your Mac after checking it", table: "App"))
            .accessibilityLabel(T("Add", table: "App"))
        } else {
            Button { addFiles() } label: { plus }
                .buttonStyle(.plain)
                .help(T("Add Files…", table: "App"))
                .accessibilityLabel(T("Add Files…", table: "App"))
        }
    }

    private func shareItem(_ title: String, _ source: SharingSource, _ rules: SourceSharing) -> some View {
        Button(rules[source] == .ask ? title : T("%@ (only on this Mac)", table: "App", title)) { chat.share(source) }
            .disabled(rules[source] != .ask)
    }

    /// While conversations stay on this Mac: one question to the online AI used before, after the review.
    private func askOnlineButton(_ recipient: ShareDestination) -> some View {
        Button { chat.askOnline() } label: {
            Label(T("Ask %@…", table: "App", recipient.provider), systemImage: "cloud")
                .font(Typo.caption.weight(.medium)).foregroundStyle(Theme.ink2)
                .padding(.horizontal, 9).frame(height: 24)
                .background(Theme.rowHover, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(chat.isAnswering || !(hasContent || chat.current?.messages.isEmpty == false))
        .help(T("Check what goes to %@, then send this one question there", table: "App", recipient.label))
    }

    /// One 32 pt circle in one place: Send (the accent as soon as there is something to send, quiet grey before), or
    /// Stop while the answer here runs, a quiet disc with a square. The symbol turns into the other.
    private var sendButton: some View {
        let stops = chat.isAnsweringHere
        let fill = !stops && canSend ? Theme.accentFill : nil
        return Button { stops ? chat.stop() : chat.send() } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(stops ? Typo.caption.weight(.bold) : Typo.callout.weight(.bold))
                .foregroundStyle(stops ? Theme.ink : canSend ? Color.white : Theme.ink3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .glassCircle(tint: fill, fallback: fill ?? Theme.sendDisabled)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(stops ? KeyboardShortcut(".", modifiers: .command) : KeyboardShortcut(.return, modifiers: .command))
        .disabled(!stops && !canSend)
        .animation(Theme.quick, value: canSend)
        .animation(Theme.quick, value: stops)
        .help(stops ? T("Stop", table: "App") + " (⌘.)"
              : chat.isAnswering ? T("Pippa is still answering in another conversation.", table: "App") : T("Send", table: "App") + " (↩)")
        .accessibilityLabel(stops ? T("Stop", table: "App") : T("Send", table: "App"))
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
        Button { SettingsWindow.shared.show(.ai) } label: {
            HStack(spacing: Space.xs) {
                if case .preparing = setup.state, !setup.usesOnlineAI { ProgressView().controlSize(.mini) }
                else { Image(systemName: setup.usesOnlineAI ? "cloud" : "laptopcomputer").font(Typo.caption.weight(.medium)) }
                Text(Self.label(setup)).lineLimit(1)
            }
            .font(Typo.caption.weight(.medium)).foregroundStyle(Theme.ink2)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Theme.rowHover, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(T("Change in Settings", table: "App"))
    }

    /// Which AI answers: on this Mac, ChatGPT or the connected model, by the names Settings shows ("OpenAI · GPT-6.1
    /// Terra"); the model's ID only when it has no name. From the settings in memory, never from disk: the composer
    /// asks for it on every redraw. The only place in the main window that names the model.
    @MainActor static func label(_ setup: SetupModel) -> String {
        let settings = SettingsModel.shared.inferenceSettings
        if let selected = settings.activePiModel { return selected.providerName + " · " + selected.modelDisplayName }
        if let connection = PiOnlineProvider.activeConnection(settings) { return connection.displayName }
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
                Image(systemName: "xmark").font(Typo.caption.weight(.bold)).imageScale(.small).foregroundStyle(Theme.ink3)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("Remove", table: "App"))
            .accessibilityLabel(T("Remove", table: "App") + ": " + url.lastPathComponent)
        }
        .font(Typo.footnote).foregroundStyle(Theme.ink)
        .padding(.leading, Space.xs).padding(.trailing, Space.xs).padding(.vertical, Space.xs)
        .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
    }
}

private extension View {
    /// The file drawer: glass like the composer; a soft fill with a hairline in snapshots.
    @ViewBuilder func drawerSurface<S: InsettableShape>(_ shape: S) -> some View {
        if Theme.drawsGlass {
            glassEffect(.regular, in: shape)
        } else {
            background(Theme.fill, in: shape).overlay { shape.strokeBorder(Theme.hairline, lineWidth: 1) }
        }
    }
}
