import Foundation

extension MailReplyScript {
    static let source = """
    on replyAt(theID, mailID, acctName, boxPath, theAddress, theSubject, theBody, quoteHeader)
        if theID is "" then return {"missing"}
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    set box to my mailboxAt(acctName, boxPath)
                    set found to (messages of box whose id is mailID)
                end timeout
            on error number errNum
                -- Read-only so far: nothing is in Mail.
                if errNum is -1712 then return {"busy"}
                return {"notHere"}
            end try
            if (count of found) is not 1 then return {"notHere"}
            set m to item 1 of found
            set exactIdentity to false
            try
                set candidateID to (message id of m) as text
                considering case
                    if candidateID is theID or candidateID is ("<" & theID & ">") then set exactIdentity to true
                end considering
            end try
            if not exactIdentity then return {"notHere"}
        end tell
        return my openReply(m, theAddress, theSubject, theBody, quoteHeader)
    end replyAt

    on openReply(m, theAddress, theSubject, theBody, quoteHeader)
        set quoteText to ""
        try
            set quoteText to my quoteOf(m, quoteHeader)
        on error number errNum
            -- Mail stalls while reading the original: stop before anything is created.
            if errNum is -1712 then return {"busy"}
        end try
        tell application id "com.apple.mail"
            try
                -- Mail 16 opens the reply window right away, whatever "opening window" says.
                with timeout of 30 seconds
                    set r to reply m
                end timeout
            on error
                -- After dispatch, even a non-timeout error cannot prove that Mail created no reply.
                return {"uncertain"}
            end try
            try
                with timeout of 30 seconds
                    set subject of r to theSubject
                    delete every to recipient of r
                    if theAddress is not "" then
                        tell r to make new to recipient at end of to recipients with properties {address:theAddress}
                    end if
                    tell r to make new paragraph at end of content with data (theBody & linefeed)
                    if quoteText is not "" then tell r to make new paragraph at end of content with data (linefeed & quoteText & linefeed)
                end timeout
            on error
                -- The window is open but its fields are unknown: leave it to the person, never close it.
                try
                    with timeout of 5 seconds
                        activate
                    end timeout
                end try
                return {"shown"}
            end try
            -- Saving makes the window show the filled content even if its editor loaded first; the reply
            -- becomes an unsent draft in Mail's Drafts, as a reply draft should.
            set saved to false
            try
                with timeout of 30 seconds
                    save r
                end timeout
                set saved to true
            end try
            -- Saving can change what Mail exposes. Only the fields read after that attempt count;
            -- an earlier read must never stand in for an unconfirmed post-save result.
            try
                with timeout of 15 seconds
                    set readBody to (content of r) as text
                    set readSubject to (subject of r) as text
                    set addresses to {}
                    repeat with targetRecipient in to recipients of r
                        set end of addresses to (address of targetRecipient) as text
                    end repeat
                end timeout
            on error
                return {"shown"}
            end try
            try
                with timeout of 5 seconds
                    activate
                end timeout
            end try
            return {"reply", readSubject, readBody, addresses, saved}
        end tell
    end openReply

    on quoteOf(m, quoteHeader)
        tell application id "com.apple.mail"
            with timeout of 20 seconds
                set original to (content of m) as text
                set d to date received of m
                set who to (sender of m) as text
            end timeout
        end tell
        if (length of original) > 20000 then set original to (text 1 thru 20000 of original) & linefeed & "[…]"
        repeat while original is not "" and {linefeed, return, space, tab} contains (last character of original)
            if (length of original) is 1 then
                set original to ""
            else
                set original to text 1 thru -2 of original
            end if
        end repeat
        set hh to text -2 thru -1 of ("0" & ((hours of d) as text))
        set mm to text -2 thru -1 of ("0" & ((minutes of d) as text))
        set header to my replaced(my replaced(quoteHeader, "{date}", (short date string of d) & " " & hh & ":" & mm), "{sender}", who)
        set out to {header}
        repeat with p in paragraphs of original
            set lineText to contents of p
            if lineText is "" then
                set end of out to ">"
            else
                set end of out to "> " & lineText
            end if
        end repeat
        set AppleScript's text item delimiters to linefeed
        set q to out as text
        set AppleScript's text item delimiters to ""
        return q
    end quoteOf

    on replaced(theText, token, value)
        set AppleScript's text item delimiters to token
        set parts to text items of theText
        set AppleScript's text item delimiters to value
        set joined to parts as text
        set AppleScript's text item delimiters to ""
        return joined
    end replaced

    on mailboxAt(acctName, boxPath)
        tell application id "com.apple.mail"
            if acctName is "" then
                set box to mailbox (item 1 of boxPath)
            else
                set box to mailbox (item 1 of boxPath) of account acctName
            end if
            repeat with i from 2 to count of boxPath
                set box to mailbox (item i of boxPath) of box
            end repeat
            return box
        end tell
    end mailboxAt

    on mailboxList()
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    repeat with acct in accounts
                        set acctName to (name of acct) as text
                        repeat with box in mailboxes of acct
                            my collectBoxes(box, acctName, {}, out)
                        end repeat
                    end repeat
                    -- On My Mac: the app-level list also holds nested mailboxes; walk only from those without a parent.
                    repeat with box in mailboxes
                        set isTop to true
                        try
                            if class of (container of box) is mailbox then set isTop to false
                        end try
                        if isTop then my collectBoxes(box, "", {}, out)
                    end repeat
                end timeout
            on error number errNum
                if errNum is -1712 then return {"timeout"}
                return {"failed"}
            end try
        end tell
        return {"ok", out}
    end mailboxList

    on collectBoxes(box, acctName, parentPath, out)
        tell application id "com.apple.mail"
            set boxPath to parentPath & {(name of box) as text}
            set end of out to {acctName, boxPath, ""}
            repeat with childBox in mailboxes of box
                my collectBoxes(childBox, acctName, boxPath, out)
            end repeat
        end tell
    end collectBoxes

    on findIn(theID, acctName, boxPath)
        tell application id "com.apple.mail"
            try
                with timeout of 15 seconds
                    set box to my mailboxAt(acctName, boxPath)
                    set found to (every message of box whose message id is theID or message id is ("<" & theID & ">"))
                    set ids to {}
                    repeat with candidate in found
                        set candidateID to (message id of candidate) as text
                        set exactIdentity to false
                        considering case
                            if candidateID is theID or candidateID is ("<" & theID & ">") then set exactIdentity to true
                        end considering
                        if exactIdentity then set end of ids to (id of candidate)
                    end repeat
                end timeout
                return {"ok", ids}
            on error number errNum
                if errNum is -1712 then return {"timeout"}
                return {"skip"}
            end try
        end tell
    end findIn

    on newMessage(theAddress, theName, theSubject, theBody)
        tell application id "com.apple.mail"
            -- Every native event is bounded, including compose creation and its readback.
            -- Errors may follow a successful creation: never create another message here.
            with timeout of 30 seconds
                set nm to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
                if theAddress is not "" then
                    if theName is "" then
                        tell nm to make new to recipient at end of to recipients with properties {address:theAddress}
                    else
                        tell nm to make new to recipient at end of to recipients with properties {address:theAddress, name:theName}
                    end if
                end if
                activate
                set recipientAddresses to {}
                repeat with targetRecipient in to recipients of nm
                    set end of recipientAddresses to (address of targetRecipient) as text
                end repeat
                return {(subject of nm) as text, (content of nm) as text, recipientAddresses}
            end timeout
        end tell
    end newMessage
    """
}
