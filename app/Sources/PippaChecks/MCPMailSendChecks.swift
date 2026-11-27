import Foundation
import PiRPC
import PippaCore

/// `mail_send` (PippaMCPMailSend.swift) against a fake Mail: never the real Mail. The fake keeps open draft windows,
/// counts send events, and files sent mails in a Sent list that appears after a chosen number of looks.
final class FakeMailSend: MailSending, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [Int: MailOutgoing] = [:]
    /// Mail's id for the next draft window (Mail's first draft of a session can have id 0).
    var nextID = 100
    /// What left, and when (the real clock: the tool's cut-offs come from it as well).
    private var sentMails: [(mail: MailOutgoing, at: Date)] = []
    private var sends = 0, sendCalls = 0, polls = 0
    /// Sent shows the mail from this look on (1 = the first look, the one before the send event); `Int.max`: never.
    var visibleFrom = 1
    /// Mails in Sent from before (an earlier reply in the same thread), sent at `earlierAt`: on every look that reaches
    /// back that far.
    var earlier: [MailSentEntry] = []
    var earlierAt = Date().addingTimeInterval(-10)
    /// Another mail that lands in Sent at the send event, whatever `visibleFrom` says.
    var other: [MailSentEntry] = []
    /// The snapshot before the send event fails, as with a slow Mail or an account without a Sent mailbox.
    var snapshotFails = false
    /// Every look into Sent: the snapshot or a later look, the address and the cut-off it got.
    private var looks: [(snapshot: Bool, from: String, since: Date)] = []
    var sentLooks: [(snapshot: Bool, from: String, since: Date)] { lock.withLock { looks } }
    /// Mail's process now; `restartMail` gives it a new one, as after quitting and opening Mail again.
    private var process: Int32 = 4242
    func restartMail() { lock.withLock { process += 1 } }
    var several: Set<Int> = []
    /// What the send event reports after the mail left (`.unclear`: Mail did not confirm).
    var outcome: MailSendDispatch = .sent
    /// Runs inside `send` before the window is compared and sent (the journal row must already be on disk).
    var beforeSend: (@Sendable (Int) async -> Void)?
    /// Mail answers the send event with true and sends nothing: the window stays open (seen on a just-made draft).
    var keepsOpen = false
    /// Optional one-shot overrides for `insertDraft` (used to test `.replyNeedsPaste` and insert failures).
    var nextInsertResult: MailInsertResult?
    var nextInsertError: Error?

    var sendCount: Int { lock.withLock { sends } }
    var sendCallCount: Int { lock.withLock { sendCalls } }
    var sentPolls: Int { lock.withLock { polls } }
    var lastID: Int { lock.withLock { nextID - 1 } }

    func edit(_ id: Int, _ change: (inout MailOutgoing) -> Void) { lock.withLock { if var w = windows[id] { change(&w); windows[id] = w } } }
    func close(_ id: Int) { lock.withLock { windows[id] = nil } }

    func insertDraft(_ draft: MailDraft) async throws -> MailDraftInsert {
        try PippaMCPWriteLease.current?.beginDispatch()
        if let error = lock.withLock({ let e = nextInsertError; nextInsertError = nil; return e }) {
            throw error
        }
        let forcedResult = lock.withLock { let r = nextInsertResult; nextInsertResult = nil; return r }
        let id: Int = lock.withLock {
            let id = nextID; nextID += 1
            windows[id] = MailOutgoing(sender: "Pippa Check <me@example.test>", subject: draft.replySubject, body: draft.body,
                                       to: draft.to.map { [$0] } ?? [])
            return id
        }
        return MailDraftInsert(result: forcedResult ?? (draft.isReply ? .reply : .newMessage), outgoingID: id, mailProcess: lock.withLock { process })
    }

    func outgoing(_ id: Int, process: Int32) async throws -> MailOutgoingLookup {
        lock.withLock {
            // A restarted Mail numbers its windows anew: the id may name another draft now.
            guard process == self.process else { return .gone }
            if several.contains(id) { return .several }
            return windows[id].map(MailOutgoingLookup.found) ?? .gone
        }
    }

    func send(_ id: Int, process: Int32, expected: MailOutgoing) async throws -> MailSendDispatch {
        lock.withLock { sendCalls += 1 }
        await beforeSend?(id)
        let window: MailOutgoing? = lock.withLock { process == self.process ? windows[id] : nil }
        guard let window else { return .gone }
        guard window.matches(expected) else { return .changed }
        try PippaMCPWriteLease.current?.beginDispatch()
        return lock.withLock {
            sends += 1
            if keepsOpen { return outcome }
            windows[id] = nil; sentMails.append((window, Date()))
            return outcome
        }
    }

    func sentMessageIDs(subject: String, from address: String, since: Date) async throws -> Set<String> {
        Set(try look(snapshot: true, subject: subject, from: address, since: since).map(\.messageID))
    }

    func sent(subject: String, from address: String, since: Date) async throws -> [MailSentEntry] {
        try look(snapshot: false, subject: subject, from: address, since: since)
    }

    private func look(snapshot: Bool, subject: String, from address: String, since: Date) throws -> [MailSentEntry] {
        try lock.withLock {
            polls += 1
            looks.append((snapshot, address, since))
            if snapshot && snapshotFails { throw PippaError.notAvailable }
            let new = polls >= visibleFrom ? sentMails.enumerated().filter { $0.element.mail.subject == subject && $0.element.at >= since }
                .map { MailSentEntry(messageID: "<sent-\($0.offset)@example.test>", sender: $0.element.mail.sender, to: $0.element.mail.to,
                                     cc: $0.element.mail.cc, bcc: $0.element.mail.bcc) } : []
            let others = sentMails.contains { $0.at >= since } ? other : []
            return (earlierAt >= since ? earlier : []) + others + new
        }
    }
}

func runMCPMailSendChecks() async {
    let context = MCPCheckContext()

    /// A conversation with Pippa's server, a fake Mail, a card that answers through `answer`, and a fake clock.
    final class World: @unchecked Sendable {
        let fake = FakeMailSend()
        let demo = DemoIntegrations(granted: true)
        let turns = PippaMCPTurns()
        let cards = LockedBox<[PippaMCPConfirmation]>([])
        let clock = LockedBox<Duration>(.zero)
        let slept = LockedBox<Int>(0)
        var turn: PippaMCPTurn
        var host: PippaMCPHost
        /// Runs at each wait for Sent (the fake clock moves on by the wait).
        var onSleep: (@Sendable () -> Void)?

        init(conversation: String = "conversation-a", answer: (@Sendable (PippaMCPConfirmation) async -> Bool)?) {
            turn = PippaMCPTurn(conversation: conversation)
            host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo), askForAccess: false)
            host.mailSender = fake
            host.turns = turns
            host.requireActiveWriteTurn = true
            let cards = cards, clock = clock, slept = slept
            if let answer { host.confirmAction = { card in cards.mutate { $0.append(card) }; return await answer(card) } }
            host.mailSendSettle = MailMoveSettle(sleep: { [weak self] d in
                clock.mutate { $0 += d }; slept.mutate { $0 += 1 }
                self?.onSleep?()
            }, now: { clock.value })
            turns.begin(turn)
        }
        var tools: PippaMCPTools { PippaMCPTools(host: host) }
        /// A new answer in the same conversation, or in another one.
        func nextAnswer(conversation: String = "conversation-a") { turn = PippaMCPTurn(conversation: conversation); turns.begin(turn) }
        func stop() { turns.end(turn) }
    }

    func draft(_ world: World, to: String? = "anna@example.test", subject: String = "Termin am Freitag",
               body: String = "Hallo Anna,\n\npasst dir Freitag um 10 Uhr?\n\nViele Grüße", aged: Bool = true) async -> String? {
        var arguments: [String: Any] = ["subject": subject, "body": body]
        if let to { arguments["to"] = to }
        let made = await context.call(world.tools, "mail_draft", arguments)
        // `aged`: the draft is old enough for the send event by the time it is sent (see `minimumDraftAge`).
        if aged { world.clock.mutate { $0 += PippaMCPMailSend.minimumDraftAge } }
        return (made.json["draft"] as? [String: Any])?["id"] as? String
    }
    func send(_ world: World, _ id: String?, extra: [String: Any] = [:]) async -> (json: [String: Any], isError: Bool, bytes: Int) {
        await context.call(world.tools, "mail_send", (["draft": id ?? ""] as [String: Any]).merging(extra) { a, _ in a })
    }
    let yes: @Sendable (PippaMCPConfirmation) async -> Bool = { _ in true }

    // A1: class, lists, annotations, receipts, egress.
    check("Mail send: mail_send is external, listed with openWorldHint, and known to readiness and the receipt") {
        let listed = PippaMCPTools.toolList().first { $0["name"] as? String == "mail_send" }
        let hints = listed?["annotations"] as? [String: Any] ?? [:]
        func classify(_ payload: [String: Any], isError: Bool) -> PiActionRecord.Outcome {
            let text = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
            return PiTurnReceipt.classify(tool: "mcp__pippa__mail_send", isError: isError, result: ["content": [["type": "text", "text": text]]])
        }
        return PippaActionClasses.of("mail_send") == .external && !PippaActionClasses.asksPerStep.contains("mail_send")
            && PippaMCPTools.toolNames.contains("mail_send") && hints["openWorldHint"] as? Bool == true && hints["readOnlyHint"] as? Bool == false
            && PiNativeReadiness.tools.contains("mcp__pippa__mail_send") && PiTurnReceipt.pippaWriters.contains("mail_send")
            && classify(["done": true, "state": "sent", "sent": true], isError: false) == .done
            && classify(["done": false, "state": "unclear"], isError: false) == .unclear
            && classify(["done": false, "status": "draft_changed", "dispatched": false], isError: true) == .blocked
    }
    check("Mail send: every status mail_send returns before the send event is a no-effect status for the receipt and for pippa-assist") {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let tool = try? String(contentsOf: checkout.appendingPathComponent("app/Sources/PippaCore/MCP/PippaMCPMailSend.swift"), encoding: .utf8),
              let assist = try? String(contentsOf: checkout.appendingPathComponent("runtime/pippa-tools/pippa-assist.ts"), encoding: .utf8),
              let open = assist.range(of: "const NATIVE_NO_EFFECT = new Set(["),
              let close = assist.range(of: "]);", range: open.upperBound..<assist.endIndex),
              let literal = try? NSRegularExpression(pattern: #"(?:refuse|notSent)\("([a-z_]+)""#) else { return false }
        let listed = String(assist[open.upperBound..<close.lowerBound])
        // Each status the tool's own code refuses with, plus those of the shared steps before the send event: the
        // argument check, the egress rule, Mail's access (`ensure`) and the card (`gate`).
        let own = literal.matches(in: tool, range: NSRange(tool.startIndex..., in: tool)).compactMap { Range($0.range(at: 1), in: tool).map { String(tool[$0]) } }
        let statuses = Set(own + ["draft_changed", "invalid_arguments", "stays_on_mac", "needs_access", "denied", "unavailable", "failed",
                                  "cancelled", "declined"])
        func outcome(_ status: String) -> PiActionRecord.Outcome {
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["done": false, "status": status, "dispatched": false]), as: UTF8.self)
            return PiTurnReceipt.classify(tool: "mcp__pippa__mail_send", isError: true, result: ["content": [["type": "text", "text": text]]])
        }
        let missing = statuses.filter { !listed.contains("\"\($0)\"") || outcome($0) != .blocked }
        if !missing.isEmpty { print("  not in both no-effect lists: \(missing.sorted())") }
        return own.contains("no_sender") && own.contains("unknown_draft") && missing.isEmpty
    }
    await checkAsync("Mail send: an online AI without Mac access can neither list nor call mail_send") {
        let world = World(answer: yes)
        let id = await draft(world)
        world.host.egress = PippaMCPEgress(rules: SourceSharing(), web: true)
        let list = await context.rpc(world.tools, "tools/list")
        let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let called = await send(world, id)
        return id != nil && !names.contains("mail_send") && names.contains("mail_draft") && !(world.host.egress?.tools.contains("mail_send") ?? true)
            && called.isError && called.json["status"] as? String == "stays_on_mac"
            && world.cards.value.isEmpty && world.fake.sendCallCount == 0
    }

    // A2: without a yes nothing is sent.
    await checkAsync("Mail send: without a yes it never sends, direct, declined, with a forged confirmed field, or from a script") {
        let none = World(answer: nil)
        let a = await send(none, await draft(none))
        let no = World(answer: { _ in false })
        let noID = await draft(no)
        let b = await send(no, noID)
        let forged = World(answer: { _ in false })
        let c = await send(forged, await draft(forged), extra: ["confirmed": true, "approved": "yes"])
        // A call from a codemode script reaches the server the same way; Pippa's server cannot tell it apart, so the
        // card is unconditional. Pi's parent call id, if it were sent, changes nothing.
        let script = World(answer: { _ in false })
        let scriptID = await draft(script)
        _ = await context.rpc(script.tools, "tools/call", ["name": "mail_send", "arguments": ["draft": scriptID ?? ""],
                                                           "_meta": ["parentToolCallId": "codemode-1"]])
        let worlds = [none, no, forged, script]
        return worlds.allSatisfy { $0.fake.sendCount == 0 && $0.fake.sendCallCount == 0 }
            && a.json["dispatched"] as? Bool == false && b.json["status"] as? String == "declined" && no.cards.value.count == 1
            && c.isError && c.json["status"] as? String == "invalid_arguments" && forged.cards.value.isEmpty
            && script.cards.value.count == 1 && noID.flatMap { no.host.mailDrafts.state($0) } == .open
    }

    // A3: with a yes, once, and the card shows the draft as Mail has it at that moment.
    await checkAsync("Mail send: with a yes it sends once; the card shows the draft as Mail has it now, edits included") {
        let world = World(answer: yes)
        let id = await draft(world)
        let window = world.fake.lastID
        world.fake.edit(window) { $0.subject = "Termin am Freitag – neue Zeit"; $0.cc = ["ben@example.test"] }
        let result = await send(world, id)
        let card = world.cards.value.first
        let shown = card?.message ?? ""
        return !result.isError && result.json["done"] as? Bool == true && result.json["sent"] as? Bool == true
            && result.json["verified"] as? String == "1 of 1" && world.fake.sendCount == 1 && world.fake.sendCallCount == 1
            && world.cards.value.count == 1 && card?.actionClass == .external && card?.turnID == world.turn.id
            && shown.contains("Termin am Freitag – neue Zeit") && shown.contains("ben@example.test") && shown.contains("anna@example.test")
            && card?.content == "Hallo Anna,\n\npasst dir Freitag um 10 Uhr?\n\nViele Grüße"
            && card?.confirmLabel != nil && card?.declineLabel != nil && id.flatMap { world.host.mailDrafts.state($0) } == .sent
    }
    await checkAsync("Mail send: a draft from an earlier answer in the same conversation can be sent") {
        let world = World(answer: yes)
        let id = await draft(world)
        world.nextAnswer()
        let result = await send(world, id)
        return result.json["done"] as? Bool == true && world.fake.sendCount == 1
    }

    // Mail's first draft of a session can have id 0; a draft Mail gave no id ("none") gets no draft id.
    await checkAsync("Mail send: a draft whose Mail id is 0 gets a draft id and can be sent; Mail's \"none\" gives no draft id") {
        let world = World(answer: yes)
        world.fake.nextID = 0
        let id = await draft(world)
        let result = await send(world, id)
        func made(_ reported: ScriptValue) async throws -> Int? {
            let mail = MailDraft(messageID: nil, to: "anna@example.test", toName: nil, subject: "Termin", body: "Hallo Anna",
                                 isReply: false, exactSubject: true)
            let runner: MailReplyScript.StepRunner = { _, _, _ in [.text("Termin"), .text("Hallo Anna"), .list([.text("anna@example.test")]), reported] }
            return try await MailReplyScript.insertDraft(mail, runner: runner).outgoingID
        }
        let zero = try await made(.number(0)), none = try await made(.text("none")), negative = try await made(.number(-3))
        return id != nil && world.fake.lastID == 0 && result.json["verified"] as? String == "1 of 1" && world.fake.sendCount == 1
            && zero == 0 && none == nil && negative == -3
    }

    // Mail drops a send of a draft made a second ago (iCloud probe, November 2026): the send event waits for its age.
    await checkAsync("Mail send: a draft made just now is sent only after minimumDraftAge; an older one at once; Stop in the wait sends nothing") {
        let fresh = World(answer: yes)
        let atSend = LockedBox<Duration?>(nil)
        fresh.fake.beforeSend = { _ in atSend.mutate { $0 = fresh.clock.value } }
        let freshResult = await send(fresh, await draft(fresh, aged: false))
        let old = World(answer: yes)
        let oldSlept = LockedBox<Int?>(nil)
        old.fake.beforeSend = { _ in oldSlept.mutate { $0 = old.slept.value } }
        let oldResult = await send(old, await draft(old))
        let stopping = World(answer: yes)
        let journal = try Executor(baseDirectory: root.appendingPathComponent("send-age-stop-" + UUID().uuidString))
        stopping.host.reminderJournal = journal; stopping.host.requiresReminderJournal = true
        let stopID = await draft(stopping, aged: false)
        stopping.onSleep = { stopping.stop() }
        let run = stopping.turn.id
        let stopped = await send(stopping, stopID)
        let rows = try await journal.runActions(run: run).filter { $0.tool == "mail_send" }
        return freshResult.json["verified"] as? String == "1 of 1" && fresh.fake.sendCount == 1
            && (atSend.value ?? .zero) >= PippaMCPMailSend.minimumDraftAge && fresh.slept.value >= 1
            && oldResult.json["verified"] as? String == "1 of 1" && oldSlept.value == 0
            && stopped.json["status"] as? String == "cancelled" && stopping.fake.sendCallCount == 0 && rows.isEmpty
            && stopping.slept.value == 1 && stopID.flatMap { stopping.host.mailDrafts.state($0) } == .open
    }

    // Mail answered true and the draft stayed open: not sent, unclear, never sent again, Sent not searched.
    await checkAsync("Mail send: send answers true but the draft stays open: unclear with its own reason, one send event, Sent skipped") {
        let world = World(answer: yes)
        world.fake.keepsOpen = true
        let journal = try Executor(baseDirectory: root.appendingPathComponent("send-still-open-" + UUID().uuidString))
        world.host.reminderJournal = journal; world.host.requiresReminderJournal = true
        let receipts = LockedBox<[PippaMCPWriteReceipt]>([])
        world.host.onWrite = { receipt in receipts.mutate { $0.append(receipt) } }
        let id = await draft(world)
        let run = world.turn.id
        let start = world.clock.value
        let result = await send(world, id)
        let again = await send(world, id)
        let rows = try await journal.runActions(run: run).filter { $0.tool == "mail_send" }
        let tell = result.json["tell"] as? String ?? ""
        let english = L("Mail hasn’t sent the mail: the draft is still open in Mail. Please look there and press Send in Mail; Pippa won’t send it again.", table: "MCP")
        return result.json["state"] as? String == "unclear" && result.json["done"] as? Bool == false && tell == english
            && receipts.value.first { $0.action == "mailSend" }?.reason == "stillOpen"
            && world.fake.sendCallCount == 1 && world.fake.sendCount == 1 && world.fake.sentPolls == 1
            && world.clock.value - start >= PippaMCPMailSend.closeBound
            && rows.count == 1 && rows[0].state == .unclear && id.flatMap { world.host.mailDrafts.state($0) } == .unclear
            && again.json["status"] as? String == "already_sent" && world.fake.sendCallCount == 1
    }

    // A4: changed between the card and the send event.
    await checkAsync("Mail send: a draft changed after the card is not sent, says so, and leaves no done row") {
        let world = World(answer: { _ in true })
        let journal = try Executor(baseDirectory: root.appendingPathComponent("send-changed-" + UUID().uuidString))
        world.host.reminderJournal = journal; world.host.requiresReminderJournal = true
        let id = await draft(world)
        let window = world.fake.lastID
        // The person edits the mail while the card is open, then presses Send.
        world.host.confirmAction = { _ in world.fake.edit(window) { $0.body += "\nPS: Bring den Schlüssel mit." }; return true }
        let result = await send(world, id)
        // Changed inside the send event itself (after Pippa's second read): Mail's own comparison refuses.
        let late = World(answer: yes)
        let lateJournal = try Executor(baseDirectory: root.appendingPathComponent("send-late-" + UUID().uuidString))
        late.host.reminderJournal = lateJournal; late.host.requiresReminderJournal = true
        let lateID = await draft(late)
        let lateWindow = late.fake.lastID
        late.fake.beforeSend = { _ in late.fake.edit(lateWindow) { $0.to.append("chris@example.test") } }
        let second = await send(late, lateID)
        let rows = try await journal.runActions(run: world.turn.id).filter { $0.tool == "mail_send" }
        let lateRows = try await lateJournal.runActions(run: late.turn.id).filter { $0.tool == "mail_send" }
        let tell = result.json["tell"] as? String ?? ""
        return [result, second].allSatisfy { $0.json["status"] as? String == "draft_changed" && $0.json["dispatched"] as? Bool == false }
            && !tell.isEmpty && world.fake.sendCount == 0 && late.fake.sendCount == 0 && rows.isEmpty && lateRows.isEmpty
            && id.flatMap { world.host.mailDrafts.state($0) } == .open
    }

    // A5: refusals before any card.
    await checkAsync("Mail send: unknown, foreign, other-conversation, sent, gone, ambiguous, no recipient and empty drafts are refused before any card") {
        let world = World(answer: yes)
        let made = await send(world, "d0000deadbeef")
        let other = World(answer: yes)
        let foreign = await send(world, await draft(other))
        let id = await draft(world)
        world.nextAnswer(conversation: "conversation-b")
        let otherConversation = await send(world, id)
        world.nextAnswer()
        _ = await send(world, id)
        let cardsAfterSend = world.cards.value.count
        let again = await send(world, id)
        let goneID = await draft(world)
        world.fake.close(world.fake.lastID)
        let gone = await send(world, goneID)
        let severalID = await draft(world)
        world.fake.several = [world.fake.lastID]
        let several = await send(world, severalID)
        let nobody = await send(world, await draft(world, to: nil))
        let emptyID = await draft(world)
        world.fake.edit(world.fake.lastID) { $0.body = " \n " }
        let empty = await send(world, emptyID)
        let statuses = [made, foreign, otherConversation, again, gone, several, nobody, empty].map { $0.json["status"] as? String ?? "?" }
        let allRefused = [made, foreign, otherConversation, again, gone, several, nobody, empty].allSatisfy {
            $0.isError && $0.json["dispatched"] as? Bool == false && $0.json["sent"] as? Bool == false && !($0.json["tell"] as? String ?? "").isEmpty
        }
        if statuses != ["unknown_draft", "unknown_draft", "unknown_draft", "already_sent", "draft_gone", "ambiguous", "no_recipient", "empty_body"] {
            print("  statuses: \(statuses)")
        }
        return allRefused && statuses == ["unknown_draft", "unknown_draft", "unknown_draft", "already_sent", "draft_gone", "ambiguous", "no_recipient", "empty_body"]
            && cardsAfterSend == 1 && world.cards.value.count == 1 && world.fake.sendCount == 1 && other.fake.sendCallCount == 0
    }

    // A6: verification in Sent, bounded, and Stop.
    await checkAsync("Mail send: found in Sent after a few looks is verified; never found is unclear after the bound and not sent again") {
        let late = World(answer: yes)
        late.fake.visibleFrom = 5
        let found = await send(late, await draft(late))
        let never = World(answer: yes)
        never.fake.visibleFrom = .max
        let neverID = await draft(never)
        let unclear = await send(never, neverID)
        let again = await send(never, neverID)
        let bound = Int(PippaMCPMailSend.sentBound.components.seconds / PippaMCPMailSend.sentInterval.components.seconds)
        return found.json["verified"] as? String == "1 of 1" && late.fake.sentPolls == 5 && late.slept.value == 3
            && unclear.json["state"] as? String == "unclear" && unclear.json["done"] as? Bool == false
            && never.fake.sentPolls == bound + 2 && never.clock.value >= PippaMCPMailSend.sentBound
            && never.fake.sendCount == 1 && never.fake.sendCallCount == 1
            && again.json["status"] as? String == "already_sent" && neverID.flatMap { never.host.mailDrafts.state($0) } == .unclear
    }
    await checkAsync("Mail send: a mail already in Sent, or another one that only shares sender, subject and To, never verifies the send") {
        // An earlier reply in the thread: same subject, sender and To, in Sent before the send event.
        let thread = World(answer: yes)
        thread.fake.visibleFrom = .max
        thread.fake.earlier = [MailSentEntry(messageID: "<earlier@example.test>", sender: "Pippa Check <me@example.test>", to: ["anna@example.test"])]
        let earlier = await send(thread, await draft(thread))
        // A Cc-only mail: another mail to nobody in To, Cc someone else, lands in Sent at the same time.
        let ccOnly = World(answer: yes)
        ccOnly.fake.visibleFrom = .max
        ccOnly.fake.other = [MailSentEntry(messageID: "<other@example.test>", sender: "Pippa Check <me@example.test>", to: [], cc: ["chris@example.test"])]
        let ccID = await draft(ccOnly, to: nil)
        ccOnly.fake.edit(ccOnly.fake.lastID) { $0.cc = ["ben@example.test"] }
        let cc = await send(ccOnly, ccID)
        // The same Cc-only mail, found in Sent: verified.
        let found = World(answer: yes)
        let foundID = await draft(found, to: nil)
        found.fake.edit(found.fake.lastID) { $0.cc = ["ben@example.test"]; $0.bcc = ["dora@example.test"] }
        let verified = await send(found, foundID)
        return [earlier, cc].allSatisfy { $0.json["state"] as? String == "unclear" && $0.json["verified"] == nil }
            && thread.fake.sendCount == 1 && ccOnly.fake.sendCount == 1 && verified.json["verified"] as? String == "1 of 1"
    }
    await checkAsync("Mail send: the snapshot of Sent and every later look get one fixed cut-off and the sender's address; Sent mails count by Message-ID") {
        let world = World(answer: yes)
        world.fake.visibleFrom = 3
        let result = await send(world, await draft(world))
        let looks = world.fake.sentLooks
        // The script gets the cut-off itself, never an age from Mail's clock, and reads Message-IDs, not Mail's ids.
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let args = LockedBox<[[ScriptArgument]]>([])
        let runner: MailSendScript.StepRunner = { handler, given, _ in
            args.mutate { $0.append(given) }
            if handler == "sentIDs" { return [.text("ok"), .list([.text("<a@example.test>")])] }
            return [.text("ok"), .list([.list([.text("<a@example.test>"), .text("Me <me@example.test>"), .list([.text("anna@example.test")]),
                                               .list([]), .list([])])])]
        }
        let ids = try await MailSendScript.sentMessageIDs(subject: "S", from: "me@example.test", since: cutoff, runner: runner)
        let entries = try await MailSendScript.sent(subject: "S", from: "me@example.test", since: cutoff, runner: runner)
        return result.json["verified"] as? String == "1 of 1" && looks.count == 3 && looks[0].snapshot && !looks[1].snapshot
            && Set(looks.map(\.since)).count == 1 && looks.allSatisfy { $0.from == "me@example.test" }
            && looks[0].since.timeIntervalSince1970 == looks[0].since.timeIntervalSince1970.rounded(.down)
            && args.value.count == 2 && args.value.allSatisfy { $0.count == 4 && $0[1] == .text("me@example.test") && $0[2] == .date(cutoff) }
            && ids == ["<a@example.test>"] && entries.map(\.messageID) == ["<a@example.test>"]
    }
    await checkAsync("Mail send: an unreadable snapshot of Sent never blocks the send; then only exactly one copy sent from the send event on verifies") {
        // One copy: verified. An identical earlier reply, sent before the send event, is out of reach and changes nothing.
        let one = World(answer: yes)
        one.fake.snapshotFails = true
        one.fake.earlier = [MailSentEntry(messageID: "<earlier@example.test>", sender: "Pippa Check <me@example.test>", to: ["anna@example.test"])]
        let verified = await send(one, await draft(one))
        let looks = one.fake.sentLooks
        // Another identical copy at the same time: the two cannot be told apart, so it is unclear, and never sent again.
        let two = World(answer: yes)
        two.fake.snapshotFails = true
        two.fake.other = [MailSentEntry(messageID: "<other@example.test>", sender: "Pippa Check <me@example.test>", to: ["anna@example.test"])]
        let twoID = await draft(two)
        let unclear = await send(two, twoID)
        let again = await send(two, twoID)
        return verified.json["verified"] as? String == "1 of 1" && one.fake.sendCount == 1 && one.cards.value.count == 1
            && looks.count >= 2 && looks[0].snapshot && looks.dropFirst().allSatisfy { !$0.snapshot && $0.since > looks[0].since }
            && unclear.json["state"] as? String == "unclear" && two.fake.sendCount == 1 && two.fake.sendCallCount == 1
            && again.json["status"] as? String == "already_sent" && twoID.flatMap { two.host.mailDrafts.state($0) } == .unclear
    }
    await checkAsync("Mail send: a draft without a sender address, or from a Mail that restarted since, is refused before any card") {
        let world = World(answer: yes)
        let noSender = await draft(world)
        world.fake.edit(world.fake.lastID) { $0.sender = "" }
        let unknown = await send(world, noSender)
        let restarted = await draft(world)
        world.fake.restartMail()
        let gone = await send(world, restarted)
        return unknown.json["status"] as? String == "no_sender" && unknown.json["dispatched"] as? Bool == false
            && gone.json["status"] as? String == "draft_gone" && gone.json["dispatched"] as? Bool == false
            && world.cards.value.isEmpty && world.fake.sendCallCount == 0
    }
    await checkAsync("Mail send: Stop while the card is open sends nothing, a late yes does nothing; Stop while waiting for Sent leaves it unclear") {
        let box = LockedBox<World?>(nil)
        let open = World(answer: { _ in box.value?.stop(); return true })
        box.mutate { $0 = open }
        let stopped = await send(open, await draft(open))
        let waiting = World(answer: yes)
        let journal = try Executor(baseDirectory: root.appendingPathComponent("send-stop-" + UUID().uuidString))
        waiting.host.reminderJournal = journal; waiting.host.requiresReminderJournal = true
        waiting.fake.visibleFrom = .max
        let id = await draft(waiting)
        waiting.onSleep = { waiting.stop() }
        let run = waiting.turn.id
        let late = await send(waiting, id)
        let rows = try await journal.runActions(run: run).filter { $0.tool == "mail_send" }
        return stopped.json["status"] as? String == "cancelled" && open.fake.sendCallCount == 0 && open.cards.value.count == 1
            && late.json["state"] as? String == "unclear" && waiting.fake.sendCount == 1 && waiting.fake.sentPolls == 2
            && rows.count == 1 && rows[0].state == .unclear
    }

    // A7: the journal row and the receipts.
    await checkAsync("Mail send: one external row with the yes, dispatched on disk before the send event, done after; receipts count it, no Undo") {
        let world = World(answer: yes)
        let journal = try Executor(baseDirectory: root.appendingPathComponent("send-journal-" + UUID().uuidString))
        world.host.reminderJournal = journal; world.host.requiresReminderJournal = true
        let receipts = LockedBox<[PippaMCPWriteReceipt]>([])
        world.host.onWrite = { receipt in receipts.mutate { $0.append(receipt) } }
        let run = world.turn.id
        let seen = LockedBox<[RunAction]>([])
        world.fake.beforeSend = { _ in
            let rows = (try? await journal.runActions(run: run))?.filter { $0.tool == "mail_send" } ?? []
            seen.mutate { $0 += rows }
        }
        _ = await send(world, await draft(world))
        let rows = try await journal.runActions(run: run).filter { $0.tool == "mail_send" }
        let summary = await world.host.runSummaries([run])[run]
        let receipt = receipts.value.last { $0.action == "mailSend" }
        let english = receipt?.item.line(language: "en") ?? "", german = receipt?.item.line(language: "de") ?? ""
        return seen.value.count == 1 && seen.value[0].state == .dispatched && seen.value[0].actionClass == .external
            && seen.value[0].object.fields["confirmed"] == "yes"
            && rows.count == 1 && rows[0].state == .done && rows[0].verified == true && rows[0].label.contains("anna@example.test")
            && world.host.runUndoRecipe(rows[0].object.kind) == nil
            && summary?.changes == 2 && summary?.undoable == 0 && (summary?.checked ?? 0) >= 1
            && receipt?.outcome == "done" && receipt?.canUndo == false && receipt?.created == nil
            && english.hasPrefix("Mail sent to anna@example.test") && german.hasPrefix("Mail an anna@example.test")
            && german.hasSuffix("gesendet")
    }

    // A11: mail_draft (reply and new email) delivers ResultCard.mailDraft via onRead and round-trips inside ActionReceipt.
    await checkAsync("Mail draft card (A11): reply and new email deliver ResultCard.mailDraft via onRead and round-trip via Codable") {
        let world = World(answer: yes)
        let notes = LockedBox<[PippaMCPReadNote]>([])
        let receipts = LockedBox<[PippaMCPWriteReceipt]>([])
        world.host.onRead = { note in notes.mutate { $0.append(note) } }
        world.host.onWrite = { receipt in receipts.mutate { $0.append(receipt) } }

        let replyBody = "Hallo,\n\nich habe das Dokument geprüft.\n\nViele Grüße"
        let replyCall = await context.call(world.tools, "mail_draft", ["reply_to": "selected", "body": replyBody])
        let replyID = (replyCall.json["draft"] as? [String: Any])?["id"] as? String

        let newBody = "Hallo Anna,\n\npasst dir Freitag um 10 Uhr?"
        let newCall = await context.call(world.tools, "mail_draft", ["to": "anna@example.test", "subject": "Termin am Freitag", "body": newBody])
        let newID = (newCall.json["draft"] as? [String: Any])?["id"] as? String

        let delivered = notes.value
        guard delivered.count == 2,
              case .mailDraft(let replyCard)? = delivered[0].card,
              case .mailDraft(let newCard)? = delivered[1].card else { return false }

        let actionReceipt = ActionReceipt(items: [], cards: [.mailDraft(replyCard), .mailDraft(newCard)])
        let round = (try? JSONEncoder().encode(actionReceipt)).flatMap { try? JSONDecoder().decode(ActionReceipt.self, from: $0) }

        return !replyCall.isError && !newCall.isError
            && delivered.allSatisfy { $0.tool == "mail_draft" && $0.read && $0.turnID == world.turn.id }
            && replyCard.status == .saved && replyCard.isReply && replyCard.body == replyBody
            && replyCard.recipient != nil && !replyCard.subject.isEmpty && replyCard.draftID == replyID && replyID != nil
            && newCard.status == .opened && !newCard.isReply && newCard.recipient == "anna@example.test"
            && newCard.recipientAddress == nil && newCard.subject == "Termin am Freitag" && newCard.body == newBody
            && newCard.draftID == newID && newID != nil
            && receipts.value.count == 2 && receipts.value.allSatisfy { $0.action == "mailDraft" && $0.outcome == "done" }
            && round?.cards == [.mailDraft(replyCard), .mailDraft(newCard)]
    }

    // A12: failed or unclear mail_draft emits no card; replyNeedsPaste emits .needsPaste with full body preserved.
    await checkAsync("Mail draft card (A12): failed and unclear mail_draft emit no card; replyNeedsPaste emits .needsPaste with full body") {
        let world = World(answer: yes)
        let notes = LockedBox<[PippaMCPReadNote]>([])
        let receipts = LockedBox<[PippaMCPWriteReceipt]>([])
        world.host.onRead = { note in notes.mutate { $0.append(note) } }
        world.host.onWrite = { receipt in receipts.mutate { $0.append(receipt) } }

        // 1. Failed insert (missingOriginal)
        world.fake.nextInsertError = MailReplyFailure.missingOriginal
        let failedCall = await context.call(world.tools, "mail_draft", ["reply_to": "selected", "body": "Antwort"])

        // 2. Unclear insert (unconfirmed)
        world.fake.nextInsertError = MailReplyFailure.unconfirmed
        let unclearCall = await context.call(world.tools, "mail_draft", ["reply_to": "selected", "body": "Antwort"])

        let notesAfterFailures = notes.value.count

        // 3. replyNeedsPaste
        let pasteBody = "Hallo,\n\nbitte diesen Text einfügen.\n\nDanke!"
        world.fake.nextInsertResult = .replyNeedsPaste
        let pasteCall = await context.call(world.tools, "mail_draft", ["reply_to": "selected", "body": pasteBody])

        guard notesAfterFailures == 0,
              notes.value.count == 1,
              case .mailDraft(let pasteCard)? = notes.value[0].card else { return false }

        let outcomes = receipts.value.filter { $0.action == "mailDraft" }.map(\.outcome)
        return failedCall.isError && unclearCall.json["state"] as? String == "unclear"
            && !pasteCall.isError && pasteCall.json["state"] as? String == "opened_text_unconfirmed"
            && outcomes == ["failed", "unclear", "done"]
            && pasteCard.status == .needsPaste && pasteCard.isReply && pasteCard.body == pasteBody && pasteCard.draftID == nil
    }
}
