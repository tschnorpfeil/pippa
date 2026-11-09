import Foundation

/// Native replies to the captured original. No fallback compose is created, nothing is ever sent.
///
/// Mail 16 (macOS 27): `set content` has no effect on a
/// reply and its content reads back empty. `make new paragraph at end of content` does work and reads back;
/// `save` makes the open window show it (the editor otherwise keeps what it loaded first); threading headers stay.
/// Mail's own quote is replaced that way, so the script appends a plain quote built from the original.
/// Order: find the original (captured mailbox first, then a bounded search in steps), reply, fill, save,
/// then read the fields back. Only failures before `reply` leave nothing in Mail.
enum MailReplyScript {
    static func insert(_ draft: MailDraft) async throws -> MailInsertResult {
        guard draft.isReply else { return try await newMessage(draft) }
        guard let id = draft.messageID.flatMap(MailReplySource.canonicalMessageID) else { throw MailReplyFailure.missingOriginal }
        // Fast path: the mailbox and Mail id captured at Call, re-checked by Message-ID in the script.
        if let hint = draft.locator, hint.mailID != nil {
            let response = try await replyAt(hint, id: id, draft: draft)
            if response.first?.text != "notHere" { return try outcome(response, draft: draft) }
        }
        let match = try await search(id, hint: draft.locator)
        let response = try await replyAt(match, id: id, draft: draft)
        // Moved again between search and reply: nothing was created.
        if response.first?.text == "notHere" { throw MailReplyFailure.notCreated }
        return try outcome(response, draft: draft)
    }

    /// Bounded search in steps: one Apple Event per mailbox, so Stop (task cancellation) and progress work
    /// between mailboxes and no single event waits for Mail's whole store.
    private static func search(_ id: String, hint: MailLocator?) async throws -> MailLocator {
        try Task.checkCancellation()
        let listed = try await run("mailboxList", [])
        let boxes = MailOriginalSearch.ordered(try searchMailboxes(listed), preferring: hint)
        let clock = ContinuousClock(), deadline = clock.now + MailOriginalSearch.budget
        var matches: [MailLocator] = [], incomplete = false
        for (index, box) in boxes.enumerated() {
            try Task.checkCancellation()
            MailOriginalSearch.progress?(index, boxes.count)
            if clock.now > deadline { incomplete = true; break }
            let found = try await run("findIn", [.text(id), .text(box.account), .texts(box.path)])
            do {
                matches += try searchMatches(found, in: box)
            } catch {
                // A skipped, timed-out or malformed mailbox response cannot establish uniqueness.
                incomplete = true
            }
        }
        MailOriginalSearch.progress?(boxes.count, boxes.count)
        try Task.checkCancellation()
        return try MailOriginalSearch.decide(matches, incomplete: incomplete)
    }

    /// Search responses must be complete lists. Dropping an unreadable mailbox or message ID could turn an
    /// ambiguous lookup into a false unique match; malformed data therefore stops admission before a reply.
    static func searchMailboxes(_ response: [ScriptValue]) throws -> [MailLocator] {
        guard response.count == 2, response[0].text == "ok", case .list(let entries) = response[1] else {
            throw MailReplyFailure.searchIncomplete
        }
        return try entries.map { entry in
            guard case .list(let parts) = entry, parts.count == 3,
                  let account = parts[0].text, case .list(let components) = parts[1], parts[2].text == "" else {
                throw MailReplyFailure.searchIncomplete
            }
            let path = try components.map { component in
                guard let text = component.text else { throw MailReplyFailure.searchIncomplete }
                return text
            }
            guard let box = MailLocator(account: account, path: path, mailID: nil) else {
                throw MailReplyFailure.searchIncomplete
            }
            return box
        }
    }

    static func searchMatches(_ response: [ScriptValue], in box: MailLocator) throws -> [MailLocator] {
        guard response.count == 2, response[0].text == "ok", case .list(let ids) = response[1] else {
            throw MailReplyFailure.searchIncomplete
        }
        return try ids.map { value in
            guard let id = value.number, let match = MailLocator(account: box.account, path: box.path, mailID: id) else {
                throw MailReplyFailure.searchIncomplete
            }
            return match
        }
    }

    private static func replyAt(_ box: MailLocator, id: String, draft: MailDraft) async throws -> [ScriptValue] {
        guard let mailID = box.mailID else { return [.text("notHere")] }
        try Task.checkCancellation()
        let header = L("On {date}, {sender} wrote:", table: "Core")
        let result = try await run("replyAt", [.text(id), .number(Int32(mailID)), .text(box.account), .texts(box.path),
                                             .text(draft.to ?? ""), .text(draft.replySubject), .text(draft.body), .text(header)], mutation: true)
        // These script statuses are returned before opening a reply. A later cancellation can still promise no change.
        if ["notHere", "busy"].contains(result.first?.text ?? "") { PippaMCPWriteLease.current?.confirmNoMutation() }
        return result
    }

    private static func outcome(_ response: [ScriptValue], draft: MailDraft) throws -> MailInsertResult {
        let status = response.first?.text ?? ""
        let filled = response.count == 5
        if status == "reply", !filled { throw MailReplyFailure.unconfirmed }
        return try draft.replyOutcome(status: status, subject: filled ? (response[1].text ?? "") : "",
                                      body: filled ? (response[2].text ?? "") : "",
                                      recipients: filled ? response[3].items.map { $0.text ?? "" } : [],
                                      saved: filled && response[4].flag == true)
    }

    private static func newMessage(_ draft: MailDraft) async throws -> MailInsertResult {
        let created = try await run("newMessage", [.text(draft.to ?? ""), .text(draft.toName ?? ""), .text(draft.replySubject), .text(draft.body)], mutation: true)
        guard created.count == 3,
              draft.isConfirmed(subject: created[0].text ?? "", body: created[1].text ?? "",
                                recipients: created[2].items.map { $0.text ?? "" }) else { throw PippaError.notAvailable }
        return .newMessage
    }

    /// One short step on the AppleScript queue.
    private static func run(_ handler: String, _ args: [ScriptArgument], mutation: Bool = false) async throws -> [ScriptValue] {
        let result = try await AppleEvents.perform {
            ScriptValue(try AppleEvents.call(source, handler: handler, args.map(\.descriptor), app: .mail, mutation: mutation))
        }.items
        await Task.yield()
        return result
    }

    /// `{account, {mailbox names…}, id}` from `selectedMessage`, or `{account, {names…}, key}` from `mailboxList`.
    static func locator(_ value: ScriptValue) -> MailLocator? {
        let parts = value.items
        guard parts.count == 3, let account = parts[0].text else { return nil }
        return MailLocator(account: account, path: parts[1].items.compactMap(\.text), mailID: parts[2].number)
    }
}
