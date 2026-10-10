import Foundation

/// A calendar answer as a card in the conversation: days with their appointments, each with the calendar's colour and
/// the way into Calendar. Built in code from the digest (same facts as `CalendarDigest.markdown`, which stays the text for
/// copying, VoiceOver and the conversation history). Stored with the message; missing in older histories.
public struct CalendarCard: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var time: String
        public var title: String
        public var calendar: String
        /// The calendar's colour as "#RRGGBB"; `nil` when the store gave none.
        public var color: String?
        /// Cancelled or declined: shown struck through.
        public var inactive: Bool
        /// Quiet second part: span, other time zone, "tentative", "cancelled" …
        public var note: String?
        public var location: String?
        /// The store's identifier, to open the appointment in Calendar.
        public var eventID: String
        public var start: Date
    }
    public struct Day: Codable, Sendable, Equatable {
        public var label: String
        public var entries: [Entry]
    }

    public var title: String
    /// The exact period under the title; `nil` for a single day (the title says it).
    public var rangeLabel: String?
    public var days: [Day]
    /// Several calendars appear: each row names its calendar.
    public var showsCalendar: Bool
    /// "Kalender auf diesem Mac · gelesen um 13:26": quiet footer.
    public var footer: String
    /// Instead of days: nothing found, or no readable calendar.
    public var emptyText: String?
    /// More appointments than shown.
    public var truncatedNote: String?
}

extension CalendarDigest {
    public var card: CalendarCard {
        let showsCalendar = Set(entries.map(\.calendar)).count > 1
        let days = days.map { day in
            CalendarCard.Day(label: day.label, entries: day.entries.map { entry in
                var notes: [String] = []
                if let span = entry.span { notes.append(span) }
                if let zone = entry.otherZone { notes.append(zone) }
                switch entry.state {
                case .cancelled: notes.append(L("cancelled", table: "Calendar"))
                case .declined: notes.append(L("declined", table: "Calendar"))
                case .tentative: notes.append(L("tentative", table: "Calendar"))
                case .active: break
                }
                return CalendarCard.Entry(time: entry.time, title: entry.title, calendar: entry.calendar, color: entry.color,
                                          inactive: entry.state == .cancelled || entry.state == .declined,
                                          note: notes.isEmpty ? nil : notes.joined(separator: " · "), location: entry.location,
                                          eventID: entry.eventID, start: entry.start)
            })
        }
        let empty: String? = calendars.isEmpty ? L("I didn’t find a calendar on this Mac that I can read.", table: "Calendar")
            : days.isEmpty ? CalendarReadResult.emptyText : nil
        return CalendarCard(title: title, rangeLabel: range.kind == .day ? nil : rangeLabel, days: days, showsCalendar: showsCalendar,
                            footer: L("Calendar on this Mac · read at %@", table: "Calendar", readAtLabel), emptyText: empty,
                            truncatedNote: truncated ? L("Showing the first %lld of %lld appointments. Ask about a shorter period for the rest.",
                                                         table: "Calendar", shown, total) : nil)
    }
}
