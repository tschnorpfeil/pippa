import SwiftUI
import PippaCore

struct ConversationWorkspace: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chat: ConversationController
    var mode: ShellMode
    var measuring: Bool
    @FocusState private var focused: Bool
    // SwiftUI state without the macro plugin, which ships only with Xcode.
    private let followState = State<Bool>(initialValue: true)
    private let bottomState = State<Bool>(initialValue: true)
    private let scrollingState = State<Bool>(initialValue: false)
    private let copiedState = State<UUID?>(initialValue: nil)
    private let scrollState = State(initialValue: ScrollPosition(edge: .bottom))
    private let restoringState = State(initialValue: true)
    private var restoringViewport: Bool { get { restoringState.wrappedValue } nonmutating set { restoringState.wrappedValue = newValue } }
    private var scrollPosition: ScrollPosition { get { scrollState.wrappedValue } nonmutating set { scrollState.wrappedValue = newValue } }
    private var followLatest: Bool { get { followState.wrappedValue } nonmutating set { followState.wrappedValue = newValue } }
    private var nearBottom: Bool { get { bottomState.wrappedValue } nonmutating set { bottomState.wrappedValue = newValue } }
    private var userScrolling: Bool { get { scrollingState.wrappedValue } nonmutating set { scrollingState.wrappedValue = newValue } }
    /// Draft copied last: its button briefly says "Copied".
    private var copied: UUID? { get { copiedState.wrappedValue } nonmutating set { copiedState.wrappedValue = newValue } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.hair.frame(height: 0.5)
            ScrollViewReader { reader in
                VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        let messages = chat.current?.messages ?? []
                        // An open card sits where it arose in the history; follow-up questions come below it.
                        let showsCard = mode.key != "input"
                        let anchor = showsCard ? min(model.cardAnchor, messages.count) : messages.count
                        if messages.isEmpty && !model.isActiveWork { welcome }
                        ForEach(Array(messages.prefix(anchor))) { message in
                            messageView(message)
                        }
                        if showsCard { card }
                        ForEach(Array(messages.dropFirst(anchor))) { message in
                            messageView(message)
                        }
                        if chat.isRunning {
                            if !chat.streamingText.isEmpty { AssistantAnswerView(text: chat.streamingText) }
                            // Real phases only; steps aside while answer text streams, returns for a tool after text.
                            ThoughtLineView(thought: chat.thought).id("thought")
                            if let ask = chat.webAsk { WebAccessCard(ask: ask) { chat.answerWebAsk(ask.id, approved: $0) }.id("web-ask") }
                            // Request to the user's own online service (RPC path), PippaOnlineService.
                            if PiRPCChat.isLive { OnlineAskSlot() }
                        }
                        ForEach(chat.queued) { entry in queuedView(entry) }
                        if !showsCard { card }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(20)
                }
                .scrollPosition(scrollState.projectedValue)
                .onScrollGeometryChange(for: ConversationScrollMetrics.self) { geometry in
                    ConversationScrollMetrics(offsetY: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                        atBottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 70)
                } action: { _, metrics in
                    nearBottom = metrics.atBottom
                    if userScrolling {
                        followLatest = metrics.atBottom
                        if !measuring { model.recordConversationActivity() }
                    }
                    if !measuring, !restoringViewport, model.mode.isConversation, let id = chat.current?.id {
                        model.conversationViewports[id] = ConversationViewport(offsetY: metrics.offsetY, followsLatest: followLatest)
                    }
                }
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating
                    if userScrolling && !measuring { model.recordConversationActivity() }
                    // Only direct scrolling changes following; layout/streaming idle events do not.
                }
                .onChange(of: chat.current?.messages.count) { _, _ in
                    if chat.current?.messages.last?.role == .user { followLatest = true }
                    follow(reader)
                }
                .onChange(of: chat.streamingText) { _, _ in follow(reader) }
                .onChange(of: chat.webAsk?.id) { _, _ in follow(reader) }
                .onReceive(PippaOnlineService.shared.$ask) { _ in follow(reader) }
                .onChange(of: chat.queued.count) { _, _ in follow(reader) }
                // Opening the receipt of the latest answer keeps its details in view.
                .onChange(of: chat.expandedReceipts) { _, _ in follow(reader) }
                .onChange(of: mode.key) { _, _ in
                    followLatest = true
                    if mode.key != "input" && mode.key != "notice" {
                        reader.scrollTo("workflow", anchor: .top)
                    } else {
                        reader.scrollTo("latest", anchor: .bottom)
                    }
                }
                .onChange(of: chat.current?.id) { _, _ in
                    restoreViewport(reader)
                }
                .onAppear { restoreViewport(reader) }
                HStack {
                    Spacer()
                    if !followLatest {
                        Button {
                            followLatest = true
                            reader.scrollTo("latest", anchor: .bottom)
                        } label: { Label(T("Jump to Latest", table: "Views"), systemImage: "arrow.down") }
                            .pippa(.quiet)
                    }
                }.padding(.horizontal, 20).frame(height: 32)
                }
            }
            if mode.shape == .sheet {
                Theme.hair.frame(height: 0.5)
                if case .sortSheet = mode { SortActions(model: model) }
                if case .invoiceSheet = mode { InvoiceActions(model: model) }
            }
            composer
        }
        .frame(width: model.conversationSize.width, height: model.conversationSize.height)
        .overlay(alignment: .bottomTrailing) { resizeGrip.padding(4) }
        .onAppear { if !measuring { focused = true } }
        .onChange(of: model.composerFocus) { _, _ in if !measuring { focused = true } }
        .onChange(of: model.query) { _, value in if !measuring && !value.isEmpty { focused = true } }
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

    /// New rows and streaming stay visible as long as nobody has scrolled up.
    private func follow(_ reader: ScrollViewProxy) {
        if followLatest && !restoringViewport { reader.scrollTo("latest", anchor: .bottom) }
    }

    private func restoreViewport(_ reader: ScrollViewProxy) {
        guard !measuring, let id = chat.current?.id else { return }
        restoringViewport = true
        let saved = model.conversationViewports[id]
        followLatest = saved?.followsLatest ?? true
        Task { @MainActor in
            // Wait for the reopened native scroll container's first layout.
            await Task.yield()
            guard chat.current?.id == id, model.mode.isConversation else { return }
            if let saved, !saved.followsLatest {
                scrollPosition.scrollTo(y: saved.offsetY)
            } else {
                reader.scrollTo("latest", anchor: .bottom)
            }
            await Task.yield()
            restoringViewport = false
        }
    }

    /// Selected text, receipt or preview: whatever currently belongs to the conversation.
    @ViewBuilder private var card: some View {
        if case .input = mode {
            if let selected = chat.current?.context?.selectedText,
               (chat.current?.messages.isEmpty ?? true), !model.isActiveWork {
                VStack(alignment: .leading, spacing: 10) {
                    Text(T("Selected Text", table: "Views")).font(Fonts.head)
                    Text(String(selected.prefix(240)) + (selected.count > 240 ? "…" : ""))
                        .font(Fonts.body).foregroundStyle(Theme.ink2).lineLimit(4)
                    SkillActions(model: model, place: .text)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.chatCard, in: RoundedRectangle(cornerRadius: 16))
            } else if let ctx = chat.current?.context, !ctx.files.isEmpty,
                       (chat.current?.messages.isEmpty ?? true), !model.isActiveWork {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: ctx.files.count == 1 && ctx.files[0].hasDirectoryPath ? "folder.fill" : "doc.on.doc.fill")
                            .foregroundStyle(Theme.accent)
                        Text(ctx.name).font(Fonts.head).foregroundStyle(Theme.ink).lineLimit(1)
                    }
                    Text(T("What should I do with this? Tell me, or pick a suggestion:", table: "Views"))
                        .font(Fonts.body).foregroundStyle(Theme.ink2)
                    AdaptiveActions {
                        // Organizing a single folder: go straight to the preview, no overview first.
                        if ctx.files.count == 1 && ctx.files[0].hasDirectoryPath {
                            Button(T("Organize", table: "Views")) { model.startSort() }.pippa(.secondary)
                        }
                        if let first = ctx.files.first,
                           let place = PippaSkill.place(for: DropKind.guess(for: first), fileExtension: first.pathExtension) {
                            let skills = PippaSkill.suggestions(for: place)
                            ForEach(skills) { skill in
                                Button(skill.title ?? skill.name) { model.runSkill(skill, offered: skills, place: place) }.pippa(.quiet)
                            }
                        }
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).chatCard()
            }
        } else if case .notice(_, _, let buttons) = mode {
            if !buttons.isEmpty {
                HStack(spacing: 10) {
                    ForEach(buttons) { button in
                        Button(button.title) { button.action() }
                            .pippa(button.title.hasPrefix(T("Undo", table: "App")) ? .tinted : button.primary ? .primary : .quiet)
                    }
                }
            }
        } else {
            WorkflowContentView(model: model, measuring: measuring, frozen: mode)
                .environment(\.embeddedWorkflow, true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .id("workflow")
                .chatCard()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            MarkSlot(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pippa").font(Fonts.head)
                Text(chat.current?.title ?? T("Your Conversation", table: "Views")).font(Fonts.hint).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer()
            // History lives in the menu bar; new topics also start automatically.
            CloseButton { model.collapse() }
        }.foregroundStyle(Theme.ink).padding(.horizontal, 20).frame(height: 64)
            .contentShape(Rectangle())
            // The conversation can be moved by its header.
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { _ in if !measuring { model.shell?.dragWorkspace(resize: false) } }
                .onEnded { _ in model.shell?.endWorkspaceDrag() })
    }

    /// New documents wait at the composer; used sources stay reachable without repeating their names.
    @ViewBuilder private var composerAttachments: some View {
        let pending = chat.current.map { ConversationPromptAttachments.pendingFiles(in: $0) } ?? []
        let used = chat.current.map { ConversationPromptAttachments.currentFiles(in: $0) } ?? []
        if !pending.isEmpty {
            DocumentAttachmentStrip(files: pending, disabled: model.isActiveWork) { model.removeConversationAttachment($0) }
        }
        if !used.isEmpty || chat.current?.context?.selectedText != nil {
            Menu {
                Text(T("These are available for future answers. Earlier messages keep their attachments.", table: "Views"))
                ForEach(Array(used.enumerated()), id: \.offset) { _, url in
                    Button(T("Stop using %@", table: "Views", url.lastPathComponent)) { model.removeConversationAttachment(url) }
                        .disabled(model.isActiveWork)
                }
                if chat.current?.context?.selectedText != nil {
                    Button(T("Stop using selected text", table: "Views")) { model.removeSelectedTextContext() }
                        .disabled(model.isActiveWork)
                }
            } label: {
                Label(T("For future answers", table: "Views"), systemImage: "paperclip")
                    .font(Fonts.hint).foregroundStyle(Theme.ink2)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help(T("Earlier messages keep their attachments. Original files stay where they are.", table: "Views"))
        }
    }

    /// Handle at the bottom right: resize.
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

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T("What would you like to do?", table: "Views"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Button {
                model.chooseFolder()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("Drop files or folders here…", table: "Views"))
                            .font(Fonts.head)
                            .foregroundStyle(Theme.ink)
                        Text(T("Or click to choose documents, letters, or spreadsheets.", table: "Views"))
                            .font(Fonts.hint)
                            .foregroundStyle(Theme.ink2)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.hair, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(T("Drop or choose files or folders", table: "Views"))
        }.padding(.vertical, 14)
    }

    @ViewBuilder private func messageView(_ message: ConversationMessage) -> some View {
        if message.role == .system, message.notice == true {
            if let previous = message.previousConversation, chat.history.contains(where: { $0.id == previous }),
               message.id == chat.current?.messages.first?.id {
                HStack(spacing: 12) {
                    Theme.hair.frame(height: 0.5)
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(T("New Topic", table: "Views"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Button(T("Previous Conversation…", table: "Views")) { model.continueInPrevious(previous) }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .buttonStyle(.plain)
                            .disabled(model.isActiveWork)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.fill2, in: Capsule())
                    Theme.hair.frame(height: 0.5)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(T("New topic. Previous conversation under Recent Conversations.", table: "Views"))
            } else {
                // Something the person needs to know: legible, with an icon, not a gray side note.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message.text).font(Fonts.body).foregroundStyle(Theme.ink).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .accessibilityLabel(T("Note: %@", table: "Views", message.text))
                        if !message.attachments.isEmpty {
                            DocumentAttachmentStrip(files: message.attachments, disabled: false)
                        }
                        receiptUndo(message)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
                .accessibilityElement(children: .contain)
            }
        } else {
            plainMessageView(message)
        }
    }

    /// "Undo" on a receipt in the history, as long as the job can still be undone.
    /// If the receipt is open as a card below, the card carries the button. Older receipts ask first:
    /// a click while scrolling should not roll back a job from days ago.
    @ViewBuilder private func receiptUndo(_ message: ConversationMessage) -> some View {
        if let id = message.receipt, let job = model.recentJobs.first(where: { $0.id == id }), job.canUndo,
           !(mode.key == "notice" && message.id == chat.current?.messages.prefix(model.cardAnchor).last?.id) {
            Button {
                if model.lastReceipt?.id == job.id { model.undo(job) } else { model.confirmUndo(job) }
            } label: { Label(T("Undo", table: "Views"), systemImage: "arrow.uturn.backward") }
                .pippa(.tinted).disabled(model.isActiveWork)
        }
    }

    /// Who is speaking, for VoiceOver.
    private static func speaker(_ role: ConversationMessage.Role) -> String {
        switch role {
        case .user: T("You", table: "Views")
        case .assistant: "Pippa"
        case .system: T("Note", table: "Views")
        }
    }

    /// Whole row for VoiceOver: who, what, and whether the answer was stopped.
    private static func spoken(_ message: ConversationMessage) -> String {
        let line = speaker(message.role) + ": " + message.text
        guard message.stopped == true else { return line }
        return T("%@ (stopped)", table: "Views", line)
    }

    /// Where an answer came from, only when there is something to know: online, or different from the previous answer.
    private func visibleLabel(_ message: ConversationMessage) -> String? {
        guard message.role == .assistant, let label = message.modelLabel else { return nil }
        if label.hasPrefix("Online") { return label }
        let messages = chat.current?.messages ?? []
        let before = messages.prefix { $0.id != message.id }.last { $0.role == .assistant }
        let previous = before?.modelLabel ?? AppModel.localStatus
        return previous == label ? nil : label
    }

    /// Written while Pippa is working: already shown, visibly marked as "up next", and can be withdrawn
    /// as long as Pippa has not picked it up yet.
    private func queuedView(_ entry: ConversationController.Queued) -> some View {
        let removable = !entry.handedToPi && chat.steering != entry.id
        let note = entry.handedToPi ? T("Pippa will read this after the current step", table: "Views") : T("Up next", table: "Views")
        return HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 5) {
                Text(entry.text).font(Fonts.lead).lineSpacing(4).foregroundStyle(Theme.ink2).textSelection(.enabled)
                    .padding(12)
                    .background(Theme.chatUser.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.chatBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 10, weight: .medium))
                    Text(note).font(.system(size: 11, weight: .medium))
                    if removable {
                        Button { chat.removeQueued(entry.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.plain).help(T("Don’t Send", table: "Views")).accessibilityLabel(T("Don’t send this waiting message", table: "Views"))
                    }
                }.foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(T("You, waiting: %@. %@", table: "Views", entry.text, note))
        }
    }

    @ViewBuilder private func plainMessageView(_ message: ConversationMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 5) {
                if let label = visibleLabel(message) {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink3)
                }
                if message.role == .assistant, let draft = message.mailDraft {
                    MailDraftCard(model: model, chat: chat, messageID: message.id, draft: draft)
                } else if message.role == .assistant {
                    AssistantAnswerView(text: message.text)
                        .contextMenu {
                            Button(T("Copy", table: "Views")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.text, forType: .string)
                            }
                        }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if !message.attachments.isEmpty {
                            DocumentAttachmentStrip(files: message.attachments, disabled: false)
                        }
                        Text(verbatim: message.text)
                            .font(message.role == .system ? Fonts.hint : Fonts.lead)
                            .lineSpacing(message.role == .system ? 2 : 4)
                            .foregroundStyle(message.role == .system ? Theme.ink3 : Theme.ink)
                            .textSelection(.enabled)
                    }
                        .padding(message.role == .user ? 12 : 0)
                        .background(message.role == .user ? Theme.chatUser : .clear, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                }
                if let actions = message.actions {
                    ActionReceiptView(receipt: actions, onUndo: { chat.undoAction($0) }, onUndoAll: { chat.undoAll(actions) },
                                      undoDisabled: chat.isRunning || chat.isUndoing,
                                      onOpenMailDraft: { chat.openMailDraft() }, onSaveMailOffer: { chat.saveMailOffer(messageID: message.id) },
                                      onCopyMailOffer: { chat.copyMailOffer(messageID: message.id) })
                }
                if message.role == .assistant, let work = message.work {
                    WorkReceiptView(receipt: work, expanded: chat.expandedReceipts.contains(message.id)) { chat.toggleReceipt(message.id) }
                }
                if message.stopped == true {
                    Text(T("Stopped", table: "Views")).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink3)
                } else if message.draft == true, message.mailDraft == nil {
                    draftActions(message)
                }
                calendarActions(message)
                receiptUndo(message)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Self.speaker(message.role))
            if message.role != .user { Spacer(minLength: 30) }
        }
    }

    /// On the calendar access request "Allow calendar" (only on the newest, while it is open),
    /// on "not allowed" the way into System Settings. Answers already read need no button.
    @ViewBuilder private func calendarActions(_ message: ConversationMessage) -> some View {
        if let read = message.calendar {
            switch read.state {
            case .needsAccess where CalendarConversation.pendingAccessOffer(in: chat.current?.messages ?? [])?.id == message.id:
                Button { model.allowCalendarAccess(message) } label: { Label(T("Allow Calendar Access", table: "CalendarUI"), systemImage: "calendar") }
                    .pippa(.primary).disabled(model.isActiveWork)
                    .accessibilityHint(T("Your Mac will ask you once. Then Pippa reads the period you asked about.", table: "CalendarUI"))
            case .denied:
                Button { model.openCalendarPrivacySettings() } label: { Label(T("Open System Settings", table: "CalendarUI"), systemImage: "gear") }
                    .pippa(.tinted)
            default:
                EmptyView()
            }
        }
    }

    /// Draft from a skill: copy it and send it yourself. Pippa writes no file and sends nothing.
    private func draftActions(_ message: ConversationMessage) -> some View {
        HStack(spacing: 10) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = message.id
            } label: {
                Label(copied == message.id ? T("Copied", table: "Views") : T("Copy", table: "Views"), systemImage: copied == message.id ? "checkmark" : "doc.on.doc")
            }.pippa(.quiet).accessibilityLabel(T("Copy Draft", table: "Views"))
            Text(T("Just a draft · nothing sent", table: "Views")).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink3)
        }
    }

    private var workspaceStatus: String {
        switch mode {
        case .sortSheet, .invoiceSheet, .entryPreview: return T("Preview · Nothing changed yet", table: "Views")
        case .overview, .deadlines: return T("Read only · Nothing changed", table: "Views")
        case .working(_, _, let writes): return writes ?? T("Just reading · Nothing will change", table: "Views")
        default: return ""
        }
    }

    private var composerPlaceholder: String {
        if model.plan != nil { return T("Ask about this preview…", table: "Views") }
        if chat.current?.context?.selectedText != nil { return T("Ask about this text…", table: "Views") }
        if chat.current?.context?.files.isEmpty == false { return T("What should I do with this…", table: "Views") }
        return T("Ask Pippa…", table: "Views")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            composerAttachments
            if !model.pendingDrops.isEmpty {
                HStack {
                    Label(model.pendingDropLabel, systemImage: "paperclip").font(Fonts.hint).foregroundStyle(Theme.ink2)
                    Spacer()
                    Button { model.discardPendingDrops() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(T("Remove Waiting Attachments", table: "Views"))
                }
            }
            if chat.current?.context != nil && (model.taskCard != nil || mode.key != "input") {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if case .input = mode {
                        if model.taskCard != nil {
                            Button { model.resumeTaskCard() } label: {
                                Label(model.taskCardTitle, systemImage: "chevron.up")
                            }.pippa(.quiet).disabled(model.isActiveWork)
                        }
                    } else if !model.isActiveWork {
                        Button { model.openInput() } label: { Label(T("Ask About This", table: "Views"), systemImage: "bubble.left") }
                            .pippa(.quiet)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { model.chooseFolder() } label: { Image(systemName: "plus").foregroundStyle(Theme.accent).frame(width: 28, height: 32) }
                    .buttonStyle(.plain).accessibilityLabel(T("Add Files", table: "Views"))
                TextField(composerPlaceholder, text: $model.query, axis: .vertical)
                    .lineLimit(1...4).font(Fonts.lead).textFieldStyle(.plain).focused($focused)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers == .shift,
                              let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                        editor.insertText("\n", replacementRange: editor.selectedRange())
                        return .handled
                    }
                    .onSubmit { model.route(model.query) }.padding(.vertical, 8)
                if chat.isRunning {
                    Button { model.stopChat() } label: { Image(systemName: "stop.fill").frame(width: 32, height: 32) }
                        .buttonStyle(.plain).accessibilityLabel(T("Stop Answering", table: "Views"))
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    // While Pippa is working: queue it, the message is handled afterwards.
                    Button { model.route(model.query) } label: { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 32, height: 32) }
                        .pippa(.primary).accessibilityLabel(model.isActiveWork ? T("Send When Ready", table: "Views") : T("Send Message", table: "Views"))
                        .accessibilityHint(model.sendBlockedReason(for: model.query) ?? "")
                        .help(model.sendBlockedReason(for: model.query) ?? (model.isActiveWork ? T("Send when ready · up next", table: "Views") : T("Send Message", table: "Views")))
                        .disabled((!model.isActiveWork && model.sendBlockedReason(for: model.query) != nil)
                                  || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(8).background(Theme.chatCard, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(focused ? Theme.accent.opacity(0.4) : Theme.chatBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            if let error = chat.error, chat.current?.messages.last?.text != error {
                Text(error).font(Fonts.hint).foregroundStyle(Theme.ink2)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let blocked = model.chatBlockedReason, case .input = mode {
                    // Why sending is not possible right now, directly under the button.
                    Text(blocked).font(Fonts.hint).foregroundStyle(Theme.ink2).lineLimit(3)
                    KnowledgeStatus(model: model, showsText: false)
                } else if model.learningText != nil {
                    KnowledgeStatus(model: model, showsText: true)
                } else if let status = workspaceStatus.nonEmpty {
                    Text(status).font(Fonts.hint).foregroundStyle(Theme.ink3).lineLimit(2)
                }
            }
        }.padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 10)
    }
}

/// Under the input field while Pippa's knowledge is missing: while loading a real bar with percent and time left,
/// without consent ("Later") the same "Load now" path as in the welcome, on network problems "Try again".
struct KnowledgeStatus: View {
    @ObservedObject var model: AppModel
    /// `false`: the reason is already shown above (sending blocked), only bar or button here.
    var showsText: Bool

    var body: some View {
        if let progress = model.progressValue, !model.downloadStalled {
            HStack(spacing: 10) {
                ThinProgress(value: progress, height: 4).frame(width: 96)
                    .accessibilityLabel(T("Pippa is loading her knowledge", table: "Settings"))
                    .accessibilityValue(T("%lld%%", table: "Settings", Int((progress * 100).rounded())))
                if showsText, let text = model.learningText {
                    Text(text).font(Fonts.hint.monospacedDigit()).foregroundStyle(Theme.ink3).lineLimit(1)
                }
            }
        } else if model.needsDownloadConsent || model.downloadStalled {
            HStack(spacing: 10) {
                if showsText, let text = model.learningText {
                    Text(text).font(Fonts.hint).foregroundStyle(Theme.ink3).lineLimit(2)
                }
                if model.needsDownloadConsent {
                    Button(T("Load Now", table: "Settings")) { model.startModelDownload() }.pippa(.tinted)
                        .help(T("Pippa loads her knowledge once. After that, everything runs on your Mac.", table: "Settings"))
                } else {
                    Button(T("Try Again", table: "Settings")) { model.retryDownloadNow() }.pippa(.quiet)
                }
            }
        } else if showsText, let text = model.learningText {
            Text(text).font(Fonts.hint).foregroundStyle(Theme.ink3).lineLimit(2)
        }
    }
}
