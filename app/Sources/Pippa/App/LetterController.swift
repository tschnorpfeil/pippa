import AppKit
import Combine
import PippaCore

// Letter in the line (reading a mail, first line, actions, draft, insert as an unsent reply).
//
// Call in Mail → "Looking at the mail …" → (first time a sentence, then the system prompt) → the chosen mail as .eml
// onto the tray → first line from code (optionally sharpened by the system model, never by the large one) → type actions at once,
// suggested ones later in the same slots → draft in the line → insert as an unsent reply in Mail.
// Decisions live in PippaCore (LetterReading, FirstLineBuilder, LetterActions, LookupHost); only the flow is here.
// Pippa never sends. The network for "Check online" is used only by the host (LookupHost/WebFetcher), never by the agent.
// All conversations with the engine run one after another: suggestion, draft and check never overlap.

/// State of the letter in the line.
enum LetterPhase: Equatable {
    case idle
    /// "Looking at the mail …": check permission, read mail.
    case calling
    /// A sentence before the system prompt (`denied: false`) or the way to Settings (`denied: true`).
    case permission(denied: Bool)
    /// First line and actions are shown.
    case ready
    /// A draft grows under the line.
    case working(title: String)
    /// The draft is done: insert, copy, edit.
    case draft
    /// Inserted into Mail (never sent). `viaReply: false` = new mail to the sender (fallback).
    case inserted(viaReply: Bool)
    /// The threaded reply is open in Mail, but Mail did not report the text in it. The draft is on the
    /// clipboard; the person pastes it. Never shown as inserted.
    case pasteReady
    /// A calm sentence.
    case failure(String)
}

@MainActor
final class LetterController: ObservableObject {
    @Published private(set) var phase: LetterPhase = .idle
    @Published private(set) var callingText = ""
    @Published private(set) var firstLine: FirstLine?
    @Published private(set) var facts: LetterFacts?
    /// At most three, from the letter's type and habits (code, no model).
    @Published private(set) var actions: [LetterAction] = []
    /// The draft; while editing, bound directly to the text field. Kept when collapsed.
    @Published var draft = ""
    @Published private(set) var editing = false
    /// Sentence about the attachment that Pippa cannot read from Mail.
    @Published private(set) var note: String?
    /// Insert failed: one sentence under the draft, the draft stays.
    @Published private(set) var insertProblem: String?
    /// An uncertain native acknowledgement may already have opened a reply; forbid blind retries.
    /// Only `insertAgain()` (an explicit click after the warning) clears it.
    @Published private(set) var insertUncertain = false
    /// While Insert looks for the original in Mail: mailboxes searched and total, for the waiting row with Stop.
    @Published private(set) var insertSearch: (done: Int, total: Int)?
    /// Text in the line's field (kept when collapsed).
    @Published var question = ""

    weak var model: AppModel? {
        didSet { watchTray() }
    }

    /// A letter that has been read: tray item, .eml, Mail and this letter's Pi session.
    private struct Session {
        let id = UUID()
        let mail: MailMessage
        let emlURL: URL
        let taskID: String
        var itemID: UUID?
        /// Mark of the chosen draft action (`TaskLogRecorder.choseTracked`) until inserted.
        var token: UUID?
        /// The draft as Pippa wrote it (for "changed" in the log).
        var original = ""
        /// Since when the letter has had the line (call). If something else lands on Pippa afterwards, the line shows the tray again.
        var claimedAt = Date()
    }

    private var session: Session?
    /// A call is running before a session exists (permission, reading).
    private var pendingCall = false
    /// Was anything chosen in this opened line? Otherwise: "passed over" in the log.
    private var choseSinceOpen = true
    /// Habits (loaded once, then extended locally).
    private var records: [TaskRecord]?
    /// A snapshot read before Forget must not restore the discarded habits.
    private var habitGeneration = 0
    private var stopRequested = false

    private var callTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    private var chooseTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var insertTask: Task<Void, Never>?
    private var trayWatch: AnyCancellable?

    // MARK: State for line and figure

    /// Does the line show the letter? During the call, and while its item is on the tray and nothing
    /// new has landed on Pippa since (otherwise the line belongs to the tray; the letter waits until the new item is gone).
    var isActive: Bool {
        if pendingCall { return true }
        guard let current = session, let itemID = current.itemID, let model else { return false }
        let items = model.tray.items
        guard items.contains(where: { $0.id == itemID }) else { return false }
        let claimed = current.claimedAt
        let newer = items.contains { item in item.role == .given && item.id != itemID && item.addedAt > claimed }
        return !newer
    }

    /// Is this letter's item still on the tray?
    private var sessionOnTray: Bool {
        guard let itemID = session?.itemID, let model else { return false }
        return model.tray.items.contains { $0.id == itemID }
    }

    /// Is an answer of our own running (draft)? Then everything else waits.
    var isWorking: Bool { isDrafting }

    var hasSession: Bool { session != nil }

    var isDrafting: Bool {
        if case .working = phase { return true }
        return false
    }

    var isInserting: Bool { insertTask != nil }

    /// "Check online" hands the statement to Pi (skill `online-pruefen`, Pippa's web card asks before any lookup).
    var canCheckOnline: Bool { session != nil }

    /// Can the actions be chosen right now?
    var canChoose: Bool {
        guard session != nil else { return false }
        switch phase {
        case .ready, .failure: return true
        default: return false
        }
    }

    // MARK: Call

    /// Call in Mail (pill, shortcut, menu). The line appears at once; reading and first line follow.
    func callMail() {
        guard let model else { return }
        if sessionOnTray, let current = session {
            // A repeated call: the letter takes the line back, even if something else is on Pippa meanwhile.
            session?.claimedAt = Date()
            model.openLine()
            recheck(current.id)
            return
        }
        if pendingCall, phase == .calling {
            model.openLine()
            return
        }
        // Also after a sentence ("Mail is not open.") or before the prompt: start over, Mail may be ready now.
        end()
        pendingCall = true
        phase = .calling
        callingText = FirstLineBuilder.calling(sender: nil)
        model.openLine()
        callTask = Task { [weak self] in await self?.checkAccess() }
    }

    /// "Continue" after the sentence before the system prompt.
    func continueAfterPermission() {
        guard case .permission(denied: false) = phase, let model else { return }
        model.taskLog.event(.permissionAsked)
        phase = .calling
        let engine = model.engine
        callTask = Task { [weak self] in
            let access = await engine.requestIntegrationAccess(.mail)
            guard let self, self.pendingCall else { return }
            if access == .granted {
                self.model?.taskLog.event(.granted)
                await self.read()
            } else {
                self.model?.taskLog.event(.declined)
                self.phase = .permission(denied: true)
            }
        }
    }

    /// "Open Settings": Privacy → Automation.
    func openMailSettings() {
        NSWorkspace.shared.open(Integration.mail.settingsURL)
        model?.collapse()
        end()
    }

    private func checkAccess() async {
        guard let model else { return }
        let access = await model.engine.integrationAccess(.mail)
        guard pendingCall else { return }
        switch access {
        case .granted:
            await read()
        case .notDetermined:
            phase = .permission(denied: false)
        case .denied:
            phase = .permission(denied: true)
        case .unavailable:
            phase = .failure(T("Mail is not open.", table: "Call"))
        }
    }

    private func read() async {
        guard let model else { return }
        let selected: MailMessage?
        do {
            selected = try await model.engine.selectedMail()
        } catch {
            guard pendingCall else { return }
            phase = .failure(UserMessage.text(for: error, context: "brief"))
            return
        }
        guard pendingCall else { return }
        guard let mail = selected else {
            // Nothing chosen: if something is already ready, behave like an ordinary click on the pill.
            if model.parked != nil || !model.tray.items.isEmpty {
                end()
                model.openPillDefault()
                return
            }
            phase = .failure(T("Nothing is selected in Mail.", table: "Call"))
            return
        }
        await begin(mail)
    }

    /// Mail read: .eml onto the tray, first line, type actions; then sharpening and suggestions in the background.
    private func begin(_ mail: MailMessage) async {
        guard let model else { return }
        let origin = T("Mail", table: "Call")
        // The same mail is already on Pippa (earlier call): no second item, same .eml. The file name comes only
        // from the subject; only identical content makes it the same mail (two mails "Invoice" are two items).
        let emlText = mail.emlText
        let existing = model.tray.items.first { item in
            guard item.role == .given, item.origin == origin, item.url.lastPathComponent == mail.fileName else { return false }
            return (try? String(contentsOf: item.url, encoding: .utf8)) == emlText
        }
        let url: URL
        if let existing {
            url = existing.url
        } else {
            do {
                url = try Inbox.freshFolder().appendingPathComponent(mail.fileName)
                try emlText.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                guard pendingCall else { return }
                phase = .failure(UserMessage.text(for: error, context: "brief"))
                return
            }
        }
        // The patterns run briefly over the mail text (milliseconds); still, long mails stay off the main thread.
        // On a GCD queue, not in the cooperative pool (long mails, many patterns).
        var facts = await withCheckedContinuation { (continuation: CheckedContinuation<LetterFacts, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: LetterReading.facts(mail: mail)) }
        }
        // Deadlines point to the real .eml (calendar note, source), not to the placeholder from `facts(mail:)`.
        facts.deadlines = facts.deadlines.map { deadline in
            var d = deadline
            d.source = url
            return d
        }
        if var best = facts.deadline {
            best.source = url
            facts.deadline = best
        }
        guard pendingCall else { return }
        callingText = FirstLineBuilder.calling(sender: facts.sender)
        let known = await loadedRecords()
        guard pendingCall else { return }
        if existing == nil { model.tray.add([url], origin: origin) }
        let key = url.standardizedFileURL.path
        let itemID = model.tray.items.first { $0.url.standardizedFileURL.path == key }?.id
        let started = Session(mail: mail, emlURL: url, taskID: "letter-" + UUID().uuidString, itemID: itemID)
        session = started
        pendingCall = false
        self.facts = facts
        firstLine = FirstLineBuilder.line(facts)
        actions = LetterActions.fallback(kind: facts.taskKind, source: facts.sender, records: known)
        note = Self.attachmentNote(facts.attachmentNames)
        choseSinceOpen = false
        phase = .ready
        refine(facts, body: mail.body, sid: started.id)
    }

    /// A repeated call while a letter is open: if a different mail is selected meanwhile, Pippa starts with it.
    private func recheck(_ sid: UUID) {
        guard let model else { return }
        let engine = model.engine
        callTask?.cancel()
        callTask = Task { [weak self] in
            guard await engine.integrationAccess(.mail) == .granted else { return }
            guard let selected = try? await engine.selectedMail() else { return }
            guard let self, let current = self.session, current.id == sid else { return }
            if Self.sameMessage(selected, current.mail) { return }
            self.end()
            self.pendingCall = true
            self.phase = .calling
            self.callingText = FirstLineBuilder.calling(sender: nil)
            await self.begin(selected)
        }
    }

    /// Same mail? Exactly by identifier if present, otherwise by subject, sender and date.
    static func sameMessage(_ a: MailMessage, _ b: MailMessage) -> Bool {
        if let x = a.messageID, let y = b.messageID { return x == y }
        return a.subject == b.subject && a.sender == b.sender && a.date == b.date
    }

    /// One sentence about the attachment: prefer naming a PDF, otherwise the first name.
    static func attachmentNote(_ names: [String]) -> String? {
        let pdf = names.first { $0.lowercased().hasSuffix(".pdf") }
        guard let name = pdf ?? names.first else { return nil }
        return T("I can read this mail but not its attachment %@; drop it on me.", table: "Call", name)
    }

    private func loadedRecords() async -> [TaskRecord] {
        if let records { return records }
        guard let model else { return [] }
        let generation = habitGeneration
        let loaded = await model.taskLog.records(limit: 500)
        // A caller awaiting the old read may continue, but it only receives the current cache (or no habits).
        guard habitGeneration == generation else { return records ?? [] }
        records = loaded
        return loaded
    }

    /// Forgetting learned actions also updates the current letter, without discarding its draft.
    func reloadHabits() async {
        habitGeneration += 1
        let generation = habitGeneration
        records = nil
        let loaded = await loadedRecords()
        guard habitGeneration == generation, session != nil, let facts, !actions.contains(where: { $0.proposed }) else { return }
        actions = LetterActions.fallback(kind: facts.taskKind, source: facts.sender, records: loaded)
    }

    /// Only when the code found neither deadline nor amount: the system model sharpens the line (at most 2.5 s, never the large one).
    private func refine(_ facts: LetterFacts, body: String, sid: UUID) {
        guard facts.deadline == nil, facts.amount == nil, let system = AppleQuickModel.system else { return }
        refineTask = Task { [weak self] in
            let better = await FirstLineBuilder.refined(facts, text: body, model: system)
            guard let self, let better, self.session?.id == sid else { return }
            self.firstLine = better
        }
    }

    /// Stop its own running answer and wait before the next begins (the engine takes only one).
    private func settle() async {
        guard model != nil else { return }
        let running = [draftTask].compactMap { $0 }
        if isWorking { await Self.cancel(pi: piDrafting) }
        for task in running { await task.value }
    }

    /// A draft runs through Pi (PiRPCChat). Only then does "Stop" also stop Pi; an answer in the conversation
    /// stays untouched.
    private var piDrafting = false

    private static func cancel(pi: Bool) async {
        if pi { await PiRPCChat.conversation.cancel() }
    }

    // MARK: Choosing

    /// Return in the empty field: the first action (or "Continue" before the system prompt).
    func chooseFirst() {
        if case .permission(denied: false) = phase { return continueAfterPermission() }
        guard canChoose, let first = actions.first else { return }
        choose(first)
    }

    func choose(_ action: LetterAction) {
        guard canChoose, let current = session, let facts, chooseTask == nil else { return }
        choseSinceOpen = true
        let offered = actions.map(\.id)
        records?.insert(TaskRecord(kind: facts.taskKind, sourceLabel: facts.sender, offered: offered, chosen: action.id), at: 0)
        let sid = current.id
        chooseTask = Task { [weak self] in
            guard let self else { return }
            await self.settle()
            self.chooseTask = nil
            guard self.session?.id == sid else { return }
            self.run(action, offered: offered)
        }
    }

    private func run(_ action: LetterAction, offered: [String]) {
        guard let model, let facts else { return }
        if model.busy || model.conversations.isRunning {
            phase = .failure(InferenceError.busy.localizedDescription)
            return
        }
        switch action.handler {
        case .addDate:
            model.taskLog.chose(action.id, offered: offered, kind: facts.taskKind, sourceLabel: facts.sender, bindsReceipt: true)
            // The code has already found the deadlines: go straight to the deadlines flow, without a model. Otherwise it searches as before.
            let found = facts.deadlines
            let sender = facts.sender
            leave {
                if found.isEmpty { model.startDeadlines() } else { model.showDeadlines(found, sender: sender) }
            }
        case .skill(let name):
            if action.writesDraft {
                writeDraft(action, skillName: name, offered: offered)
            } else {
                // Explain, summarize: the conversation takes over.
                model.taskLog.chose(action.id, offered: offered, kind: facts.taskKind, sourceLabel: facts.sender)
                let skill = PippaSkill.bundled.first { $0.name == name }
                let instruction = action.instruction
                leave { model.route(instruction, skill: skill) }
            }
        }
    }

    /// With text to Pippa: the mail goes into the conversation.
    func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let model, !isDrafting, chooseTask == nil else { return }
        question = ""
        guard let current = session else {
            end()
            model.route(q)
            return
        }
        choseSinceOpen = true
        let sid = current.id
        chooseTask = Task { [weak self] in
            guard let self else { return }
            await self.settle()
            self.chooseTask = nil
            guard self.session?.id == sid else { return }
            self.leave { model.route(q) }
        }
    }

    /// Hand the letter to the conversation: item off the tray, session closed, then `then` (skill, question, deadlines).
    private func leave(_ then: @MainActor () -> Void) {
        guard let model, let current = session else { return }
        let url = current.emlURL
        let itemID = current.itemID
        end()
        if let itemID { model.tray.remove(itemID) }
        model.handOver([url], then: then)
    }

    // MARK: Draft

    private func writeDraft(_ action: LetterAction, skillName: String, offered: [String]) {
        guard let model, var current = session, let facts else { return }
        if let reason = model.piSetupBlockedReason {
            phase = .failure(reason)
            return
        }
        current.token = model.taskLog.choseTracked(action.id, offered: offered, kind: facts.taskKind, sourceLabel: facts.sender)
        current.original = ""
        session = current
        draft = ""
        editing = false
        insertProblem = nil
        stopRequested = false
        phase = .working(title: action.workingTitle)
        let sid = current.id
        draftTask = Task { [weak self] in await self?.streamDraft(action, skillName: skillName, sid: sid) }
    }

    private func streamDraft(_ action: LetterAction, skillName: String, sid: UUID) async {
        guard let current = session, current.id == sid else { return }
        await streamPiDraft(action, skillName: skillName, sid: sid, chat: PiRPCChat.conversation, current: current)
    }

    /// Draft through Pi. The mail is shown (.eml), the skill ("antwort-schreiben") is given as instructions
    /// up front (`PiSkillTurn`, text only, create nothing); own Pi session per letter (`taskID`). Whatever Pi writes before a
    /// tool call disappears again (`onReset`), so that only the draft stands in the line.
    private func streamPiDraft(_ action: LetterAction, skillName: String, sid: UUID, chat: any ConversationChat, current: Session) async {
        piDrafting = true
        defer { piDrafting = false }
        let skill = PippaSkill.bundled.first { $0.name == skillName }
        let context = ChatContext(files: [current.emlURL], focusedFiles: [current.emlURL])
        do {
            if stopRequested || Task.isCancelled { throw CancellationError() }
            let answer = try await chat.answer(action.instruction, taskID: current.taskID, context: context, newFiles: [current.emlURL],
                                              skill: skill, draftOnly: true,
                                              onDelta: { [weak self] delta in Task { @MainActor [weak self] in self?.grow(delta, sid: sid) } },
                                              onSteered: { _ in },
                                              onReset: { [weak self] text in Task { @MainActor [weak self] in self?.resetDraft(text, sid: sid) } }).text
            if let actions = chat.takeShownActions(), !actions.items.isEmpty {
                // The line has no room for receipts; what Pi did anyway is in the log (without contents).
                DiagnosticsLog.shared.event("brief-entwurf-werkzeuge", ["anzahl": String(actions.items.count),
                                                                         "arten": actions.items.map(\.action).joined(separator: ",")])
            }
            guard session?.id == sid else { return }
            finishDraft(answer)
        } catch {
            _ = chat.takeShownActions()
            guard session?.id == sid else { return }
            if case AnswerFailure.stopped(let partial) = error { return finishDraft(partial) }
            if stopRequested || error is CancellationError { return finishDraft(draft) }
            phase = .failure(PiRPCChat.userText(for: error, context: "brief"))
        }
    }

    private func grow(_ delta: String, sid: UUID) {
        guard session?.id == sid, isDrafting else { return }
        draft += delta
    }

    private func resetDraft(_ text: String, sid: UUID) {
        guard session?.id == sid, isDrafting else { return }
        draft = text
    }

    /// Done or stopped: what is written stays as the draft; if empty, back to the actions.
    private func finishDraft(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stopRequested = false
        guard !clean.isEmpty else {
            draft = ""
            phase = .ready
            return
        }
        draft = clean
        session?.original = clean
        phase = .draft
    }

    /// "Stop": the running draft stops.
    func stop() {
        guard isDrafting else { return }
        stopRequested = true
        let pi = piDrafting
        Task { await Self.cancel(pi: pi) }
    }

    /// ⌘Return: unsent reply to the captured original mail; no silent compose fallback.
    func insert() {
        guard phase == .draft, !insertUncertain, let model, let current = session, insertTask == nil else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let replyTo = current.mail.replyTo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let recipient = MailAddress.parse(replyTo.isEmpty ? current.mail.sender : replyTo)
        let mailDraft = MailDraft(messageID: current.mail.messageID, to: recipient.address, toName: recipient.name,
                                  subject: current.mail.subject, body: body, locator: current.mail.locator)
        let edited = body != current.original
        let sid = current.id
        insertProblem = nil
        editing = false
        let engine = model.engine
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor [weak self] in
                guard let self, self.insertTask != nil, self.session?.id == sid else { return }
                self.insertSearch = (done, total)
            }
        }
        insertTask = Task { [weak self] in
            do {
                let result = try await MailOriginalSearch.$progress.withValue(progress) {
                    try await engine.insertMailReply(mailDraft)
                }
                guard let self else { return }
                self.insertTask = nil
                self.insertSearch = nil
                guard self.session?.id == sid else { return }
                if result == .replyNeedsPaste {
                    // Honest fallback: the threaded reply is open, the text goes in with one ⌘V.
                    self.copyDraft()
                    self.phase = .pasteReady
                } else {
                    self.phase = .inserted(viaReply: result == .reply)
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
                if let token = self.session?.token {
                    self.model?.taskLog.inserted(token, edited: edited)
                    self.session?.token = nil
                }
            } catch {
                guard let self else { return }
                self.insertTask = nil
                self.insertSearch = nil
                guard self.session?.id == sid else { return }
                if let message = Self.retryableInsertProblem(error) {
                    self.insertProblem = message
                } else {
                    self.insertUncertain = true
                    self.insertProblem = T("The reply could not be confirmed. Check Mail before continuing; an unsent reply may already be open.", table: "App")
                }
            }
        }
    }

    /// Failures that leave nothing in Mail: Insert stays available. `nil`: a reply may exist, the person checks Mail first.
    static func retryableInsertProblem(_ error: Error) -> String? {
        if error is CancellationError { return T("Stopped. Nothing was opened in Mail.", table: "App") }
        switch error as? MailReplyFailure {
        case .missingOriginal:
            return T("The original email was not found in Mail. No new message was created. Copy the draft and reply manually.", table: "App")
        case .ambiguousOriginal:
            return T("Several emails in Mail have this Message-ID. No reply was opened. Copy the draft and choose the original manually.", table: "App")
        case .notCreated:
            return T("Mail couldn’t open the reply just now. Nothing was opened in Mail. You can try again.", table: "App")
        case .searchIncomplete:
            return T("I couldn’t search all of Mail in time and didn’t find the original. Nothing was opened. Try again when Mail has finished loading.", table: "App")
        case .unconfirmed: return nil
        case nil: break
        }
        switch error as? PippaError {
        case .accessDenied, .appNotOpen: return UserMessage.text(for: error, context: "mail")
        default: return nil
        }
    }

    /// Stop while Insert is still looking for the original. Nothing is in Mail yet at that point.
    func stopInsert() {
        guard insertSearch != nil else { return }
        insertTask?.cancel()
    }

    /// After „check Mail first“: one explicit click clears the guard and inserts again.
    func insertAgain() {
        guard insertUncertain, insertTask == nil, phase == .draft else { return }
        insertUncertain = false
        insert()
    }

    func copyDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func toggleEdit() {
        guard phase == .draft else { return }
        editing.toggle()
    }

    // MARK: Check online

    /// "Check online" on a deadline: the conversation takes over with skill `online-pruefen` and only the general
    /// statement about the deadline. Pi searches with Pippa's web tool, whose card shows the exact query first and whose
    /// QueryGuard keeps personal details out.
    func checkOnline(_ deadline: Deadline) {
        guard canCheckOnline, let model, !isDrafting, chooseTask == nil else { return }
        guard !model.busy, !model.conversations.isRunning else { return }
        guard let skill = PippaSkill.bundled.first(where: { $0.name == "online-pruefen" }) else { return }
        let statement = FirstLineBuilder.statement(for: deadline)
        leave { model.route(statement, skill: skill) }
    }

    // MARK: Line open, closed, end

    /// The line opens with this letter (AppModel.openLine): if actions are shown, this opening counts for the log.
    func lineOpened() {
        guard session != nil else { return }
        choseSinceOpen = phase != .ready
    }

    /// The line closes. Without a choice, logged as "passed over" (once per opening). A draft stays.
    func lineClosed() {
        guard session != nil else {
            // While reading, keep reading; sentence before the prompt or error without a letter: done.
            if phase != .calling { end() }
            return
        }
        if !choseSinceOpen, let facts, !actions.isEmpty {
            let ids = actions.map(\.id)
            model?.taskLog.ignored(offered: ids, kind: facts.taskKind, sourceLabel: facts.sender)
            records?.insert(TaskRecord(kind: facts.taskKind, sourceLabel: facts.sender, offered: ids, chosen: nil), at: 0)
        }
        choseSinceOpen = true
        editing = false
        switch phase {
        case .working, .draft:
            // A draft (finished or growing) stays; the next click on the pill shows it again.
            break
        default:
            // Read, passed over, inserted or a sentence: the letter steps back. The mail stays on the tray as a given item
            // (tray line with its actions); a new call in Mail brings the letter back.
            end()
        }
    }

    /// End everything: stop own answers, forget this letter's Pi session, clear state.
    func end() {
        let ending = session
        if isWorking {
            let pi = piDrafting
            Task { await Self.cancel(pi: pi) }
        }
        callTask?.cancel(); callTask = nil
        refineTask?.cancel(); refineTask = nil
        draftTask?.cancel(); draftTask = nil
        if let ending {
            // The Pi session of this letter (draft) goes to the trash instead of being deleted for good.
            let taskID = ending.taskID
            let chat = PiRPCChat.conversation
            Task { await chat.forget([taskID]) }
        }
        session = nil
        insertUncertain = false
        insertSearch = nil
        pendingCall = false
        stopRequested = false
        phase = .idle
        callingText = ""
        firstLine = nil
        facts = nil
        actions = []
        draft = ""
        editing = false
        note = nil
        insertProblem = nil
        choseSinceOpen = true
    }

    /// If the letter's item leaves the tray (✕, fading, hand-over), the letter ends.
    private func watchTray() {
        trayWatch = model?.tray.$state.sink { [weak self] state in
            let ids = Set(state.items.map(\.id))
            Task { @MainActor [weak self] in self?.trayChanged(ids) }
        }
    }

    private func trayChanged(_ ids: Set<UUID>) {
        guard let itemID = session?.itemID, !ids.contains(itemID) else { return }
        // First check that it is really gone (the published field may already be different again).
        if model?.tray.items.contains(where: { $0.id == itemID }) == true { return }
        end()
    }
}
