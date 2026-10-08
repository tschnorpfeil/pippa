import Foundation

// Gemma often wrote the reply to a shown mail only into the text and once claimed "draft created" without calling
// `mail_draft`. Pippa makes that visible and fixable without a model:
//
// - If the answer has a shown mail (.eml) or a read selected mail, contains a reply text and there is no mail draft
//   from code (receipt `mailDraft` done or unclear), below the answer it says "No draft in Mail yet" with the button
//   "Save as draft in Mail". The button creates the draft via the same path as `mail_draft`
//   (`PippaMCPWriteTools`, same states and receipt).
// - If the answer claims a draft without a receipt, the line "No draft in Mail yet" appears even without a button: the
//   claim never stands alone.

/// An offer below an answer: this text as a reply draft to this mail.
public struct MailDraftOffer: Codable, Sendable, Equatable {
    public var id: UUID
    /// The mail the answer was about, recorded when answering: message ID from the shown .eml or from
    /// Pippa's `mail_selected` result. The click looks up exactly this mail (never the selection at click time). `nil` (older
    /// histories): no button.
    public var source: MailReplySource?
    public var body: String
    /// Already clicked (button gone; free again after "didn't work").
    public var used: Bool
    /// At click time the mail was no longer in Mail: instead of "Save as draft in Mail" there is "Copy text".
    public var missing: Bool?

    public init(id: UUID = UUID(), source: MailReplySource?, body: String, used: Bool = false, missing: Bool = false) {
        self.id = id; self.source = source; self.body = body; self.used = used; self.missing = missing ? true : nil
    }

    /// The "Save as draft in Mail" button is shown.
    public var canSave: Bool { source != nil && !used && missing != true }
    /// Instead "Copy text" (the mail is no longer in Mail).
    public var canCopy: Bool { missing == true }
}

/// Extract the reply text from a model answer and detect claims: simple, fixed rules, no model.
public enum MailReplyText {
    static let salutation = #"^(guten (tag|morgen|abend)|hallo|hi|liebe|lieber|sehr geehrte|sehr geehrter|moin|servus|dear|hello)\b"#
    static let closing = #"^(mit freundlichen grüßen|freundliche grüße|viele grüße|liebe grüße|beste grüße|herzliche grüße|schöne grüße|gruß|grüße|best regards|kind regards|regards|best|cheers|sincerely)\b"#
    static let followUp = #"^(soll ich|möchtest du|willst du|sag mir|shall i|should i|do you want|would you like|let me know)\b"#
    static let claim = #"(entwurf|antwort)[^.!?\n]{0,60}\b(erstellt|angelegt|gespeichert|abgelegt|vorbereitet)|(draft|reply)[^.!?\n]{0,60}\b(created|saved|prepared)\b|(erstellt|angelegt|gespeichert)[^.!?\n]{0,40}\b(entwurf)|(created|saved|prepared)[^.!?\n]{0,40}\bdraft"#

    /// Does the text claim there is a draft? ("Ich habe einen Entwurf … erstellt", "als Entwurf gespeichert".)
    public static func claimsDraft(_ answer: String) -> Bool {
        answer.range(of: claim, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The reply text: 1. a block in quotation marks (≥ 40 characters), 2. from a salutation to the closing (and at most
    /// one short name line), otherwise up to before a follow-up question, 3. lines with ">". Unclear (none of these): with `fallback`
    /// the whole answer without an introductory sentence, otherwise `nil`.
    public static func extract(_ answer: String, fallback: Bool = false) -> String? {
        let text = answer.replacingOccurrences(of: "\r\n", with: "\n")
        if let quoted = quotedBlock(text) { return clean(quoted) }
        let lines = text.components(separatedBy: "\n")
        func plain(_ line: String) -> String {
            line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ">*_\"„“”")))
        }
        func matches(_ line: String, _ pattern: String) -> Bool {
            plain(line).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if let start = lines.firstIndex(where: { matches($0, salutation) }) {
            var end = lines.count
            if let close = lines[(start + 1)...].firstIndex(where: { matches($0, closing) }) {
                end = close + 1
                if end < lines.count, case let name = plain(lines[end]), !name.isEmpty, name.count <= 40, !matches(lines[end], followUp) { end += 1 }
            } else if let ask = lines[(start + 1)...].firstIndex(where: { matches($0, followUp) }) {
                end = ask
            }
            let body = clean(lines[start..<end].joined(separator: "\n"))
            if body.count >= 20 { return body }
        }
        let quotedLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        if quotedLines.count >= 2 { return clean(quotedLines.joined(separator: "\n")) }
        guard fallback else { return nil }
        // Unclear: everything except an introductory line that ends with ":" or talks about the draft.
        var rest = lines
        if let first = rest.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           first.hasSuffix(":") || claimsDraft(first) || first.range(of: #"(entwurf|antwort|draft|reply)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            rest = Array(rest.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.dropFirst())
        }
        let body = clean(rest.joined(separator: "\n"))
        return body.count >= 20 ? body : nil
    }

    /// Largest block between opening and closing quotation mark with a line break or ≥ 80 characters.
    static func quotedBlock(_ text: String) -> String? {
        let opens: Set<Character> = ["„", "“", "\""], closes: Set<Character> = ["“", "”", "\""]
        var best: String?
        var index = text.startIndex
        while let open = text[index...].firstIndex(where: { opens.contains($0) }) {
            let after = text.index(after: open)
            guard let close = text[after...].firstIndex(where: { closes.contains($0) }) else { break }
            let inner = String(text[after..<close])
            if inner.count >= 40, inner.contains("\n") || inner.count >= 80, inner.count > (best?.count ?? 0) { best = inner }
            index = text.index(after: close)
        }
        return best
    }

    /// Markdown bold and quote marks removed, blank lines collapsed, edges trimmed.
    static func clean(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "„“”\"")))
    }
}

/// The rule below an answer on the Pi RPC path (from code, not from the model's text).
public enum MailDraftOfferRule {
    /// `mailSource`: identity of the mail the answer was about (shown .eml or `mail_selected` of this answer); `nil`: none
    /// (or without message ID: then there is no offer, a reply in the history would not be safe).
    /// `items`: this answer's receipt. Result: the line "No draft in Mail yet" (or `nil`) and the offer.
    public static func evaluate(answer: String, mailSource: MailReplySource?, items: [ActionReceipt.Item]) -> (line: ActionReceipt.Item?, offer: MailDraftOffer?) {
        let drafted = items.contains { $0.action == "mailDraft" && ($0.outcome == "done" || $0.outcome == "unclear") }
        guard !drafted else { return (nil, nil) }
        let claims = MailReplyText.claimsDraft(answer)
        let offer = mailSource.flatMap { source in MailReplyText.extract(answer, fallback: claims).map { MailDraftOffer(source: source, body: $0) } }
        guard claims || offer != nil else { return (nil, nil) }
        return (ActionReceipt.Item(action: "mailDraft", outcome: "notYet"), offer)
    }

    /// Receipt for the click: from Pippa's own result of `mail_draft` (same states as the tool).
    public static func item(from result: PippaMCPToolResult) -> ActionReceipt.Item {
        guard let r = result.receipt else {
            return ActionReceipt.Item(action: "mailDraft", outcome: "failed", name: L("reply", table: "MCP"), reason: "invalid")
        }
        return ActionReceipt.Item(action: r.action, outcome: r.outcome, name: r.name, restorable: false, reason: r.reason)
    }

    /// The shown mail of an answer: the intended one first, otherwise the first .eml/.emlx with a message ID.
    public static func shownMail(files: [URL], focused: [URL]) -> MailReplySource? {
        let mails = { (urls: [URL]) in urls.filter { ["eml", "emlx"].contains($0.pathExtension.lowercased()) } }
        return (mails(focused) + mails(files)).lazy.compactMap(MailReplySource.capture(from:)).first
    }

    /// Click on "Save as draft in Mail": exactly the offer's mail via its message ID (PippaMCPWriteTools.replyDraft).
    /// `missing`: the mail is no longer in Mail (then the line offers "Copy text").
    public static func save(_ offer: MailDraftOffer, with tools: PippaMCPWriteTools) async -> (item: ActionReceipt.Item, missing: Bool) {
        guard let source = offer.source else {
            return (ActionReceipt.Item(action: "mailDraft", outcome: "failed", name: L("reply", table: "MCP"), reason: "invalid"), false)
        }
        let item = item(from: await tools.replyDraft(to: source, body: offer.body))
        return (item, item.outcome == "failed" && item.reason == "not_found")
    }
}
