import Foundation

// "Kalender lesen": which time span is read is always decided by code.
// Neither the person's words nor the model compute dates; both only name a kind of period.

/// A period of the person's calendar, half-open `[start, end)` in the given `Calendar` (its time zone and first weekday).
public struct CalendarRange: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// From now until the end of the local week (`Calendar.firstWeekday`): „anstehend diese Woche“.
        case restOfWeek = "rest_of_week"
        case nextWeek = "next_week"
        case lastWeek = "last_week"
        case weekend
        case day
        case days
        /// From now through the end of the N-th day (today counts as the first).
        case nextDays = "next_days"
    }
    public var kind: Kind
    public var start: Date
    public var end: Date
    public init(kind: Kind, start: Date, end: Date) {
        self.kind = kind; self.start = start; self.end = end
    }

    /// Longest period read at once, in days.
    public static let maxDays = 31

    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }

    /// From `now` until the end of the local week.
    public static func restOfWeek(now: Date, calendar: Calendar) -> CalendarRange? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        return CalendarRange(kind: .restOfWeek, start: now, end: week.end)
    }

    /// The whole following local week.
    public static func nextWeek(now: Date, calendar: Calendar) -> CalendarRange? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let next = calendar.dateInterval(of: .weekOfYear, for: week.end) else { return nil }
        return CalendarRange(kind: .nextWeek, start: next.start, end: next.end)
    }

    /// The whole previous local week.
    public static func lastWeek(now: Date, calendar: Calendar) -> CalendarRange? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let last = calendar.dateInterval(of: .weekOfYear, for: week.start.addingTimeInterval(-1)) else { return nil }
        return CalendarRange(kind: .lastWeek, start: last.start, end: last.end)
    }

    /// One whole local day (DST-safe: the next start of day, not +24 h).
    public static func day(_ date: Date, calendar: Calendar) -> CalendarRange? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return CalendarRange(kind: .day, start: start, end: end)
    }

    /// Whole days `first...last`, at most `maxDays`.
    public static func days(from first: DayDate, through last: DayDate, calendar: Calendar) -> CalendarRange? {
        guard first <= last, let start = calendar.date(from: DateComponents(year: first.year, month: first.month, day: first.day)),
              let lastStart = calendar.date(from: DateComponents(year: last.year, month: last.month, day: last.day)),
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastStart)) else { return nil }
        let count = (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: lastStart)).day ?? 0) + 1
        guard count <= maxDays else { return nil }
        return CalendarRange(kind: count == 1 ? .day : .days, start: calendar.startOfDay(for: start), end: end)
    }

    /// From now through the end of the `count`-th day, today included.
    public static func nextDays(_ count: Int, now: Date, calendar: Calendar) -> CalendarRange? {
        guard (1...maxDays).contains(count),
              let end = calendar.date(byAdding: .day, value: count, to: calendar.startOfDay(for: now)) else { return nil }
        return CalendarRange(kind: .nextDays, start: now, end: end)
    }

    /// The weekend that is running now (from now) or the next one, as the locale defines it.
    public static func weekend(now: Date, calendar: Calendar) -> CalendarRange? {
        if calendar.isDateInWeekend(now), let current = calendar.dateIntervalOfWeekend(containing: now) {
            return CalendarRange(kind: .weekend, start: now, end: current.end)
        }
        guard let next = calendar.nextWeekend(startingAfter: now) else { return nil }
        return CalendarRange(kind: .weekend, start: next.start, end: next.end)
    }

    /// The day with `weekday` (1 = Sunday … 7 = Saturday): the next one from today, today included unless `strictlyAfterToday`.
    public static func weekday(_ weekday: Int, now: Date, calendar: Calendar, strictlyAfterToday: Bool = false) -> CalendarRange? {
        guard (1...7).contains(weekday) else { return nil }
        let today = calendar.component(.weekday, from: now)
        var delta = (weekday - today + 7) % 7
        if delta == 0 && strictlyAfterToday { delta = 7 }
        guard let date = calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: now)) else { return nil }
        return day(date, calendar: calendar)
    }

    /// The day with `weekday` inside the local week that contains `reference`.
    public static func weekday(_ weekday: Int, inWeekOf reference: Date, calendar: Calendar) -> CalendarRange? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: reference) else { return nil }
        var day = week.start
        for _ in 0..<7 {
            if calendar.component(.weekday, from: day) == weekday { return Self.day(day, calendar: calendar) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// Smallest range covering both, if it stays within `maxDays`.
    public func union(_ other: CalendarRange, calendar: Calendar) -> CalendarRange? {
        let start = min(self.start, other.start), end = max(self.end, other.end)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: end).day ?? Int.max
        guard days <= Self.maxDays else { return nil }
        return CalendarRange(kind: .days, start: start, end: end)
    }

    /// Last moment still inside the range (for showing the inclusive last day).
    public var lastMoment: Date { end > start ? end.addingTimeInterval(-1) : start }

    /// Range for the agent tool `read_calendar` (AgentBridge.swift). The model names a kind of period; code computes it.
    public static func resolve(_ request: CalendarToolRequest, now: Date, calendar: Calendar) -> CalendarRange? {
        switch request.period {
        case "today": return day(now, calendar: calendar)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: now).flatMap { day($0, calendar: calendar) }
        case "rest_of_week": return restOfWeek(now: now, calendar: calendar)
        case "next_week": return nextWeek(now: now, calendar: calendar)
        case "weekend": return weekend(now: now, calendar: calendar)
        case "next_days": return request.days.flatMap { nextDays($0, now: now, calendar: calendar) }
        case "dates":
            guard let first = request.start.flatMap(DayDate.init(iso:)), let last = (request.end ?? request.start).flatMap(DayDate.init(iso:)) else { return nil }
            return days(from: first, through: last, calendar: calendar)
        default: return nil
        }
    }
}

extension DayDate {
    /// `YYYY-MM-DD`, nothing else.
    init?(iso text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Day of `date` in `calendar` (its time zone), not in the Mac's current zone.
    init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self = DayDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1) ?? DayDate(date)
    }
}
