import Foundation

/// What the send probe needs beyond `mail_send`'s own Mail: the account list and one account's own addresses.
public protocol MailSendProbeMail: MailSending {
    /// Every account with Mail's id, name, type and class (the move probe's listing).
    func accountKinds() async throws -> [MailMoveProbe.AccountKind]
    /// The email addresses of the account with this Mail id, in Mail's order. Read only.
    func accountAddresses(account: String) async throws -> [String]
    /// Whether Mail finds exactly one Sent mailbox for the one account that has `address`: "found", "none", "busy" or
    /// "failed". The same lookup `mail_send`'s snapshot starts with. Read only.
    func sentMailbox(address: String) async throws -> String
}

extension SystemIntegrations {
    /// The real Mail for `Pippa --mail-send-probe` only.
    public var mailSendProbe: any MailSendProbeMail { MailSendProbeLive(system: self) }
}

/// Developer diagnostic before `mail_send` meets a real account: `Pippa --mail-send-probe --account <name> --read-only | --send`.
/// It makes one new draft through `mail_draft`, addressed to the account's own first address as Mail reports it (never
/// an address from the arguments), and reads it back through the reader `mail_send` uses. `--read-only` stops there and
/// leaves the unsent draft open. `--send` then runs the real `mail_send` path end to end, with the probe standing in for
/// the person's click on the card, and sends exactly that one mail to the account's own address.
///
/// The yes on the card: `confirmAction` is set only on the `PippaMCPHost` this probe builds for itself, a local value
/// that no server ever gets. The probe starts no MCP server, so no tool call from Pi or a script can reach it; the app's
/// server builds its own host in `PippaMCPService` with the person's card. The probe's yes is given once, only for a
/// `mail_send` card that shows the probe's own recipient, subject and text; any other card gets a no.
///
/// The JSON report holds counts, lengths, booleans, timings, status words and Mail's error numbers only: never an
/// address, a name, a subject or a text. Only the account listing (no `--account`) names the accounts, so one can be
/// chosen.
public enum MailSendProbe {
    public static let body = "This is a test mail from Pippa's send check and can be deleted."
    static let subjectPrefix = "Pippa test "

    public static let usage = """
        usage: Pippa --mail-send-probe [--account <name> (--read-only | --send)]
          Without --account: lists Mail's accounts with their types and exits. Changes nothing.
          With --account and --read-only: makes one new unsent draft through mail_draft ("\(subjectPrefix)<id>", one fixed
          sentence saying it is a test mail from Pippa's send check), addressed to the account's own first email address as
          Mail reports it. Reads it back as mail_send would, looks for the account's Sent mailbox and reads mail_send's
          snapshot of it. Sends nothing; the draft window stays open in Mail (close it without saving, or delete it).
          With --account and --send: the same, then runs mail_send end to end, with the probe confirming the card in place
          of the person. Sends exactly that one mail, only to the account's own address; any other recipient or sender is
          refused before the card. Waits up to \(PippaMCPMailSend.sentBound.components.seconds) s for it in Sent, then
          checks that a second mail_send of the same draft is refused.
          Prints one JSON report without addresses, names, subjects or texts: counts, lengths, booleans, milliseconds and
          status words. On a timeout it names the step and the kind of Apple event that did not answer. Exit code 0 only
          when the run ended as intended for its mode.
        """

    public enum Invocation: Equatable, Sendable { case help, list, readOnly(account: String), send(account: String) }

    /// Strict: a missing, repeated or unknown argument is an error, before Mail is asked anything.
    public static func parse(_ arguments: [String]) throws -> Invocation {
        var account: String?
        var sawCommand = false, readOnly = false, send = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h": return .help
            case "--mail-send-probe":
                guard !sawCommand else { throw MailMoveProbe.UsageError(message: "--mail-send-probe given twice.") }
                sawCommand = true
            case "--read-only":
                guard !readOnly else { throw MailMoveProbe.UsageError(message: "--read-only given twice.") }
                readOnly = true
            case "--send":
                guard !send else { throw MailMoveProbe.UsageError(message: "--send given twice.") }
                send = true
            case "--account":
                guard account == nil else { throw MailMoveProbe.UsageError(message: "--account given twice.") }
                guard let value = rest.popFirst(), !value.hasPrefix("--"), !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw MailMoveProbe.UsageError(message: "--account needs an account name.")
                }
                account = value
            default: throw MailMoveProbe.UsageError(message: "Unknown argument.")
            }
        }
        guard sawCommand else { throw MailMoveProbe.UsageError(message: "Missing --mail-send-probe.") }
        guard let account else {
            if readOnly || send { throw MailMoveProbe.UsageError(message: "--read-only and --send need --account.") }
            return .list
        }
        guard readOnly != send else { throw MailMoveProbe.UsageError(message: "--account needs exactly one of --read-only or --send.") }
        return readOnly ? .readOnly(account: account) : .send(account: account)
    }

    /// `mail` and `host` are only made after the arguments parsed. The probe sets its own Mail, journal, answer and
    /// card on `host`; `settle` paces the looks into Sent, `pause` the first-event retry.
    public static func execute(_ arguments: [String], mail: () -> any MailSendProbeMail, host: () -> PippaMCPHost,
                               journalDirectory: URL? = nil,
                               pause: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) },
                               settle: MailMoveSettle = .live) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let invocation: Invocation
        do { invocation = try parse(arguments) } catch let error as MailMoveProbe.UsageError { return (2, "", error.message + "\n" + usage) }
        catch { return (2, "", usage) }
        switch invocation {
        case .help: return (0, usage, "")
        case .list:
            var retries = 0
            do {
                let kinds = try await firstAccounts(mail(), pause: pause) { retries += 1 }
                return (0, MailMoveProbe.json(["probe": "mail-send-probe", "first_event_retries": retries,
                                               "accounts": kinds.map { ["name": $0.name, "type": $0.type, "class": $0.className] }]), "")
            } catch {
                return (1, MailMoveProbe.json(["probe": "mail-send-probe", "first_event_retries": retries,
                                               "error": ["step": "accounts", "kind": MailMover.describe(error)]]), "")
            }
        case .readOnly(let name), .send(let name):
            let sending = if case .send = invocation { true } else { false }
            let directory = journalDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("pippa-mail-send-probe-\(UUID().uuidString)")
            defer { if journalDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
            let report = await run(account: name, send: sending, mail: mail(), host: host(), directory: directory, pause: pause, settle: settle)
            return (report["result"] as? String == "as_intended" ? 0 : 1, MailMoveProbe.json(report), "")
        }
    }

    /// The first, read-only question: asked once more after `pause` when it times out, as in the move probe.
    static func firstAccounts(_ mail: any MailSendProbeMail, pause: @Sendable () async -> Void, retried: () -> Void) async throws -> [MailMoveProbe.AccountKind] {
        do { return try await mail.accountKinds() } catch MailAccountProblem.timeout {
            retried()
            await pause()
            return try await mail.accountKinds()
        }
    }

    struct Failure: Error { var step: String; var kind: String; var event: String? }

    // MARK: The run

    static func run(account name: String, send sending: Bool, mail probeMail: any MailSendProbeMail, host base: PippaMCPHost,
                    directory: URL, pause: @Sendable () async -> Void, settle: MailMoveSettle) async -> [String: Any] {
        var report: [String: Any] = ["probe": "mail-send-probe", "mode": sending ? "send" : "read_only"]
        var timings: [String: Int] = [:]
        var retries = 0
        let mail = Recorder(probeMail)
        func finish(_ result: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            report["timings_ms"] = timings
            report["first_event_retries"] = retries
            report["send_events"] = mail.sendCalls
            report["result"] = result
            return report.merging(extra) { _, b in b }
        }
        func refuse(_ reason: String, _ next: String) -> [String: Any] {
            finish("refused", ["refused": reason, "next": next])
        }
        func timed<T>(_ step: String, _ body: () async throws -> T) async throws -> T {
            let start = ContinuousClock.now
            defer { timings[step] = MailMoveProbe.milliseconds(ContinuousClock.now - start) }
            mail.clear()
            do { return try await body() } catch let failure as Failure { throw failure }
            catch { throw Failure(step: step, kind: MailMover.describe(error), event: mail.event) }
        }

        do {
            // The account and its own addresses, from Mail.
            let kinds = try await timed("accounts") { try await firstAccounts(mail, pause: pause) { retries += 1 } }
            let matches = kinds.filter { $0.id == name || $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
            guard matches.count == 1, let kind = matches.first, !kind.id.isEmpty else {
                return refuse(matches.isEmpty ? "unknown_account" : "ambiguous_account", "Run Pippa --mail-send-probe without --account to list the accounts.")
            }
            report["account_type"] = kind.type
            report["account_class"] = kind.className
            let addresses = try await timed("addresses") { try await mail.accountAddresses(account: kind.id) }
            let own = Set(addresses.map { $0.lowercased() })
            report["account_addresses"] = addresses.count
            guard let recipient = addresses.first.flatMap({ MailAddress.parse($0).address }) else {
                return refuse("no_own_address", "Mail lists no email address for this account. Nothing was created.")
            }

            // The probe's own host: its Mail, its journal, a fresh answer, and the card answered here (see the type's note).
            let journal = try Executor(baseDirectory: directory)
            let turns = PippaMCPTurns()
            let turn = PippaMCPTurn(conversation: "mail-send-probe-" + UUID().uuidString)
            let cards = CardLog()
            let receipts = CardLog.Receipts()
            let subject = subjectPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
            var host = base
            host.mailSender = mail
            host.mailDrafts = MailSendDrafts()
            host.mailSendSettle = settle
            host.reminderJournal = journal
            host.requiresReminderJournal = true
            host.turns = turns
            host.requireActiveWriteTurn = true
            host.egress = nil
            host.extraTools = []
            host.onRead = nil
            host.onWrite = { receipts.add($0) }
            let answer: @Sendable (PippaMCPConfirmation) async -> Bool = { card in cards.answer(card, recipient: recipient, subject: subject, body: body) }
            host.confirmAction = sending ? answer : nil
            let tools = PippaMCPTools(host: host)
            turns.begin(turn)
            defer { turns.end(turn) }

            // One new draft through mail_draft, to the account's own first address.
            let made = try await timed("draft") { await call(tools, "mail_draft", ["subject": subject, "body": body, "to": recipient]) }
            let draftID = (made["draft"] as? [String: Any])?["id"] as? String
            var draft: [String: Any] = ["created": made["done"] as? Bool == true, "state": made["state"] as? String ?? made["status"] as? String ?? "none",
                                        "id_present": draftID != nil, "mail_process_recorded": mail.inserted?.mailProcess != nil,
                                        "window_id_recorded": mail.inserted?.outgoingID != nil]
            if let event = mail.event { draft["event"] = event }
            report["draft"] = draft
            guard made["done"] as? Bool == true, let inserted = mail.inserted, let window = inserted.outgoingID, let process = inserted.mailProcess else {
                return finish("failed", ["error": ["step": "draft", "kind": made["status"] as? String ?? "no_window_id", "event": mail.event ?? "insert_draft"]])
            }
            report["draft_window"] = "left_open_unsent"

            // Read back through mail_send's reader.
            let lookup = try await timed("read_back") { try await mail.outgoing(window, process: process) }
            guard case .found(let shown) = lookup else {
                return finish("failed", ["error": ["step": "read_back", "kind": Recorder.word(lookup), "event": "read_draft"]])
            }
            let senderAddress = shown.senderAddress
            let recipientsOwn = !shown.recipients.isEmpty && shown.recipients.allSatisfy { own.contains($0.lowercased()) }
            let senderOwn = senderAddress.map { own.contains($0.lowercased()) } ?? false
            report["read_back"] = ["has_sender": senderAddress != nil, "sender_is_account": senderOwn,
                                   "recipients": shown.recipients.count, "to": shown.to.count, "cc": shown.cc.count, "bcc": shown.bcc.count,
                                   "recipients_are_own": recipientsOwn, "subject_length": shown.subject.count, "subject_matches": shown.subject == subject,
                                   "body_length": shown.body.count, "body_matches": shown.body.trimmingCharacters(in: .whitespacesAndNewlines) == body,
                                   "attachments": shown.attachments.count]

            // The account's Sent mailbox and mail_send's snapshot of it, by the address the draft would be sent from.
            let from = senderAddress ?? recipient
            var sent: [String: Any] = [:]
            do { sent["mailbox"] = try await timed("sent_mailbox") { try await mail.sentMailbox(address: from) } }
            catch let failure as Failure { sent["mailbox"] = failure.kind; if let event = failure.event { sent["mailbox_event"] = event } }
            sent["mailbox_ms"] = timings["sent_mailbox"]
            let cutoff = PippaMCPWriteTools.wholeSecond(Date()).addingTimeInterval(-PippaMCPMailSend.sentSlack)
            do {
                let ids = try await timed("sent_snapshot") { try await mail.sentMessageIDs(subject: shown.subject, from: from, since: cutoff) }
                sent["snapshot_read"] = true
                sent["snapshot_ids"] = ids.count
            } catch let failure as Failure {
                sent["snapshot_read"] = false
                sent["snapshot_error"] = failure.kind
                if let event = failure.event { sent["snapshot_event"] = event }
            }
            sent["snapshot_ms"] = timings["sent_snapshot"]
            report["sent"] = sent

            guard sending else {
                report["sent_anything"] = false
                let intact = senderAddress != nil && recipientsOwn && shown.subject == subject && shown.attachments.isEmpty
                return finish(intact ? "as_intended" : "not_as_intended",
                              ["next": "Nothing was sent. The probe's test draft is open in Mail: close it without saving, or run with --send."])
            }

            // Only the account's own address, from the account, exactly the probe's mail: else nothing is sent, no card.
            guard shown.recipients.count == 1, recipientsOwn else {
                return refuse("recipient_not_own", "The draft's recipient is not this account's own address. Nothing was sent; close the draft in Mail.")
            }
            guard senderOwn else {
                return refuse("sender_not_this_account", "The draft would be sent from another account. Nothing was sent; close the draft in Mail.")
            }
            guard shown.subject == subject, shown.body.trimmingCharacters(in: .whitespacesAndNewlines) == body, shown.attachments.isEmpty else {
                return refuse("draft_not_probe_mail", "The draft is not exactly the probe's test mail. Nothing was sent; close the draft in Mail.")
            }

            // mail_send end to end. The card is answered by `cards.answer` alone.
            let sendStart = ContinuousClock.now
            let result = try await timed("mail_send") { await call(tools, "mail_send", ["draft": draftID ?? ""]) }
            let total = MailMoveProbe.milliseconds(ContinuousClock.now - sendStart)
            let receipt = receipts.last(action: "mailSend")
            let verified = result["done"] as? Bool == true && result["verified"] as? String == "1 of 1"
            let card = cards.first
            var send: [String: Any] = ["gate_asked": cards.count > 0, "cards": cards.count, "card_fields_non_empty": card?.complete ?? false,
                                       "card_matched_probe_mail": card?.matched ?? false,
                                       "draft_unchanged_before_send": mail.expectedMatches(shown) ?? false,
                                       "send_event": mail.dispatchWord ?? "not_called", "sent_lookups": mail.sentCalls]
            if let ms = mail.foundAfterMs(verified: verified) { send["found_in_sent_ms"] = ms }
            send["found_in_sent"] = verified
            send["mail_send_ms"] = total
            if let event = mail.event { send["event"] = event }
            let outcome: String = verified ? "done" : result["state"] as? String == "unclear" ? "unclear" : "not_sent"
            send["outcome"] = outcome
            if outcome != "done" { send["why"] = receipt?.reason ?? result["status"] as? String ?? "unknown" }
            let rows = try await journal.runActions(run: turn.id)
            send["journal_rows"] = MailMoveProbe.tally(rows.filter { $0.tool == PippaMCPMailSend.name }.map(\.state.rawValue))
            send["journal_draft_rows"] = MailMoveProbe.tally(rows.filter { $0.tool == "mail_draft" }.map(\.state.rawValue))

            // A second mail_send of the same draft must be refused, before any card and without a send event.
            let eventsBefore = mail.sendCalls, cardsBefore = cards.count
            let again = try await timed("second_send") { await call(tools, "mail_send", ["draft": draftID ?? ""]) }
            let refusedAgain = again["status"] as? String == "already_sent" && mail.sendCalls == eventsBefore && cards.count == cardsBefore
            send["second_send_status"] = again["status"] as? String ?? again["state"] as? String ?? "none"
            send["second_send_refused"] = refusedAgain
            report["send"] = send
            let intended = outcome == "done" && mail.sendCalls == 1 && cards.count == 1 && refusedAgain
            return finish(intended ? "as_intended" : "not_as_intended",
                          ["next": outcome == "done" ? "One test mail went to the account's own address. It can be deleted from the inbox and Sent."
                                                     : "Look in Sent in Mail. The probe does not send again."])
        } catch let failure as Failure {
            var error: [String: Any] = ["step": failure.step, "kind": failure.kind]
            if let event = failure.event { error["event"] = event }
            return finish("failed", ["error": error])
        } catch {
            return finish("failed", ["error": ["step": "journal", "kind": MailMover.describe(error)]])
        }
    }

    /// One `tools/call` through Pippa's own tool code, in process (no server): the result's JSON text.
    static func call(_ tools: PippaMCPTools, _ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        guard let body = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                      "params": ["name": name, "arguments": arguments]]),
              let reply = await tools.handle(body),
              let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let text = ((json["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String,
              let result = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        return result
    }

    /// The cards the probe was shown, and its one yes: only for the first `mail_send` card that shows exactly the probe's
    /// recipient, subject and text. Every other card gets a no.
    final class CardLog: @unchecked Sendable {
        struct Seen { var complete: Bool; var matched: Bool }
        private let lock = NSLock()
        private var seen: [Seen] = []
        var count: Int { lock.withLock { seen.count } }
        var first: Seen? { lock.withLock { seen.first } }

        func answer(_ card: PippaMCPConfirmation, recipient: String, subject: String, body: String) -> Bool {
            let complete = ![card.title, card.recipient ?? "", card.content, card.confirmLabel ?? ""].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && !card.objects.isEmpty && card.objects.allSatisfy { !$0.isEmpty }
            let lines = (card.recipient ?? "").split(separator: "\n").map(String.init)
            let matched = card.tool == PippaMCPMailSend.name && card.actionClass == .external
                && lines.count == 1 && lines[0].lowercased() == L("To: %@", table: "MCP", recipient).lowercased()
                && card.objects.first?.split(separator: "\n").first.map(String.init) == L("Subject: %@", table: "MCP", subject)
                && card.content.trimmingCharacters(in: .whitespacesAndNewlines) == body
                && !(card.objects.first ?? "").contains(L("Attachments: %@", table: "MCP", ""))
            return lock.withLock {
                seen.append(Seen(complete: complete, matched: matched))
                return seen.count == 1 && complete && matched
            }
        }

        final class Receipts: @unchecked Sendable {
            private let lock = NSLock()
            private var all: [PippaMCPWriteReceipt] = []
            func add(_ receipt: PippaMCPWriteReceipt) { lock.withLock { all.append(receipt) } }
            func last(action: String) -> PippaMCPWriteReceipt? { lock.withLock { all.last { $0.action == action } } }
        }
    }

    /// Passes every call on to Mail and notes what the report needs: the draft window Mail made, the send event and its
    /// answer, the looks into Sent, and which kind of Apple event last failed or timed out. Never a name or an address.
    final class Recorder: MailSendProbeMail, @unchecked Sendable {
        private let mail: any MailSendProbeMail
        private let lock = NSLock()
        private var last: String?
        private var insert: MailDraftInsert?
        private var sends = 0, sentLooks = 0
        private var expected: MailOutgoing?
        private var dispatch: String?
        private var sendEnded: ContinuousClock.Instant?, lastLookEnded: ContinuousClock.Instant?
        init(_ mail: any MailSendProbeMail) { self.mail = mail }

        var event: String? { lock.withLock { last } }
        func clear() { lock.withLock { last = nil } }
        var inserted: MailDraftInsert? { lock.withLock { insert } }
        var sendCalls: Int { lock.withLock { sends } }
        var sentCalls: Int { lock.withLock { sentLooks } }
        var dispatchWord: String? { lock.withLock { dispatch } }
        /// Whether what the send event was told to send is the mail the probe read back. `nil`: no send event.
        func expectedMatches(_ shown: MailOutgoing) -> Bool? { lock.withLock { expected.map { $0.matches(shown) } } }
        /// Milliseconds from the end of the send event to the look that found the mail.
        func foundAfterMs(verified: Bool) -> Int? {
            lock.withLock {
                guard verified, let sendEnded, let lastLookEnded else { return nil }
                return MailMoveProbe.milliseconds(lastLookEnded - sendEnded)
            }
        }

        private func note<T>(_ event: String, _ body: () async throws -> T) async throws -> T {
            do { return try await body() } catch {
                lock.withLock { last = event }
                throw error
            }
        }

        static func word(_ lookup: MailOutgoingLookup) -> String {
            switch lookup {
            case .found: "found"
            case .gone: "gone"
            case .several: "several"
            case .unreadable: "unreadable"
            }
        }

        func accountKinds() async throws -> [MailMoveProbe.AccountKind] { try await note("accounts") { try await mail.accountKinds() } }
        func accountAddresses(account: String) async throws -> [String] { try await note("addresses") { try await mail.accountAddresses(account: account) } }
        func sentMailbox(address: String) async throws -> String { try await note("sent_mailbox") { try await mail.sentMailbox(address: address) } }

        func insertDraft(_ draft: MailDraft) async throws -> MailDraftInsert {
            let made = try await note("insert_draft") { try await mail.insertDraft(draft) }
            lock.withLock { insert = made }
            return made
        }
        func outgoing(_ id: Int, process: Int32) async throws -> MailOutgoingLookup {
            let found = try await note("read_draft") { try await mail.outgoing(id, process: process) }
            // Mail's reader answers a timeout (-1712) or an unreadable field as `unreadable`.
            if case .unreadable = found { lock.withLock { last = "read_draft" } }
            return found
        }
        func send(_ id: Int, process: Int32, expected: MailOutgoing) async throws -> MailSendDispatch {
            lock.withLock { sends += 1; self.expected = expected }
            do {
                let result = try await mail.send(id, process: process, expected: expected)
                lock.withLock {
                    sendEnded = .now
                    dispatch = switch result { case .sent: "sent"; case .changed: "changed"; case .gone: "gone"; case .busy: "busy"; case .unclear: "unclear" }
                    if result == .busy { last = "send" }
                }
                return result
            } catch {
                lock.withLock { sendEnded = .now; dispatch = "error_" + MailMover.describe(error); last = "send" }
                throw error
            }
        }
        func sentMessageIDs(subject: String, from address: String, since: Date) async throws -> Set<String> {
            try await note("sent_ids") { try await mail.sentMessageIDs(subject: subject, from: address, since: since) }
        }
        func sent(subject: String, from address: String, since: Date) async throws -> [MailSentEntry] {
            defer { lock.withLock { sentLooks += 1; lastLookEnded = .now } }
            return try await note("find_sent") { try await mail.sent(subject: subject, from: address, since: since) }
        }
    }
}

/// The real Mail for the send probe: `mail_send`'s own Apple Events, the move probe's account listing, and one read of an
/// account's addresses.
struct MailSendProbeLive: MailSendProbeMail {
    let system: SystemIntegrations

    func accountKinds() async throws -> [MailMoveProbe.AccountKind] { try await MailAccountScript.Live().accountKinds() }

    func accountAddresses(account: String) async throws -> [String] {
        guard AppleEvents.isRunning(.mail) else { throw PippaError.appNotOpen(Integration.mail.appName) }
        return try await AppleEvents.perform {
            let reply = try AppleEvents.call(Self.source, handler: "accountAddresses", [NSAppleEventDescriptor(string: account)], app: .mail)
            return AppleEvents.strings(try MailAccountParse.payload(reply))
        }
    }

    func sentMailbox(address: String) async throws -> String {
        guard AppleEvents.isRunning(.mail) else { throw PippaError.appNotOpen(Integration.mail.appName) }
        // The handler of mail_send's snapshot, with a subject no mail has: only whether the Sent mailbox was found counts.
        let reply = try await MailSendScript.run("sentIDs", [.text("\u{2063}"), .text(address), .date(Date()), .number(MailSendScript.snapshotTimeout)], false)
        return switch reply.first?.text { case "ok": "found"; case "nobox": "none"; case "busy": "busy"; default: "failed" }
    }

    func insertDraft(_ draft: MailDraft) async throws -> MailDraftInsert { try await system.insertDraft(draft) }
    func outgoing(_ id: Int, process: Int32) async throws -> MailOutgoingLookup { try await system.outgoing(id, process: process) }
    func send(_ id: Int, process: Int32, expected: MailOutgoing) async throws -> MailSendDispatch { try await system.send(id, process: process, expected: expected) }
    func sentMessageIDs(subject: String, from address: String, since: Date) async throws -> Set<String> {
        try await system.sentMessageIDs(subject: subject, from: address, since: since)
    }
    func sent(subject: String, from address: String, since: Date) async throws -> [MailSentEntry] { try await system.sent(subject: subject, from: address, since: since) }

    static let source = """
    -- The email addresses of one account, by Mail's id. Reads only.
    on accountAddresses(acctID)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    repeat with acct in accounts
                        if ((id of acct) as text) is acctID then
                            repeat with a in (email addresses of acct)
                                set end of out to (contents of a) as text
                            end repeat
                        end if
                    end repeat
                end timeout
            on error number errNum
                if errNum is -1712 then return {"timeout"}
                if errNum is -1743 then return {"denied"}
                return {"failed", errNum}
            end try
        end tell
        return {"ok", out}
    end accountAddresses
    """
}
