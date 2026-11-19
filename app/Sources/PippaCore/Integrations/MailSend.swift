import Foundation

// Sending one mail (`mail_send`): only an open, unsent draft window that `mail_draft` created, only exactly as the card
// showed it, and only after the person pressed Send. The Apple Events live in `MailSendScript` below; checks hand the
// tool a fake `MailSending` and never touch Mail.

/// What `insertDraft` created: the result `mail_draft` reports, and Mail's id of the draft window when Mail confirmed
/// its fields (`nil`: nothing `mail_send` could later find). The id holds only for one run of Mail, so the Mail process
/// that made the draft comes with it: another process means the draft is gone.
public struct MailDraftInsert: Sendable, Equatable {
    public var result: MailInsertResult
    public var outgoingID: Int?
    public var mailProcess: Int32?
    public init(result: MailInsertResult, outgoingID: Int?, mailProcess: Int32? = nil) {
        self.result = result; self.outgoingID = outgoingID; self.mailProcess = mailProcess
    }
}

/// An open, unsent mail in Mail as Mail reports it right now: what would leave if it were sent.
public struct MailOutgoing: Sendable, Equatable {
    public var sender: String
    public var subject: String
    public var body: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    /// File names only.
    public var attachments: [String]

    public init(sender: String, subject: String, body: String, to: [String], cc: [String] = [], bcc: [String] = [], attachments: [String] = []) {
        self.sender = sender; self.subject = subject; self.body = body; self.to = to; self.cc = cc; self.bcc = bcc
        self.attachments = attachments
    }

    public var recipients: [String] { to + cc + bcc }
    /// The address in `sender` ("Name <a@b>" → "a@b"); `nil` when Mail named no sender (it reads as "").
    public var senderAddress: String? { MailAddress.parse(sender).address }

    /// The same mail on another read: exact fields, recipients in any order and case (each address as often).
    public func matches(_ other: MailOutgoing) -> Bool {
        sender == other.sender && subject == other.subject && body == other.body && Self.sameAddresses(to, other.to)
            && Self.sameAddresses(cc, other.cc) && Self.sameAddresses(bcc, other.bcc) && attachments == other.attachments
    }

    /// Both lists hold the same addresses, each as often, in any order and case.
    static func sameAddresses(_ a: [String], _ b: [String]) -> Bool {
        a.map { $0.lowercased() }.sorted() == b.map { $0.lowercased() }.sorted()
    }
}

/// What Mail has under one draft window id.
public enum MailOutgoingLookup: Sendable, Equatable {
    case found(MailOutgoing)
    /// Closed, sent, or never there: no open window has this id.
    case gone
    /// More than one window answers to the id: which one is meant is unknown.
    case several
    /// Mail did not answer, or a field (an attachment) could not be read.
    case unreadable
}

/// The one send event. Only `sent` and `unclear` mean the mail may have left.
public enum MailSendDispatch: Sendable, Equatable {
    case sent
    /// The window no longer holds exactly what the card showed: not sent.
    case changed
    /// The window is gone or several answer to the id: not sent.
    case gone
    /// Mail did not answer before the send command: not sent.
    case busy
    /// Mail did not confirm the send (an error or `false` after the event went out): it may have left.
    case unclear
}

/// One mail in Sent, as the lookup reports it, for comparing in Swift. `id` is Mail's id of the message: a mail that
/// was in Sent before the send event is never the one just sent.
public struct MailSentEntry: Sendable, Equatable {
    public var id: Int
    public var sender: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public init(id: Int, sender: String, to: [String], cc: [String] = [], bcc: [String] = []) {
        self.id = id; self.sender = sender; self.to = to; self.cc = cc; self.bcc = bcc
    }
}

/// Mail for `mail_send`. The app uses `SystemIntegrations`; checks a fake. Only `send` changes anything.
public protocol MailSending: Sendable {
    /// As `AppIntegrations.insertReply`, with the id of the open draft window and the Mail process that has it.
    func insertDraft(_ draft: MailDraft) async throws -> MailDraftInsert
    /// The draft window `id` as it is now, only in the Mail process `process` (another one: `.gone`). Read only.
    func outgoing(_ id: Int, process: Int32) async throws -> MailOutgoingLookup
    /// The single mutating Apple Event: sends window `id` of Mail process `process` only while it still holds exactly
    /// `expected`. Never repeated.
    func send(_ id: Int, process: Int32, expected: MailOutgoing) async throws -> MailSendDispatch
    /// Mails in Sent with exactly this subject, sent since `since`. Read only.
    func sent(subject: String, since: Date) async throws -> [MailSentEntry]
}

extension MailSentEntry {
    /// The sent copy of `mail`: from the same address, to the same To, Cc and Bcc (any order and case, each as often).
    public func isCopy(of mail: MailOutgoing) -> Bool {
        guard let address = mail.senderAddress?.lowercased(), MailAddress.parse(sender).address?.lowercased() == address else { return false }
        return MailOutgoing.sameAddresses(to, mail.to) && MailOutgoing.sameAddresses(cc, mail.cc) && MailOutgoing.sameAddresses(bcc, mail.bcc)
    }
}

extension SystemIntegrations: MailSending {
    public func insertDraft(_ draft: MailDraft) async throws -> MailDraftInsert {
        var inserted = try await MailReplyScript.insertDraft(draft)
        inserted.mailProcess = AppleEvents.process(bundle: Integration.mail.bundleIdentifier)
        return inserted
    }
    public func outgoing(_ id: Int, process: Int32) async throws -> MailOutgoingLookup {
        // A closed or restarted Mail has no window under this id; Pippa never starts it to look.
        try await MailSendScript.outgoing(id, process: process)
    }
    public func send(_ id: Int, process: Int32, expected: MailOutgoing) async throws -> MailSendDispatch {
        try await MailSendScript.send(id, process: process, expected: expected)
    }
    public func sent(subject: String, since: Date) async throws -> [MailSentEntry] {
        guard AppleEvents.isRunning(.mail) else { throw PippaError.appNotOpen(Integration.mail.appName) }
        return try await MailSendScript.sent(subject: subject, since: since)
    }
}

/// The Apple Events for `mail_send`. Texts go in as parameters, never into the script text.
public enum MailSendScript {
    public typealias StepRunner = MailReplyScript.StepRunner

    public static func outgoing(_ id: Int, process: Int32) async throws -> MailOutgoingLookup { try await outgoing(id, runner: run(in: process)) }
    public static func send(_ id: Int, process: Int32, expected: MailOutgoing) async throws -> MailSendDispatch {
        try await send(id, expected: expected, runner: run(in: process))
    }
    public static func sent(subject: String, since: Date) async throws -> [MailSentEntry] { try await sent(subject: subject, since: since, now: Date(), runner: run) }

    public static func outgoing(_ id: Int, runner: StepRunner) async throws -> MailOutgoingLookup {
        guard let id = Int32(exactly: id) else { return .gone }
        return lookup(try await runner("readOutgoing", [.number(id)], false))
    }

    /// The handler compares the window with `expected` once more and only then sends it, in the same event.
    public static func send(_ id: Int, expected: MailOutgoing, runner: StepRunner) async throws -> MailSendDispatch {
        guard let id = Int32(exactly: id) else { return .gone }
        let response = try await runner("sendOutgoing", [.number(id), .text(expected.sender), .text(expected.subject), .text(expected.body),
                                                         .texts(expected.to), .texts(expected.cc), .texts(expected.bcc),
                                                         .texts(expected.attachments)], true)
        let status = response.first?.text ?? ""
        switch status {
        case "sent": return .sent
        // Returned before the send command: nothing left the Mac.
        case "changed":
            PippaMCPWriteLease.current?.confirmNoMutation()
            return .changed
        case "unreadable", "busy":
            PippaMCPWriteLease.current?.confirmNoMutation()
            return .busy
        case "gone", "several":
            PippaMCPWriteLease.current?.confirmNoMutation()
            return .gone
        default: return .unclear
        }
    }

    public static func sent(subject: String, since: Date, now: Date, runner: StepRunner) async throws -> [MailSentEntry] {
        // A minute of slack for Mail's own clock and rounding to seconds.
        let age = Int32(clamping: Int(max(0, now.timeIntervalSince(since)).rounded(.up)) + 60)
        let response = try await runner("findSent", [.text(subject), .number(age)], false)
        guard response.count == 2, response[0].text == "ok" else { throw PippaError.notAvailable }
        return response[1].items.compactMap { entry in
            let parts = entry.items
            guard parts.count == 5, let id = parts[0].number, let sender = parts[1].text else { return nil }
            return MailSentEntry(id: id, sender: sender, to: parts[2].items.compactMap(\.text), cc: parts[3].items.compactMap(\.text),
                                 bcc: parts[4].items.compactMap(\.text))
        }
    }

    static func lookup(_ response: [ScriptValue]) -> MailOutgoingLookup {
        switch response.first?.text {
        case "ok":
            guard response.count == 8, let sender = response[1].text, let subject = response[2].text, let body = response[3].text else { return .unreadable }
            func texts(_ value: ScriptValue) -> [String]? {
                guard case .list(let items) = value else { return nil }
                let texts = items.compactMap(\.text)
                return texts.count == items.count ? texts : nil
            }
            guard let to = texts(response[4]), let cc = texts(response[5]), let bcc = texts(response[6]), let files = texts(response[7]),
                  !(to + cc + bcc).contains(where: \.isEmpty) else { return .unreadable }
            return .found(MailOutgoing(sender: sender, subject: subject, body: body, to: to, cc: cc, bcc: bcc, attachments: files))
        case "gone": return .gone
        case "several": return .several
        default: return .unreadable
        }
    }

    private static func run(_ handler: String, _ args: [ScriptArgument], _ mutation: Bool) async throws -> [ScriptValue] {
        let result = try await AppleEvents.perform {
            ScriptValue(try AppleEvents.call(source, handler: handler, args.map(\.descriptor), app: .mail, mutation: mutation))
        }.items
        await Task.yield()
        return result
    }

    /// As `run`, only while Mail is still the process `process`, checked on the AppleScript queue right before the
    /// event: a draft window id of an earlier Mail may name another draft now. Otherwise the answer is "gone".
    private static func run(in process: Int32) -> StepRunner {
        { handler, args, mutation in
            let result = try await AppleEvents.perform {
                guard AppleEvents.process(bundle: Integration.mail.bundleIdentifier) == process else { return ScriptValue.list([.text("gone")]) }
                return ScriptValue(try AppleEvents.call(source, handler: handler, args.map(\.descriptor), app: .mail, mutation: mutation))
            }.items
            await Task.yield()
            return result
        }
    }

    static let source = """
    on findOutgoing(theID)
        set found to {}
        tell application id "com.apple.mail"
            with timeout of 15 seconds
                repeat with candidate in outgoing messages
                    if (id of candidate) is theID then set end of found to (contents of candidate)
                end repeat
            end timeout
        end tell
        return found
    end findOutgoing

    on snapshotOf(om)
        tell application id "com.apple.mail"
            with timeout of 15 seconds
                set theSender to my textOf(sender of om)
                set theSubject to my textOf(subject of om)
                set theBody to my textOf(content of om)
                set toList to {}
                repeat with r in to recipients of om
                    set end of toList to my textOf(address of r)
                end repeat
                set ccList to {}
                repeat with r in cc recipients of om
                    set end of ccList to my textOf(address of r)
                end repeat
                set bccList to {}
                repeat with r in bcc recipients of om
                    set end of bccList to my textOf(address of r)
                end repeat
                set fileNames to {}
                repeat with a in (every attachment of content of om)
                    set end of fileNames to my fileName(file name of a)
                end repeat
            end timeout
        end tell
        return {"ok", theSender, theSubject, theBody, toList, ccList, bccList, fileNames}
    end snapshotOf

    -- Mail's missing value (no sender yet, no subject) is "", never the words "missing value".
    on textOf(theValue)
        if theValue is missing value then return ""
        return theValue as text
    end textOf

    -- An attachment without a readable name makes the whole read fail: the card would not show what leaves.
    on fileName(theValue)
        if theValue is missing value then error "attachment name unreadable" number -10000
        set theName to my lastPart(theValue as text)
        if theName is "" then error "attachment name unreadable" number -10000
        return theName
    end fileName

    on lastPart(thePath)
        set AppleScript's text item delimiters to ":"
        set parts to text items of thePath
        set AppleScript's text item delimiters to ""
        repeat while (count of parts) > 1 and (last item of parts) is ""
            set parts to items 1 thru -2 of parts
        end repeat
        return (last item of parts) as text
    end lastPart

    on readOutgoing(theID)
        try
            set found to my findOutgoing(theID)
            if (count of found) is 0 then return {"gone"}
            if (count of found) is not 1 then return {"several"}
            return my snapshotOf(item 1 of found)
        on error number errNum
            if errNum is -1712 then return {"busy"}
            return {"unreadable"}
        end try
    end readOutgoing

    on sendOutgoing(theID, theSender, theSubject, theBody, toList, ccList, bccList, fileNames)
        -- Everything before the sending step only reads: a mismatch leaves the window as it is.
        try
            set found to my findOutgoing(theID)
            if (count of found) is 0 then return {"gone"}
            if (count of found) is not 1 then return {"several"}
            set om to item 1 of found
            set nowMail to my snapshotOf(om)
        on error number errNum
            if errNum is -1712 then return {"busy"}
            return {"unreadable"}
        end try
        if my differs(nowMail, theSender, theSubject, theBody, toList, ccList, bccList, fileNames) then return {"changed"}
        tell application id "com.apple.mail"
            try
                with timeout of 60 seconds
                    set didSend to send om
                end timeout
            on error
                -- After the event went out, an error cannot prove that nothing left.
                return {"uncertain"}
            end try
        end tell
        if didSend is true then return {"sent"}
        return {"uncertain"}
    end sendOutgoing

    -- Pure (no Mail): does the snapshot `nowMail` differ from what the card showed?
    on differs(nowMail, theSender, theSubject, theBody, toList, ccList, bccList, fileNames)
        considering case, diacriticals, hyphens, punctuation and white space
            if (item 2 of nowMail) is not theSender then return true
            if (item 3 of nowMail) is not theSubject then return true
            if (item 4 of nowMail) is not theBody then return true
            if (item 8 of nowMail) is not fileNames then return true
        end considering
        if not (my sameAddresses(item 5 of nowMail, toList)) then return true
        if not (my sameAddresses(item 6 of nowMail, ccList)) then return true
        if not (my sameAddresses(item 7 of nowMail, bccList)) then return true
        return false
    end differs

    -- Pure (no Mail): the same addresses, each as often, in any order and case.
    on sameAddresses(found, expected)
        if (count of found) is not (count of expected) then return false
        set remaining to {} & found
        repeat with wanted in expected
            set hit to 0
            repeat with i from 1 to (count of remaining)
                if (item i of remaining) is (contents of wanted) then
                    set hit to i
                    exit repeat
                end if
            end repeat
            if hit is 0 then return false
            if (count of remaining) is 1 then
                set remaining to {}
            else if hit is 1 then
                set remaining to items 2 thru -1 of remaining
            else if hit is (count of remaining) then
                set remaining to items 1 thru -2 of remaining
            else
                set remaining to (items 1 thru (hit - 1) of remaining) & (items (hit + 1) thru -1 of remaining)
            end if
        end repeat
        return true
    end sameAddresses

    on findSent(theSubject, ageSeconds)
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 15 seconds
                    set sinceDate to (current date) - ageSeconds
                    set found to (every message of sent mailbox whose subject is theSubject and date sent is greater than or equal to sinceDate)
                    repeat with m in found
                        set toList to {}
                        repeat with r in to recipients of m
                            set end of toList to my textOf(address of r)
                        end repeat
                        set ccList to {}
                        repeat with r in cc recipients of m
                            set end of ccList to my textOf(address of r)
                        end repeat
                        set bccList to {}
                        repeat with r in bcc recipients of m
                            set end of bccList to my textOf(address of r)
                        end repeat
                        set end of out to {(id of m) as integer, my textOf(sender of m), toList, ccList, bccList}
                    end repeat
                end timeout
            on error number errNum
                if errNum is -1712 then return {"busy"}
                return {"failed"}
            end try
        end tell
        return {"ok", out}
    end findSent
    """
}
