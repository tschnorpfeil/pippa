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
    /// `MailScript.messageInfo` is reused for reading one message, so the same fields come back as from `mail_read`.
    static let source = MailScript.source + """

    on accountInboxes()
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    repeat with box in (mailboxes of inbox)
                        set acctID to ""
                        set acctName to ""
                        try
                            set acct to account of box
                            set acctID to (id of acct) as text
                            set acctName to (name of acct) as text
                        on error number errNum
                            my rethrowAccess(errNum)
                        end try
                        set end of out to {acctID, acctName}
                    end repeat
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountInboxes

    on rethrowAccess(errNum)
        if errNum is -1712 or errNum is -1743 or errNum is -1744 then error number errNum
    end rethrowAccess

    on inboxOf(acctID)
        tell application id "com.apple.mail"
            repeat with box in (mailboxes of inbox)
                set boxID to ""
                try
                    set boxID to (id of (account of box)) as text
                on error number errNum
                    my rethrowAccess(errNum)
                end try
                if boxID is acctID then return contents of box
            end repeat
        end tell
        error "gone" number -1728
    end inboxOf

    -- Where Mail says a message is: its account's id and the whole mailbox path, top first.
    on identityOf(m)
        tell application id "com.apple.mail"
            set box to mailbox of m
            set acctID to (id of (account of box)) as text
            set boxPath to {(name of box) as text}
            set cur to box
            repeat 31 times
                try
                    set parentBox to container of cur
                    if class of parentBox is not mailbox then exit repeat
                    set beginning of boxPath to (name of parentBox) as text
                    set cur to parentBox
                on error number errNum
                    my rethrowAccess(errNum)
                    exit repeat
                end try
            end repeat
            return {acctID, boxPath}
        end tell
    end identityOf

    on identityOrNone(m)
        try
            return my identityOf(m)
        on error number errNum
            my rethrowAccess(errNum)
            return {"", {}}
        end try
    end identityOrNone

    on accountCandidates(acctID, q, onlyUnread)
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    set box to my inboxOf(acctID)
                    if q is "" and onlyUnread then
                        set theIDs to id of (messages of box whose read status is false)
                        set theDates to date received of (messages of box whose read status is false)
                    else if q is "" then
                        set theIDs to id of (messages of box)
                        set theDates to date received of (messages of box)
                    else if onlyUnread then
                        set theIDs to id of (messages of box whose (subject contains q or sender contains q) and read status is false)
                        set theDates to date received of (messages of box whose (subject contains q or sender contains q) and read status is false)
                    else
                        set theIDs to id of (messages of box whose subject contains q or sender contains q)
                        set theDates to date received of (messages of box whose subject contains q or sender contains q)
                    end if
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
            return {"ok", {theIDs as list, theDates as list}}
        end tell
    end accountCandidates

    on accountRows(acctID, wantedIDs)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    set box to my inboxOf(acctID)
                    repeat with i from 1 to count of wantedIDs
                        set wanted to item i of wantedIDs
                        set found to (messages of box whose id is wanted)
                        if (count of found) is not 1 then
                            set end of out to {}
                        else
                            set m to item 1 of found
                            set theSubject to ""
                            set theSender to ""
                            set theDate to missing value
                            set boxName to ""
                            set c to ""
                            set mid to ""
                            set isUnread to false
                            try
                                set theSubject to (subject of m) as text
                            end try
                            try
                                set theSender to (sender of m) as text
                            end try
                            try
                                set theDate to date received of m
                            end try
                            try
                                set boxName to (name of mailbox of m) as text
                            end try
                            try
                                set c to (content of m) as text
                                if (length of c) > 400 then set c to text 1 thru 400 of c
                            end try
                            try
                                set mid to (message id of m) as text
                            end try
                            try
                                set isUnread to not (read status of m)
                            end try
                            set ident to my identityOrNone(m)
                            set end of out to {wanted, theSubject, theSender, theDate, boxName, c, mid, isUnread, item 1 of ident, item 2 of ident}
                        end if
                    end repeat
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountRows

    on accountMessage(acctID, mailID, theID)
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    set box to my inboxOf(acctID)
                    set found to (messages of box whose id is mailID)
                    if (count of found) is not 1 then return {"ok", {}}
                    set m to item 1 of found
                    if theID is "" then return {"ok", {}}
                    set exactIdentity to false
                    try
                        set candidateID to (message id of m) as text
                        considering case
                            if candidateID is theID or candidateID is ("<" & theID & ">") then set exactIdentity to true
                        end considering
                    on error number errNum
                        my rethrowAccess(errNum)
                    end try
                    if not exactIdentity then return {"ok", {}}
                    return {"ok", {my messageInfo(m), my identityOf(m)}}
                end timeout
            on error number errNum
                if errNum is -1728 then return {"ok", {}}
                return my problem(errNum)
            end try
        end tell
    end accountMessage

    on problem(errNum)
        if errNum is -1712 then return {"timeout"}
        if errNum is -1743 or errNum is -1744 then return {"denied"}
        return {"failed"}
    end problem
    """

    /// The real Mail, through Apple Events: one short step per call on the AppleScript queue.
    struct Live: MailAccountReading {
        func inboxAccounts() async throws -> [MailAccountInfo] {
            try await run("accountInboxes", { [] }) { try MailAccountParse.accounts($0) }
        }

        func candidates(account: String, query: String, unread: Bool) async throws -> [MailSearchCandidate] {
            try await run("accountCandidates", {
                [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(string: query), NSAppleEventDescriptor(boolean: unread)]
            }) { try MailSearchFlow.parseCandidates($0) }
        }

        func rows(account: String, ids: [Int]) async throws -> [MailSearchRow] {
            try await run("accountRows", {
                let list = NSAppleEventDescriptor.list()
                for (i, id) in ids.enumerated() { list.insert(NSAppleEventDescriptor(int32: Int32(id)), at: i + 1) }
                return [NSAppleEventDescriptor(string: account), list]
            }) { try MailSearchFlow.parseRows($0, expecting: ids.count, identity: true) }
        }

        func message(account: String, mailID: Int, messageID: String) async throws -> MailInboxMessage? {
            guard !messageID.isEmpty else { return nil }
            return try await run("accountMessage", {
                [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(int32: Int32(mailID)), NSAppleEventDescriptor(string: messageID)]
            }) { try MailAccountParse.message($0) }
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

    /// `{{id, name}, …}`. An inbox whose account Mail could not name keeps an empty id: it is reported, never dropped.
    public static func accounts(_ payload: NSAppleEventDescriptor) throws -> [MailAccountInfo] {
        try AppleEvents.items(payload).map { entry in
            guard entry.descriptorType == typeAEList, entry.numberOfItems == 2,
                  let id = entry.atIndex(1)?.stringValue, let name = entry.atIndex(2)?.stringValue else { throw MailAccountProblem.failed }
            return MailAccountInfo(id: id.trimmingCharacters(in: .whitespacesAndNewlines), name: name)
        }
    }
}
