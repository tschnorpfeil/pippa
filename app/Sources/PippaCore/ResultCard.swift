import Foundation

/// What a reading tool returned, as a card under the answer: built in code from Pippa's own result, never from the
/// model's text. Stored with the answer (`ActionReceipt.cards`); missing in older histories. A closed list: every card
/// has a row limit and a source line (footer), and a card that cannot be read is dropped while the answer text stays.
public enum ResultCard: Codable, Sendable, Equatable {
    case calendar(CalendarCard)
    case mail(MailCard)
    case photos(PhotoCard)
    case reminders(ReminderCard)
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

/// Open reminders: title, due date (overdue marked), list; a click brings Reminders forward. Read only: ticking off
/// stays in Reminders.
public struct ReminderCard: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var title: String
        public var list: String
        /// "Heute, 14:00", "Morgen", "Mo., 12. Okt."; `nil` without a due date.
        public var dueLabel: String?
        public var overdue: Bool
    }
    /// "Erinnerungen · heute fällig"
    public var title: String
    public var items: [Item]
    public var total: Int
    /// The list name per row only when the reminders come from several lists.
    public var showsList: Bool
    /// "Erinnerungen auf diesem Mac · 12 von 40"
    public var footer: String
    public static let maxItems = 40

    /// `days`: as asked (`nil`: all open ones, 1: due today).
    public init(days: Int?, reminders: [ReminderItem], total: Int, now: Date, calendar: Calendar) {
        title = switch days {
        case nil: L("Reminders · open", table: "MCP")
        case 1?: L("Reminders · due today", table: "MCP")
        case let days?: L("Reminders · due in the next %lld days", table: "MCP", days)
        }
        self.total = total
        let relative = DateFormatter(), day = DateFormatter(), dayTime = DateFormatter()
        for f in [relative, day, dayTime] { f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = calendar.locale ?? .autoupdatingCurrent }
        relative.dateStyle = .medium; relative.doesRelativeDateFormatting = true
        day.setLocalizedDateFormatFromTemplate("EEEdMMM"); dayTime.setLocalizedDateFormatFromTemplate("EEEdMMMjmm")
        let near = { (d: Date) in calendar.isDateInToday(d) || calendar.isDateInTomorrow(d) || calendar.isDateInYesterday(d) }
        items = reminders.prefix(Self.maxItems).map { r in
            let label = r.due.map { due -> String in
                if near(due) {
                    relative.timeStyle = r.dueHasTime ? .short : .none
                    return relative.string(from: due)
                }
                return (r.dueHasTime ? dayTime : day).string(from: due)
            }
            let overdue = r.due.map { $0 < (r.dueHasTime ? now : calendar.startOfDay(for: now)) } ?? false
            return Item(title: MailCard.line(r.title, 120), list: MailCard.line(r.list, 40), dueLabel: label, overdue: overdue)
        }
        showsList = Set(items.map(\.list)).count > 1
        footer = total > items.count ? L("Reminders on this Mac · %lld of %lld", table: "MCP", items.count, total)
            : L("Reminders on this Mac", table: "MCP")
    }
}
