import AppKit
import UniformTypeIdentifiers
import PiRPC
import PippaCore

/// One step Pi took while answering (a tool call), shown as a quiet line under the answer.
struct ChatStep: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var done = false
    var failed = false
    /// When the step started and ended; older conversations have neither.
    var started: Date?
    var ended: Date?

    /// How long the step took, once it ended.
    var duration: TimeInterval? {
        guard let started, let ended else { return nil }
        return max(0, ended.timeIntervalSince(started))
    }
}

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var files: [String] = []
    var steps: [ChatStep] = []
    var cards: [ResultCard] = []
    var receipts: [PippaMCPWriteReceipt] = []
    /// Answer: the receipt for all its journaled changes (the run journal), with one Undo for the whole answer. Set
    /// when the answer starts, so a crash mid-answer still shows its unclear changes at the next start.
    var run: RunSummary?
    /// The model's reasoning before it answered (local models think first); shown folded.
    var thinking: String?
    /// Dates in the answer that nothing Pippa read shows (`DateEvidence`); named under the answer.
    var unsupportedDates: [String]?
    /// Dates in the answer that a source shows.
    var checkedDates: [String]?
    /// What the answer read, from its tool calls.
    var sources: [ChatSource]?
    /// How full the conversation's context was afterwards.
    var context: ContextUsage?
    var error: String?
    /// Characters of `text` written before the last tool call: what she said on the way ("I'll read chapter 6 now").
    /// The island shows only what follows, the result; the chat shows all of it.
    var lead: Int?
    /// How long the answer took, for "Worked for 18 s".
    var duration: TimeInterval?
    /// The person stopped the answer.
    var stopped: Bool?
    /// Answer: what its tools read on this Mac, from the tools' own names (`SharingSource.read(byTool:)`). `nil` in
    /// answers saved before 0.8: their origin is unknown.
    var provenance: [SharingSource]?
    /// Answer: the online AI that wrote it. Question: the online AI it went to. `nil`: the AI on this Mac.
    var destination: String?
    /// Question: the parts the person checked and shared with `destination` ("Lease.pdf", "Calendar, next 7 days").
    var shared: [String]?
    /// Answer: the online AI stayed at its limit after all of Pi's tries. From this time on, Continue picks the answer
    /// up in the same Pi session (`ChatModel.resume`).
    var resumeAfter: Date?
    /// The Pi session that answer ran in (`PiSession.resumeScope`): Continue only while typed words still go there.
    var resumeScope: String?
}

/// The review before anything from the Mac goes to an online AI: the provider, the person's words and each part Pippa
/// read on this Mac, editable, and what stays here. Nothing is sent until the person presses Send. Its lifecycle
/// (cancel, switching conversations, a failed send) is `ShareDesk`.
typealias ShareReview = ShareDraft

extension ChatMessage {
    /// What she found, without what she said on the way there: the text after the last tool call, or all of it when
    /// nothing came after.
    var result: String {
        guard let lead, lead > 0, lead < text.count else { return text }
        let after = String(text.dropFirst(lead)).trimmingCharacters(in: .whitespacesAndNewlines)
        return after.isEmpty ? text : after
    }
}

struct Conversation: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var updated: Date
    var messages: [ChatMessage]
    var pinned: Bool?
    /// Sources still in the local Pi history after Retry replaces a visible turn.
    var retriedSources: [SharingSource]?

    @MainActor mutating func removeTurnForRetry() {
        let prior = ChatModel.localHistorySources(in: messages.suffix(2))
        retriedSources = Set(retriedSources ?? []).union(prior).sorted()
        messages.removeLast(2)
    }

    @MainActor func localSources(through index: Int) -> Set<SharingSource> {
        ChatModel.localHistorySources(in: messages[...index]).union(retriedSources ?? [])
    }

}

/// The chat: conversations on disk (what the window shows), one answer at a time through `PiSession`.
/// Pi keeps the model's side of each conversation in its own session file.
@MainActor
final class ChatModel: ObservableObject {
    static let shared = ChatModel()

    @Published var conversations: [Conversation] = []
    @Published var currentID: String?
    private var composers: [String: ShareComposer] = [:]
    var hasReviewHere: Bool {
        review != nil || desk.parked(in: currentID, handoff: false) != nil || desk.parked(in: currentID, handoff: true) != nil
    }
    @Published var draft = ""
    @Published var attachments: [URL] = []
    /// The app that was in front when Pippa was called ("Mail"), told to Pi with the next question so "this mail"
    /// works; Pi reads it with `front_read`. Not shown: most questions have nothing to do with it.
    var frontApp: String?
    /// An answer came in or failed while the chat window was not in front: Pippa Island says so for a moment, the menu
    /// bar symbol and the Dock badge until the chat opens.
    @Published var unseen: Unseen?
    enum Unseen { case answer, failed }
    @Published private(set) var isAnswering = false
    /// The conversation the running answer belongs to. The person may look at another one meanwhile.
    @Published private(set) var answeringID: String?
    /// Conversations whose answer arrived while the person looked at another one: a dot in the sidebar.
    @Published private(set) var unseenIDs: Set<String> = []
    /// What the current answer read, for its dates; the person's follow-ups while it runs count as what they said.
    private(set) var evidence = DateEvidence()
    /// The answer the running turn writes into now: its first reply, or the reply after the person's latest follow-up
    /// (`steered`). `nil` when nothing runs.
    private var activeReplyID: UUID?
    /// A follow-up is on its way to Pi (`steer`): a second Return never sends it twice.
    @Published private(set) var isSteering = false
    /// Sources of tool calls that have started but not ended.
    private var pendingSources: [String: ChatSource] = [:]
    /// Running steps that reported progress: their label without it. Notes files of running reads, by call.
    private var stepLabels: [String: String] = [:]
    private var pendingNotes: [String: String] = [:]
    /// When the running answer started, for the live "Thinking … 12 s".
    @Published private(set) var answerStarted: Date?
    /// The AI on this Mac is starting or loading into memory before the question goes out (shown once it takes a moment).
    @Published private(set) var startingAI = false
    private var startingTask: Task<Void, Never>?
    /// Words of the answer are coming in right now. Text already there says nothing about it: after a first sentence
    /// Pippa often thinks or reads on.
    @Published private(set) var isWriting = false
    /// Pi waits before it tries the online AI again, with the seconds left, counted down once a second.
    @Published var retryWait: RetryWait?
    var retryTick: Task<Void, Never>?
    private var answer: Task<Void, Never>?
    private var pdfTask: Task<Void, Never>?
    /// "Stop" was pressed for the running answer.
    var stopRequested = false
    /// Counts answers, so a late result of an earlier one never lands on a newer one.
    private var generation = 0
    /// The review open while the person checks what goes to an online AI, and the ones parked with their edits.
    /// Changed only by the sharing methods (`ChatModel+Sharing.swift`).
    @Published var desk = ShareDesk()
    /// Open while the person checks what goes to an online AI (`ShareReview`). Set directly only by snapshots.
    var review: ShareReview? {
        get { desk.open }
        set { desk.present(newValue) }
    }

    private static var folder: URL { Pippa.supportDirectory.appendingPathComponent("conversations", isDirectory: true) }
    /// Reading and writing conversation files, away from the window.
    private let store = ConversationStore(folder: ChatModel.folder)
    /// The saved conversations have been read (the sidebar says "nothing here" only after that).
    @Published private(set) var isLoaded = false
    /// Saved conversation files (or their folder) that could not be read: the sidebar says so instead of "nothing here".
    @Published private(set) var unreadable = 0
    /// Snapshots show sample conversations: the saved ones, read later, must not join them.
    private var showsSample = false
    private var terminateWatch: NSObjectProtocol?

    var current: Conversation? { conversations.first { $0.id == currentID } }
    /// The conversation with the running answer (not necessarily the one on screen).
    var answering: Conversation? { answeringID.flatMap { id in conversations.first { $0.id == id } } }
    /// The running answer belongs to the conversation on screen (Stop shows there, not elsewhere).
    var isAnsweringHere: Bool { isAnswering && (answeringID == nil || answeringID == currentID) }

    init() {
        load()
        // Quitting waits for the last writes, so an answer that just ended is on disk.
        let store = self.store
        terminateWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                object: nil, queue: nil) { _ in store.flush() }
    }

    // MARK: Conversations

    func newConversation() {
        if let current, current.messages.isEmpty && !hasReviewHere { return }
        if let currentID { saveComposer(for: currentID) }
        desk.select(nil)
        currentID = nil
        // The app in front belonged to the question being written; it never moves into another conversation.
        draft = ""; attachments = []; frontApp = nil
    }

    private func saveComposer(for id: String) {
        let composer = ShareComposer(text: draft, files: attachments)
        composers[id] = composer.isEmpty ? nil : composer
    }

    /// Opening an Island result carries ordinary unsent input. A reviewed draft always belongs to its source chat.
    func select(_ id: String, carryingIslandDraft: Bool = false) {
        if currentID != id {
            let carry = carryingIslandDraft && !hasReviewHere && (!draft.isEmpty || !attachments.isEmpty)
            if let currentID {
                if carry { composers[currentID] = nil } else { saveComposer(for: currentID) }
            }
            desk.select(id)
            currentID = id
            if !carry {
                let saved = composers.removeValue(forKey: id)
                draft = saved?.text ?? ""; attachments = saved?.files ?? []
                // Switching from Pippa Island keeps the app-in-front context captured when the island opened.
                if !carryingIslandDraft { frontApp = nil }
            }
        }
        unseenIDs.remove(id)
    }

    func delete(_ id: String) {
        guard !isAnswering || id != answeringID else { return }
        cancelTitleRefinement(for: id)
        unseenIDs.remove(id)
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = nil; draft = ""; attachments = [] }
        composers[id] = nil
        undoneNotes[id] = nil
        desk.forget(id)
        store.trash(id)
        Task { await PiSession.shared.forget(id) }
    }

    func rename(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        cancelTitleRefinement(for: id)
        conversations[index].title = String(title.prefix(80))
        save(id)
    }

    func togglePin(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned = conversations[index].pinned == true ? nil : true
        save(id)
    }

    // MARK: Undo

    /// Receipts being undone right now (message id, receipt index): the button stays disabled meanwhile.
    @Published var undoing: Set<String> = []
    /// Conversation id → what the person undid that Pi has not heard of yet; told with the next question.
    var undoneNotes: [String: [String]] = [:]

    // MARK: Asking

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAnswering, review == nil, !text.isEmpty || !attachments.isEmpty else { return }
        problem = nil
        // An online AI answers: typed words go as they are; files only after the review (issue #193). The app in front
        // and earlier undos are notes for the AI on this Mac and stay here. One the person allowed Mac access (issue #196)
        // gets what the AI on this Mac gets; PiSession checks that again before anything goes out.
        let settings = SettingsModel.shared.inferenceSettings
        let destination = ShareDestination.active(settings)
        let limited = destination != nil && !settings.allowsMacAccess(destination)
        let files = attachments.map(\.path)
        let id = currentID ?? UUID().uuidString.lowercased()
        guard let outgoing = Self.outgoing(text, files: files, frontApp: frontApp, undone: limited ? [] : undoneNotes[id] ?? [],
                                           online: limited) else {
            if let destination { startReview(destination, handoff: false) }
            return
        }
        if !limited { undoneNotes[id] = nil }
        draft = ""; attachments = []; frontApp = nil
        ask(text, files: limited ? [] : files, outgoing: outgoing, destination: destination?.label)
    }

    /// The person may send a short follow-up into the answer running here: typed words only, no files, no review, no
    /// PDF, and only while Pi's turn takes one (`PiSession.canSteer`: not a single question, an approved message or a
    /// turn after the settings changed).
    var canSteerHere: Bool {
        isAnsweringHere && !isSteering && review == nil && attachments.isEmpty && pdfTask == nil && PiSession.shared.canSteer
    }

    /// Sends the draft into the running answer; Pi reads it after its current step and it shows as the person's message
    /// (`steered`). Refused by Pi: the words go back into the composer, if nothing new was typed meanwhile.
    func steer() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSteerHere, !text.isEmpty else { return }
        let targetID = answeringID ?? currentID
        isSteering = true
        draft = ""
        Task {
            let accepted = await PiSession.shared.steer(text)
            isSteering = false
            if !accepted { restoreDraft(text, to: targetID) }
        }
    }

    /// Returns undelivered follow-up text to `targetID`'s composer when nothing newer was typed there.
    func restoreDraft(_ text: String, to targetID: String?) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if currentID == targetID {
            if draft.isEmpty { draft = cleaned }
        } else if let targetID, composers[targetID] == nil {
            composers[targetID] = ShareComposer(text: cleaned, files: [])
        }
    }

    /// What goes to Pi for the composer's content: everything for the AI on this Mac; for an online AI only typed words,
    /// and `nil` (review first) as soon as files are attached. The app in front and undo notes never go online.
    static func outgoing(_ text: String, files: [String], frontApp: String?, undone: [String], online: Bool) -> PiSession.Outgoing? {
        guard online else { return .local(prompt(text, files: files, frontApp: frontApp, undone: undone)) }
        return files.isEmpty ? .typed(text) : nil
    }

    /// One question and its answer, in `conversation` (the one shown when `nil`). `destination`: the online AI it goes to
    /// (shown on both). `review`: the approved review it came from; if the answer fails, refused or mid-way, the review is
    /// parked there with its edits and its words go back only into an empty composer (`ShareDesk.failed`), never resent.
    func ask(_ text: String, files: [String], outgoing: PiSession.Outgoing, in conversation: String? = nil, handoff: Bool = false,
             destination: String? = nil, shared: [String]? = nil, review: ShareReview? = nil) {
        let id = conversation ?? currentID ?? UUID().uuidString.lowercased()
        if !conversations.contains(where: { $0.id == id }) {
            let title = String((text.isEmpty ? files.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? shared?.first ?? "" : text).prefix(60))
            startConversation(id, title: title)
            if !text.isEmpty { refineTitleIfUnchanged(conversationID: id, initialTitle: title, prompt: text) }
        }
        let question = ChatMessage(role: .user, text: text, files: files, destination: destination, shared: shared)
        append(question, to: id)
        // The question is on disk before the answer starts: a crash or quit mid-answer never loses it.
        save(id)
        let reply = ChatMessage(role: .assistant, text: "", provenance: [], destination: destination)
        append(reply, to: id)
        let started = Date()
        begin(started, in: id)
        activeReplyID = reply.id
        _ = PippaMCPService.writeNotes.take()
        evidence = DateEvidence(); pendingSources = [:]; stepLabels = [:]; pendingNotes = [:]
        switch outgoing {
        case .local(let prompt), .typed(let prompt): evidence.add(prompt: prompt)
        case .approved(let approval): evidence.add(prompt: approval.message)
        }
        let turn = generation
        PiSession.shared.onSteeringChange = { [weak self] in self?.objectWillChange.send() }
        answer = Task {
            var refused = false
            var mcpTurnID: UUID?
            do {
                try await PippaMCPService.$onBeginTurn.withValue({ turnID in
                    mcpTurnID = turnID
                    // On disk with its run before any tool runs (RunJournal.swift).
                    self.update(self.activeReplyID ?? reply.id, in: id) { $0.run = RunSummary(run: turnID) }
                    self.save(id)
                }) {
                    try await PiSession.shared.ask(outgoing, conversation: id, handoff: handoff, onStarting: { self.starting($0) }) {
                        self.apply($0, in: id)
                    }
                }
            } catch is CancellationError {
            } catch let failure as PiSession.Failure where failure == .needsReview || failure == .destinationChanged || failure == .settingsChanged {
                refused = true
                let canRestore = currentID == id && draft.isEmpty && attachments.isEmpty
                if review != nil || canRestore {
                    if let index = conversations.firstIndex(where: { $0.id == id }) {
                        conversations[index].messages.removeAll { $0.id == question.id || $0.id == reply.id }
                    }
                    if let review { parkFailed(review, in: id, problem: failure.localizedDescription) }
                    else { draft = text; attachments = files.map { URL(fileURLWithPath: $0) } }
                    if currentID == id { problem = failure.localizedDescription }
                } else {
                    // Keep both drafts: the refused question in its own conversation and the new text in the composer.
                    update(activeReplyID ?? reply.id, in: id) { $0.error = failure.localizedDescription }
                }
            } catch {
                if !stopRequested { update(activeReplyID ?? reply.id, in: id) { $0.error = error.localizedDescription } }
            }
            // After a follow-up from the person the turn ends in the reply to it: the receipt, cards and dates go there.
            let last = activeReplyID ?? reply.id
            // A failure Pi streamed (the provider's error, the answer cut off) counts like a thrown one.
            if let review, !refused, !stopRequested,
               let failure = conversations.first(where: { $0.id == id })?.messages.first(where: { $0.id == last })?.error {
                parkFailed(review, in: id, problem: failure)
            }
            let cards = PippaMCPService.takeReadCards(turnID: mcpTurnID)
            let receipts = PippaMCPService.writeNotes.take()
            let run = await PippaMCPService.runSummary(mcpTurnID)
            let stopped = stopRequested
            if refused { end(); save(id); return }
            update(last, in: id) { message in
                message.cards = cards
                message.receipts = receipts
                message.run = run
                let dates = evidence.unsupported(in: message.text)
                message.unsupportedDates = dates.isEmpty ? nil : dates
                let checked = evidence.supported(in: message.text)
                message.checkedDates = checked.isEmpty ? nil : checked
                for index in message.steps.indices where !message.steps[index].done {
                    message.steps[index].done = true
                    message.steps[index].ended = Date()
                }
                message.duration = Date().timeIntervalSince(started)
                if stopped {
                    message.stopped = true
                    message.resumeAfter = nil
                    message.resumeScope = nil
                    // Pi reports the abort as an error; the person asked for it, so it is no failure.
                    message.error = nil
                }
            }
            // Done before the stats: a slow `get_session_stats` never leaves the window stuck in "answering".
            end()
            if !stopped {
                if !ChatWindow.shared.isKey {
                    unseen = conversations.first(where: { $0.id == id })?.messages.last?.error == nil ? .answer : .failed
                }
                if currentID != id { unseenIDs.insert(id) }
            }
            save(id)
            guard let usage = await PiSession.shared.contextUsage(), generation == turn else { return }
            update(last, in: id) { $0.context = usage }
            save(id)
        }
    }

    /// A sentence over the composer when something was not sent (the online AI changed meanwhile).
    @Published var problem: String?

    /// The person picks up their question again: its words and files go back into the composer.
    func edit(_ message: ChatMessage) {
        guard !isAnswering, message.role == .user else { return }
        draft = message.text
        attachments = message.files.map { URL(fileURLWithPath: $0) }
    }

    /// Dropped photos or PDFs, one PDF: done by the app itself, no model needed.
    func makePDF() {
        guard !isAnswering, !attachments.isEmpty else { return }
        let id = currentID ?? UUID().uuidString.lowercased()
        if current == nil {
            startConversation(id, title: T("One PDF", table: "App"))
        }
        let files = attachments
        append(ChatMessage(role: .user, text: T("Make one PDF", table: "App"), files: files.map(\.path)), to: id)
        save(id)
        let reply = ChatMessage(role: .assistant, text: "")
        append(reply, to: id)
        attachments = []
        let started = Date()
        begin(started, in: id)
        let turn = generation
        pdfTask = Task {
            let result = await PippaMCPService.makePDF(files)
            // Stop gave up waiting (`stop`): `end()` already cleared `pdfTask` and marked the answer stopped.
            guard generation == turn, self.pdfTask != nil else { return }
            let stopped = stopRequested
            update(reply.id, in: id) { message in
                message.duration = Date().timeIntervalSince(started)
                if stopped { message.stopped = true; return }
                if let card = result.card { message.cards = [card] }
                if result.failed { message.error = result.text } else if result.card == nil { message.text = result.text }
            }
            end()
            save(id)
        }
    }

    /// The button shows when everything attached is a photo or a PDF.
    var canMakePDF: Bool {
        !attachments.isEmpty && attachments.allSatisfy { url in
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            return type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true
        }
    }

    /// "Stop": Pi aborts the answer and settles, the answer is marked as stopped. Should Pi not settle soon after,
    /// the answer task is cancelled, so the window never stays in "answering".
    func stop() {
        guard isAnswering, !stopRequested else { return }
        stopRequested = true
        if let pdfTask {
            pdfTask.cancel()
            PippaMCPService.cancelNativeTurn()
            // A PDF step that does not notice the cancellation must not leave the window in "answering".
            let turn = generation
            Task {
                try? await Task.sleep(for: .seconds(3))
                guard isAnswering, generation == turn, self.pdfTask == pdfTask, let id = answeringID else { return }
                updateLast(in: id) { $0.stopped = true }
                end()
                save(id)
            }
            return
        }
        waitForRetry(nil)
        let running = answer
        let targetID = answeringID
        Task {
            let undelivered = await PiSession.shared.stop()
            if !undelivered.isEmpty { restoreDraft(undelivered.joined(separator: "\n"), to: targetID) }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if isAnswering, answer == running { running?.cancel() }
        }
    }

    private func begin(_ started: Date, in id: String) {
        generation += 1
        stopRequested = false
        answeringID = id
        isAnswering = true
        answerStarted = started
    }

    /// A warm AI is ready within milliseconds: only a start that takes a moment is worth saying.
    private func starting(_ on: Bool) {
        startingTask?.cancel()
        startingTask = nil
        guard on else { startingAI = false; return }
        startingTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { startingAI = true }
        }
    }

    private func end() {
        // The conversation is as recent as its answer's end, not its start: a follow-up in the island counts from here.
        if let id = answeringID, let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index].updated = Date() }
        starting(false)
        isWriting = false
        isAnswering = false
        answeringID = nil
        answerStarted = nil
        answer = nil
        pdfTask = nil
        activeReplyID = nil
        stopRequested = false
        waitForRetry(nil)
    }

    /// What Pi receives: the person's words, then the files they added and the app they called Pippa from.
    static func prompt(_ text: String, files: [String], frontApp: String?, undone: [String] = []) -> String {
        var parts = [text]
        if !files.isEmpty { parts.append("Files:\n" + files.map { "- \($0)" }.joined(separator: "\n")) }
        // Pi still believes what it added is there; the person undid it from the receipt row since.
        if !undone.isEmpty {
            parts.append("[The person pressed Undo since your last answer; Pippa took back these changes, so they are no longer as you left them: "
                         + undone.joined(separator: "; ") + ".]")
        }
        if let frontApp { parts.append("[Background context only: \(frontApp) was in front when Pippa opened. This is not a request to read that app. Use it only if the person asks about its content.]") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Whether words of the answer are coming in after `event`: text with more than line breaks (models open with
    /// them) starts it; thinking, a tool call and the end of the model's turn end it.
    static func writing(_ now: Bool, after event: PiRPCEvent) -> Bool {
        switch event {
        case .textDelta(let delta): now || delta.contains { !$0.isWhitespace }
        case .thinkingDelta, .toolStarted, .assistantEnded: false
        default: now
        }
    }

    /// A single question to an online AI is online too, while Settings still says "this Mac".
    private func answersOnline(_ id: String) -> Bool {
        SettingsModel.shared.inferenceSettings.usesOnlineAI || conversations.first(where: { $0.id == id })?.messages.last?.destination != nil
    }

    func apply(_ event: PiRPCEvent, in id: String) {
        evidence.observe(event)
        // The model is at work again: Pi's next try has started (it reports the try's end only after its whole answer).
        switch event {
        case .textDelta, .thinkingDelta, .toolStarted: if retryWait != nil { waitForRetry(nil) }
        default: break
        }
        let writing = Self.writing(isWriting, after: event)
        if writing != isWriting { isWriting = writing }
        switch event {
        case .textDelta(let delta):
            updateLast(in: id) { $0.text += delta }
        case .thinkingDelta(let delta):
            updateLast(in: id) { $0.thinking = ($0.thinking ?? "") + delta }
        case .toolStarted(let call, let name, let arguments, let parent):
            // A script's own calls stay inside its one step ("Working through the list"); what they read still counts.
            if parent == nil {
                updateLast(in: id) {
                    $0.steps.append(ChatStep(id: call, label: StepLabel.text(tool: name, arguments: arguments), started: Date()))
                    $0.lead = $0.text.count
                }
            }
            if let source = SourceLog.source(tool: name, arguments: arguments) { pendingSources[call] = source }
            // What the answer may rest on, from the tool's name; counted when it starts, read or not.
            let read = SharingSource.read(byTool: name)
            if !read.isEmpty { updateLast(in: id) { $0.provenance = Array(Set($0.provenance ?? []).union(read)).sorted() } }
        case .toolProgress(let call, let part, let of, let merging):
            updateLast(in: id) { message in
                guard let index = message.steps.firstIndex(where: { $0.id == call }), !message.steps[index].done else { return }
                let label = stepLabels[call] ?? message.steps[index].label
                stepLabels[call] = label
                message.steps[index].label = StepLabel.progress(label, part: part, of: of, merging: merging)
            }
        case .toolNotes(let call, let path):
            pendingNotes[call] = path
        case .toolEnded(let call, let name, let isError, let result, let outcome, _, _):
            // A failed Pi tool leaves a line; Pippa's MCP tools log themselves in the server (`mcp-werkzeug`). Only the
            // kind goes in, never the result text.
            if let fields = PiToolFailure.fields(tool: name, isError: isError, result: result) {
                DiagnosticsLog.shared.event("pi-werkzeug", fields)
            }
            let failed = isError || (outcome.map { $0 != .done } ?? false)
            let label = stepLabels.removeValue(forKey: call)
            let notes = pendingNotes.removeValue(forKey: call)
            updateLast(in: id) { message in
                guard let index = message.steps.firstIndex(where: { $0.id == call }) else { return }
                // The finished step is "Reading Thesis.docx" again, not its last part.
                if let label { message.steps[index].label = label }
                message.steps[index].done = true
                message.steps[index].failed = failed
                message.steps[index].ended = Date()
            }
            // A source counts once it was read; the same file read twice shows once, with its latest pages.
            let pendingSource = pendingSources.removeValue(forKey: call)
            if !failed, var source = SourceLog.source(tool: name, arguments: "{}", result: result) ?? pendingSource {
                if name.hasSuffix("read_document") || name.hasSuffix("mail_read") { source.detail = SourceLog.detail(result: result, mail: name.hasSuffix("mail_read")) }
                if source.kind == .file { source.notes = notes }
                updateLast(in: id) { message in
                    var sources = message.sources ?? []
                    let same = { (other: ChatSource) in other.kind == source.kind && other.name == source.name && other.location == source.location }
                    // Reading an exact passage after the notes keeps the notes (the digest asks for such reads).
                    if source.notes == nil { source.notes = sources.last(where: same)?.notes }
                    sources.removeAll(where: same)
                    sources.append(source)
                    message.sources = sources
                }
            }
        case .assistantEnded(_, let reason, let error):
            if reason == "toolUse" { updateLast(in: id) { if !$0.text.isEmpty, !$0.text.hasSuffix("\n") { $0.text += "\n\n" } } }
            let online = answersOnline(id)
            if reason == "error", let error { updateLast(in: id) { $0.error = Self.modelError(error, online: online) } }
            // The model used up its answer length (usually while thinking) and stopped mid-way: say so, never end quietly.
            if reason == "length" {
                updateLast(in: id) {
                    $0.error = online ? T("That was too much at once for the AI. Ask for a smaller part, for example one document at a time.", table: "App")
                        : T("That was too much at once for the AI on this Mac. Ask for a smaller part, for example one document at a time.", table: "App")
                }
            }
        case .retryScheduled(_, _, let delay, let error):
            // The failed try is not the end of the answer: Pi waits and tries again.
            updateLast(in: id) { $0.error = nil }
            waitForRetry(Date().addingTimeInterval(Double(delay) / 1000),
                         rateLimit: answersOnline(id) && PiProviderClient.problem(in: error) == .rateLimit)
        case .retryEnded(let success, _, let finalError):
            waitForRetry(nil)
            // Still at its limit after every try: the answer can go on later where it stopped. Only a typed question's
            // session holds the conversation; an approved one ran in a session of its own.
            guard !success, !stopRequested, let scope = PiSession.shared.answerScope, let finalError,
                  PiProviderClient.problem(in: finalError) == .rateLimit,
                  let messages = conversations.first(where: { $0.id == id })?.messages, messages.count >= 2,
                  messages[messages.count - 2].shared == nil else { break }
            updateLast(in: id) {
                $0.error = T("The online AI is still at its limit. Wait a minute, then continue where it stopped.", table: "App")
                $0.resumeAfter = Date().addingTimeInterval(Self.resumeDelay)
                $0.resumeScope = scope
            }
        case .userMessage(let text):
            steered(text, in: id)
        case .notice(let text, let kind) where kind == "error" || kind == "warning":
            updateLast(in: id) { $0.error = text }
        case .notice(let text, "pippa-change"):
            // Under the running answer's own turn id (set when it began), never whichever turn is active now.
            PippaMCPService.recordFileChanges(text, run: conversations.first(where: { $0.id == id })?.messages.last?.run?.run)
        default:
            break
        }
    }

    /// Pi took the person's follow-up (`steer`) after its last step: the reply so far ends there, the follow-up shows as
    /// their message, and what Pi writes next goes into a new reply. The turn's run moves along, so its one receipt
    /// shows under the last reply.
    private func steered(_ text: String, in id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              let last = conversations[index].messages.indices.last, conversations[index].messages[last].role == .assistant else { return }
        let destination = conversations[index].messages[last].destination
        var run: RunSummary?
        update(conversations[index].messages[last].id, in: id) { message in
            for step in message.steps.indices where !message.steps[step].done {
                message.steps[step].done = true
                message.steps[step].ended = Date()
            }
            let dates = evidence.unsupported(in: message.text)
            message.unsupportedDates = dates.isEmpty ? nil : dates
            let checked = evidence.supported(in: message.text)
            message.checkedDates = checked.isEmpty ? nil : checked
            run = message.run
            message.run = nil
        }
        // A reply that had not begun yet (no words, no steps) leaves no empty bubble behind.
        let previous = conversations[index].messages[last]
        if previous.text.isEmpty && previous.steps.isEmpty && (previous.thinking ?? "").isEmpty && previous.error == nil {
            conversations[index].messages.remove(at: last)
        }
        evidence.add(prompt: text)
        append(ChatMessage(role: .user, text: text, destination: destination), to: id)
        var next = ChatMessage(role: .assistant, text: "", provenance: [], destination: destination)
        next.run = run
        append(next, to: id)
        activeReplyID = next.id
        save(id)
    }

    /// Snapshots only (`Snapshots`): never saved.
    func replaceForSnapshot(_ conversations: [Conversation], current: String?, answering: Bool, starting: Bool = false,
                            writing: Bool = false, waiting: TimeInterval? = nil) {
        waitForRetry(waiting.map { Date().addingTimeInterval($0) }, rateLimit: true)
        stopRequested = false
        showsSample = true
        isLoaded = true
        self.conversations = conversations
        currentID = current
        isAnswering = answering
        answeringID = answering ? current : nil
        answerStarted = answering ? Date().addingTimeInterval(-42) : nil
        startingAI = starting
        isWriting = writing
    }

    // MARK: Storage

    /// A new, empty conversation at the top of the list, shown.
    func startConversation(_ id: String, title: String) {
        conversations.insert(Conversation(id: id, title: title, updated: Date(), messages: []), at: 0)
        currentID = id
    }

    private func append(_ message: ChatMessage, to id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.append(message)
        conversations[index].updated = Date()
    }

    /// Changes one message by its id (not "the last one": a new question may have come since).
    func update(_ messageID: UUID, in id: String, _ change: (inout ChatMessage) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              let message = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&conversations[index].messages[message])
    }

    private func updateLast(in id: String, _ change: (inout ChatMessage) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), !conversations[index].messages.isEmpty else { return }
        change(&conversations[index].messages[conversations[index].messages.count - 1])
    }

    /// Reads the saved conversations in the background. One asked meanwhile stays; a saved one with the same id
    /// does not replace it.
    private func load() {
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let saved = store.load()
            await MainActor.run {
                guard !self.showsSample else { return }
                let known = Set(self.conversations.map(\.id))
                self.conversations = (self.conversations + saved.conversations.filter { !known.contains($0.id) }).sorted { $0.updated > $1.updated }
                self.unreadable = saved.unreadable
                self.isLoaded = true
                self.refreshRuns()
            }
        }
    }

    /// Hands a copy to the background writer; files are written in the order they were saved.
    func save(_ id: String) {
        guard !showsSample, let conversation = conversations.first(where: { $0.id == id }) else { return }
        store.save(conversation)
    }
}
