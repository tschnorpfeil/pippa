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

    /// Single line and shortened (titles come from the model, which reads mails).
    static func singleLine(_ text: String, max: Int) -> String {
        let one = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }

    func format(_ date: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.calendar = host.calendar; f.timeZone = host.calendar.timeZone
        f.locale = Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en")
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// Short for the receipt ("Do., 8. Okt., 09:00"), for the model with year and end ("Do., 8. Okt. 2026, 09:00–10:00").
    func when(_ start: Date, _ end: Date, allDay: Bool, short: Bool) -> String {
        if allDay { return format(start, short ? "EEE d MMM" : "EEE d MMM y") }
        let head = format(start, short ? "EEE d MMM HH:mm" : "EEE d MMM y HH:mm")
        return short ? head : head + "–" + format(end, "HH:mm")
    }
}
