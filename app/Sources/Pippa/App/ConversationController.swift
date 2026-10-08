import AppKit
import Combine
import PiRPC
import PippaCore

/// UI history and running answer. The agent history stays with the Pi core;
/// files, context and visible messages belong to the respective conversation.
@MainActor
final class ConversationController: ObservableObject {
    @Published private(set) var current: Conversation?
    @Published private(set) var history: [ConversationSummary] = []
    @Published private(set) var isRunning = false
    @Published private(set) var streamingText = ""
    @Published private(set) var error: String?
    /// Thought Line: what Pippa is actually doing for the running answer (PippaCore/ThoughtLine.swift).
    @Published private(set) var thought = ThoughtLine()
    /// Receipts opened to show what was read (view state only, not saved).
    @Published private(set) var expandedReceipts: Set<UUID> = []
    /// An undo (one line or "Undo all") is running: the buttons are off meanwhile.
    @Published private(set) var isUndoing = false
    /// Pi wants to look something up online; the card shows exactly what would go out and waits for the click.
    @Published private(set) var webAsk: WebAccessAsk?
    private var webAskReply: CheckedContinuation<Bool, Never>?
    /// The guard asks before Pi changes something; the card waits in the conversation instead of a window.
    @Published private(set) var guardAsk: GuardAsk?
    private var guardAskReply: CheckedContinuation<PiUIResponse, Never>?
    /// Brings the conversation into view when a card needs the person (set by AppModel).
    var onNeedsPerson: (() -> Void)?
    private var webGate: WebAccessGate?
    /// One lookup process for all conversations (exits by itself after two minutes idle).
    private let webFetcher = WebFetcher()
    private var lastAnnouncedKind: String?
    private var lastAnnouncement: Date?
    private var store: ConversationStore?
    private var request: Task<Void, Never>?
    private var requestID: UUID?
    /// Who writes the running answer (Pi, or a stand-in in debug captures).
    private var runningChat: (any ConversationChat)?
    /// "Stop" pressed: the partial answer stays, marked as stopped rather than as an error.
    private var stopRequested = false

    /// Written during an answer or file task: comes up next. `handedToPi`: Pi reads it along after the current
    /// step (steering); otherwise AppModel sends it as its own message after the work.
    struct Queued: Identifiable, Equatable { let id = UUID(); let text: String; var handedToPi = false }
    @Published private(set) var queued: [Queued] = []
    /// Currently on its way to Pi; only one at a time so the order is right.
    @Published private(set) var steering: UUID?
    /// Pi did not accept a message in this answer: it and all after it wait until after the answer.
    private var heldBack = false

    init() {
        do {
            // Developer captures do not change any real history.
            let directory = DevEnvironment.value("PIPPA_SNAPSHOT").map { URL(fileURLWithPath: $0).appendingPathComponent("conversations") }
                ?? Pippa.supportDirectory.appendingPathComponent("Conversations")
            let store = try ConversationStore(directory: directory)
            self.store = store
            current = try store.selectedID.map { try store.load($0) } ?? store.create()
            refresh()
            if store.setAside != nil {
                append(.system, T("I couldn’t read the earlier conversation history. I kept a copy of it and I’m starting fresh here.", table: "App"))
            }
        } catch { self.error = UserMessage.text(for: error, context: "gespraech") }
    }

    /// Deletes a conversation together with its agent history. If it was open, continues with the next (or a new one).
    func delete(_ id: UUID) {
        guard !isRunning, let store else { return }
        do {
            let removed = try store.load(id)
            try store.delete(id)
            let keys = [id.uuidString] + ((removed.retiredModelSessionRevisions ?? []) + (removed.modelSessionRevision.map { [$0] } ?? []))
                .map { id.uuidString + ":" + $0.uuidString }
            // Pi's session files go to the trash instead of being deleted for good (PiRPCChat.forget).
            let chat = PiRPCChat.conversation
            Task { await chat.forget(keys) }
            if current?.id == id {
                current = try store.list(limit: 1).first.map { try store.select($0.id) } ?? store.create()
                error = nil; streamingText = ""
            }
            refresh()
        } catch { self.error = UserMessage.text(for: error, context: "gespraech") }
    }

    func newConversation() {
        guard !isRunning, let store else { return }
        do { current = try store.create(); error = nil; streamingText = ""; refresh() }
        catch { self.error = UserMessage.text(for: error, context: "gespraech") }
    }

    func select(_ id: UUID) {
        guard !isRunning, let store else { return }
        do { current = try store.select(id); error = nil; streamingText = ""; refresh() }
        catch { self.error = UserMessage.text(for: error, context: "gespraech") }
    }

    func setContext(name: String, files: [URL], selectedText: String?, focusedFiles: [URL]? = nil, announce: Bool = true, addingFiles: [URL] = []) {
        guard !isRunning, let store, let current else { return }
        let bookmarks = ConversationContext.bookmarks(for: files, existing: current.context?.bookmarks ?? [], resolve: { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }, make: { url in
            try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        })
        var pending = ConversationPromptAttachments.pendingFiles(in: current).filter { files.contains($0) }
        for url in files where !(current.context?.files.contains(url) ?? false) { if !pending.contains(url) { pending.append(url) } }
        for url in addingFiles where files.contains(url) && !pending.contains(url) { pending.append(url) }
        do {
            self.current = try store.setContext(ConversationContext(name: name, files: files, selectedText: selectedText, bookmarks: bookmarks, focusedFiles: focusedFiles, pendingFiles: pending), for: current.id)
            if announce { append(.system, T("Added: %@", table: "App", name)) }
            else { refresh() }
        } catch { self.error = UserMessage.text(for: error, context: "gespraech") }
    }

    func clearContext() {
        guard !isRunning, let store, let current else { return }
        do { self.current = try store.setContext(nil, for: current.id); refresh() }
        catch { self.error = UserMessage.text(for: error, context: "gespraech") }
    }

    func append(_ role: ConversationMessage.Role, _ text: String, attachments: [URL] = [], modelLabel: String? = nil, stopped: Bool = false, notice: Bool = false,
                previousConversation: UUID? = nil, receipt: UUID? = nil, draft: Bool = false, mailDraft: ConversationMailDraft? = nil, capturingAttachments: Bool = false,
                calendar: ConversationCalendarRead? = nil, work: WorkReceipt? = nil, actions: ActionReceipt? = nil) {
        guard let store, let current, !text.isEmpty else { return }
        do {
            if role == .user && !current.messages.contains(where: { $0.role == .user }) {
                _ = try store.rename(current.id, title: String(text.prefix(60)))
            }
            self.current = try store.append(ConversationMessage(role: role, text: text, attachments: attachments, modelLabel: modelLabel,
                                                                stopped: stopped, notice: notice, previousConversation: previousConversation,
                                                                receipt: receipt, draft: draft, mailDraft: mailDraft, calendar: calendar, work: work, actions: actions), to: current.id, capturingAttachments: capturingAttachments)
            refresh()
        } catch { self.error = UserMessage.text(for: error, context: "gespraech") }
    }

    @discardableResult func updateMailDraft(messageID: UUID, draft: ConversationMailDraft) -> Bool {
        guard let id = current?.id else { return false }
        return updateMailDraft(messageID: messageID, in: id, draft: draft)
    }

    /// Completion remains bound to the originating topic even if the user has switched chats.
    @discardableResult func transitionMailDraft(messageID: UUID, in conversationID: UUID,
                                                to state: ConversationMailDraft.State) -> Bool {
        guard let store else { return false }
        do {
            let conversation = try store.load(conversationID)
            guard var draft = conversation.messages.first(where: { $0.id == messageID })?.mailDraft else { return false }
            draft.state = state
            return updateMailDraft(messageID: messageID, in: conversationID, draft: draft)
        } catch { self.error = UserMessage.text(for: error, context: "gespraech"); return false }
    }

    @discardableResult private func updateMailDraft(messageID: UUID, in conversationID: UUID,
                                                    draft: ConversationMailDraft) -> Bool {
        guard let store else { return false }
        do {
            let updated = try store.updateMailDraft(messageID: messageID, in: conversationID, draft: draft)
            if current?.id == conversationID { current = updated }
            error = nil
            refresh()
            return true
        } catch { self.error = UserMessage.text(for: error, context: "gespraech"); return false }
    }

    /// `skill`: explicitly chosen skill; only `text` appears in the history, Pi gets the instructions.
    /// `chat`: who answers (default: `PiRPCChat.conversation`; debug captures pass a stand-in).
    func send(_ text: String, chat: (any ConversationChat)? = nil, workflowSummary: String = "", modelLabel: String? = nil,
              skill: PippaSkill? = nil) {
        let chat = chat ?? PiRPCChat.conversation
        guard !isRunning, let id = current?.id, store != nil else { return }
        error = nil
        append(.user, text, capturingAttachments: true)
        guard error == nil else { return }
        let context = current?.context
        // What is newly shown with this message is spelled out in Pi's message.
        let newFiles = current?.messages.last(where: { $0.role == .user })?.attachments ?? []
        let sessionID = current?.modelSessionRevision.map { id.uuidString + ":" + $0.uuidString } ?? id.uuidString
        isRunning = true
        stopRequested = false
        heldBack = false
        streamingText = ""
        runningChat = chat
        let requestID = UUID()
        self.requestID = requestID
        thought.begin(requestID, at: Date())
        lastAnnouncedKind = nil; lastAnnouncement = nil
        // Phase events arrive from any thread; one ordered stream keeps their order, the request ID drops late ones.
        let (workEvents, workSink) = AsyncStream<WorkEvent>.makeStream()
        let phases = Task { [weak self] in
            for await event in workEvents {
                guard let self, self.isRunning, self.current?.id == id, self.requestID == requestID else { continue }
                if event == .phase(.writing), self.thought.phase == .writing { continue }
                if self.thought.apply(event, request: requestID, at: Date()) { self.announcePhase() }
            }
        }
        request = Task { [weak self] in
            var scoped: [URL] = []
            defer {
                self?.endWebAccess()
                self?.endGuardAsk()
                workSink.finish(); phases.cancel()
                self?.thought.end(request: requestID)
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                // What Pi no longer accepted goes out afterwards as its own message (AppModel.sendQueued).
                if let self { for i in self.queued.indices { self.queued[i].handedToPi = false } }
                self?.isRunning = false
                self?.runningChat = nil
            }
            var urls = context?.files ?? []
            if let bookmarks = context?.bookmarks, !bookmarks.isEmpty {
                for data in bookmarks {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                        if url.startAccessingSecurityScopedResource() { scoped.append(url) }
                        if !urls.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) { urls.append(url) }
                    }
                }
            }
            // Resolve host-captured mail provenance while the original source lease is open.
            // Generated text can never select or replace the original message identity.
            let mailFiles = urls.filter { ["eml", "emlx"].contains($0.pathExtension.lowercased()) }
            let focusedMail = mailFiles.filter { context?.focusedFiles?.contains($0) == true }
            let replyCandidates = focusedMail.isEmpty ? mailFiles : focusedMail
            let replySource: MailReplySource? = replyCandidates.count == 1 ? MailReplySource.capture(from: replyCandidates[0]) : nil
            var chatContext = ChatContext(files: urls, focusedFiles: context?.focusedFiles ?? [], selectedText: context?.selectedText ?? "", workflowSummary: workflowSummary)
            chatContext.onWork = { event in workSink.yield(event) }
            // Pi may look things up online, also with skills (Pi always has `web_search`; the card is the boundary,
            // not the button). Each single query only after the click on the card.
            if let self {
                // A shown link (selected text) counts as typed by the person.
                let typed = text + "\n" + (context?.selectedText ?? "")
                let gate = WebAccessGate(fetcher: self.webFetcher, typed: typed) { [weak self] ask in
                    workSink.yield(.phase(.waitingForPerson))
                    let approved = await self?.awaitWebAsk(ask, request: requestID) ?? false
                    if approved { workSink.yield(.phase(.lookingUpOnline)) }
                    return approved
                }
                self.webGate = gate
                chatContext.web = gate
            }
            do {
                // The real Pi via `pi --mode rpc` (PiRPCChat), a stand-in in debug captures (ConversationChat).
                let onDelta: @Sendable (String) -> Void = { [weak self] delta in
                        // Through the same ordered stream as the phases: a tool that ended before this text cannot
                        // bring the line back after it.
                        if !delta.isEmpty { workSink.yield(.phase(.writing)) }
                        Task { @MainActor [weak self] in
                            guard let self, self.isRunning, !self.stopRequested, self.current?.id == id, self.requestID == requestID else { return }
                            self.streamingText += delta
                        }
                    }
                let onSteered: @Sendable (String) -> Void = { [weak self] before in
                        Task { @MainActor [weak self] in
                            guard let self, self.isRunning, !self.stopRequested, self.current?.id == id, self.requestID == requestID else { return }
                            self.steered(answerSoFar: before, modelLabel: modelLabel)
                        }
                    }
                // With what was shown, source checking and looking things up online (PiRPCChat+Shown.swift); skills.
                let answer = try await chat.answer(text, taskID: sessionID, context: chatContext, newFiles: newFiles, skill: skill,
                                                   draftOnly: false, onDelta: onDelta, onSteered: onSteered, onReset: nil).text
                guard let self, self.current?.id == id, self.requestID == requestID else { return }
                // Some engines finish normally after cancellation. Preserve only
                // the text accepted before Stop, never a completed draft or plan.
                if self.stopRequested || Task.isCancelled { throw CancellationError() }
                let work = self.thought.finish(request: requestID, at: Date())
                // "What happened" from tool events and guard, never from the answer text.
                let actions = chat.takeShownActions()
                self.append(.assistant, answer, modelLabel: modelLabel, draft: skill?.writesDraft == true,
                            mailDraft: skill?.name == "antwort-schreiben" ? ConversationMailDraft(
                                to: replySource.flatMap { MailAddress.parse($0.replyTo ?? "").address } ?? "",
                                subject: replySource.map { MailDraft(messageID: $0.messageID, to: nil, toName: nil, subject: $0.subject, body: "").replySubject } ?? "",
                                body: answer, replySource: replySource, requiresOriginalReply: !mailFiles.isEmpty) : nil, work: work, actions: actions)
                self.streamingText = ""
                // VoiceOver: announce the finished answer once (not every streamed piece).
                NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: "Pippa: " + answer, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            } catch {
                guard let self, self.current?.id == id, self.requestID == requestID else { return }
                var partial: String?
                // Also when stopped or failed: what tools did until then is shown with it.
                let actions = chat.takeShownActions()
                if case AnswerFailure.stopped(let text) = error { partial = text }
                else if self.stopRequested || Task.isCancelled { partial = self.streamingText }
                if let partial {
                    // Stopped is not an error: what was already written stays.
                    if partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.append(.system, T("Answer stopped. You can pick up from here.", table: "App"), actions: actions)
                    } else {
                        self.append(.assistant, partial, modelLabel: modelLabel, stopped: true, actions: actions)
                    }
                } else {
                    self.error = PiRPCChat.userText(for: error, context: "gespraech")
                    self.append(.system, PiRPCChat.userText(for: error, context: "antwort"), notice: true, actions: actions)
                }
                self.streamingText = ""
            }
        }
        steerNext()
    }

    /// Queues a message. If an answer is running, Pi gets it right after the current step.
    func enqueue(_ text: String) {
        queued.append(Queued(text: text))
        steerNext()
    }

    /// Take back a queued message as long as Pi doesn't have it yet.
    func removeQueued(_ id: UUID) {
        queued.removeAll { $0.id == id && !$0.handedToPi && steering != id }
    }

    /// Next queued message to send after the work (not during an answer).
    func takeQueued() -> String? {
        guard !isRunning, steering == nil, !queued.isEmpty else { return nil }
        return queued.removeFirst().text
    }

    /// Everything queued goes back (after "Stop"): returns to the input field instead of being lost.
    func takeAllQueued() -> [String] {
        let texts = queued.map(\.text)
        queued = []
        return texts
    }

    /// Hands the next queued message to the running answer, in order.
    private func steerNext() {
        guard isRunning, !stopRequested, !heldBack, steering == nil, let chat = runningChat,
              let next = queued.first(where: { !$0.handedToPi }) else { return }
        steering = next.id
        Task { [weak self] in
            let accepted = await chat.steer(next.text)
            guard let self else { return }
            self.steering = nil
            if accepted, self.isRunning, let i = self.queued.firstIndex(where: { $0.id == next.id }) { self.queued[i].handedToPi = true }
            else if !accepted { self.heldBack = true }
            self.steerNext()
        }
    }

    /// Pi has taken up the next follow-up message: the answer up to here comes before it, the message is in the history,
    /// and what comes now is the answer to it.
    private func steered(answerSoFar: String, modelLabel: String?) {
        if let request = requestID { thought.steered(request: request) }
        if !answerSoFar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { append(.assistant, answerSoFar, modelLabel: modelLabel) }
        if let i = queued.firstIndex(where: { $0.handedToPi || $0.id == steering }) { append(.user, queued.remove(at: i).text) }
        streamingText = ""
    }

    /// Asks the core to stop; the answer then ends with the text written so far.
    /// If the cancel doesn't get through, the task is killed after 5 s.
    func stop() {
        guard isRunning else { return }
        stopRequested = true
        endWebAccess()
        endGuardAsk()
        if let request = requestID { thought.stop(request: request); announcePhase() }
        if let chat = runningChat { Task { await chat.cancel() } }
        let running = request
        Task { try? await Task.sleep(for: .seconds(5)); running?.cancel() }
    }

    /// Shows the card and waits for the person. Only for the running answer; otherwise immediately "Not now".
    private func awaitWebAsk(_ ask: WebAccessAsk, request: UUID) async -> Bool {
        guard isRunning, !stopRequested, requestID == request else { return false }
        webAskReply?.resume(returning: false)
        webAsk = ask
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: T("Look it up online:", table: "App") + " " + ask.shown,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        return await withCheckedContinuation { continuation in webAskReply = continuation }
    }

    /// "Look it up" or "Not now" on the card. Applies to exactly this one query.
    func answerWebAsk(_ id: UUID, approved: Bool) {
        guard webAsk?.id == id else { return }
        webAsk = nil
        let reply = webAskReply
        webAskReply = nil
        reply?.resume(returning: approved)
    }

    /// A guard question during the running answer: card, VoiceOver, conversation in view, then wait. `nil` when no
    /// answer is running (the caller asks with a prompt window instead) or the question has no buttons.
    func awaitGuardAsk(_ request: PiUIRequest) async -> PiUIResponse? {
        guard isRunning, !stopRequested, let ask = GuardAsk(request) else { return nil }
        guardAskReply?.resume(returning: .cancelled)
        guardAsk = ask
        onNeedsPerson?()
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: ask.title + " " + ask.sentence,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        return await withCheckedContinuation { continuation in guardAskReply = continuation }
    }

    #if DEBUG
    /// Dev snapshot only: the card as during a running answer.
    func showGuardAskForSnapshot(_ ask: GuardAsk) { isRunning = true; guardAsk = ask }
    #endif

    func answerGuardAsk(_ id: UUID, _ response: PiUIResponse) {
        guard guardAsk?.id == id else { return }
        guardAsk = nil
        let reply = guardAskReply
        guardAskReply = nil
        reply?.resume(returning: response)
    }

    /// Answer over or stopped: an open question counts as not allowed.
    private func endGuardAsk() {
        guardAsk = nil
        let reply = guardAskReply
        guardAskReply = nil
        reply?.resume(returning: .cancelled)
    }

    /// Answer over or stopped: an open card counts as "Not now", and the gate lets nothing more out.
    private func endWebAccess() {
        webAsk = nil
        let reply = webAskReply
        webAskReply = nil
        reply?.resume(returning: false)
        if let gate = webGate { Task { await gate.cancel() } }
        webGate = nil
    }

    /// "Undo" on a receipt line from the Pi path: replay the guard entry natively (PiUndo, same
    /// rules as restore.mjs); the result appears as a new receipt line in the history, never as model text.
    func undoAction(_ item: ActionReceipt.Item) {
        guard !isRunning, !isUndoing, item.canUndo else { return }
        isUndoing = true
        let root = PiRPCChat.undoRoot
        Task { [weak self] in
            // Event or reminder via Pippa's MCP server; removes only what is unchanged since it was created.
            let line = await PiUndo.undo(item, root: root) { created in try await PippaMCPService.remove(created) }
            DiagnosticsLog.shared.event("pi-rueckgaengig", ["status": line.outcome])
            self?.isUndoing = false
            self?.append(.system, T("Undo", table: "App"), actions: ActionReceipt(items: [line]))
        }
    }

    /// "Undo all" under an answer with at least two replayable lines: all from bottom to top,
    /// one result line per step in one message (what didn't work is noted).
    func undoAll(_ receipt: ActionReceipt) {
        guard !isRunning, !isUndoing, receipt.offersUndoAll else { return }
        isUndoing = true
        let root = PiRPCChat.undoRoot
        Task { [weak self] in
            let lines = await PiUndo.undoAll(receipt, root: root) { created in try await PippaMCPService.remove(created) }
            DiagnosticsLog.shared.event("pi-alles-rueckgaengig", ["zeilen": String(lines.count),
                                                                 "fehler": String(lines.filter { $0.outcome != "done" }.count)])
            self?.isUndoing = false
            self?.append(.system, T("Undo All", table: "App"), actions: ActionReceipt(items: lines))
        }
    }

    /// "Open draft" on a mail draft from the Pi path: bring Mail to the front (the reply window is open there,
    /// the saved draft is under "Drafts"). Never deletes anything.
    func openMailDraft() {
        Task { await PippaMCPService.showMail() }
    }

    /// "As draft in Mail" under an answer without a draft. First mark as used (no double click),
    /// then create; the result appears as its own receipt line in the history. If it failed, the button is back.
    func saveMailOffer(messageID: UUID) {
        guard !isRunning, let store, let conversationID = current?.id,
              var offer = current?.messages.first(where: { $0.id == messageID })?.actions?.mailOffer, offer.canSave else { return }
        offer.used = true
        do {
            let updated = try store.updateMailOffer(messageID: messageID, in: conversationID, offer: offer)
            if current?.id == conversationID { current = updated }
        } catch { self.error = UserMessage.text(for: error, context: "gespraech"); return }
        Task { [weak self] in
            let (item, missing) = await PippaMCPService.saveDraft(offer)
            DiagnosticsLog.shared.event("entwurf-angebot", ["ergebnis": item.outcome, "grund": item.reason ?? "-"])
            guard let self else { return }
            if missing {
                // The mail is no longer in Mail: no fallback to the selection, "Copy text" instead.
                offer.missing = true
                if let updated = try? store.updateMailOffer(messageID: messageID, in: conversationID, offer: offer), self.current?.id == conversationID {
                    self.current = updated
                }
            } else if item.outcome == "failed" {
                offer.used = false
                if let updated = try? store.updateMailOffer(messageID: messageID, in: conversationID, offer: offer), self.current?.id == conversationID {
                    self.current = updated
                }
            }
            if self.current?.id == conversationID {
                self.append(.system, T("Draft in Mail", table: "App"), actions: ActionReceipt(items: [item]))
            }
        }
    }

    /// "Copy text" when the offer's mail is no longer in Mail.
    func copyMailOffer(messageID: UUID) {
        guard let offer = current?.messages.first(where: { $0.id == messageID })?.actions?.mailOffer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(offer.body, forType: .string)
    }

    func toggleReceipt(_ messageID: UUID) {
        if expandedReceipts.remove(messageID) == nil { expandedReceipts.insert(messageID) }
    }

    /// VoiceOver hears a new kind of activity politely, never every page or second (ThoughtLine.shouldAnnounce).
    private func announcePhase() {
        guard let phase = thought.phase else { return }
        let now = Date()
        guard ThoughtLine.shouldAnnounce(phase, lastKind: lastAnnouncedKind, lastAnnouncement: lastAnnouncement, now: now) else { return }
        lastAnnouncedKind = phase.kind; lastAnnouncement = now
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: phase.title, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }

    /// For tray cleanup: what conversations still have attached.
    var contextFiles: [URL] { store?.contextFiles() ?? [] }

    private func refresh() { history = store?.list() ?? [] }
}
