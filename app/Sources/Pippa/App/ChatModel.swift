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

    @Published private(set) var conversations: [Conversation] = []
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
    /// What the current answer read, for its dates.
    private var evidence = DateEvidence()
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
    private var answer: Task<Void, Never>?
    private var pdfTask: Task<Void, Never>?
    /// "Stop" was pressed for the running answer.
    private var stopRequested = false
    /// Counts answers, so a late result of an earlier one never lands on a newer one.
    private var generation = 0
    /// The review open while the person checks what goes to an online AI, and the ones parked with their edits.
    @Published private(set) var desk = ShareDesk()
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
        draft = ""; attachments = []
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
            }
        }
        unseenIDs.remove(id)
    }

    func delete(_ id: String) {
        guard !isAnswering || id != answeringID else { return }
        unseenIDs.remove(id)
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = nil; draft = ""; attachments = [] }
        composers[id] = nil
        desk.forget(id)
        store.trash(id)
        Task { await PiSession.shared.forget(id) }
    }

    func rename(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
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
    @Published private(set) var undoing: Set<String> = []
    /// Conversation id → what the person undid that Pi has not heard of yet; told with the next question.
    private var undoneNotes: [String: [String]] = [:]

    static func undoKey(_ messageID: UUID, _ index: Int) -> String { "\(messageID.uuidString)#\(index)" }

    /// Removes the event or reminder a receipt names, only if it is unchanged since Pippa added it, and keeps the
    /// outcome on the receipt (shown in the row, saved with the conversation).
    func undo(receiptAt index: Int, in messageID: UUID) {
        guard let id = currentID,
              let receipts = conversations.first(where: { $0.id == id })?.messages.first(where: { $0.id == messageID })?.receipts,
              receipts.indices.contains(index), receipts[index].canUndo else { return }
        let receipt = receipts[index]
        let key = Self.undoKey(messageID, index)
        guard !undoing.contains(key) else { return }
        undoing.insert(key)
        Task {
            let result = await PippaMCPService.undo(receipt)
            undoing.remove(key)
            update(messageID, in: id) { message in
                guard message.receipts.indices.contains(index) else { return }
                message.receipts[index] = result
            }
            if result.undo == "removed" { undoneNotes[id, default: []].append(result.name) }
            save(id)
        }
    }

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

    /// What goes to Pi for the composer's content: everything for the AI on this Mac; for an online AI only typed words,
    /// and `nil` (review first) as soon as files are attached. The app in front and undo notes never go online.
    static func outgoing(_ text: String, files: [String], frontApp: String?, undone: [String], online: Bool) -> PiSession.Outgoing? {
        guard online else { return .local(prompt(text, files: files, frontApp: frontApp, undone: undone)) }
        return files.isEmpty ? .typed(text) : nil
    }

    /// One question and its answer, in `conversation` (the one shown when `nil`). `destination`: the online AI it goes to
    /// (shown on both). `review`: the approved review it came from; if the answer fails, refused or mid-way, the review is
    /// parked there with its edits and its words go back only into an empty composer (`ShareDesk.failed`), never resent.
    private func ask(_ text: String, files: [String], outgoing: PiSession.Outgoing, in conversation: String? = nil, handoff: Bool = false,
                     destination: String? = nil, shared: [String]? = nil, review: ShareReview? = nil) {
        let id = conversation ?? currentID ?? UUID().uuidString.lowercased()
        if !conversations.contains(where: { $0.id == id }) {
            let title = String((text.isEmpty ? files.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? shared?.first ?? "" : text).prefix(60))
            conversations.insert(Conversation(id: id, title: title, updated: Date(), messages: []), at: 0)
            currentID = id
        }
        let question = ChatMessage(role: .user, text: text, files: files, destination: destination, shared: shared)
        append(question, to: id)
        // The question is on disk before the answer starts: a crash or quit mid-answer never loses it.
        save(id)
        let reply = ChatMessage(role: .assistant, text: "", provenance: [], destination: destination)
        append(reply, to: id)
        let started = Date()
        begin(started, in: id)
        _ = PippaMCPService.readNotes.take(); _ = PippaMCPService.writeNotes.take()
        evidence = DateEvidence(); pendingSources = [:]; stepLabels = [:]; pendingNotes = [:]
        switch outgoing {
        case .local(let prompt), .typed(let prompt): evidence.add(prompt: prompt)
        case .approved(let approval): evidence.add(prompt: approval.message)
        }
        let turn = generation
        answer = Task {
            var refused = false
            do {
                try await PiSession.shared.ask(outgoing, conversation: id, handoff: handoff, onStarting: { self.starting($0) }) { event in self.apply(event, in: id) }
            } catch is CancellationError {
            } catch let failure as PiSession.Failure where failure == .needsReview || failure == .destinationChanged {
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
                    update(reply.id, in: id) { $0.error = failure.localizedDescription }
                }
            } catch {
                if !stopRequested { update(reply.id, in: id) { $0.error = error.localizedDescription } }
            }
            // A failure Pi streamed (the provider's error, the answer cut off) counts like a thrown one.
            if let review, !refused, !stopRequested,
               let failure = conversations.first(where: { $0.id == id })?.messages.first(where: { $0.id == reply.id })?.error {
                parkFailed(review, in: id, problem: failure)
            }
            let cards = PippaMCPService.readNotes.take().compactMap(\.card)
            let receipts = PippaMCPService.writeNotes.take()
            let stopped = stopRequested
            if refused { end(); save(id); return }
            update(reply.id, in: id) { message in
                message.cards = cards
                message.receipts = receipts
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
            update(reply.id, in: id) { $0.context = usage }
            save(id)
        }
    }

    /// A sentence over the composer when something was not sent (the online AI changed meanwhile).
    @Published var problem: String?

    // MARK: Sharing with an online AI

    /// The online AI a single question can go to while conversations stay on this Mac ("Ask OpenAI…").
    var handoffDestination: ShareDestination? { ShareDestination.handoff(SettingsModel.shared.inferenceSettings, recipients: .unresolved) }

    /// "Ask <provider>…": the review for one question to the recipient, with the files attached and Pippa's last answer
    /// here (each part with what it was read from). Nothing is sent before the person's OK.
    func askOnline() {
        guard !isAnswering, review == nil, let destination = ShareDestination.handoff(SettingsModel.shared.inferenceSettings) else { return }
        startReview(destination, handoff: true)
    }

    /// Where a review opened now would go: the online AI conversations use, or else the recipient of single questions.
    private var reviewRoute: (destination: ShareDestination, handoff: Bool)? {
        let settings = SettingsModel.shared.inferenceSettings
        if let active = ShareDestination.active(settings) { return (active, false) }
        return ShareDestination.handoff(settings).map { ($0, true) }
    }

    /// The + menu: one source read on this Mac by Pippa herself, then the review for the online AI, or with the AI on
    /// this Mac for one question to the recipient of single questions.
    func share(_ source: SharingSource) {
        guard !isAnswering, let route = review.map({ ($0.plan.destination, $0.handoff) }) ?? reviewRoute else { return }
        let rules = SettingsModel.shared.inferenceSettings.sharing
        guard rules[source] == .ask, source != .photos, source != .documents else { return }
        if review == nil { startReview(route.destination, handoff: route.handoff) }
        let extraction = ShareExtraction(host: PippaMCPService.currentHost)
        guard let reviewID = review?.id else { return }
        desk.reading()
        Task {
            let piece: SharePiece?
            var problem: String?
            do {
                switch source {
                case .mail: piece = try await extraction.selectedMail()
                case .calendar: piece = try await extraction.calendar()
                case .reminders: piece = try await extraction.reminders()
                case .documents, .photos: piece = nil
                }
            } catch {
                piece = nil; problem = error.localizedDescription
            }
            // Into the review it was read for, even if that one was cancelled or parked meanwhile.
            desk.add(piece.map { [$0] } ?? [], problem: problem, to: reviewID, rules: SettingsModel.shared.inferenceSettings.sharing)
        }
    }

    /// One picture chosen in the Photos picker: only the text recognized in it on this Mac joins the review, under the
    /// Photos rule; the picture itself never leaves the Mac. `data` is the picture's bytes, read into a temporary file
    /// for local OCR and removed right after.
    func sharePhoto(type: UTType?, load: @escaping @MainActor () async -> Data?) {
        guard !isAnswering, let route = review.map({ ($0.plan.destination, $0.handoff) }) ?? reviewRoute,
              SettingsModel.shared.inferenceSettings.sharing.photos == .ask else { return }
        if review == nil { startReview(route.destination, handoff: route.handoff) }
        guard let reviewID = review?.id else { return }
        desk.reading()
        let name = T("Photo", table: "App")
        Task {
            let data = await load()
            let piece: SharePiece? = await Task.detached(priority: .userInitiated) { () -> SharePiece? in
                guard let data else { return nil }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-photo-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let file = folder.appendingPathComponent(name).appendingPathExtension(type?.preferredFilenameExtension ?? "jpg")
                guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                      (try? data.write(to: file)) != nil else { return nil }
                return ShareExtraction.files([file]).first
            }.value
            desk.add(piece.map { [$0] } ?? [], problem: piece == nil ? T("Pippa couldn’t read this photo.", table: "App") : nil,
                     to: reviewID, rules: SettingsModel.shared.inferenceSettings.sharing)
        }
    }

    /// Opens the review for the conversation shown, resuming one parked there with its edits (`ShareDesk.open`), and
    /// reads the files it does not have yet. `composer`: what it is made from, the composer itself unless a retry says.
    private func startReview(_ destination: ShareDestination, handoff: Bool, composer: ShareComposer? = nil, explicit: Bool = false) {
        if currentID == nil {
            let id = UUID().uuidString.lowercased()
            let words = (composer?.text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = words.isEmpty ? T("New Conversation", table: "App") : String(words.prefix(60))
            conversations.insert(Conversation(id: id, title: title, updated: Date(), messages: []), at: 0)
            currentID = id
        }
        let rules = SettingsModel.shared.inferenceSettings.sharing
        let fresh = handoff ? lastAnswerHere().map { [$0] } ?? [] : []
        let unread = desk.open(in: currentID, destination: destination, handoff: handoff,
                               composer: composer ?? ShareComposer(text: draft, files: attachments), fresh: fresh, rules: rules, explicit: explicit)
        problem = nil
        ChatWindow.shared.show()
        guard !unread.isEmpty, let reviewID = review?.id else { return }
        Task {
            let pieces = await Task.detached(priority: .userInitiated) { ShareExtraction.files(unread, rules: rules) }.value
            desk.add(pieces, files: unread, to: reviewID, rules: SettingsModel.shared.inferenceSettings.sharing)
        }
    }

    /// A review parked in the conversation shown (cancelled, or not answered), for "Continue checking".
    var parkedReview: ShareReview? {
        desk.parked(in: currentID, handoff: !SettingsModel.shared.inferenceSettings.usesOnlineAI)
    }

    /// "Continue checking": the parked review as it was, with every edit, for the recipient as it is now.
    func resumeReview() {
        guard !isAnswering, review == nil, let route = reviewRoute, desk.parked(in: currentID, handoff: route.handoff) != nil else { return }
        startReview(route.destination, handoff: route.handoff, explicit: true)
    }

    /// The person no longer wants the parked review.
    func discardParkedReview() {
        guard let route = reviewRoute else { return }
        desk.discard(in: currentID, handoff: route.handoff)
    }

    /// The approved review failed: parked in its conversation, its words back into the composer only if that is empty.
    private func parkFailed(_ review: ShareReview, in conversation: String, problem: String?) {
        var review = review
        review.conversation = conversation
        if let back = desk.failed(review, problem: problem, current: currentID, composer: ShareComposer(text: draft, files: attachments)) {
            draft = back.text; attachments = back.files
        }
    }

    /// Pippa's last answer here, by the AI on this Mac, as a part: its sources are what its tools read.
    private func lastAnswerHere() -> SharePiece? {
        guard let current, let index = current.messages.lastIndex(where: { $0.role == .assistant }) else { return nil }
        let answer = current.messages[index]
        let text = answer.result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard answer.destination == nil, answer.error == nil, !text.isEmpty else { return nil }
        // Pi can use any earlier local turn to answer a follow-up, even when it calls no tool on this turn.
        let sources = current.localSources(through: index)
        return SharePiece(sources: sources, title: T("Pippa’s answer on this Mac", table: "App"), text: text)
    }

    static func localHistorySources(in history: ArraySlice<ChatMessage>) -> Set<SharingSource> {
        var sources = Set<SharingSource>()
        for message in history where message.destination == nil {
            if message.role == .assistant {
                sources.formUnion(message.provenance ?? SharingSource.allCases)
            }
            for file in message.files {
                sources.formUnion(SharingSource.sources(forFile: URL(fileURLWithPath: file)))
            }
        }
        return sources
    }

    /// The person's changes in the review sheet (their words, a part's text, leaving a part out).
    func updateReview(_ change: (inout SharePlan) -> Void) { desk.update(change) }

    /// Cancel or closing the sheet: nothing is sent; the edits stay, parked with the conversation, and the edited words
    /// go into the composer if it still holds what the review opened with.
    func dismissReview() {
        guard review != nil else { return }
        if let back = desk.cancel(current: currentID, composer: ShareComposer(text: draft, files: attachments)) {
            draft = back.text; attachments = back.files
        }
    }

    /// Send: the approval is fixed now (`ShareApproval`), for the destination shown and the rules as they are now. If the
    /// online AI changed while the review was open, nothing is sent and the review says so.
    /// The answer goes to the review's own conversation; a draft typed in the composer meanwhile stays there.
    func approveReview() {
        guard let current = review, !isAnswering else { return }
        let settings = SettingsModel.shared.inferenceSettings
        let now = current.handoff ? ShareDestination.handoff(settings) : ShareDestination.active(settings)
        switch desk.approve(current: currentID, destination: now, composer: ShareComposer(text: draft, files: attachments), rules: settings.sharing) {
        case .send(let approval, let sent, let clearComposer):
            if clearComposer { draft = ""; attachments = []; frontApp = nil }
            ask(approval.question, files: sent.files.map(\.path), outgoing: .approved(approval), in: sent.conversation, handoff: sent.handoff,
                destination: approval.destination.label, shared: approval.parts.map(\.title), review: sent)
        case .destinationChanged:
            desk.setProblem(PiSession.Failure.destinationChanged.localizedDescription)
        case .parked, .nothing:
            break
        }
    }

    /// The person picks up their question again: its words and files go back into the composer.
    func edit(_ message: ChatMessage) {
        guard !isAnswering, message.role == .user else { return }
        draft = message.text
        attachments = message.files.map { URL(fileURLWithPath: $0) }
    }

    /// The last answer failed: ask the same question again.
    /// An approved question is never sent again as it was: it goes back through the review (no replay).
    func retry() {
        guard !isAnswering, review == nil, let id = currentID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let messages = conversations[index].messages
        guard messages.count >= 2, messages[messages.count - 1].role == .assistant, messages[messages.count - 2].role == .user else { return }
        let question = messages[messages.count - 2]
        let files = question.files.map { URL(fileURLWithPath: $0) }
        if question.shared != nil, let route = reviewRoute {
            // Back through the review, with the edits of the one that failed when it is parked here. The composer keeps
            // whatever was typed since.
            conversations[index].removeTurnForRetry()
            save(id)
            let parked = desk.parked(in: id, handoff: route.handoff) != nil
            startReview(route.destination, handoff: route.handoff, composer: ShareComposer(text: question.text, files: files), explicit: parked)
            return
        }
        guard question.shared == nil else {
            // No online AI to check it for any more: the words go back into an empty composer, nothing is sent.
            if draft.isEmpty && attachments.isEmpty { draft = question.text; attachments = files }
            return
        }
        conversations[index].removeTurnForRetry()
        draft = question.text
        attachments = files
        send()
    }

    /// Dropped photos or PDFs, one PDF: done by the app itself, no model needed.
    func makePDF() {
        guard !isAnswering, !attachments.isEmpty else { return }
        let id = currentID ?? UUID().uuidString.lowercased()
        if current == nil {
            conversations.insert(Conversation(id: id, title: T("One PDF", table: "App"), updated: Date(), messages: []), at: 0)
            currentID = id
        }
        let files = attachments
        append(ChatMessage(role: .user, text: T("Make one PDF", table: "App"), files: files.map(\.path)), to: id)
        save(id)
        let reply = ChatMessage(role: .assistant, text: "")
        append(reply, to: id)
        attachments = []
        let started = Date()
        begin(started, in: id)
        pdfTask = Task {
            let result = await PippaMCPService.makePDF(files)
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
        if let pdfTask { pdfTask.cancel(); return }
        let running = answer
        Task { await PiSession.shared.stop() }
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
        stopRequested = false
    }

    /// A failure mid-answer as one plain sentence: an online provider's ("401 {…}", "usage limit"), or the AI on this Mac
    /// running out of memory (the raw text goes to the log, not the chat); anything else as Pi said it.
    static func modelError(_ error: String, online: Bool) -> String {
        if let plain = OMLXServer.plainFailure(error, online: online) {
            DiagnosticsLog.shared.event("ki-zu-wenig-speicher", ["text": error])
            return plain
        }
        guard online, let problem = PiProviderClient.problem(in: error) else { return error }
        return problem == .limit
            ? T("Your online AI limit is reached for now. Try again later, or switch to the AI on this Mac in Settings.", table: "App")
            : T("Reconnect your online AI in Settings.", table: "App")
    }

    /// What Pi receives: the person's words, then the files they added and the app they called Pippa from.
    static func prompt(_ text: String, files: [String], frontApp: String?, undone: [String] = []) -> String {
        var parts = [text]
        if !files.isEmpty { parts.append("Files:\n" + files.map { "- \($0)" }.joined(separator: "\n")) }
        // Pi still believes what it added is there; the person undid it from the receipt row since.
        if !undone.isEmpty {
            parts.append("[The person pressed Undo since your last answer; these are no longer on the Mac: "
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

    private func apply(_ event: PiRPCEvent, in id: String) {
        evidence.observe(event)
        let writing = Self.writing(isWriting, after: event)
        if writing != isWriting { isWriting = writing }
        switch event {
        case .textDelta(let delta):
            updateLast(in: id) { $0.text += delta }
        case .thinkingDelta(let delta):
            updateLast(in: id) { $0.thinking = ($0.thinking ?? "") + delta }
        case .toolStarted(let call, let name, let arguments):
            updateLast(in: id) {
                $0.steps.append(ChatStep(id: call, label: StepLabel.text(tool: name, arguments: arguments), started: Date()))
                $0.lead = $0.text.count
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
        case .toolEnded(let call, let name, let isError, let result, let outcome, _):
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
                if name.hasSuffix("read_document") { source.detail = SourceLog.detail(result: result) }
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
            // A single question to an online AI is online too, while Settings still says "this Mac".
            let online = SettingsModel.shared.inferenceSettings.usesOnlineAI
                || conversations.first(where: { $0.id == id })?.messages.last?.destination != nil
            if reason == "error", let error { updateLast(in: id) { $0.error = Self.modelError(error, online: online) } }
            // The model used up its answer length (usually while thinking) and stopped mid-way: say so, never end quietly.
            if reason == "length" {
                updateLast(in: id) {
                    $0.error = online ? T("That was too much at once for the AI. Ask for a smaller part, for example one document at a time.", table: "App")
                        : T("That was too much at once for the AI on this Mac. Ask for a smaller part, for example one document at a time.", table: "App")
                }
            }
        case .notice(let text, let kind) where kind == "error" || kind == "warning":
            updateLast(in: id) { $0.error = text }
        default:
            break
        }
    }

    /// Snapshots only (`Snapshots`): never saved.
    func replaceForSnapshot(_ conversations: [Conversation], current: String?, answering: Bool, starting: Bool = false,
                            writing: Bool = false) {
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

    private func append(_ message: ChatMessage, to id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.append(message)
        conversations[index].updated = Date()
    }

    /// Changes one message by its id (not "the last one": a new question may have come since).
    private func update(_ messageID: UUID, in id: String, _ change: (inout ChatMessage) -> Void) {
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
            }
        }
    }

    /// Hands a copy to the background writer; files are written in the order they were saved.
    private func save(_ id: String) {
        guard !showsSample, let conversation = conversations.first(where: { $0.id == id }) else { return }
        store.save(conversation)
    }
}

/// The conversation files, read and written on one background queue: encoding and writing never hold up the window,
/// and saves land on disk in the order they were made (a later save of a conversation never loses to an earlier one).
final class ConversationStore: Sendable {
    private let folder: URL
    private let queue = DispatchQueue(label: "Pippa.conversations", qos: .utility)

    init(folder: URL) { self.folder = folder }

    /// Called off the main actor (at launch). Every file that can be read counts; a missing folder is a first run. The
    /// folder or files that cannot be read are counted and logged, so they never pass for an empty history.
    func load() -> (conversations: [Conversation], unreadable: Int) {
        queue.sync {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
            catch {
                if (error as NSError).code == NSFileReadNoSuchFileError { return ([], 0) }
                UserMessage.record(error, context: "gespraeche-ordner")
                return ([], 1)
            }
            let decoder = JSONDecoder()
            var conversations: [Conversation] = [], unreadable = 0
            for file in files where file.pathExtension == "json" {
                do { conversations.append(try decoder.decode(Conversation.self, from: Data(contentsOf: file))) }
                catch { unreadable += 1; UserMessage.record(error, context: "gespraech-lesen") }
            }
            return (conversations.sorted { $0.updated > $1.updated }, unreadable)
        }
    }

    func save(_ conversation: Conversation) {
        let folder = self.folder
        queue.async {
            guard let data = try? JSONEncoder().encode(conversation) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent("\(conversation.id).json"), options: .atomic)
        }
    }

    /// After any save still waiting, so a late write never brings a deleted conversation back.
    func trash(_ id: String) {
        let file = folder.appendingPathComponent("\(id).json")
        queue.async { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
    }

    /// Waits until every save so far is on disk (when Pippa quits).
    func flush() { queue.sync {} }
}

/// A short everyday line for a tool call ("Reading Lease.pdf"). Display only; Pi never sees it.
enum StepLabel {
    /// A running step's label with where it is in a long document: "Reading Thesis.docx · Part 3 of 10".
    static func progress(_ label: String, part: Int, of: Int, merging: Bool) -> String {
        merging ? T("%@ · merging the notes", table: "App", label) : T("%@ · Part %lld of %lld", table: "App", label, part, of)
    }

    static func text(tool: String, arguments: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let name = tool.hasPrefix("mcp__pippa__") ? String(tool.dropFirst("mcp__pippa__".count)) : tool
        func file(_ key: String) -> String { (args[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
        func value(_ key: String) -> String { (args[key] as? String) ?? "" }
        switch name {
        case "read", "read_document": return T("Reading %@", table: "App", file("path"))
        case "write": return T("Writing %@", table: "App", file("path"))
        case "bash": return T("Running a command", table: "App")
        case "search_files": return T("Searching files for “%@”", table: "App", value("query"))
        case "list_folder": return T("Looking in %@", table: "App", file("path"))
        case "move_files": return T("Moving files", table: "App")
        case "web_search": return T("Searching the web", table: "App")
        case "fetch_content": return T("Reading a web page", table: "App")
        case "remember": return T("Remembering", table: "App")
        case "ask": return T("Asking you", table: "App")
        case "calendar_read": return T("Reading Calendar", table: "App")
        case "calendar_add": return T("Adding to Calendar", table: "App")
        case "reminders_read": return T("Reading Reminders", table: "App")
        case "reminder_add": return T("Adding a reminder", table: "App")
        case "mail_search", "mail_read": return T("Reading Mail", table: "App")
        case "mail_draft": return T("Writing a Mail draft", table: "App")
        case "photos_search": return T("Searching Photos", table: "App")
        case "front_read": return T("Reading the app in front", table: "App")
        case "prepare_files": return T("Preparing files", table: "App")
        case "browse": return T("Browsing a web page", table: "App")
        default: return name
        }
    }
}
