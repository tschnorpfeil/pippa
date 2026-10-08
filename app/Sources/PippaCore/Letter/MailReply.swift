import Foundation

// Insert into Mail: Pippa only creates an unsent reply window. Nothing is ever sent;
// that stays with the person. The Apple Events for this live in SystemIntegrations.swift (`MailReplyScript`).

/// What goes into the reply. Built in code from the read mail and the draft.
public struct MailDraft: Sendable, Equatable {
    /// Captured RFC Message-ID. The original is resolved independently of Mail selection.
    public var messageID: String?
    /// Sender's address.
    public var to: String?
    public var toName: String?
    /// Subject of the original mail.
    public var subject: String
    public var body: String
    /// False for an explicitly composed new message; never reads the selected mail.
    public var exactSubject: Bool
    public var isReply: Bool
    /// Where Mail showed the original at Call time. Only a hint for the fast path: the script re-checks the
    /// Message-ID of the message it finds there and falls back to a bounded search when it does not match.
    public var locator: MailLocator?

    public init(messageID: String?, to: String?, toName: String?, subject: String, body: String, isReply: Bool = true,
                exactSubject: Bool = false, locator: MailLocator? = nil) {
        self.messageID = messageID; self.to = to; self.toName = toName; self.subject = subject; self.body = body
        self.isReply = isReply; self.exactSubject = exactSubject; self.locator = locator
    }

    /// "Re: <subject>", unless the subject already starts with Re:/AW:/WG:/Fwd: (case-insensitive).
    public var replySubject: String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isReply || exactSubject { return subject }
        if trimmed.isEmpty { return "Re:" }
        let lower = trimmed.lowercased()
        let prefixes = ["re:", "aw:", "wg:", "fwd:"]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return trimmed }
        return "Re: " + trimmed
    }

    /// Is the complete draft in the content read back from the reply? (Setting the content of a reply
    /// is unreliable, hence the read-back.) Compared via `GermanText.normalize`,
    /// because Mail wraps lines and may change quotation marks.
    public func isConfirmed(byReadback readback: String) -> Bool {
        let expected = GermanText.normalize(body)
        guard !expected.isEmpty else { return false }
        return GermanText.normalize(readback).contains(expected)
    }

    /// Check all user-approved fields before reporting that a new compose window opened.
    public func isConfirmed(subject: String, body: String, recipients: [String]) -> Bool {
        isConfirmedEnvelope(subject: subject, recipients: recipients) && isConfirmed(byReadback: body)
    }

    /// Subject and recipients as Mail reports them, without the body.
    public func isConfirmedEnvelope(subject: String, recipients: [String]) -> Bool {
        let expectedRecipients = to.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        return subject == replySubject && recipients.count == expectedRecipients.count
            && zip(recipients, expectedRecipients).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    /// Maps what the reply script reported to an outcome. Only a body Mail reads back, in a reply Mail saved
    /// (saving is what makes the open window show it), counts as inserted. Otherwise the threaded reply is open
    /// but its text unconfirmed: `.replyNeedsPaste`, never a confirmation.
    public func replyOutcome(status: String, subject: String, body: String, recipients: [String], saved: Bool) throws -> MailInsertResult {
        switch status {
        case "reply":
            guard isConfirmedEnvelope(subject: subject, recipients: recipients) else { throw MailReplyFailure.unconfirmed }
            return saved && isConfirmed(byReadback: body) ? .reply : .replyNeedsPaste
        case "missing": throw MailReplyFailure.missingOriginal
        // Mail answered before the reply existed (or not at all while looking it up): nothing is in Mail.
        case "failed", "busy": throw MailReplyFailure.notCreated
        // "shown": a reply window is open with unknown recipients; "uncertain": Mail may still open one.
        default: throw MailReplyFailure.unconfirmed
        }
    }
}

/// Native reply, or an explicitly requested new compose (never a reply fallback).
/// `replyNeedsPaste`: the threaded reply is open in Mail, but Mail did not report the text in it.
/// The person pastes the draft (Pippa puts it on the clipboard); this is never shown as confirmed.
public enum MailInsertResult: String, Sendable, Equatable { case reply, replyNeedsPaste, newMessage }

/// Where a message lives in Mail: account name ("" for On My Mac), mailbox names from the top, Mail's own id.
/// Captured at Call; used only to find the same message again quickly, always re-checked by Message-ID.
public struct MailLocator: Codable, Hashable, Sendable {
    public var account: String
    public var path: [String]
    public var mailID: Int?

    public init?(account: String, path: [String], mailID: Int?) {
        guard !path.isEmpty, path.count <= 32, !path.contains(where: { $0.isEmpty }),
              mailID.map({ $0 > 0 && $0 <= Int(Int32.max) }) ?? true else { return nil }
        self.account = account; self.path = path; self.mailID = mailID
    }

    var mailbox: MailLocator { MailLocator(account: account, path: path, mailID: nil) ?? self }
}

/// Searching Mail for the original, step by step. Plain decisions, testable without Mail.
public enum MailOriginalSearch {
    /// Whole fallback search; each step also has its own Apple Event timeout in the script.
    public static let budget: Duration = .seconds(90)

    /// Each mailbox once: the captured mailbox, its account, then On My Mac (answers fast even while accounts
    /// sync), then the other accounts in Mail's order.
    public static func ordered(_ boxes: [MailLocator], preferring hint: MailLocator?) -> [MailLocator] {
        var seen = Set<MailLocator>()
        let unique = boxes.map(\.mailbox).filter { seen.insert($0).inserted }
        func rank(_ box: MailLocator) -> Int {
            if let hint, box == hint.mailbox { return 0 }
            if let hint, box.account == hint.account { return 1 }
            return box.account.isEmpty ? 2 : 3
        }
        return unique.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// One exact match is the original. None: missing (or unknown if some mailboxes did not answer).
    /// Several distinct messages with this Message-ID: ambiguous, nothing is opened.
    /// Mail's `id` names one stored message, so a mailbox listed twice cannot make a match ambiguous.
    public static func decide(_ matches: [MailLocator], incomplete: Bool) throws -> MailLocator {
        var seen = Set<Int>()
        let unique = matches.filter { $0.mailID.map { seen.insert($0).inserted } ?? false }
        if unique.count > 1 { throw MailReplyFailure.ambiguousOriginal }
        guard let match = unique.first else { throw incomplete ? MailReplyFailure.searchIncomplete : MailReplyFailure.missingOriginal }
        return match
    }

    /// Progress of the fallback search (mailboxes done, total) for the waiting UI. Set by the caller with `withValue`.
    @TaskLocal public static var progress: (@Sendable (Int, Int) -> Void)?
}

public enum MailAddress {
    static let addressPattern = #"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$"#

    static func isAddress(_ s: String) -> Bool {
        s.range(of: addressPattern, options: .regularExpression) != nil
    }

    /// "Finanzamt München <poststelle@fa.bayern.de>" → ("Finanzamt München", "poststelle@fa.bayern.de");
    /// address only → (nil, address); without "@" → (name or nil, nil). Invalid addresses become nil.
    public static func parse(_ sender: String) -> (name: String?, address: String?) {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes = CharacterSet(charactersIn: "\"'“”„").union(.whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let inner = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            let rawName = String(trimmed[..<open]).trimmingCharacters(in: quotes)
            let address: String? = isAddress(inner) ? inner : nil
            let unusable = rawName.isEmpty || rawName.contains("@")
            let name: String? = unusable ? nil : rawName
            return (name, address)
        }
        if trimmed.contains("@") {
            return (nil, isAddress(trimmed) ? trimmed : nil)
        }
        let name = trimmed.trimmingCharacters(in: quotes)
        return (name.isEmpty ? nil : name, nil)
    }
}
