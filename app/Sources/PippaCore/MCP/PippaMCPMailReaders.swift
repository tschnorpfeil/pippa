import Foundation

extension PippaMCPTools {
    // MARK: Mail

    func mailSelected() async -> PippaMCPToolResult {
        if case .blocked(let reply) = await ensure(.mail) { return reply }
        do {
            guard let mail = try await host.integrations.selectedMail() else {
                return blocked("nothing_selected", L("No email is selected in Mail. Select one and ask again.", table: "MCP"))
            }
            return mailResult(mail, source: "Mail on this Mac (selected email)")
        } catch {
            return failure(error, .mail)
        }
    }

    func mailRead(_ input: ToolInput) async -> PippaMCPToolResult {
        let subject = (input.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...300).contains(subject.count) else { return invalid("subject must be the exact subject from mail_search.") }
        let sender = Self.address(input.from ?? "")
        if case .blocked(let reply) = await ensure(.mail, openMail: true,
                                                   closed: L("Open %@ first. Then ask again.", table: "MCP", Integration.mail.appName)) {
            return reply
        }
        do {
            guard let mail = try await host.integrations.findMail(subject: subject, sender: sender) else {
                return blocked("not_found", L("I couldn’t find this email in the inbox.", table: "MCP"))
            }
            return mailResult(mail, source: "Mail on this Mac (email from the inbox)")
        } catch {
            return failure(error, .mail)
        }
    }

    /// "Frank Semmler <frank@firma.de>" → "frank@firma.de"; a bare name or address stays as it is.
    static func address(_ from: String) -> String {
        let text = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close else { return text }
        return String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    }

    /// One mail for the model: text, identity for a reply draft, and its attachments saved as files (`MailFiling`), so
    /// read_document can read them. Without Mail's original message only the attachment names are known.
    private func mailResult(_ mail: MailMessage, source: String) -> PippaMCPToolResult {
        let limit = 6000
        let body = Self.compact(mail.body)
        var data: [String: Any] = ["subject": mail.subject, "from": mail.sender, "body": String(body.prefix(limit)),
                                   "bodyTruncated": body.count > limit]
        if let date = mail.date { data["date"] = Self.dateLabel(date, time: true, calendar: host.calendar) }
        // Identity for "Als Entwurf in Mail" (reply to exactly this mail, found via the Message-ID).
        if let source = mail.replySource {
            data["messageID"] = source.messageID
            if let replyTo = source.replyTo { data["replyTo"] = replyTo }
        }
        var next = "Use only what the email says. Never send mail; replies are drafts. "
        let files = mail.source == nil ? [] : ((try? MailFiling.file(mail, root: host.mailFiles))?.attachments ?? [])
        if !files.isEmpty {
            data["attachments"] = files.prefix(20).map { ["name": $0.lastPathComponent, "path": $0.path] }
            next += "Its attachments are saved as files: read one with mcp__pippa__read_document and its path. "
        } else if !mail.attachmentNames.isEmpty {
            data["attachments"] = Array(mail.attachmentNames.prefix(20))
        }
        return Self.bounded(source: source, data: data, next: next + Self.mailAppointmentHint)
    }

    func mailSearch(_ input: ToolInput) async -> PippaMCPToolResult {
        let query = (input.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // No query: the newest mails ("Habe ich neue Mails?"), not a made-up search word.
        guard query.isEmpty || (2...100).contains(query.count) else { return invalid("query must be 2 to 100 characters, or omitted for the newest mails.") }
        let unread = input.unread ?? false
        let limit = input.limit ?? 10
        guard (1...20).contains(limit) else { return invalid("limit must be 1 to 20.") }
        if case .blocked(let reply) = await ensure(.mail, openMail: true,
                                                   closed: L("Open %@ first. Then ask again.", table: "MCP", Integration.mail.appName)) {
            return reply
        }
        do {
            var fetch = try await host.hostData.searchMail(query, unread: unread, limit: limit)
            // Mail finds parts of words, not other forms: "Zahlungseingänge" misses "Zahlungseingangsliste". A small
            // model then guesses word after word; one retry with the singular saves those turns.
            var searched = query
            if fetch.items.isEmpty, let singular = Self.mailSingular(query) {
                let retry = try await host.hostData.searchMail(singular, unread: unread, limit: limit)
                if !retry.items.isEmpty { fetch = retry; searched = singular }
            }
            let query = searched
            let mails = fetch.items.map { m -> [String: Any] in
                var value: [String: Any] = ["subject": m.subject, "from": m.sender, "mailbox": m.mailbox, "start": Self.compact(m.preview),
                                            "unread": m.unread]
                if let date = m.date { value["date"] = Self.dateLabel(date, time: true, calendar: host.calendar) }
                return value
            }
            var next = "If mails is not empty, the person sees them as a card under your answer: do not list them again; answer in one or two sentences. start is only the beginning of each email; for the whole email or its attachments call mail_read with its subject and from. If mails is empty, no email in the inbox matches."
            // A small model asked for "the last three" when there are two keeps searching until time runs out.
            if let count = await host.turns.active?.countMailSearch(), count >= Self.mailSearchesBeforeStop {
                next = "This is Mail search \(count) in this answer: stop searching. Tell the person which mails you found and that you found no others, then work with those."
            }
            var result = Self.bounded(source: query.isEmpty ? "Mail on this Mac (newest in the inbox)" : "Mail on this Mac (inbox search by subject or sender)",
                                      data: ["query": query, "unread": unread, "mails": mails, "shown": mails.count, "total": fetch.total,
                                             "truncated": fetch.total > mails.count],
                                      next: next)
            if !fetch.items.isEmpty {
                result.card = .mail(MailCard(query: query, unread: unread, mails: fetch.items, total: fetch.total, calendar: host.calendar))
            }
            return result
        } catch {
            return failure(error, .mail)
        }
    }

    /// From this Mail search on in one answer, the result tells the model to stop and work with what it found.
    static let mailSearchesBeforeStop = 4

    /// A German plural as a stem Mail's search finds: "Zahlungseingänge" → "Zahlungseingang", "Rechnungen" → "Rechnung",
    /// "Verträge" → "Vertrag". One word only; `nil` when nothing changes.
    public static func mailSingular(_ word: String) -> String? {
        guard !word.contains(where: \.isWhitespace), word.count >= 5 else { return nil }
        var w = word
        let vowels: [Character: Character] = ["ä": "a", "ö": "o", "ü": "u", "Ä": "A", "Ö": "O", "Ü": "U"]
        if let i = w.indices.suffix(4).last(where: { vowels[w[$0]] != nil }) { w.replaceSubrange(i...i, with: String(vowels[w[i]]!)) }
        for ending in ["en", "er", "es", "e", "n", "s"] where w.lowercased().hasSuffix(ending) && w.count - ending.count >= 4 {
            w.removeLast(ending.count)
            break
        }
        return w == word ? nil : w
    }
}
