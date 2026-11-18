import Foundation

extension PippaMCPWriteTools {
    // MARK: Date and time (Pippa computes, not the model)

    static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
        "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7, "sonnabend": 7,
    ]

    /// "2026-10-08", "today"/"heute", "tomorrow"/"morgen" or a weekday (the next one after today). Start of day in the
    /// host's calendar; `nil` if unknown, invalid, before today or more than three years away.
    public static func day(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let today = calendar.startOfDay(for: now)
        let found: Date?
        switch value {
        case "today", "heute": found = today
        case "tomorrow", "morgen": found = calendar.date(byAdding: .day, value: 1, to: today)
        default:
            if let weekday = weekdays[value] {
                found = calendar.nextDate(after: today, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)
            } else {
                let parts = value.split(separator: "-").map { Int($0) }
                guard value.count == 10, parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2],
                      let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
                let check = calendar.dateComponents([.year, .month, .day], from: date)
                guard check.year == y, check.month == m, check.day == d else { return nil }   // 2026-02-30 does not exist
                found = calendar.startOfDay(for: date)
            }
        }
        guard let found, found >= today, let limit = calendar.date(byAdding: .year, value: 3, to: today), found <= limit else { return nil }
        return found
    }

    /// "9:00", "09:00", "9.30", "9" → (hour, minute).
    public static func time(_ raw: String) -> (hour: Int, minute: Int)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " uhr", with: "")
        let parts = value.split(whereSeparator: { $0 == ":" || $0 == "." }).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isASCII) && Int($0) != nil }),
              let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1])! : 0
        guard (0...59).contains(minute), parts.count == 1 || parts[1].count == 2 else { return nil }
        return (hour, minute)
    }

    /// Exact wall-clock time on `day` in `calendar`; `nil` if a DST spring-forward gap skips that local minute.
    static func exactTime(_ t: (hour: Int, minute: Int), on day: Date, calendar: Calendar) -> Date? {
        let d = calendar.dateComponents([.year, .month, .day], from: day)
        guard let y = d.year, let m = d.month, let dom = d.day,
              let resolved = calendar.date(from: DateComponents(year: y, month: m, day: dom, hour: t.hour, minute: t.minute, second: 0)) else {
            return nil
        }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resolved)
        guard check.year == y, check.month == m, check.day == dom, check.hour == t.hour, check.minute == t.minute else { return nil }
        return resolved
    }

    /// Whole civil-calendar days between `start` and `end` (0 for the same date), independent of DST transitions.
    static func dayOffset(from start: Date, to end: Date, calendar: Calendar) -> Int? {
        let a = calendar.dateComponents([.year, .month, .day], from: start)
        let b = calendar.dateComponents([.year, .month, .day], from: end)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let d0 = utc.date(from: DateComponents(year: a.year, month: a.month, day: a.day)),
              let d1 = utc.date(from: DateComponents(year: b.year, month: b.month, day: b.day)) else { return nil }
        return utc.dateComponents([.day], from: d0, to: d1).day
    }

    /// Start of the calendar day following `day` (exact even when `day` started at 01:00 after a midnight DST jump).
    static func dayAfter(_ day: Date, calendar: Calendar) -> Date {
        if let end = calendar.dateInterval(of: .day, for: day)?.end, end > day { return end }
        if let next = calendar.date(byAdding: .day, value: 1, to: day) { return calendar.startOfDay(for: next) }
        return day.addingTimeInterval(86_400)
    }

    /// Single line and shortened (titles come from the model, which reads mails).
    static func singleLine(_ text: String, max: Int) -> String {
        let one = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }

    func format(_ date: Date, _ template: String) -> String {
        PippaMCPTools.localized(date, template: template, calendar: host.calendar)
    }

    /// Short for the receipt ("Do., 8. Okt., 09:00"), for the model with year and end ("Do., 8. Okt. 2026, 09:00–10:00").
    /// Spanning days: both ends ("Sa., 10. Okt. – Mo., 12. Okt."; an all-day end is exclusive, so the last day is shown).
    func when(_ start: Date, _ end: Date, allDay: Bool, short: Bool) -> String {
        let cal = host.calendar
        if allDay {
            let template = short ? "EEE d MMM" : "EEE d MMM y"
            let last = end > start ? end.addingTimeInterval(-1) : start
            return cal.isDate(start, inSameDayAs: last) ? format(start, template) : format(start, template) + " – " + format(last, template)
        }
        let head = format(start, short ? "EEE d MMM HH:mm" : "EEE d MMM y HH:mm")
        if !cal.isDate(start, inSameDayAs: end) && end > start {
            return head + " – " + format(end, short ? "EEE d MMM HH:mm" : "EEE d MMM y HH:mm")
        }
        return short ? head : head + "–" + format(end, "HH:mm")
    }
}
