import Foundation

extension MailAccountScript {
    /// Folders, lookup by Message-ID and moves, one account at a time (MailMove.swift). Appended to `source`, so the
    /// helpers there (`boxOf`, `rethrowAccess`, `problem`) are shared. Texts and ids come in as parameters, never as
    /// script text. A mailbox is named by its whole path, top first, as `boxPathOf` walks its containers.
    static let moveSource = """

    -- The account itself, by Mail's id.
    on accountOf(acctID)
        tell application id "com.apple.mail"
            repeat with acct in accounts
                if ((id of acct) as text) is acctID then return contents of acct
            end repeat
        end tell
        error "gone" number -1728
    end accountOf

    -- A mailbox's whole path, top first: its containers up to its account (of any account class).
    on boxPathOf(box, acctID)
        tell application id "com.apple.mail"
            set boxPath to {(name of box) as text}
            set cur to box
            repeat 31 times
                set parentBox to missing value
                try
                    set parentBox to container of cur
                on error number errNum
                    my rethrowAccess(errNum)
                    error "unknown mailbox root" number -1728
                end try
                if parentBox is missing value then return boxPath
                set parentClass to class of parentBox
                if parentClass is mailbox or parentClass is «class mbxc» then
                    set beginning of boxPath to (name of parentBox) as text
                    set cur to parentBox
                else
                    set parentID to ""
                    try
                        set parentID to (id of parentBox) as text
                    on error number errNum
                        my rethrowAccess(errNum)
                    end try
                    if parentID is acctID then return boxPath
                    error "unknown mailbox root" number -1728
                end if
            end repeat
            error "mailbox path too deep" number -1728
        end tell
    end boxPathOf

    on boxPathOrNone(box, acctID)
        try
            return my boxPathOf(box, acctID)
        on error number errNum
            my rethrowAccess(errNum)
            return {}
        end try
    end boxPathOrNone

    -- Every mailbox of the account, nested ones included (at most 500).
    on allBoxes(acct)
        tell application id "com.apple.mail"
            set queue to {}
            try
                set queue to (mailboxes of acct) as list
            on error number errNum
                my rethrowAccess(errNum)
            end try
            set i to 1
            repeat while i ≤ (count of queue) and i ≤ 500
                set box to item i of queue
                try
                    set kids to (mailboxes of box) as list
                    repeat with k in kids
                        set end of queue to contents of k
                    end repeat
                on error number errNum
                    my rethrowAccess(errNum)
                end try
                set i to i + 1
            end repeat
            return queue
        end tell
    end allBoxes

    -- The mailbox at exactly this path, or missing value. Direct by names first, then every mailbox of the account.
    on boxAt(acctID, wantedPath)
        tell application id "com.apple.mail"
            set acct to my accountOf(acctID)
            try
                set cur to mailbox (item 1 of wantedPath) of acct
                repeat with i from 2 to count of wantedPath
                    set cur to mailbox (item i of wantedPath) of cur
                end repeat
                considering case, diacriticals, hyphens, punctuation and white space
                    if my boxPathOrNone(cur, acctID) is wantedPath then return cur
                end considering
            on error number errNum
                my rethrowAccess(errNum)
            end try
            try
                set ib to my boxOf(acctID, "inbox")
                considering case, diacriticals, hyphens, punctuation and white space
                    if my boxPathOrNone(ib, acctID) is wantedPath then return ib
                end considering
            on error number errNum
                my rethrowAccess(errNum)
            end try
            repeat with box in my allBoxes(acct)
                set candidate to contents of box
                considering case, diacriticals, hyphens, punctuation and white space
                    if my boxPathOrNone(candidate, acctID) is wantedPath then return candidate
                end considering
            end repeat
        end tell
        return missing value
    end boxAt

    -- Paths of the account's Inbox, Sent, Drafts, Trash and Junk, as Mail's top-level mailboxes list them.
    on rolePaths(acctID)
        set out to {}
        tell application id "com.apple.mail"
            repeat with roleName in {"inbox", "sent", "drafts", "trash", "junk"}
                set kids to {}
                try
                    if (roleName as text) is "inbox" then set kids to (mailboxes of inbox) as list
                    if (roleName as text) is "sent" then set kids to (mailboxes of sent mailbox) as list
                    if (roleName as text) is "drafts" then set kids to (mailboxes of drafts mailbox) as list
                    if (roleName as text) is "trash" then set kids to (mailboxes of trash mailbox) as list
                    if (roleName as text) is "junk" then set kids to (mailboxes of junk mailbox) as list
                on error number errNum
                    my rethrowAccess(errNum)
                end try
                repeat with box in kids
                    try
                        if ((id of (account of box)) as text) is acctID then
                            set p to my boxPathOrNone(contents of box, acctID)
                            if (count of p) > 0 then set end of out to {roleName as text, p}
                        end if
                    on error number errNum
                        my rethrowAccess(errNum)
                    end try
                end repeat
            end repeat
        end tell
        return out
    end rolePaths

    -- {{path, count, role, {{sender, subject}, …}}, …}; count -1 when Mail did not say.
    on accountFolders(acctID, sampleCount)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 30 seconds
                    set acct to my accountOf(acctID)
                    set roles to my rolePaths(acctID)
                    set seen to {}
                    repeat with box in my allBoxes(acct)
                        set candidate to contents of box
                        set boxPath to my boxPathOrNone(candidate, acctID)
                        if (count of boxPath) > 0 and not (seen contains {boxPath}) then
                            set end of seen to boxPath
                            set n to -1
                            try
                                set n to count of messages of candidate
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            set role to ""
                            repeat with r in roles
                                considering case, diacriticals, hyphens, punctuation and white space
                                    if (item 2 of r) is boxPath then set role to item 1 of r
                                end considering
                            end repeat
                            set picks to {}
                            if sampleCount > 0 and n > 0 then
                                set k to sampleCount
                                if n < k then set k to n
                                repeat with j from 1 to k
                                    set f to ""
                                    set s to ""
                                    try
                                        set m to message j of candidate
                                        try
                                            set f to (sender of m) as text
                                        on error number errNum
                                            my rethrowAccess(errNum)
                                        end try
                                        try
                                            set s to (subject of m) as text
                                        on error number errNum
                                            my rethrowAccess(errNum)
                                        end try
                                        set end of picks to {f, s}
                                    on error number errNum
                                        my rethrowAccess(errNum)
                                    end try
                                end repeat
                            end if
                            set end of out to {boxPath, n, role, picks}
                        end if
                    end repeat
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountFolders

    -- For each Message-ID, Mail's ids of the messages in this mailbox that carry it (with or without angle brackets).
    on accountLocate(acctID, wantedPath, wantedIDs)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 30 seconds
                    set box to my boxAt(acctID, wantedPath)
                    if box is missing value then return {"nobox"}
                    repeat with i from 1 to count of wantedIDs
                        set x to item i of wantedIDs
                        set found to (id of (messages of box whose message id is x or message id is ("<" & x & ">"))) as list
                        set end of out to found
                    end repeat
                end timeout
            on error number errNum
                if errNum is -1728 then return {"nobox"}
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountLocate

    -- Moves each message only when its Mail id still carries its Message-ID. One status per message ("moved",
    -- "changed", "gone" or Mail's error number): for diagnostics only, the result is read back by Message-ID.
    on accountMove(acctID, fromPath, mailIDs, messageIDs, toPath)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 60 seconds
                    set src to my boxAt(acctID, fromPath)
                    set dst to my boxAt(acctID, toPath)
                    if src is missing value or dst is missing value then return {"nobox"}
                    repeat with i from 1 to count of mailIDs
                        set wanted to item i of mailIDs
                        set theID to item i of messageIDs
                        set status to "gone"
                        try
                            set found to (messages of src whose id is wanted)
                            if (count of found) is 1 then
                                set m to item 1 of found
                                set candidateID to (message id of m) as text
                                set same to false
                                considering case, diacriticals, hyphens, punctuation and white space
                                    if candidateID is theID or candidateID is ("<" & theID & ">") then set same to true
                                end considering
                                if same then
                                    move m to dst
                                    set status to "moved"
                                else
                                    set status to "changed"
                                end if
                            end if
                        on error number errNum
                            my rethrowAccess(errNum)
                            set status to (errNum as text)
                        end try
                        set end of out to status
                    end repeat
                end timeout
            on error number errNum
                if errNum is -1728 then return {"nobox"}
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountMove

    -- The probe (`Pippa --mail-move-probe`): every account with Mail's id, name, account type and class.
    on accountKinds()
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    repeat with acct in accounts
                        set acctID to ""
                        set acctName to ""
                        set acctType to ""
                        set acctClass to ""
                        try
                            set acctID to (id of acct) as text
                            set acctName to (name of acct) as text
                        on error number errNum
                            my rethrowAccess(errNum)
                        end try
                        try
                            set acctType to (account type of acct) as text
                        on error number errNum
                            my rethrowAccess(errNum)
                        end try
                        try
                            set acctClass to (class of acct) as text
                        on error number errNum
                            my rethrowAccess(errNum)
                        end try
                        set end of out to {acctID, acctName, acctType, acctClass}
                    end repeat
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountKinds

    -- The probe: a top-level folder of the account with this name, made when it is missing.
    on accountMakeFolder(acctID, theName)
        tell application id "com.apple.mail"
            try
                with timeout of 30 seconds
                    set acct to my accountOf(acctID)
                    if my boxAt(acctID, {theName}) is not missing value then return {"ok", {"existed"}}
                    tell acct to make new mailbox with properties {name:theName}
                    return {"ok", {"made"}}
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
        end tell
    end accountMakeFolder

    -- The probe: the Message-ID of every message in the mailbox at wantedPath (only its two test folders ask).
    on accountMessageIDs(acctID, wantedPath)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 30 seconds
                    set box to my boxAt(acctID, wantedPath)
                    if box is missing value then return {"nobox"}
                    if (count of messages of box) is 0 then return {"ok", {}}
                    set out to (message id of messages of box) as list
                end timeout
            on error number errNum
                if errNum is -1728 then return {"nobox"}
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountMessageIDs

    -- The probe: copies of these inbox messages into the mailbox at toPath. Never a move: the inbox stays as it is.
    on accountDuplicate(acctID, mailIDs, toPath)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 60 seconds
                    set src to my boxOf(acctID, "inbox")
                    set dst to my boxAt(acctID, toPath)
                    if dst is missing value then return {"nobox"}
                    repeat with i from 1 to count of mailIDs
                        set wanted to item i of mailIDs
                        set status to "gone"
                        try
                            set found to (messages of src whose id is wanted)
                            if (count of found) is 1 then
                                duplicate (item 1 of found) to dst
                                set status to "copied"
                            end if
                        on error number errNum
                            my rethrowAccess(errNum)
                            set status to (errNum as text)
                        end try
                        set end of out to status
                    end repeat
                end timeout
            on error number errNum
                if errNum is -1728 then return {"nobox"}
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountDuplicate
    """
}

extension MailAccountScript.Live {
    func folders(account: String, samples: Int) async throws -> [MailFolderInfo] {
        try await run("accountFolders", { [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(int32: Int32(samples))] }) {
            try MailMoveParse.folders($0)
        }
    }

    func locate(account: String, path: [String], messageIDs: [String]) async throws -> [String: [Int]] {
        try await run("accountLocate", {
            [NSAppleEventDescriptor(string: account), MailMoveParse.list(path), MailMoveParse.list(messageIDs)]
        }) { try MailMoveParse.located($0, messageIDs: messageIDs) }
    }

    @discardableResult
    func move(account: String, from: [String], mails: [MailMoveItem], to: [String]) async throws -> [String] {
        guard !mails.isEmpty else { return [] }
        return try await run("accountMove", mutation: true, {
            let ids = NSAppleEventDescriptor.list()
            for (i, mail) in mails.enumerated() { ids.insert(NSAppleEventDescriptor(int32: Int32(truncatingIfNeeded: mail.mailID)), at: i + 1) }
            return [NSAppleEventDescriptor(string: account), MailMoveParse.list(from), ids, MailMoveParse.list(mails.map(\.messageID)), MailMoveParse.list(to)]
        }) { try MailMoveParse.statuses($0, expecting: mails.count) }
    }
}

/// The probe's extra steps on the real Mail (`MailMoveProbe`): account kinds, a test folder, copies of inbox mails.
extension MailAccountScript.Live: MailMoveProbeMail {
    func accountKinds() async throws -> [MailMoveProbe.AccountKind] {
        try await run("accountKinds", { [] }) { payload in
            try AppleEvents.items(payload).map { entry in
                let parts = AppleEvents.strings(entry)
                guard entry.descriptorType == typeAEList, parts.count == 4 else { throw MailAccountProblem.failed }
                return MailMoveProbe.AccountKind(id: parts[0], name: parts[1], type: parts[2], className: parts[3])
            }
        }
    }

    func makeFolder(account: String, name: String) async throws -> Bool {
        try await run("accountMakeFolder", mutation: true, { [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(string: name)] }) {
            AppleEvents.strings($0).first == "made"
        }
    }

    func messageIDs(account: String, path: [String]) async throws -> [String] {
        // Only the probe's own test folders, never any other mailbox.
        guard path == [MailMoveProbe.folderA] || path == [MailMoveProbe.folderB] else { throw MailAccountProblem.failed }
        return try await run("accountMessageIDs", { [NSAppleEventDescriptor(string: account), MailMoveParse.list(path)] }) { AppleEvents.strings($0) }
    }

    func duplicate(account: String, inboxIDs: [Int], to: [String]) async throws -> [String] {
        guard !inboxIDs.isEmpty else { return [] }
        return try await run("accountDuplicate", mutation: true, {
            let ids = NSAppleEventDescriptor.list()
            for (i, id) in inboxIDs.enumerated() { ids.insert(NSAppleEventDescriptor(int32: Int32(truncatingIfNeeded: id)), at: i + 1) }
            return [NSAppleEventDescriptor(string: account), ids, MailMoveParse.list(to)]
        }) { try MailMoveParse.statuses($0, expecting: inboxIDs.count) }
    }
}

/// Strict reading of the folder, lookup and move answers.
public enum MailMoveParse {
    static func list(_ strings: [String]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (i, s) in strings.enumerated() { list.insert(NSAppleEventDescriptor(string: s), at: i + 1) }
        return list
    }

    /// `{{path, count, role, {{sender, subject}, …}}, …}`.
    public static func folders(_ payload: NSAppleEventDescriptor) throws -> [MailFolderInfo] {
        try AppleEvents.items(payload).map { entry in
            guard entry.descriptorType == typeAEList, entry.numberOfItems == 4, let pathList = entry.atIndex(1), pathList.descriptorType == typeAEList,
                  let countValue = entry.atIndex(2), let roleValue = entry.atIndex(3)?.stringValue, let picks = entry.atIndex(4),
                  picks.descriptorType == typeAEList else { throw MailAccountProblem.failed }
            let path = try AppleEvents.items(pathList).map { part -> String in
                guard part.descriptorType != typeAEList, let name = part.stringValue else { throw MailAccountProblem.failed }
                return name
            }
            let count = Int(countValue.int32Value)
            let samples = try AppleEvents.items(picks).map { pick -> MailFolderSample in
                let parts = AppleEvents.strings(pick)
                guard pick.descriptorType == typeAEList, parts.count == 2 else { throw MailAccountProblem.failed }
                return MailFolderSample(sender: parts[0], subject: parts[1])
            }
            return MailFolderInfo(path: path, count: count >= 0 ? count : nil, role: MailFolderRole(rawValue: roleValue), samples: samples)
        }
    }

    /// One list of Mail ids per asked Message-ID, in order.
    public static func located(_ payload: NSAppleEventDescriptor, messageIDs: [String]) throws -> [String: [Int]] {
        let lists = AppleEvents.items(payload)
        guard lists.count == messageIDs.count || (messageIDs.isEmpty && payload.numberOfItems == 0) else { throw MailAccountProblem.failed }
        var out: [String: [Int]] = [:]
        for (id, list) in zip(messageIDs, lists) {
            out[id, default: []] += list.descriptorType == typeAEList ? AppleEvents.items(list).map { Int($0.int32Value) } : [Int(list.int32Value)]
        }
        return out
    }

    public static func statuses(_ payload: NSAppleEventDescriptor, expecting: Int) throws -> [String] {
        let statuses = AppleEvents.strings(payload)
        guard statuses.count == expecting else { throw MailAccountProblem.failed }
        return statuses
    }
}
