import Foundation

/// What a reading tool returned, as a card under the answer: built in code from Pippa's own result, never from the
/// model's text. Stored with the answer (`ActionReceipt.cards`); missing in older histories. A closed list: every card
/// has a row limit and a source line (footer), and a card that cannot be read is dropped while the answer text stays.
public enum ResultCard: Codable, Sendable, Equatable {
    case calendar(CalendarCard)
    case mail(MailCard)
}

/// Mails a search found: sender, subject, date, the start of the text; a click opens the mail in Mail.
public struct MailCard: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var subject: String
        /// The sender's name (or the address when there is no name).
        public var sender: String
        public var date: Date?
        public var dateLabel: String?
        /// One line, at most 160 characters.
        public var preview: String
        /// Message-ID without angle brackets, to open the mail; `nil` when Mail gave none.
        public var messageID: String?
    }
    public var query: String
    public var items: [Item]
    public var total: Int
    /// "Mail auf diesem Mac · 3 von 7"
    public var footer: String
    /// More rows than the search tool ever returns (mail_search allows at most 20).
    public static let maxItems = 20

    public init(query: String, mails: [MailHeader], total: Int, calendar: Calendar) {
        self.query = query
        self.total = total
        let day = DateFormatter(), time = DateFormatter()
        for f in [day, time] { f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = calendar.locale ?? .autoupdatingCurrent }
        day.setLocalizedDateFormatFromTemplate("EEEdMMM"); time.timeStyle = .short; time.dateStyle = .none
        items = mails.prefix(Self.maxItems).map { m in
            let label = m.date.map { calendar.isDateInToday($0) ? time.string(from: $0) : day.string(from: $0) }
            let one = m.preview.split(whereSeparator: \.isNewline).joined(separator: " ")
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return Item(subject: Self.line(m.subject, 120), sender: Self.line(MailCard.name(of: m.sender), 80), date: m.date, dateLabel: label,
                        preview: one.count > 160 ? String(one.prefix(159)) + "…" : one,
                        messageID: m.messageID.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }.flatMap { $0.isEmpty ? nil : $0 })
        }
        footer = total > items.count ? L("Mail on this Mac · %lld of %lld", table: "MCP", items.count, total) : L("Mail on this Mac", table: "MCP")
    }

    /// "Hausverwaltung Berger <info@berger-hv.de>" → "Hausverwaltung Berger".
    static func name(of sender: String) -> String {
        guard let open = sender.firstIndex(of: "<") else { return sender }
        let name = sender[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? String(sender[sender.index(after: open)...]).trimmingCharacters(in: CharacterSet(charactersIn: "> ")) : name
    }

    static func line(_ text: String, _ limit: Int) -> String {
        let one = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count > limit ? String(one.prefix(limit - 1)) + "…" : one
    }
}
