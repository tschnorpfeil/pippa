import Foundation

// `mail_send` (class `external`): sends exactly one draft that `mail_draft` saved earlier in the same conversation and
// that is still open and unsent in Mail, only after the person pressed Send on a card that shows the draft as Mail has
// it at that moment. Nothing else can be sent: no free text, no forwarding, no attachments beyond the draft's own.
//
// Order: the draft id → read the draft from Mail → refuse what cannot be sent → the card (`PippaMCPTools.gate`) → read
// again and compare → the Message-IDs already in the sending account's Sent (bounded; unreadable never stops the send)
// → a run journal row, dispatched → the one send event (`MailSending.send`, which compares once more in the same event)
// → look for the mail in that Sent, bounded. Anything in doubt sends nothing; after the event nothing is
// ever sent again. The gate sits in the app's server, so it holds for a call from a codemode script as well: the server
// cannot tell such a call apart, and it does not need to.

public enum PippaMCPMailSend {
    public static let name = "mail_send"
    /// How long Pippa looks for the sent mail in Sent after Mail took it. Mail files it within seconds on IMAP; 30 s
    /// leaves room for a slow server, then the outcome is unclear (never sent again).
    public static let sentBound: Duration = .seconds(30)
    public static let sentInterval: Duration = .seconds(2)
    /// How far before the send event the snapshot of Sent reaches: room for Mail's clock. The later looks reach exactly
    /// as far, never further.
    public static let sentSlack: TimeInterval = 60
    public static let journalKind = "mail.send"

    static func toolList() -> [[String: Any]] {
        let title = "Mail senden"
        return [["name": name, "title": title,
                 "description": "Send a mail_draft draft (draft=its id) the person asked to send. Pippa shows it and asks.",
                 "inputSchema": ["type": "object", "properties": ["draft": ["type": "string"]], "required": ["draft"]],
                 "annotations": PippaActionClasses.annotations(name, title: title)]]
    }
}

/// The drafts `mail_draft` saved, each under an opaque id for its owner (a conversation, else one answer). A draft
/// is sent at most once: after the send event it is `sent` or `unclear` for good.
public final class MailSendDrafts: @unchecked Sendable {
    public enum State: String, Sendable { case open, sending, sent, unclear }
    /// `process`: the Mail process that has the window `outgoingID`; Mail numbers windows anew after a restart.
    private struct Entry { let outgoingID: Int; let process: Int32; let owner: String; var state: State }
    enum Claim: Equatable { case claimed(Int, process: Int32), unknown, sending, sent, unclear }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    public init() {}

    func register(outgoingID: Int, process: Int32, owner: String) -> String {
        let token = "d" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        lock.withLock { entries[token] = Entry(outgoingID: outgoingID, process: process, owner: owner, state: .open) }
        return token
    }

    /// Takes an open draft for one attempt. Another owner's draft is unknown here.
    func claim(_ token: String, owner: String?) -> Claim {
        lock.withLock {
            guard let owner, let entry = entries[token], entry.owner == owner else { return .unknown }
            switch entry.state {
            case .open: entries[token]?.state = .sending; return .claimed(entry.outgoingID, process: entry.process)
            case .sending: return .sending
            case .sent: return .sent
            case .unclear: return .unclear
            }
        }
    }

    /// Ends an attempt: `open` again when nothing left the Mac.
    func finish(_ token: String, _ state: State) {
        lock.withLock { if entries[token]?.state == .sending { entries[token]?.state = state } }
    }

    /// Checks only.
    public func state(_ token: String) -> State? { lock.withLock { entries[token]?.state } }
}

extension PippaMCPWriteTools {
    func mailSend(_ raw: [String: Any], context: PippaMCPRequestContext) async -> PippaMCPToolResult {
        await withLease(action: "mailSend") { await sendLeased(raw, context: context) }
    }

    private func sendLeased(_ raw: [String: Any], context: PippaMCPRequestContext) async -> PippaMCPToolResult {
        let unknown = raw.keys.filter { $0 != "draft" }.sorted()
        guard unknown.isEmpty else { return Self.invalid("Unknown or invalid arguments: \(unknown.joined(separator: ", ")).") }
        guard let token = (raw["draft"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return Self.invalid("draft is required: draft.id from mail_draft in this conversation.")
        }
        var name = ""
        func receipt(_ outcome: String, _ reason: String) -> PippaMCPWriteReceipt {
            PippaMCPWriteReceipt(action: "mailSend", outcome: outcome, name: name, reason: reason)
        }
        func refuse(_ status: String, _ tell: String) -> PippaMCPToolResult {
            Self.notSent(status, tell, receipt: status == "cancelled" ? receipt("cancelled", "stopped") : receipt("failed", status))
        }
        // Only the class table makes this tool ask; should it ever lose `external`, it sends nothing rather than less carefully.
        guard let actionClass = PippaActionClasses.of(PippaMCPMailSend.name), actionClass == .external, let sender = host.mailSender else {
            return refuse("unavailable", L("Pippa can’t send mail here. Nothing was sent.", table: "MCP"))
        }
        let drafts = host.mailDrafts
        let outgoingID: Int, process: Int32
        switch drafts.claim(token, owner: scope.draftOwner) {
        case .claimed(let id, let mail): outgoingID = id; process = mail
        case .unknown: return refuse("unknown_draft", L("Pippa sends only a draft she saved in this conversation. Nothing was sent.", table: "MCP"))
        case .sending: return refuse("busy", L("This mail is already being sent. Nothing else was sent.", table: "MCP"))
        case .sent: return refuse("already_sent", L("This mail was already sent. Pippa doesn’t send it again.", table: "MCP"))
        case .unclear: return refuse("already_sent", L("This mail may already have gone out. Please look in Sent in Mail; Pippa doesn’t send it again.", table: "MCP"))
        }
        // Back to open unless the send event went out.
        var final: MailSendDrafts.State = .open
        defer { drafts.finish(token, final) }

        if case .blocked(let status, let tell) = await ensure(.mail) { return refuse(status, tell) }
        let shown: MailOutgoing
        switch await read(outgoingID, process, sender) {
        case .found(let mail): shown = mail
        case .notSent(let status, let tell): return refuse(status, tell)
        }
        name = Self.sendName(shown)
        // Mail named no sender (yet): the card could not say who it comes from, and Sent could not confirm it.
        guard shown.senderAddress != nil else {
            return refuse("no_sender", L("Pippa can’t see which address the draft would be sent from, so she sent nothing. Choose the sender (From) in Mail, then ask again.", table: "MCP"))
        }
        guard !shown.recipients.isEmpty else {
            return refuse("no_recipient", L("The draft has no recipient, so Pippa sent nothing. Add one in Mail, or tell Pippa who gets it.", table: "MCP"))
        }
        guard !shown.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return refuse("empty_body", L("The draft has no text, so Pippa sent nothing.", table: "MCP"))
        }

        // The card shows what would leave, as Mail has it now; the yes comes only from its button.
        if var refused = await PippaMCPTools(host: host).gate(PippaMCPMailSend.name, actionClass, card: Self.sendCard(shown), context: context) {
            let status = (try? JSONSerialization.jsonObject(with: Data(refused.text.utf8)) as? [String: Any])?["status"] as? String ?? "cancelled"
            refused.receipt = status == "declined" ? receipt("declined", "declined") : receipt("cancelled", "stopped")
            return refused
        }
        do { try PippaMCPWriteLease.current?.check() } catch { return refuse("cancelled", Self.stoppedText) }

        // Right before the send event: what leaves must be exactly what the card showed.
        let current: MailOutgoing
        switch await read(outgoingID, process, sender) {
        case .found(let mail) where mail.matches(shown): current = mail
        case .found: return Self.changed(receipt: receipt("failed", "draft_changed"))
        case .notSent(let status, let tell): return refuse(status, tell)
        }

        // What the sending account's Sent already holds under this subject (an earlier reply in the thread), by
        // Message-ID: never taken for this mail. One cut-off, a whole second, for the snapshot and every later look.
        // Unreadable (slow, no Sent mailbox): the person said yes, so it sends anyway; only verifying gets stricter.
        let address = current.senderAddress ?? ""
        let cutoff = Self.wholeSecond(host.now()).addingTimeInterval(-PippaMCPMailSend.sentSlack)
        let before: Set<String>?
        do {
            before = try await sender.sentMessageIDs(subject: current.subject, from: address, since: cutoff)
        } catch {
            if error is CancellationError { return refuse("cancelled", Self.stoppedText) }
            before = nil
        }

        let lease = PippaMCPWriteLease.current
        let row: PippaMCPRunRow?
        do {
            try lease?.check()
            row = try await PippaMCPRunRow.dispatch(host, run: scope.turnID, tool: PippaMCPMailSend.name, actionClass: .external,
                                                    object: RunObject(kind: PippaMCPMailSend.journalKind, fields: [
                                                        "confirmed": "yes", "to": current.recipients.joined(separator: ", "),
                                                        "subject": current.subject, "draft": token]),
                                                    label: String(name.prefix(200)))
        } catch {
            if error is CancellationError { return refuse("cancelled", Self.stoppedText) }
            return refuse("unavailable", L("Pippa’s journal is unavailable, so she sent nothing.", table: "MCP"))
        }

        // Without a snapshot only mails sent from this second on count (see `inSent`).
        let sendStart = Self.wholeSecond(host.now())
        let dispatch: MailSendDispatch
        do {
            dispatch = try await sender.send(outgoingID, process: process, expected: current)
        } catch {
            if lease?.hasDispatched == true {
                await row?.abandon(dispatched: true)
                final = .unclear
                return Self.unclear(L("Pippa isn’t sure whether Mail sent the mail. Please look in Sent in Mail; Pippa won’t send it again.", table: "MCP"),
                                    receipt: receipt("unclear", "unconfirmed"))
            }
            await row?.abandon(dispatched: false)
            if error is CancellationError { return refuse("cancelled", Self.stoppedText) }
            return refuse("not_sent", L("Mail didn’t take the mail, so nothing was sent. Try again in a moment.", table: "MCP"))
        }
        switch dispatch {
        case .sent: final = .sent
        case .changed:
            await row?.abandon(dispatched: false)
            return Self.changed(receipt: receipt("failed", "draft_changed"))
        case .gone:
            await row?.abandon(dispatched: false)
            return refuse("draft_gone", Self.goneText)
        case .busy:
            await row?.abandon(dispatched: false)
            return refuse("busy", L("Mail didn’t answer, so Pippa sent nothing. Try again in a moment.", table: "MCP"))
        case .unclear:
            await row?.abandon(dispatched: true)
            final = .unclear
            return Self.unclear(L("Pippa isn’t sure whether Mail sent the mail. Please look in Sent in Mail; Pippa won’t send it again.", table: "MCP"),
                                receipt: receipt("unclear", "unconfirmed"))
        }

        guard await inSent(current, from: address, since: before == nil ? sendStart : cutoff, before: before, sender: sender) else {
            await row?.abandon(dispatched: true)
            final = .unclear
            return Self.unclear(L("Mail took the mail, but Pippa could not confirm it in Sent. Please look in Sent; Pippa won’t send it again.", table: "MCP"),
                                receipt: receipt("unclear", "notInSent"))
        }
        await row?.complete(verified: true)
        return PippaMCPToolResult(text: PippaMCPTools.json([
            "done": true, "state": "sent", "sent": true, "verified": "1 of 1",
            "mail": ["to": current.to, "subject": current.subject],
            "next": "Sent, and Pippa found it in Sent. Say so in one sentence. Never send it again.",
        ]), isError: false, receipt: receipt("done", "verified"))
    }

    private enum Read { case found(MailOutgoing), notSent(String, String) }

    private func read(_ id: Int, _ process: Int32, _ sender: any MailSending) async -> Read {
        do {
            try PippaMCPWriteLease.current?.check()
            switch try await sender.outgoing(id, process: process) {
            case .found(let mail): return .found(mail)
            case .gone: return .notSent("draft_gone", Self.goneText)
            case .several: return .notSent("ambiguous", L("Mail shows more than one window for this draft, so Pippa sent nothing.", table: "MCP"))
            case .unreadable: return .notSent("unavailable", Self.unreadableText)
            }
        } catch is CancellationError {
            return .notSent("cancelled", Self.stoppedText)
        } catch PippaError.accessDenied {
            return .notSent("denied", Self.denied(.mail))
        } catch {
            return .notSent("unavailable", Self.unreadableText)
        }
    }

    /// Looks for the sent copy in the account's Sent until `PippaMCPMailSend.sentBound`. With the snapshot (`before`), a
    /// copy whose Message-ID was not there before the send event counts. Without it, `since` is the second the send
    /// event started: exactly one copy dated from then on counts, as nothing older can be; two or more cannot be told
    /// apart, so it is unclear. Stop ends the wait: then it is unclear.
    private func inSent(_ mail: MailOutgoing, from address: String, since: Date, before: Set<String>?, sender: any MailSending) async -> Bool {
        let settle = host.mailSendSettle
        let start = settle.now()
        while !Task.isCancelled, !scope.snapshot.cancelled {
            if let entries = try? await sender.sent(subject: mail.subject, from: address, since: since) {
                let copies = entries.filter { $0.isCopy(of: mail) }
                if let before {
                    if copies.contains(where: { !$0.messageID.isEmpty && !before.contains($0.messageID) }) { return true }
                } else if copies.count == 1 {
                    return true
                } else if copies.count > 1 {
                    return false
                }
            }
            guard settle.now() - start < PippaMCPMailSend.sentBound, !Task.isCancelled, !scope.snapshot.cancelled else { return false }
            await settle.sleep(PippaMCPMailSend.sentInterval)
        }
        return false
    }

    static func wholeSecond(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    /// The card: recipients, subject, sender and attachments, then the whole text as Mail has it.
    public static func sendCard(_ mail: MailOutgoing) -> PippaMCPConfirmation {
        var who: [String] = []
        if !mail.to.isEmpty { who.append(L("To: %@", table: "MCP", mail.to.joined(separator: ", "))) }
        if !mail.cc.isEmpty { who.append(L("Cc: %@", table: "MCP", mail.cc.joined(separator: ", "))) }
        if !mail.bcc.isEmpty { who.append(L("Bcc: %@", table: "MCP", mail.bcc.joined(separator: ", "))) }
        var about = [L("Subject: %@", table: "MCP", mail.subject)]
        if !mail.sender.isEmpty { about.append(L("From: %@", table: "MCP", mail.sender)) }
        if !mail.attachments.isEmpty { about.append(L("Attachments: %@", table: "MCP", mail.attachments.joined(separator: ", "))) }
        return PippaMCPConfirmation(tool: PippaMCPMailSend.name, actionClass: .external, title: L("Send this mail?", table: "MCP"),
                                    recipient: who.joined(separator: "\n"), objects: [about.joined(separator: "\n")], content: mail.body,
                                    confirmLabel: L("Send", table: "MCP"), declineLabel: L("Don’t Send", table: "MCP"))
    }

    /// The receipt's name: "anna@example.org · “Subject”".
    static func sendName(_ mail: MailOutgoing) -> String {
        String((mail.recipients.joined(separator: ", ") + " · " + quoted(mail.subject)).prefix(200))
    }

    static var goneText: String {
        L("The draft is no longer open in Mail, so Pippa sent nothing. Open it in Mail to send it yourself, or ask Pippa for a new draft.", table: "MCP")
    }
    static var unreadableText: String { L("Pippa couldn’t read the draft in Mail, so she sent nothing. Try again in a moment.", table: "MCP") }

    static func notSent(_ status: String, _ tell: String, receipt: PippaMCPWriteReceipt) -> PippaMCPToolResult {
        if status == "cancelled" { return stopped(receipt: receipt) }
        return PippaMCPToolResult(text: PippaMCPTools.json(["done": false, "status": status, "dispatched": false, "sent": false, "tell": tell,
                                                            "next": "Nothing was sent. Repeat the sentence in tell. Do not send it another way."]),
                                  isError: true, receipt: receipt)
    }

    static func changed(receipt: PippaMCPWriteReceipt) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json([
            "done": false, "status": "draft_changed", "dispatched": false, "sent": false,
            "tell": L("The mail in Mail is no longer what you saw, so Pippa didn’t send it. She can show it to you again.", table: "MCP"),
            "next": "Nothing was sent. Repeat tell and offer to ask again; only if the person agrees, call mail_send with the same draft.",
        ]), isError: true, receipt: receipt)
    }

    static func unclear(_ tell: String, receipt: PippaMCPWriteReceipt) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json([
            "done": false, "state": "unclear", "tell": tell,
            "next": "Repeat tell. Never call mail_send for this draft again.",
        ]), isError: false, receipt: receipt)
    }
}
