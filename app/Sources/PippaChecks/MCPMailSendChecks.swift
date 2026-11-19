import Foundation
import PiRPC
import PippaCore

/// `mail_send` (PippaMCPMailSend.swift) against a fake Mail: never the real Mail. The fake keeps open draft windows,
/// counts send events, and files sent mails in a Sent list that appears after a chosen number of looks.
final class FakeMailSend: MailSending, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [Int: MailOutgoing] = [:]
    private var nextID = 100
    private var sentMails: [MailOutgoing] = []
    private var sends = 0, sendCalls = 0, polls = 0
    /// Sent shows the mail from this look on (1 = the first look, the one before the send event); `Int.max`: never.
    var visibleFrom = 1
    /// Mails in Sent from before (an earlier reply in the same thread): there on every look.
    var earlier: [MailSentEntry] = []
    /// Another mail that lands in Sent after the send event, whatever `visibleFrom` says.
    var other: [MailSentEntry] = []
    /// Mail's process now; `restartMail` gives it a new one, as after quitting and opening Mail again.
    private var process: Int32 = 4242
    func restartMail() { lock.withLock { process += 1 } }
    var several: Set<Int> = []
    /// What the send event reports after the mail left (`.unclear`: Mail did not confirm).
    var outcome: MailSendDispatch = .sent
    /// Runs inside `send` before the window is compared and sent (the journal row must already be on disk).
    var beforeSend: (@Sendable (Int) async -> Void)?

    var sendCount: Int { lock.withLock { sends } }
    var sendCallCount: Int { lock.withLock { sendCalls } }
    var sentPolls: Int { lock.withLock { polls } }
    var lastID: Int { lock.withLock { nextID - 1 } }

    func edit(_ id: Int, _ change: (inout MailOutgoing) -> Void) { lock.withLock { if var w = windows[id] { change(&w); windows[id] = w } } }
    func close(_ id: Int) { lock.withLock { windows[id] = nil } }

    func insertDraft(_ draft: MailDraft) async throws -> MailDraftInsert {
        try PippaMCPWriteLease.current?.beginDispatch()
        let id: Int = lock.withLock {
            let id = nextID; nextID += 1
            windows[id] = MailOutgoing(sender: "Pippa Check <me@example.test>", subject: draft.replySubject, body: draft.body,
                                       to: draft.to.map { [$0] } ?? [])
            return id
        }
        return MailDraftInsert(result: draft.isReply ? .reply : .newMessage, outgoingID: id, mailProcess: lock.withLock { process })
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
            sends += 1; windows[id] = nil; sentMails.append(window)
            return outcome
        }
    }

    func sent(subject: String, since: Date) async throws -> [MailSentEntry] {
        lock.withLock {
            polls += 1
            let new = polls >= visibleFrom ? sentMails.enumerated().filter { $0.element.subject == subject }
                .map { MailSentEntry(id: 900 + $0.offset, sender: $0.element.sender, to: $0.element.to, cc: $0.element.cc, bcc: $0.element.bcc) } : []
            return earlier + (polls >= 2 ? other : []) + new
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
               body: String = "Hallo Anna,\n\npasst dir Freitag um 10 Uhr?\n\nViele Grüße") async -> String? {
        var arguments: [String: Any] = ["subject": subject, "body": body]
        if let to { arguments["to"] = to }
        let made = await context.call(world.tools, "mail_draft", arguments)
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
        thread.fake.earlier = [MailSentEntry(id: 7, sender: "Pippa Check <me@example.test>", to: ["anna@example.test"])]
        let earlier = await send(thread, await draft(thread))
        // A Cc-only mail: another mail to nobody in To, Cc someone else, lands in Sent at the same time.
        let ccOnly = World(answer: yes)
        ccOnly.fake.visibleFrom = .max
        ccOnly.fake.other = [MailSentEntry(id: 8, sender: "Pippa Check <me@example.test>", to: [], cc: ["chris@example.test"])]
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
}
