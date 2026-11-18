import Foundation

extension PippaMCPWriteTools {
    // MARK: mail_draft

    static let draftReplyError = "reply_to cannot be an unsent draft from Drafts. Open or edit the draft in Mail, or reply to an inbox or sent email."

    func mailDraft(_ input: Input) async -> PippaMCPToolResult {
        guard var body = input.text("body") else { return Self.invalid("body is required.") }
        // In the proof of concept, a 12B model wrote line breaks doubly escaped ("\\n" instead of a break): without a real break
        // this is translated back, otherwise "\n" would appear literally in the mail.
        if !body.contains("\n"), body.contains("\\n") { body = body.replacingOccurrences(of: "\\n", with: "\n") }
        guard body.count <= Self.mailBodyLimit else { return Self.invalid("body is too long.") }
        let draft: MailDraft
        if let replyTo = input.text("reply_to") {
            let label = L("reply", table: "MCP")
            func notDone(_ reason: String) -> PippaMCPWriteReceipt { PippaMCPWriteReceipt(action: "mailDraft", outcome: "failed", name: label, reason: reason) }
            let source: MailReplySource
            var locator: MailLocator?
            var mailbox: MailBoxKind?
            var explicitReplyTo: String?
            if replyTo.lowercased() == "selected" {
                if case .blocked(let status, let tell) = await ensure(.mail) { return Self.blocked(status, tell, receipt: notDone(status)) }
                do {
                    guard let mail = try await host.integrations.selectedMail() else {
                        return Self.blocked("nothing_selected", L("No email is selected in Mail. Select one and ask again.", table: "MCP"), receipt: notDone("nothingSelected"))
                    }
                    if mail.isUnsentDraft { return Self.invalid(Self.draftReplyError) }
                    guard let found = mail.replySource else {
                        return Self.blocked("no_message_id", L("Pippa can’t reply to this email in its thread. Copy the text and reply in Mail yourself.", table: "MCP"),
                                            receipt: notDone("noMessageID"))
                    }
                    let strictSelected = mail.locator.flatMap {
                        MailLocator(account: $0.account, path: $0.path, mailID: $0.mailID, accountID: $0.accountID, strict: true)
                    }
                    source = found; locator = strictSelected ?? mail.locator; mailbox = mail.mailboxKind; explicitReplyTo = mail.explicitReplyTo
                } catch {
                    return failure(error, .mail, receipt: notDone("failed"))
                }
            } else if MailPageStore.isToken(replyTo, prefix: "m") {
                // A mail_ref from this answer's mail_search: exactly that message, checked like mail_read checks it.
                switch await replySource(ref: replyTo) {
                case .found(let found, let at, let kind, let explicit):
                    source = found; locator = at; mailbox = kind; explicitReplyTo = explicit
                case .notDone(let result): return result
                }
            } else {
                var path = replyTo
                if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
                path = (path as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else { return Self.invalid("reply_to must be a mail_ref from mail_search, the exact absolute path of the email file (eml_path), or selected.") }
                let url = URL(fileURLWithPath: path)
                let filedOrigin = MailFiling.origin(for: url)
                if filedOrigin?.mailbox == .drafts { return Self.invalid(Self.draftReplyError) }
                guard let inspected = MailReplySource.inspect(from: url) else {
                    return Self.invalid("reply_to is not an email file Pippa can reply to (.eml with Message-ID). Use the exact path from the message, or selected.")
                }
                if inspected.isDraft { return Self.invalid(Self.draftReplyError) }
                if filedOrigin?.requiresStrictLocator == true, filedOrigin?.locator?.strict != true {
                    return Self.blocked("not_found", L("Pippa couldn’t find the original email in Mail, so no reply was created.", table: "MCP"),
                                        receipt: notDone("not_found"))
                }
                if case .blocked(let status, let tell) = await ensure(.mail, openMail: true) { return Self.blocked(status, tell, receipt: notDone(status)) }
                source = inspected.source
                locator = filedOrigin?.locator
                mailbox = filedOrigin?.mailbox
                explicitReplyTo = inspected.explicitReplyTo
            }
            if mailbox == .sent {
                let explicit = explicitReplyTo.map(MailAddress.parse)
                if let explicit, let address = explicit.address {
                    draft = MailDraft(messageID: source.messageID, to: address, toName: explicit.name, subject: source.subject, body: body,
                                      isReply: true, locator: locator, keepMailRecipients: false)
                } else {
                    draft = MailDraft(messageID: source.messageID, to: nil, toName: nil, subject: source.subject, body: body,
                                      isReply: true, locator: locator, keepMailRecipients: true)
                }
            } else {
                let address = source.replyTo.map(MailAddress.parse)
                draft = MailDraft(messageID: source.messageID, to: address?.address, toName: address?.name, subject: source.subject, body: body,
                                  isReply: true, locator: locator, keepMailRecipients: false)
            }
        } else {
            guard let subject = input.text("subject") else {
                return Self.invalid("A new email needs subject (and to). To reply, give reply_to: the exact path of the shown email file, or selected.")
            }
            let to = input.text("to")
            if let to, MailAddress.parse(to).address != to { return Self.invalid("to must be one email address.") }
            if case .blocked(let status, let tell) = await ensure(.mail, openMail: true) {
                return Self.blocked(status, tell, receipt: PippaMCPWriteReceipt(action: "mailDraft", outcome: "failed", name: Self.quoted(subject), reason: status))
            }
            draft = MailDraft(messageID: nil, to: to, toName: nil, subject: Self.singleLine(subject, max: 200), body: body, isReply: false, exactSubject: true)
        }
        return await insert(draft)
    }

    private enum RefSource { case found(MailReplySource, MailLocator?, MailBoxKind, String?), notDone(PippaMCPToolResult) }

    /// The original a `mail_ref` names, only in the answer that searched and only when the whole locator still matches
    /// (account id, mailbox path, Mail id, Message-ID, date). An unknown, old or changed reference writes nothing.
    private func replySource(ref token: String) async -> RefSource {
        let label = L("reply", table: "MCP")
        func notDone(_ status: String) -> RefSource {
            .notDone(Self.blocked(status, L("Pippa couldn’t find the original email in Mail, so no reply was created.", table: "MCP"),
                                  receipt: PippaMCPWriteReceipt(action: "mailDraft", outcome: "failed", name: label, reason: status)))
        }
        // The answer this request belongs to owns the search's references; any other answer finds none.
        let (active, generation) = host.turns.capture()
        guard active == nil || active?.writes === scope, let reader = host.mailAccounts,
              let ref = host.mailPages.ref(token, turn: generation) else { return notDone("stale_ref") }
        if ref.mailbox == .drafts { return .notDone(Self.invalid(Self.draftReplyError)) }
        if case .blocked(let status, let tell) = await ensure(.mail, openMail: true) {
            return .notDone(Self.blocked(status, tell, receipt: PippaMCPWriteReceipt(action: "mailDraft", outcome: "failed", name: label, reason: status)))
        }
        guard host.turns.isLive(active, generation: generation) else {
            return .notDone(Self.stopped(receipt: PippaMCPWriteReceipt(action: "mailDraft", outcome: "cancelled", name: label, reason: "stopped")))
        }
        do {
            guard let found = try await PippaMCPTools.resolve(ref, reader: reader), let source = found.message.replySource else { return notDone("not_found") }
            if found.message.isUnsentDraft { return .notDone(Self.invalid(Self.draftReplyError)) }
            guard host.turns.isLive(active, generation: generation) else {
                return .notDone(Self.stopped(receipt: PippaMCPWriteReceipt(action: "mailDraft", outcome: "cancelled", name: label, reason: "stopped")))
            }
            guard let strictLocator = MailLocator(account: ref.account.name, path: ref.path, mailID: ref.mailID, accountID: ref.account.id, strict: true) else {
                return notDone("not_found")
            }
            return .found(source, strictLocator, ref.mailbox, found.message.explicitReplyTo)
        } catch {
            return .notDone(failure(error, .mail, receipt: PippaMCPWriteReceipt(action: "mailDraft", outcome: "failed", name: label, reason: "failed")))
        }
    }

    private func insert(_ draft: MailDraft) async -> PippaMCPToolResult {
        let name = Self.quoted(draft.replySubject)
        func receipt(_ outcome: String, _ reason: String) -> PippaMCPWriteReceipt {
            PippaMCPWriteReceipt(action: "mailDraft", outcome: outcome, name: name, reason: reason)
        }
        let result: MailInsertResult
        do {
            try PippaMCPWriteLease.current?.check()
            result = try await host.integrations.insertReply(draft)
        } catch MailReplyFailure.unconfirmed {
            // A reply window may be open, its content is unknown: neither "created" nor "not created".
            return PippaMCPToolResult(text: PippaMCPTools.json([
                "done": false, "state": "unclear", "sent": false,
                "tell": L("Pippa isn’t sure whether a reply opened in Mail. Please look in Mail before trying again. Nothing was sent.", table: "MCP"),
                "next": "Repeat the sentence in tell. Do not try again in this answer.",
            ]), isError: false, receipt: receipt("unclear", "unconfirmed"))
        } catch let failure as MailReplyFailure {
            let (status, tell): (String, String) = switch failure {
            case .missingOriginal: ("not_found", L("Pippa couldn’t find the original email in Mail, so no reply was created.", table: "MCP"))
            case .ambiguousOriginal: ("ambiguous", L("Mail has several emails with the same identity, so Pippa created no reply.", table: "MCP"))
            case .searchIncomplete: ("search_incomplete", L("Mail didn’t answer in time while Pippa looked for the original email. Nothing was created; try again in a moment.", table: "MCP"))
            default: ("not_created", L("Mail didn’t create the reply. Nothing is in Mail; try again in a moment.", table: "MCP"))
            }
            return Self.blocked(status, tell, receipt: receipt("failed", status))
        } catch {
            return self.failure(error, .mail, receipt: receipt("failed", "failed"))
        }
        let (state, reason, next): (String, String, String) = switch result {
        case .reply: ("draft_saved", "reply",
                      "The reply is saved as an unsent draft in Mail, in the thread. Say that in one sentence. Never say it was sent.")
        case .replyNeedsPaste: ("opened_text_unconfirmed", "opened",
                                "The reply is open in Mail, but Mail did not confirm the text in it. Say so and show the text so the person can paste it. Nothing was sent.")
        case .newMessage: ("new_mail_open", "newMessage",
                           "A new unsent email is open in Mail. Say that in one sentence. Never say it was sent.")
        }
        var data: [String: Any] = ["subject": draft.replySubject]
        if let to = draft.to { data["to"] = to }
        return PippaMCPToolResult(text: PippaMCPTools.json(["done": true, "state": state, "sent": false, "draft": data, "next": next]),
                                  isError: false, receipt: receipt("done", reason))
    }

    static func quoted(_ subject: String) -> String { L("“%@”", table: "MCP", singleLine(subject, max: 80)) }
}
