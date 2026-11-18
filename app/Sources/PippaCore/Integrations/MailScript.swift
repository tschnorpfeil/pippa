import Foundation

enum MailScript {
    static let source = """
    on selectedMessage()
        tell application id "com.apple.mail"
            set sel to selection
            if (count of sel) is 0 then return {}
            return my messageInfo(item 1 of sel)
        end tell
    end selectedMessage

    on findInInbox(q, who)
        tell application id "com.apple.mail"
            with timeout of 20 seconds
                set found to (messages of inbox whose subject is q)
            end timeout
            set best to missing value
            set copies to 0
            repeat with m in found
                if who is "" or (sender of m) contains who then
                    set copies to copies + 1
                    if best is missing value then set best to contents of m
                end if
            end repeat
            if best is missing value then return {}
            -- Several messages match (e.g. one in each of two accounts): which one is meant is unknown.
            if copies > 1 then return {"ambiguous"}
            return my messageInfo(best)
        end tell
    end findInInbox

    on findByMessageID(theID)
        tell application id "com.apple.mail"
            with timeout of 20 seconds
                set found to (messages of inbox whose message id is theID or message id is ("<" & theID & ">"))
            end timeout
            set best to missing value
            set copies to 0
            repeat with m in found
                set candidateID to ""
                try
                    set candidateID to (message id of m) as text
                end try
                set exactIdentity to false
                considering case
                    if candidateID is theID or candidateID is ("<" & theID & ">") then set exactIdentity to true
                end considering
                if exactIdentity then
                    set copies to copies + 1
                    if best is missing value then
                        set best to contents of m
                    else
                        try
                            if (date received of m) > (date received of best) then set best to contents of m
                        end try
                    end if
                end if
            end repeat
            if best is missing value then return {}
            -- Several messages carry this id (e.g. one in each of two accounts): which one is meant is unknown.
            if copies > 1 then return {"ambiguous"}
            return my messageInfo(best)
        end tell
    end findByMessageID

    on messageInfo(m)
        tell application id "com.apple.mail"
            set attachmentNames to {}
            repeat with a in (mail attachments of m)
                set end of attachmentNames to (name of a)
            end repeat
            set theID to ""
            try
                set theID to (message id of m) as text
            end try
            set theLocation to {}
            try
                set box to mailbox of m
                set boxPath to {(name of box) as text}
                set acct to account of box
                set acctName to ""
                set acctID to ""
                set locationComplete to true
                if acct is missing value then
                    set acctID to "__local__"
                else
                    try
                        set acctName to (name of acct) as text
                    end try
                    try
                        set acctID to (id of acct) as text
                    on error
                        set locationComplete to false
                    end try
                    if acctID is "" or acctID is "__local__" then set locationComplete to false
                end if
                set cur to box
                repeat 31 times
                    try
                        set parentBox to container of cur
                        if class of parentBox is not mailbox then exit repeat
                        set beginning of boxPath to (name of parentBox) as text
                        set cur to parentBox
                    on error
                        exit repeat
                    end try
                end repeat
                if locationComplete then
                    set theLocation to {acctName, boxPath, (id of m)}
                    if acctID is not "" then set end of theLocation to acctID
                end if
            end try
            set theSource to ""
            try
                set theSource to (source of m) as text
            end try
            set wasReplied to false
            set wasForwarded to false
            set isFlagged to false
            try
                set wasReplied to (was replied to of m) as boolean
            end try
            try
                set wasForwarded to (was forwarded of m) as boolean
            end try
            try
                set isFlagged to (flagged status of m) as boolean
            end try
            set boxKind to ""
            try
                set box to mailbox of m
                if (mailboxes of drafts mailbox) contains box then
                    set boxKind to "drafts"
                else if (mailboxes of sent mailbox) contains box then
                    set boxKind to "sent"
                else if (mailboxes of inbox) contains box then
                    set boxKind to "inbox"
                end if
            end try
            set theDate to missing value
            if boxKind is "sent" or boxKind is "drafts" then
                try
                    set theDate to date sent of m
                end try
                if theDate is missing value then
                    try
                        set theDate to date received of m
                    end try
                end if
            else
                try
                    set theDate to date received of m
                end try
                if boxKind is not "inbox" and theDate is missing value then
                    try
                        set theDate to date sent of m
                    end try
                end if
            end if
            return {subject of m, sender of m, theDate, content of m, attachmentNames, theID, (reply to of m) as text, theLocation, theSource, wasReplied, wasForwarded, isFlagged, boxKind}
        end tell
    end messageInfo
    """

    static func selected() async throws -> MailMessage? {
        try await AppleEvents.perform { () throws -> MailMessage? in
            message(try AppleEvents.call(source, handler: "selectedMessage", app: .mail))
        }
    }

    static func find(subject: String, sender: String) async throws -> MailMessage? {
        try await AppleEvents.perform { () throws -> MailMessage? in
            let reply = try AppleEvents.call(source, handler: "findInInbox",
                                             [NSAppleEventDescriptor(string: subject), NSAppleEventDescriptor(string: sender)], app: .mail)
            if isAmbiguous(reply) { throw MailLookupAmbiguous() }
            return message(reply)
        }
    }

    static func find(messageID: String) async throws -> MailMessage? {
        try await AppleEvents.perform { () throws -> MailMessage? in
            let reply = try AppleEvents.call(source, handler: "findByMessageID", [NSAppleEventDescriptor(string: messageID)], app: .mail)
            if isAmbiguous(reply) { throw MailLookupAmbiguous() }
            return message(reply)
        }
    }

    /// `{"ambiguous"}`: more than one inbox message has the requested Message-ID.
    static func isAmbiguous(_ reply: NSAppleEventDescriptor) -> Bool {
        reply.descriptorType == typeAEList && reply.numberOfItems == 1 && reply.atIndex(1)?.stringValue == "ambiguous"
    }

    static func message(_ r: NSAppleEventDescriptor) -> MailMessage? {
        let parts = AppleEvents.items(r)
        guard parts.count >= 5 else { return nil }
        let rawID = parts.count >= 6 ? (parts[5].stringValue ?? "") : ""
        let messageID: String? = rawID.isEmpty ? nil : rawID
        let locator = parts.count >= 8 ? MailReplyScript.locator(ScriptValue(parts[7])) : nil
        let source = parts.count >= 9 ? parts[8].stringValue : nil
        // Mail's flags (items 10–12); an older or shorter answer leaves them false.
        let flags = (9..<12).map { i in parts.count > i && [typeBoolean, typeTrue, typeFalse].contains(parts[i].descriptorType) && parts[i].booleanValue }
        let kind = parts.count > 12 ? MailBoxKind(rawValue: parts[12].stringValue ?? "") : nil
        return MailMessage(subject: parts[0].stringValue ?? "", sender: parts[1].stringValue ?? "", date: parts[2].dateValue,
                           body: parts[3].stringValue ?? "", attachmentNames: AppleEvents.strings(parts[4]), messageID: messageID,
                           replyTo: parts.count >= 7 ? parts[6].stringValue : nil, locator: locator, source: source,
                           replied: flags[0], forwarded: flags[1], flagged: flags[2], mailboxKind: kind)
    }
}
