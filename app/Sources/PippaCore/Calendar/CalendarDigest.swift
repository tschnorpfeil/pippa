import Foundation

/// One occurrence as the calendar store reports it (EventKit already expands recurring series into occurrences).
/// Only what an answer needs: no notes, no attendees, no URLs.
public struct CalendarEvent: Sendable, Equatable {
    public enum Status: String, Sendable { case none, confirmed, tentative, cancelled }
    /// Identifier of the series or single event; together with `start` it names one occurrence.
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var calendar: String
    /// The event's own time zone identifier; `nil` for floating and all-day events.
    public var timeZone: String?
    public var status: Status
    /// The person declined this invitation.
    public var declined: Bool
    public var recurring: Bool
    public var location: String?
    /// The calendar's colour as "#RRGGBB" (for the card), `nil` when unknown.
    public var color: String?
    public init(id: String, title: String, start: Date, end: Date, allDay: Bool = false, calendar: String, timeZone: String? = nil,
                status: Status = .none, declined: Bool = false, recurring: Bool = false, location: String? = nil, color: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.calendar = calendar
        self.timeZone = timeZone; self.status = status; self.declined = declined; self.recurring = recurring; self.location = location
        self.color = color
    }
}

/// What one bounded read returned: at most `limit` occurrences (sorted by start), the total found, and every calendar that was read.
public struct CalendarFetch: Sendable, Equatable {
    public var events: [CalendarEvent]
    public var total: Int
    public var calendars: [String]
    public init(events: [CalendarEvent], total: Int, calendars: [String]) {
        self.events = events; self.total = total; self.calendars = calendars
    }
}

/// Events of a period, ordered by day; all days, times and hints computed and formatted in code
/// (time zone, first weekday and language from `Calendar`). From this come the native answer (`markdown`)
/// and the data for the agent tool (`toolPayload`), so both show the same facts.
public struct CalendarDigest: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public enum State: String, Sendable { case active, tentative, cancelled, declined }
        public var title: String
        /// "09:00–10:00", "Ganztägig" (all day), "ab 18:00" (from 18:00) …
        public var time: String
        public var allDay: Bool
        public var calendar: String
        public var state: State
        public var recurring: Bool
        /// Multi-day: "bis Fr., 10. Okt." (until) / "seit Sa., 11. Okt." (since)
        public var span: String?
        /// Different time zone than this Mac: "15:00 in New York".
        public var otherZone: String?
        public var location: String?
        public var start: Date
        public var color: String?
        public var eventID: String
    }
    public struct Day: Sendable, Equatable {
        public var date: DayDate
        public var label: String
        public var entries: [Entry]
    }
    public var range: CalendarRange
    public var title: String
    public var rangeLabel: String
    public var days: [Day]
    public var calendars: [String]
    public var total: Int
    public var readAt: Date
    public var timeZone: String
    public var readAtLabel: String

    public var entries: [Entry] { days.flatMap(\.entries) }
    public var shown: Int { entries.count }
    public var truncated: Bool { total > shown }
    public var activeCount: Int { entries.filter { $0.state == .active || $0.state == .tentative }.count }
    public var inactiveCount: Int { entries.filter { $0.state == .cancelled || $0.state == .declined }.count }

    public static func make(_ fetch: CalendarFetch, range: CalendarRange, now: Date, calendar: Calendar) -> CalendarDigest {
        let format = CalendarFormat(calendar: calendar)
        let firstDay = calendar.startOfDay(for: range.start)
        var seen = Set<String>()
        var placed: [(day: Date, entry: Entry)] = []
        for event in fetch.events.sorted(by: { ($0.start, $0.title) < ($1.start, $1.title) }) {
            // Overlap check again in code: a store may return a neighbour; a repeated occurrence is listed once.
            guard event.end > range.start || (event.end == event.start && event.start >= range.start), event.start < range.end else { continue }
            guard seen.insert(event.id + "|" + String(event.start.timeIntervalSinceReferenceDate)).inserted else { continue }
            let startDay = calendar.startOfDay(for: event.start)
            let lastDay = calendar.startOfDay(for: event.end > event.start ? event.end.addingTimeInterval(-1) : event.start)
            let day = max(startDay, firstDay)
            var entry = Entry(title: format.title(event.title), time: "", allDay: event.allDay, calendar: String(event.calendar.prefix(80)),
                              state: event.status == .cancelled ? .cancelled : event.declined ? .declined : event.status == .tentative ? .tentative : .active,
                              recurring: event.recurring, span: nil, otherZone: nil,
                              location: event.location.map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 },
                              start: event.start, color: event.color, eventID: event.id)
            if event.allDay {
                entry.time = L("All day", table: "Calendar")
                if lastDay > startDay { entry.span = L("until %@", table: "Calendar", format.shortDay.string(from: lastDay)) }
            } else if lastDay > day && startDay < day {
                entry.time = L("all day long", table: "Calendar")
                entry.span = L("%@ to %@", table: "Calendar", format.shortDayTime.string(from: event.start), format.shortDayTime.string(from: event.end))
            } else if startDay < day {
                entry.time = L("until %@", table: "Calendar", format.time.string(from: event.end))
                entry.span = L("since %@", table: "Calendar", format.shortDayTime.string(from: event.start))
            } else if lastDay > startDay {
                entry.time = L("from %@", table: "Calendar", format.time.string(from: event.start))
                entry.span = L("until %@", table: "Calendar", format.shortDayTime.string(from: event.end))
            } else if event.end > event.start {
                entry.time = format.time.string(from: event.start) + "–" + format.time.string(from: event.end)
            } else {
                entry.time = format.time.string(from: event.start)
            }
            if !event.allDay, let id = event.timeZone, let zone = TimeZone(identifier: id),
               zone.secondsFromGMT(for: event.start) != calendar.timeZone.secondsFromGMT(for: event.start) {
                let other = DateFormatter()
                other.locale = format.time.locale; other.timeZone = zone; other.timeStyle = .short; other.dateStyle = .none
                let city = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
                entry.otherZone = L("%@ in %@", table: "Calendar", other.string(from: event.start), city)
            }
            placed.append((day, entry))
        }
        // `total` counts only what is missing: filtered duplicates and neighbours do not belong to "N of M".
        // All-day first, then by start (like Calendar itself).
        let grouped = Dictionary(grouping: placed, by: \.day)
        let days = grouped.keys.sorted().map { day in
            Day(date: DayDate(day, calendar: calendar), label: format.dayLabel(day, now: now),
                entries: grouped[day]!.map(\.entry).sorted { a, b in a.allDay != b.allDay ? a.allDay : (a.start, a.title) < (b.start, b.title) })
        }
        return CalendarDigest(range: range, title: format.title(of: range, now: now), rangeLabel: format.rangeLabel(range),
                              days: days, calendars: fetch.calendars.map { String($0.prefix(80)) }, total: max(placed.count, fetch.total - (fetch.events.count - placed.count)),
                              readAt: now, timeZone: calendar.timeZone.identifier, readAtLabel: format.time.string(from: now))
    }

    /// The native answer: short, grouped by day, with the exact period and the source.
    public var markdown: String {
        var lines: [String] = []
        if range.kind == .day {
            lines.append("**\(title)**")
        } else {
            lines.append("**\(title)** · \(rangeLabel)")
        }
        if calendars.isEmpty {
            lines.append(L("I didn’t find a calendar on this Mac that I can read.", table: "Calendar"))
        } else if days.isEmpty {
            lines.append(CalendarReadResult.emptyText)
        } else {
            var counts = L("Appointments: %lld", table: "Calendar", activeCount)
            if inactiveCount > 0 { counts += " · " + L("Cancelled or declined: %lld", table: "Calendar", inactiveCount) }
            lines.append(counts)
            let showsCalendar = Set(entries.map(\.calendar)).count > 1
            for day in days {
                if range.kind != .day { lines.append(""); lines.append("**\(day.label)**") }
                for entry in day.entries { lines.append("- " + line(entry, showsCalendar: showsCalendar)) }
            }
            if truncated {
                lines.append("")
                lines.append(L("Showing the first %lld of %lld appointments. Ask about a shorter period for the rest.", table: "Calendar", shown, total))
            }
        }
        lines.append("")
        lines.append("_" + sourceLine + "_")
        return lines.joined(separator: "\n")
    }

    /// "Quelle: Kalender auf diesem Mac · Arbeit, Privat · gelesen um 14:32" (source: Calendar on this Mac · calendars · read at time)
    public var sourceLine: String {
        let names = calendars.isEmpty ? L("no calendars", table: "Calendar")
            : calendars.count <= 3 ? calendars.map(CalendarFormat.escaped).joined(separator: ", ") : L("Calendars: %lld", table: "Calendar", calendars.count)
        return L("Source: Calendar on this Mac · %@ · read at %@", table: "Calendar", names, readAtLabel)
    }

    private func line(_ entry: Entry, showsCalendar: Bool) -> String {
        var text = entry.time + " · " + CalendarFormat.escaped(entry.title)
        var notes: [String] = []
        if let span = entry.span { notes.append(span) }
        if let zone = entry.otherZone { notes.append(zone) }
        switch entry.state {
        case .cancelled: notes.append(L("cancelled", table: "Calendar"))
        case .declined: notes.append(L("declined", table: "Calendar"))
        case .tentative: notes.append(L("tentative", table: "Calendar"))
        case .active: break
        }
        if showsCalendar { text += " · " + CalendarFormat.escaped(entry.calendar) }
        if !notes.isEmpty { text += " (" + notes.joined(separator: "; ") + ")" }
        return text
    }

    /// For `read_calendar`: the same facts as the native answer, already formatted, plus ISO dates.
    public func toolPayload() -> [String: Any] {
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX"); iso.timeZone = TimeZone(identifier: timeZone); iso.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return [
            "source": "Calendar on this Mac",
            "range": ["title": title, "label": rangeLabel, "start": iso.string(from: range.start), "end": iso.string(from: range.end), "timeZone": timeZone],
            "calendars": Array(calendars.prefix(30)),
            "count": activeCount, "shown": shown, "total": total, "truncated": truncated,
            "days": days.map { day -> [String: Any] in
                ["date": day.date.iso, "label": day.label, "events": day.entries.map { entry -> [String: Any] in
                    var value: [String: Any] = ["time": entry.time, "title": entry.title, "calendar": entry.calendar, "state": entry.state.rawValue,
                                                "allDay": entry.allDay, "recurring": entry.recurring]
                    if let span = entry.span { value["span"] = span }
                    if let zone = entry.otherZone { value["otherZone"] = zone }
                    if let location = entry.location { value["location"] = location }
                    return value
                }]
            },
        ]
    }
}

/// Formatting in code, in the language and time zone of the `Calendar` (tests fix both).
struct CalendarFormat {
    let calendar: Calendar
    let longDay: DateFormatter, shortDay: DateFormatter, shortDayTime: DateFormatter, time: DateFormatter

    init(calendar: Calendar) {
        self.calendar = calendar
        func make(_ template: String?) -> DateFormatter {
            let f = DateFormatter()
            f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = calendar.locale ?? .autoupdatingCurrent
            if let template { f.setLocalizedDateFormatFromTemplate(template) } else { f.timeStyle = .short; f.dateStyle = .none }
            return f
        }
        longDay = make("EEEEdMMMM"); shortDay = make("EEEdMMM"); shortDayTime = make("EEEdMMMjmm"); time = make(nil)
    }

    /// "Heute, Dienstag, 7. Oktober" (Today, Tuesday, 7 October)
    func dayLabel(_ day: Date, now: Date) -> String {
        let text = longDay.string(from: day)
        if calendar.isDate(day, inSameDayAs: now) { return L("Today, %@", table: "Calendar", text) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)), calendar.isDate(day, inSameDayAs: tomorrow) {
            return L("Tomorrow, %@", table: "Calendar", text)
        }
        return text
    }

    /// The exact period: „Di., 7. Okt., 14:32 – So., 12. Okt.“
    func rangeLabel(_ range: CalendarRange) -> String {
        let startsAtMidnight = calendar.startOfDay(for: range.start) == range.start
        let start = startsAtMidnight ? shortDay.string(from: range.start) : shortDayTime.string(from: range.start)
        if calendar.isDate(range.start, inSameDayAs: range.lastMoment) {
            return startsAtMidnight ? longDay.string(from: range.start) : L("%@ until the end of the day", table: "Calendar", start)
        }
        return L("%@ – %@", table: "Calendar", start, shortDay.string(from: range.lastMoment))
    }

    func title(of range: CalendarRange, now: Date) -> String {
        switch range.kind {
        case .restOfWeek: L("This week, from now", table: "Calendar")
        case .nextWeek: L("Next week", table: "Calendar")
        case .lastWeek: L("Last week", table: "Calendar")
        case .weekend: L("Weekend", table: "Calendar")
        case .day: dayLabel(range.start, now: now)
        case .days: L("Your appointments", table: "Calendar")
        case .nextDays: L("Until %@", table: "Calendar", shortDay.string(from: range.lastMoment))
        }
    }

    /// Titles from the calendar are foreign text: one line, limited. Markdown characters are defused only by `markdown`.
    func title(_ raw: String) -> String {
        let line = raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? L("(No title)", table: "Calendar") : String(line.prefix(120))
    }

    static func escaped(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\*_`[]#~<>|".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
