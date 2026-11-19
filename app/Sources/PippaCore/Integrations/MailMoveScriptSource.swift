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

    -- A clock for the folder listing's bounds, in whole seconds (the probe's --diagnose passes one in milliseconds).
    -- Outside any tell block, so asking the time never waits for Mail.
    script coarseClock
        on mark()
            return current date
        end mark
        on secondsSince(m)
            return ((current date) - m) as real
        end secondsSince
    end script

    -- A mailbox's whole path, top first: its containers up to its account (of any account class).
    on boxPathOf(box, acctID)
        return my boxPathWithin(box, acctID, 30)
    end boxPathOf

    -- As boxPathOf, each Apple event bounded by secs seconds; a timeout raises -1712.
    on boxPathWithin(box, acctID, secs)
        tell application id "com.apple.mail"
            with timeout of secs seconds
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
            end timeout
        end tell
    end boxPathWithin

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

    -- The listing behind mail_folders and the probe's --diagnose. Each question about one mailbox (its path, its count,
    -- one sample, its subfolders) is its own Apple event bounded by perEvent seconds. One that times out (-1712) leaves
    -- only that mailbox incomplete: count -1 and no samples ("slow"), or not named at all, and the rest go on. After
    -- countBound seconds the remaining mailboxes get their path only ("path_only"); after pathBound seconds they are not
    -- asked at all and only counted. Returns {folders, unnamed, unexpanded, stats}: folders
    -- {{path, count, role, {{sender, subject}, …}, gap}, …}, count -1 when Mail did not say; unnamed: mailboxes not
    -- listed; unexpanded: listed mailboxes whose subfolders Mail did not list in time; stats {asked, listed,
    -- {path, count, sample, subfolders timeouts}, slowest mailbox seconds, total seconds, countBound hit, pathBound hit}.
    on listFolders(acctID, sampleCount, perEvent, countBound, pathBound, clk)
        set started to clk's mark()
        set out to {}
        set seen to {}
        set unnamed to 0
        set unexpanded to 0
        set pathTimeouts to 0
        set countTimeouts to 0
        set sampleTimeouts to 0
        set kidTimeouts to 0
        set slowest to 0
        set countHit to 0
        set pathHit to 0
        set asked to 0
        tell application id "com.apple.mail"
            with timeout of 30 seconds
                set acct to my accountOf(acctID)
                set roles to my rolePaths(acctID)
                set queue to {}
                try
                    set queue to (mailboxes of acct) as list
                on error number errNum
                    my rethrowAccess(errNum)
                end try
            end timeout
            set i to 1
            repeat while i ≤ (count of queue)
                if i > 500 then
                    set unnamed to unnamed + ((count of queue) - 500)
                    exit repeat
                end if
                set elapsed to clk's secondsSince(started)
                if elapsed ≥ pathBound then
                    set pathHit to 1
                    set unnamed to unnamed + ((count of queue) - i + 1)
                    exit repeat
                end if
                set withCounts to elapsed < countBound
                if not withCounts then set countHit to 1
                set asked to asked + 1
                set boxStart to clk's mark()
                set candidate to item i of queue
                set boxPath to {}
                try
                    set boxPath to my boxPathWithin(candidate, acctID, perEvent)
                on error number errNum
                    if errNum is -1712 then
                        set pathTimeouts to pathTimeouts + 1
                        set unnamed to unnamed + 1
                    else
                        my rethrowAccess(errNum)
                    end if
                end try
                if (count of boxPath) > 0 and not (seen contains {boxPath}) then
                    set end of seen to boxPath
                    set role to ""
                    repeat with r in roles
                        considering case, diacriticals, hyphens, punctuation and white space
                            if (item 2 of r) is boxPath then set role to item 1 of r
                        end considering
                    end repeat
                    set n to -1
                    set picks to {}
                    set gap to "path_only"
                    if withCounts then
                        set gap to ""
                        try
                            with timeout of perEvent seconds
                                set n to count of messages of candidate
                            end timeout
                        on error number errNum
                            if errNum is -1712 then
                                set gap to "slow"
                                set countTimeouts to countTimeouts + 1
                            else
                                my rethrowAccess(errNum)
                            end if
                        end try
                        if gap is "" and sampleCount > 0 and n > 0 then
                            set k to sampleCount
                            if n < k then set k to n
                            repeat with j from 1 to k
                                set f to ""
                                set s to ""
                                set timedOut to false
                                try
                                    with timeout of perEvent seconds
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
                                    end timeout
                                    set end of picks to {f, s}
                                on error number errNum
                                    if errNum is -1712 then
                                        set timedOut to true
                                    else
                                        my rethrowAccess(errNum)
                                    end if
                                end try
                                if timedOut then
                                    set gap to "slow"
                                    set n to -1
                                    set picks to {}
                                    set sampleTimeouts to sampleTimeouts + 1
                                    exit repeat
                                end if
                            end repeat
                        end if
                    end if
                    set kids to {}
                    try
                        with timeout of perEvent seconds
                            set kids to (mailboxes of candidate) as list
                        end timeout
                    on error number errNum
                        if errNum is -1712 then
                            set kidTimeouts to kidTimeouts + 1
                            set unexpanded to unexpanded + 1
                        else
                            my rethrowAccess(errNum)
                        end if
                    end try
                    repeat with kid in kids
                        set end of queue to contents of kid
                    end repeat
                    set end of out to {boxPath, n, role, picks, gap}
                end if
                set d to clk's secondsSince(boxStart)
                if d > slowest then set slowest to d
                set i to i + 1
            end repeat
        end tell
        set stats to {asked, count of out, {pathTimeouts, countTimeouts, sampleTimeouts, kidTimeouts}, slowest, clk's secondsSince(started), countHit, pathHit}
        return {out, unnamed, unexpanded, stats}
    end listFolders

    -- {{folders, unnamed, unexpanded} as listFolders returns them, or a problem word.
    on accountFolders(acctID, sampleCount, perEvent, countBound, pathBound)
        try
            set r to my listFolders(acctID, sampleCount, perEvent, countBound, pathBound, coarseClock)
        on error number errNum
            return my problem(errNum)
        end try
        return {"ok", {item 1 of r, item 2 of r, item 3 of r}}
    end accountFolders

    -- For each Message-ID, Mail's ids of the messages in this mailbox that carry it (with or without angle brackets):
    -- {live ids, ids marked deleted}. On IMAP a moved mail's old copy can stay listed with deleted status until expunged.
    -- Each Apple event bounded by secs seconds; a timeout raises -1712.
    on accountLocate(acctID, wantedPath, wantedIDs, secs)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of secs seconds
                    set box to my boxAt(acctID, wantedPath)
                    if box is missing value then return {"nobox"}
                    repeat with i from 1 to count of wantedIDs
                        set x to item i of wantedIDs
                        set found to (messages of box whose message id is x or message id is ("<" & x & ">")) as list
                        set liveIDs to {}
                        set goneIDs to {}
                        repeat with hit in found
                            set m to contents of hit
                            if (deleted status of m) is true then
                                set end of goneIDs to (id of m)
                            else
                                set end of liveIDs to (id of m)
                            end if
                        end repeat
                        set end of out to {liveIDs, goneIDs}
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

    -- The probe: the top-level mailbox with exactly this name, or missing value. Asked by name only, never by listing the
    -- account's other mailboxes. Each Apple event bounded by perEvent seconds; a timeout raises -1712.
    on testBoxOf(acct, acctID, theName, perEvent)
        tell application id "com.apple.mail"
            try
                with timeout of perEvent seconds
                    set cur to mailbox theName of acct
                end timeout
                considering case, diacriticals, hyphens, punctuation and white space
                    if my boxPathWithin(cur, acctID, perEvent) is {theName} then return cur
                end considering
            on error number errNum
                my rethrowAccess(errNum)
            end try
        end tell
        return missing value
    end testBoxOf

    -- The probe: its test folders, each by exact name (testBoxOf) and counted. Per name {"ok", count}, {"missing", -1}
    -- or {"timeout", "resolve" or "count"}: which Apple event did not answer within perEvent seconds.
    on accountTestFolders(acctID, theNames, perEvent)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 30 seconds
                    set acct to my accountOf(acctID)
                end timeout
                repeat with theName in theNames
                    set phase to "resolve"
                    try
                        set box to my testBoxOf(acct, acctID, (contents of theName) as text, perEvent)
                        if box is missing value then
                            set end of out to {"missing", -1}
                        else
                            set phase to "count"
                            with timeout of perEvent seconds
                                set n to count of messages of box
                            end timeout
                            set end of out to {"ok", n}
                        end if
                    on error number errNum
                        if errNum is not -1712 then error number errNum
                        set end of out to {"timeout", phase}
                    end try
                end repeat
            on error number errNum
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountTestFolders

    -- The probe: a top-level folder of the account with this name, made when it is missing.
    on accountMakeFolder(acctID, theName)
        tell application id "com.apple.mail"
            try
                with timeout of 30 seconds
                    set acct to my accountOf(acctID)
                    if my testBoxOf(acct, acctID, theName, 10) is not missing value then return {"ok", {"existed"}}
                    tell acct to make new mailbox with properties {name:theName}
                    return {"ok", {"made"}}
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
        end tell
    end accountMakeFolder

    -- The probe: the Message-ID and deleted status of every message in the mailbox at wantedPath (only its two test
    -- folders ask): {{Message-IDs}, {deleted statuses}}, in the same order.
    on accountMessageIDs(acctID, wantedPath)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 30 seconds
                    set box to my testBoxOf(my accountOf(acctID), acctID, item 1 of wantedPath, 10)
                    if box is missing value then return {"nobox"}
                    if (count of messages of box) is 0 then return {"ok", {{}, {}}}
                    set theIDs to (message id of messages of box) as list
                    set flags to (deleted status of messages of box) as list
                    set out to {theIDs, flags}
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
                    set dst to my testBoxOf(my accountOf(acctID), acctID, item 1 of toPath, 10)
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

extension MailAccountScript {
    /// The probe's `--diagnose` only: the same listing as `accountFolders`, timed in milliseconds through
    /// AppleScriptObjC's clock. A source of its own, so `use framework` never reaches the scripts the tools run.
    static let diagnoseSource = """
    use AppleScript version "2.4"
    use framework "Foundation"
    use scripting additions

    """ + source + """

    script fineClock
        on mark()
            return (current application's NSDate's timeIntervalSinceReferenceDate()) as real
        end mark
        on secondsSince(m)
            return ((current application's NSDate's timeIntervalSinceReferenceDate()) as real) - m
        end secondsSince
    end script

    -- {asked, listed, unnamed, unexpanded, {path, count, sample, subfolders timeouts}, slowest, total, countHit, pathHit}:
    -- numbers only, never a mailbox's name.
    on accountFolderTimings(acctID, sampleCount, perEvent, countBound, pathBound)
        try
            set r to my listFolders(acctID, sampleCount, perEvent, countBound, pathBound, fineClock)
        on error number errNum
            return my problem(errNum)
        end try
        set stats to item 4 of r
        return {"ok", {item 1 of stats, item 2 of stats, item 2 of r, item 3 of r, item 3 of stats, item 4 of stats, item 5 of stats, item 6 of stats, item 7 of stats}}
    end accountFolderTimings
    """
}

extension MailAccountScript.Live {
    static var listingBounds: [NSAppleEventDescriptor] {
        [MailFolderListing.eventTimeout, MailFolderListing.countBound, MailFolderListing.pathBound].map { NSAppleEventDescriptor(int32: Int32($0)) }
    }

    func folders(account: String, samples: Int) async throws -> MailFolderList {
        try await run("accountFolders", { [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(int32: Int32(samples))] + Self.listingBounds }) {
            try MailMoveParse.folders($0)
        }
    }

    func locate(account: String, path: [String], messageIDs: [String]) async throws -> [String: MailLocated] {
        try await locate(account: account, path: path, messageIDs: messageIDs, eventTimeout: 30)
    }

    func locate(account: String, path: [String], messageIDs: [String], eventTimeout: Int) async throws -> [String: MailLocated] {
        try await run("accountLocate", {
            [NSAppleEventDescriptor(string: account), MailMoveParse.list(path), MailMoveParse.list(messageIDs), NSAppleEventDescriptor(int32: Int32(eventTimeout))]
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

    func testFolders(account: String) async throws -> [MailMoveProbe.TestFolder] {
        let names = [MailMoveProbe.folderA, MailMoveProbe.folderB]
        return try await run("accountTestFolders", {
            [NSAppleEventDescriptor(string: account), MailMoveParse.list(names), NSAppleEventDescriptor(int32: Int32(MailFolderListing.eventTimeout))]
        }) { payload in
            let entries = AppleEvents.items(payload)
            guard entries.count == names.count else { throw MailAccountProblem.failed }
            return try zip(names, entries).map { name, entry in
                guard entry.descriptorType == typeAEList, entry.numberOfItems == 2, let state = entry.atIndex(1)?.stringValue,
                      let value = entry.atIndex(2) else { throw MailAccountProblem.failed }
                switch state {
                case "ok": return MailMoveProbe.TestFolder(path: [name], count: Int(value.int32Value))
                case "missing": return MailMoveProbe.TestFolder(path: [name], count: nil, exists: false)
                case "timeout": return MailMoveProbe.TestFolder(path: [name], count: nil, timedOut: value.stringValue == "count" ? "count" : "resolve")
                default: throw MailAccountProblem.failed
                }
            }
        }
    }

    func folderTimings(account: String, samples: Int) async throws -> MailMoveProbe.ListingTimings {
        guard AppleEvents.isRunning(.mail) else { throw PippaError.appNotOpen(Integration.mail.appName) }
        return try await AppleEvents.perform { () throws -> MailMoveProbe.ListingTimings in
            let reply = try AppleEvents.call(MailAccountScript.diagnoseSource, handler: "accountFolderTimings",
                                             [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(int32: Int32(samples))] + Self.listingBounds, app: .mail)
            let payload = try MailAccountParse.payload(reply)
            guard payload.numberOfItems == 9, let timeouts = payload.atIndex(5), timeouts.descriptorType == typeAEList, timeouts.numberOfItems == 4 else {
                throw MailAccountProblem.failed
            }
            func int(_ i: Int) -> Int { Int(payload.atIndex(i)?.int32Value ?? 0) }
            func ms(_ i: Int) -> Int { Int(((payload.atIndex(i)?.doubleValue ?? 0) * 1000).rounded()) }
            let t = AppleEvents.items(timeouts).map { Int($0.int32Value) }
            return MailMoveProbe.ListingTimings(asked: int(1), listed: int(2), unnamed: int(3), unexpanded: int(4),
                                                timeouts: ["path": t[0], "count": t[1], "sample": t[2], "subfolders": t[3]],
                                                slowestMs: ms(6), totalMs: ms(7), countBoundReached: int(8) != 0, pathBoundReached: int(9) != 0)
        }
    }

    func makeFolder(account: String, name: String) async throws -> Bool {
        try await run("accountMakeFolder", mutation: true, { [NSAppleEventDescriptor(string: account), NSAppleEventDescriptor(string: name)] }) {
            AppleEvents.strings($0).first == "made"
        }
    }

    func messageIDs(account: String, path: [String]) async throws -> [MailMoveProbe.Listed] {
        // Only the probe's own test folders, never any other mailbox.
        guard path == [MailMoveProbe.folderA] || path == [MailMoveProbe.folderB] else { throw MailAccountProblem.failed }
        return try await run("accountMessageIDs", { [NSAppleEventDescriptor(string: account), MailMoveParse.list(path)] }) { try MailMoveParse.listed($0) }
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

    /// `{{{path, count, role, {{sender, subject}, …}, gap}, …}, unnamed, unexpanded}`; gap "", "slow" or "path_only".
    public static func folders(_ payload: NSAppleEventDescriptor) throws -> MailFolderList {
        guard payload.numberOfItems == 3, let list = payload.atIndex(1), list.descriptorType == typeAEList,
              let unnamed = payload.atIndex(2), unnamed.descriptorType != typeAEList,
              let unexpanded = payload.atIndex(3), unexpanded.descriptorType != typeAEList else { throw MailAccountProblem.failed }
        let folders = try AppleEvents.items(list).map { entry in
            guard entry.descriptorType == typeAEList, entry.numberOfItems == 5, let pathList = entry.atIndex(1), pathList.descriptorType == typeAEList,
                  let countValue = entry.atIndex(2), let roleValue = entry.atIndex(3)?.stringValue, let picks = entry.atIndex(4),
                  picks.descriptorType == typeAEList, let gapValue = entry.atIndex(5)?.stringValue else { throw MailAccountProblem.failed }
            let gap: MailFolderGap?
            if gapValue.isEmpty { gap = nil } else if let known = MailFolderGap(rawValue: gapValue) { gap = known } else { throw MailAccountProblem.failed }
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
            return MailFolderInfo(path: path, count: count >= 0 && gap == nil ? count : nil, role: MailFolderRole(rawValue: roleValue),
                                  samples: gap == nil ? samples : [], gap: gap)
        }
        return MailFolderList(folders: folders, unnamed: max(0, Int(unnamed.int32Value)), unexpanded: max(0, Int(unexpanded.int32Value)))
    }

    /// `{live ids, deleted ids}` per asked Message-ID, in order.
    public static func located(_ payload: NSAppleEventDescriptor, messageIDs: [String]) throws -> [String: MailLocated] {
        let entries = AppleEvents.items(payload)
        guard entries.count == messageIDs.count || (messageIDs.isEmpty && payload.numberOfItems == 0) else { throw MailAccountProblem.failed }
        func ids(_ list: NSAppleEventDescriptor?) throws -> [Int] {
            guard let list, list.descriptorType == typeAEList else { throw MailAccountProblem.failed }
            return AppleEvents.items(list).map { Int($0.int32Value) }
        }
        var out: [String: MailLocated] = [:]
        for (id, entry) in zip(messageIDs, entries) {
            guard entry.descriptorType == typeAEList, entry.numberOfItems == 2 else { throw MailAccountProblem.failed }
            let live = try ids(entry.atIndex(1)), deleted = try ids(entry.atIndex(2))
            out[id, default: MailLocated()].live += live
            out[id, default: MailLocated()].deleted += deleted
        }
        return out
    }

    /// The probe's `{{Message-IDs}, {deleted statuses}}` of one test folder, as many of each.
    public static func listed(_ payload: NSAppleEventDescriptor) throws -> [MailMoveProbe.Listed] {
        guard payload.numberOfItems == 2, let ids = payload.atIndex(1), ids.descriptorType == typeAEList,
              let flags = payload.atIndex(2), flags.descriptorType == typeAEList, ids.numberOfItems == flags.numberOfItems else {
            throw MailAccountProblem.failed
        }
        return zip(AppleEvents.items(ids), AppleEvents.items(flags)).map { MailMoveProbe.Listed(messageID: $0.stringValue ?? "", deleted: $1.booleanValue) }
    }

    public static func statuses(_ payload: NSAppleEventDescriptor, expecting: Int) throws -> [String] {
        let statuses = AppleEvents.strings(payload)
        guard statuses.count == expecting else { throw MailAccountProblem.failed }
        return statuses
    }
}
