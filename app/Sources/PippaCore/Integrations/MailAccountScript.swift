import Foundation

/// Mail's inboxes one account at a time, read only. Each step is its own Apple Event with its own timeout, so one slow or
/// refused account is reported as that account's problem and never as an empty inbox, and Stop works between accounts.
///
/// The top-level `inbox` lists one child mailbox per account inbox (`mailboxes of inbox`), and `id of account` is Mail's
/// stable account identifier (Mail.sdef: "The unique identifier of the account"). Confirmed on a Mac with three accounts
/// by a metadata-only run (account ids, inbox children and their names; no message read). Reading messages per account is
/// checked against the scripting dictionary and with synthetic stand-ins only.
/// Timeouts and refused access are never swallowed: a step that cannot ask Mail reports why, never "gone" or empty.
enum MailAccountScript {
    /// The real Mail, through Apple Events: one short step per call on the AppleScript queue.
    struct Live: MailAccountReading {
        func inboxAccounts() async throws -> [MailAccountInfo] {
            try await run("accountInboxes", { [] }) { try MailAccountParse.accounts($0) }
        }

        func candidates(account: String, query: String, unread: Bool) async throws -> [MailSearchCandidate] {
            try await candidates(account: account, query: query, readStatus: unread ? .unread : .all, mailbox: .inbox)
        }

        func candidates(account: String, query: String, readStatus: MailReadStatus, mailbox: MailBoxKind) async throws -> [MailSearchCandidate] {
            try await run("accountCandidates", {
                [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(string: query), NSAppleEventDescriptor(string: readStatus.rawValue),
                 NSAppleEventDescriptor(string: mailbox.rawValue)]
            }) { try MailSearchFlow.parseCandidates($0) }
        }

        func rows(account: String, ids: [Int]) async throws -> [MailSearchRow] {
            try await rows(account: account, ids: ids, mailbox: .inbox)
        }

        func rows(account: String, ids: [Int], mailbox: MailBoxKind) async throws -> [MailSearchRow] {
            try await run("accountRows", {
                let list = NSAppleEventDescriptor.list()
                for (i, id) in ids.enumerated() { list.insert(NSAppleEventDescriptor(int32: Int32(id)), at: i + 1) }
                return [NSAppleEventDescriptor(string: account), list, NSAppleEventDescriptor(string: mailbox.rawValue)]
            }) { try MailSearchFlow.parseRows($0, expecting: ids.count, identity: true) }
        }

        func message(account: String, mailID: Int, messageID: String, path: [String]) async throws -> MailInboxMessage? {
            try await message(account: account, mailID: mailID, messageID: messageID, path: path, mailbox: .inbox)
        }

        func message(account: String, mailID: Int, messageID: String, path: [String], mailbox: MailBoxKind) async throws -> MailInboxMessage? {
            guard !messageID.isEmpty else { return nil }
            return try await run("accountMessage", {
                let expectedPath = NSAppleEventDescriptor.list()
                for (i, name) in path.enumerated() { expectedPath.insert(NSAppleEventDescriptor(string: name), at: i + 1) }
                return [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(int32: Int32(mailID)),
                        NSAppleEventDescriptor(string: messageID), expectedPath, NSAppleEventDescriptor(string: mailbox.rawValue)]
            }) { try MailAccountParse.message($0) }
        }

        func threadActivity(account: String, messageID: String, subject: String, since: Date?) async throws -> MailThreadActivity? {
            let core = MailThreadMatch.core(subject)
            let boxes = try await run("accountThreadCandidates", {
                [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(string: core)]
            }) { try MailAccountParse.threadCandidates($0) }
            let sentPick = MailThreadMatch.selectCandidates(all: boxes.sent.all, coreMatches: boxes.sent.coreIDs, since: since)
            let draftsPick = MailThreadMatch.selectCandidates(all: boxes.drafts.all, coreMatches: boxes.drafts.coreIDs, since: since)
            if sentPick.ids.isEmpty && draftsPick.ids.isEmpty {
                return MailThreadActivity(sentReply: false, draft: false, sentComplete: sentPick.complete, draftsComplete: draftsPick.complete)
            }
            return try await run("accountThreadHeaders", {
                func idList(_ ids: [Int]) -> NSAppleEventDescriptor {
                    let list = NSAppleEventDescriptor.list()
                    for (i, id) in ids.enumerated() { list.insert(NSAppleEventDescriptor(int32: Int32(id)), at: i + 1) }
                    return list
                }
                return [NSAppleEventDescriptor(string: account), idList(sentPick.ids), idList(draftsPick.ids)]
            }) {
                try MailAccountParse.threadHeaders($0, messageID: messageID,
                                                   expecting: (sentPick.ids.count, draftsPick.ids.count),
                                                   complete: (sentPick.complete, draftsPick.complete))
            }
        }

        /// One step: descriptors are built and read on the AppleScript queue, only Swift values leave it.
        private func run<T: Sendable>(_ handler: String, _ args: @escaping @Sendable () -> [NSAppleEventDescriptor],
                                      _ parse: @escaping @Sendable (NSAppleEventDescriptor) throws -> T) async throws -> T {
            try Task.checkCancellation()
            guard AppleEvents.isRunning(.mail) else { throw PippaError.appNotOpen(Integration.mail.appName) }
            let value = try await AppleEvents.perform {
                try parse(try MailAccountParse.payload(try AppleEvents.call(MailAccountScript.source, handler: handler, args(), app: .mail)))
            }
            try Task.checkCancellation()
            return value
        }
    }
}

/// Strict reading of the per-account answers: `{"ok", payload}`, or one word for what went wrong.
public enum MailAccountParse {
    public static func payload(_ reply: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        guard reply.descriptorType == typeAEList, reply.numberOfItems >= 1, let head = reply.atIndex(1)?.stringValue else {
            throw MailAccountProblem.failed
        }
        switch head {
        case "ok":
            guard reply.numberOfItems == 2, let payload = reply.atIndex(2), payload.descriptorType == typeAEList else { throw MailAccountProblem.failed }
            return payload
        case "timeout": throw MailAccountProblem.timeout
        case "denied": throw PippaError.accessDenied(Integration.mail.appName)
        default: throw MailAccountProblem.failed
        }
    }

    /// `{}` (gone) or `{messageInfo, {acctID, {box, …}}}`; anything else fails.
    public static func message(_ payload: NSAppleEventDescriptor) throws -> MailInboxMessage? {
        if payload.numberOfItems == 0 { return nil }
        guard payload.numberOfItems == 2, let info = payload.atIndex(1), let ident = payload.atIndex(2), info.descriptorType == typeAEList,
              ident.descriptorType == typeAEList, ident.numberOfItems == 2, let account = ident.atIndex(1)?.stringValue,
              let pathList = ident.atIndex(2), pathList.descriptorType == typeAEList, let message = MailScript.message(info) else { throw MailAccountProblem.failed }
        let path = try AppleEvents.items(pathList).map { part -> String in
            guard part.descriptorType != typeAEList, let name = part.stringValue else { throw MailAccountProblem.failed }
            return name
        }
        return MailInboxMessage(message: message, accountID: account.trimmingCharacters(in: .whitespacesAndNewlines), path: path)
    }

    /// `{sent, drafts}`, each `{candidatesReply, coreIDs}`.
    public static func threadCandidates(_ payload: NSAppleEventDescriptor) throws
        -> (sent: (all: [MailSearchCandidate], coreIDs: Set<Int>), drafts: (all: [MailSearchCandidate], coreIDs: Set<Int>)) {
        guard payload.numberOfItems == 2 else { throw MailAccountProblem.failed }
        let parsed = try AppleEvents.items(payload).map { entry -> (all: [MailSearchCandidate], coreIDs: Set<Int>) in
            guard entry.descriptorType == typeAEList, entry.numberOfItems == 2,
                  let candidates = entry.atIndex(1), let coreList = entry.atIndex(2) else { throw MailAccountProblem.failed }
            do {
                let all = try MailSearchFlow.parseCandidates(candidates)
                guard Set(all.map(\.id)).count == all.count else { throw MailAccountProblem.failed }
                return (all, Set(try MailSearchFlow.parseIDs(coreList)))
            } catch {
                throw MailAccountProblem.failed
            }
        }
        return (parsed[0], parsed[1])
    }

    /// `{sent, drafts}`, each `{{headers, own Message-ID, headersComplete, ownComplete} or {}, …}`.
    public static func threadHeaders(_ payload: NSAppleEventDescriptor, messageID: String,
                                     expecting: (Int, Int), complete: (Bool, Bool)) throws -> MailThreadActivity {
        guard payload.numberOfItems == 2 else { throw MailAccountProblem.failed }
        let boolTypes: Set<DescType> = [typeBoolean, typeTrue, typeFalse]
        let counts = [expecting.0, expecting.1]
        let boxes = try zip(AppleEvents.items(payload), counts).map { box, expected -> (hit: Bool, allPresent: Bool) in
            guard box.descriptorType == typeAEList, box.numberOfItems == expected else { throw MailAccountProblem.failed }
            var hit = false
            var allPresent = true
            for entry in AppleEvents.items(box) {
                guard entry.descriptorType == typeAEList else { throw MailAccountProblem.failed }
                if entry.numberOfItems == 0 { allPresent = false; continue }
                guard entry.numberOfItems == 4,
                      entry.atIndex(1)?.descriptorType != typeAEList, let hdrs = entry.atIndex(1)?.stringValue,
                      entry.atIndex(2)?.descriptorType != typeAEList, let ownRaw = entry.atIndex(2)?.stringValue,
                      let hdrsFlag = entry.atIndex(3), boolTypes.contains(hdrsFlag.descriptorType),
                      let ownFlag = entry.atIndex(4), boolTypes.contains(ownFlag.descriptorType) else { throw MailAccountProblem.failed }
                let hdrsComplete = hdrsFlag.booleanValue
                let ownComplete = ownFlag.booleanValue
                if !hdrsComplete || !ownComplete { allPresent = false }
                let safeHdrs = hdrsComplete ? hdrs : MailThreadMatch.completeHeaderLines(hdrs)
                let canExcludeSelf = ownComplete || MailReplySource.capture(headers: Data(safeHdrs.utf8))?.messageID != nil
                if canExcludeSelf, MailThreadMatch.isConfirmedReply(headers: safeHdrs, ownMessageID: ownRaw, to: messageID) {
                    hit = true
                }
            }
            return (hit, allPresent)
        }
        return MailThreadActivity(sentReply: boxes[0].hit, draft: boxes[1].hit,
                                  sentComplete: complete.0 && boxes[0].allPresent,
                                  draftsComplete: complete.1 && boxes[1].allPresent)
    }

    /// `{{id, name}, …}`. An inbox whose account Mail could not name keeps an empty id: it is reported, never dropped.
    public static func accounts(_ payload: NSAppleEventDescriptor) throws -> [MailAccountInfo] {
        try AppleEvents.items(payload).map { entry in
            guard entry.descriptorType == typeAEList, entry.numberOfItems == 2,
                  let id = entry.atIndex(1)?.stringValue, let name = entry.atIndex(2)?.stringValue else { throw MailAccountProblem.failed }
            return MailAccountInfo(id: id.trimmingCharacters(in: .whitespacesAndNewlines), name: name)
        }
    }
}
