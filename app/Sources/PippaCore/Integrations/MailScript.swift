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
            repeat with m in found
                if who is "" or (sender of m) contains who then
                    if best is missing value then
                        set best to contents of m
                    else if (date received of m) > (date received of best) then
                        set best to contents of m
                    end if
                end if
            end repeat
            if best is missing value then return {}
            return my messageInfo(best)
        end tell
    end findInInbox

    on findByMessageID(theID)
        tell application id "com.apple.mail"
            with timeout of 20 seconds
                set found to (messages of inbox whose message id is theID or message id is ("<" & theID & ">"))
            end timeout
            set best to missing value
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
                set acctName to ""
                try
                    set acctName to (name of account of box) as text
                end try
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
                set theLocation to {acctName, boxPath, (id of m)}
            end try
            set theSource to ""
            try
                set theSource to (source of m) as text
            end try
            return {subject of m, sender of m, date received of m, content of m, attachmentNames, theID, (reply to of m) as text, theLocation, theSource}
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
            message(try AppleEvents.call(source, handler: "findInInbox",
                                         [NSAppleEventDescriptor(string: subject), NSAppleEventDescriptor(string: sender)], app: .mail))
        }
    }

    static func find(messageID: String) async throws -> MailMessage? {
        try await AppleEvents.perform { () throws -> MailMessage? in
            message(try AppleEvents.call(source, handler: "findByMessageID", [NSAppleEventDescriptor(string: messageID)], app: .mail))
        }
    }

    static func message(_ r: NSAppleEventDescriptor) -> MailMessage? {
        let parts = AppleEvents.items(r)
        guard parts.count >= 5 else { return nil }
        let rawID = parts.count >= 6 ? (parts[5].stringValue ?? "") : ""
        let messageID: String? = rawID.isEmpty ? nil : rawID
        let locator = parts.count >= 8 ? MailReplyScript.locator(ScriptValue(parts[7])) : nil
        let source = parts.count >= 9 ? parts[8].stringValue : nil
        return MailMessage(subject: parts[0].stringValue ?? "", sender: parts[1].stringValue ?? "", date: parts[2].dateValue,
                           body: parts[3].stringValue ?? "", attachmentNames: AppleEvents.strings(parts[4]), messageID: messageID,
                           replyTo: parts.count >= 7 ? parts[6].stringValue : nil, locator: locator, source: source)
    }
}
