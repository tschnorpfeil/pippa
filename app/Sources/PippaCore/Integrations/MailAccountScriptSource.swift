import Foundation

extension MailAccountScript {
    /// `MailScript.messageInfo` is reused for reading one message, so the same fields come back as from `mail_read`.
    static let source = MailScript.source + moveSource + """

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
        return my boxOf(acctID, "inbox")
    end inboxOf

    -- The account's child of Mail's top-level In, Sent or Drafts mailbox.
    on boxOf(acctID, boxKind)
        tell application id "com.apple.mail"
            if boxKind is "sent" then
                set boxes to mailboxes of sent mailbox
            else if boxKind is "drafts" then
                set boxes to mailboxes of drafts mailbox
            else
                set boxes to mailboxes of inbox
            end if
            repeat with box in boxes
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
    end boxOf

    -- When a message is dated: received for the inbox; sent (else received) for Sent and Drafts.
    on dateOf(m, boxKind)
        tell application id "com.apple.mail"
            set d to missing value
            if boxKind is not "inbox" then
                try
                    set d to date sent of m
                on error number errNum
                    my rethrowAccess(errNum)
                end try
            end if
            if d is missing value then
                try
                    set d to date received of m
                on error number errNum
                    my rethrowAccess(errNum)
                end try
            end if
            return d
        end tell
    end dateOf

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
                    if parentBox is missing value then return {acctID, boxPath}
                    set parentClass to class of parentBox
                    if parentClass is in {account, imap account, iCloud account, pop account} then
                        if (id of parentBox as text) is acctID then return {acctID, boxPath}
                        error "wrong mailbox account" number -1728
                    end if
                    if parentClass is not mailbox and parentClass is not «class mbxc» then error "unknown mailbox root" number -1728
                    set beginning of boxPath to (name of parentBox) as text
                    set cur to parentBox
                on error number errNum
                    my rethrowAccess(errNum)
                    error "unknown mailbox root" number -1728
                end try
            end repeat
            error "mailbox path too deep" number -1728
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

    -- Every match is read in bulk (one Apple Event per property), never message by message: a large mailbox stays
    -- within the timeout. Sent and Drafts pair `date sent` by Mail id and fall back to `date received` per message.
    on accountCandidates(acctID, q, readMode, boxKind)
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    set box to my boxOf(acctID, boxKind)
                    set theIDs to my matchIDs(box, q, readMode) as list
                    set theDates to my matchDates(box, q, readMode, false) as list
                    if (count of theIDs) is not (count of theDates) then
                        set theIDs to my matchIDs(box, q, readMode) as list
                        set theDates to my matchDates(box, q, readMode, false) as list
                    end if
                    if boxKind is not "inbox" then
                        set sentIDs to {}
                        set sentDates to {}
                        set bulkOK to false
                        try
                            set sentIDs to my matchIDs(box, q, readMode) as list
                            set sentDates to my matchDates(box, q, readMode, true) as list
                            if (count of sentIDs) is not (count of sentDates) then
                                set sentIDs to my matchIDs(box, q, readMode) as list
                                set sentDates to my matchDates(box, q, readMode, true) as list
                            end if
                            if (count of sentIDs) is (count of sentDates) then set bulkOK to true
                        on error number errNum
                            my rethrowAccess(errNum)
                        end try
                        if not bulkOK then
                            set sentIDs to {}
                            set sentDates to {}
                            if (count of theIDs) ≤ 200 then
                                repeat with i from 1 to count of theIDs
                                    set wanted to item i of theIDs
                                    set found to (messages of box whose id is wanted)
                                    if (count of found) is 1 then
                                        set d to missing value
                                        try
                                            set d to date sent of (item 1 of found)
                                        on error number errNum
                                            my rethrowAccess(errNum)
                                        end try
                                        set end of sentIDs to wanted
                                        set end of sentDates to d
                                    end if
                                end repeat
                            end if
                        end if
                        return {"ok", {theIDs, theDates, sentIDs, sentDates}}
                    end if
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
            return {"ok", {theIDs, theDates}}
        end tell
    end accountCandidates

    on matchIDs(box, q, readMode)
        tell application id "com.apple.mail"
            if q is "" then
                if readMode is "unread" then return id of (messages of box whose read status is false)
                if readMode is "read" then return id of (messages of box whose read status is true)
                return id of (messages of box)
            end if
            if readMode is "unread" then return id of (messages of box whose (subject contains q or sender contains q) and read status is false)
            if readMode is "read" then return id of (messages of box whose (subject contains q or sender contains q) and read status is true)
            return id of (messages of box whose subject contains q or sender contains q)
        end tell
    end matchIDs

    on matchDates(box, q, readMode, bySent)
        tell application id "com.apple.mail"
            if bySent then
                if q is "" then
                    if readMode is "unread" then return date sent of (messages of box whose read status is false)
                    if readMode is "read" then return date sent of (messages of box whose read status is true)
                    return date sent of (messages of box)
                end if
                if readMode is "unread" then return date sent of (messages of box whose (subject contains q or sender contains q) and read status is false)
                if readMode is "read" then return date sent of (messages of box whose (subject contains q or sender contains q) and read status is true)
                return date sent of (messages of box whose subject contains q or sender contains q)
            end if
            if q is "" then
                if readMode is "unread" then return date received of (messages of box whose read status is false)
                if readMode is "read" then return date received of (messages of box whose read status is true)
                return date received of (messages of box)
            end if
            if readMode is "unread" then return date received of (messages of box whose (subject contains q or sender contains q) and read status is false)
            if readMode is "read" then return date received of (messages of box whose (subject contains q or sender contains q) and read status is true)
            return date received of (messages of box whose subject contains q or sender contains q)
        end tell
    end matchDates

    on accountRows(acctID, wantedIDs, boxKind)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    set box to my boxOf(acctID, boxKind)
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
                            set wasReplied to false
                            set wasForwarded to false
                            set isFlagged to false
                            try
                                set theSubject to (subject of m) as text
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            try
                                set theSender to (sender of m) as text
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            set theDate to my dateOf(m, boxKind)
                            try
                                set boxName to (name of mailbox of m) as text
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            try
                                set c to (content of m) as text
                                if (length of c) > 400 then set c to text 1 thru 400 of c
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            try
                                set mid to (message id of m) as text
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            try
                                set isUnread to not (read status of m)
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            try
                                set wasReplied to (was replied to of m) as boolean
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            try
                                set wasForwarded to (was forwarded of m) as boolean
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            try
                                set isFlagged to (flagged status of m) as boolean
                            on error number errNum
                                my rethrowAccess(errNum)
                            end try
                            set ident to my identityOrNone(m)
                            set end of out to {wanted, theSubject, theSender, theDate, boxName, c, mid, isUnread, item 1 of ident, item 2 of ident, wasReplied, wasForwarded, isFlagged}
                        end if
                    end repeat
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountRows

    on accountMessage(acctID, mailID, theID, expectedPath, boxKind)
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    set box to my boxOf(acctID, boxKind)
                    set found to (messages of box whose id is mailID)
                    if (count of found) is not 1 then return {"ok", {}}
                    set m to item 1 of found
                    if theID is "" then return {"ok", {}}
                    set exactIdentity to false
                    try
                        set candidateID to (message id of m) as text
                        considering case, diacriticals, hyphens, punctuation and white space
                            if candidateID is theID or candidateID is ("<" & theID & ">") then set exactIdentity to true
                        end considering
                    on error number errNum
                        my rethrowAccess(errNum)
                    end try
                    if not exactIdentity then return {"ok", {}}
                    set ident to my identityOf(m)
                    considering case, diacriticals, hyphens, punctuation and white space
                        if (id of m) is not mailID then return {"ok", {}}
                        if item 1 of ident is not acctID or item 2 of ident is not expectedPath then return {"ok", {}}
                    end considering
                    set info to my messageInfo(m)
                    -- The same date the search showed, so the reference still matches (Sent and Drafts: date sent).
                    if boxKind is not "inbox" then set item 3 of info to my dateOf(m, boxKind)
                    return {"ok", {info, ident}}
                end timeout
            on error number errNum
                if errNum is -1728 then return {"ok", {}}
                return my problem(errNum)
            end try
        end tell
    end accountMessage

    -- Bulk candidate ids and dates in this account's Sent and Drafts, plus ids whose subject contains `core`.
    -- No message headers are read here, so a large Sent mailbox stays fast and changed-subject replies are not dropped.
    on accountThreadCandidates(acctID, core)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 6 seconds
                    repeat with boxKind in {"sent", "drafts"}
                        set entry to {{{}, {}}, {}}
                        try
                            set box to my boxOf(acctID, boxKind as text)
                            set recvIDs to (id of (messages of box)) as list
                            set recvDates to (date received of (messages of box)) as list
                            if (count of recvIDs) is not (count of recvDates) then
                                set recvIDs to (id of (messages of box)) as list
                                set recvDates to (date received of (messages of box)) as list
                            end if
                            set sentIDs to {}
                            set sentDates to {}
                            try
                                set sentIDs to (id of (messages of box)) as list
                                set sentDates to (date sent of (messages of box)) as list
                                if (count of sentIDs) is not (count of sentDates) then
                                    set sentIDs to (id of (messages of box)) as list
                                    set sentDates to (date sent of (messages of box)) as list
                                end if
                                if (count of sentIDs) is not (count of sentDates) then
                                    set sentIDs to {}
                                    set sentDates to {}
                                end if
                            on error number errNum
                                my rethrowAccess(errNum)
                                set sentIDs to {}
                                set sentDates to {}
                            end try
                            set coreIDs to {}
                            if core is not "" then
                                try
                                    set coreIDs to (id of (messages of box whose subject contains core)) as list
                                on error number errNum
                                    my rethrowAccess(errNum)
                                end try
                            end if
                            set entry to {{recvIDs, recvDates, sentIDs, sentDates}, coreIDs}
                        on error number errNum
                            my rethrowAccess(errNum)
                            if errNum is not -1728 then error number errNum
                        end try
                        set end of out to entry
                    end repeat
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountThreadCandidates

    -- Reads headers, own Message-ID and completeness flags for the chosen Sent and Drafts ids (at most 40 per mailbox).
    on accountThreadHeaders(acctID, sentWanted, draftsWanted)
        set out to {}
        set pairs to {{"sent", sentWanted}, {"drafts", draftsWanted}}
        tell application id "com.apple.mail"
            try
                with timeout of 8 seconds
                    repeat with pair in pairs
                        set boxKind to item 1 of pair
                        set wantedIDs to item 2 of pair
                        set found to {}
                        if (count of wantedIDs) > 0 then
                            try
                                set box to my boxOf(acctID, boxKind)
                                repeat with i from 1 to count of wantedIDs
                                    set wanted to item i of wantedIDs
                                    set hits to (messages of box whose id is wanted)
                                    if (count of hits) is not 1 then
                                        set end of found to {}
                                    else
                                        set m to item 1 of hits
                                        set hdrs to ""
                                        set hdrsComplete to false
                                        try
                                            set rawHdrs to (all headers of m) as text
                                            if (length of rawHdrs) > 65536 then
                                                set hdrs to text 1 thru 65536 of rawHdrs
                                            else
                                                set hdrs to rawHdrs
                                                set hdrsComplete to true
                                            end if
                                        on error number errNum
                                            my rethrowAccess(errNum)
                                        end try
                                        set ownID to ""
                                        set ownComplete to false
                                        try
                                            set rawOwn to message id of m
                                            if rawOwn is missing value then
                                                set ownComplete to true
                                            else
                                                set ownID to rawOwn as text
                                                set ownComplete to true
                                            end if
                                        on error number errNum
                                            my rethrowAccess(errNum)
                                        end try
                                        set end of found to {hdrs, ownID, hdrsComplete, ownComplete}
                                    end if
                                end repeat
                            on error number errNum
                                my rethrowAccess(errNum)
                                if errNum is -1728 then
                                    set found to {}
                                    repeat (count of wantedIDs) times
                                        set end of found to {}
                                    end repeat
                                else
                                    error number errNum
                                end if
                            end try
                        end if
                        set end of out to found
                    end repeat
                end timeout
            on error number errNum
                return my problem(errNum)
            end try
        end tell
        return {"ok", out}
    end accountThreadHeaders

    on problem(errNum)
        if errNum is -1712 then return {"timeout"}
        if errNum is -1743 or errNum is -1744 then return {"denied"}
        return {"failed"}
    end problem
    """
}
