import Foundation

/// Recognizes in code that a message asks about the person's own appointments, and which time range it means.
/// Deliberately narrow: read only, never create/move/cancel (writing stays with preview -> confirm -> undo),
/// and never when the message points to a letter, a file or a mail ("Welche Termine stehen im Brief?" = which appointments are in the letter?).
/// What is not recognized here goes to Pi as before, which has the tool `read_calendar` for it.
public struct CalendarIntent: Sendable, Equatable {
    public var range: CalendarRange
    /// Short follow-up ("und morgen?" = and tomorrow?) after a calendar answer in the same conversation.
    public var followUp: Bool
    public init(range: CalendarRange, followUp: Bool) { self.range = range; self.followUp = followUp }

    /// `recentCalendarTurn`: the calendar was just read (or access asked for) in the same conversation;
    /// then a short message with a time reference suffices ("Was ist am Donnerstag?" = what is on Thursday?).
    public static func parse(_ text: String, now: Date, calendar: Calendar, recentCalendarTurn: Bool = false) -> CalendarIntent? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
            .replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "’", with: "'")
        let words = folded.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
        guard !words.isEmpty, words.count <= 40 else { return nil }
        let set = Set(words)
        if words.contains(where: isDocumentWord) || words.contains(where: isWriteWord) || writePhrase(folded) { return nil }

        let time = timeRange(words: words, folded: folded, now: now, calendar: calendar)
        let noun = words.contains(where: isCalendarNoun)
        let personal = !set.isDisjoint(with: personalWords)
        let upcoming = words.contains { $0.hasPrefix("anstehend") || $0.hasPrefix("bevorstehend") || $0 == "upcoming" || $0 == "demnachst" }
        let standsOn = !set.isDisjoint(with: ["steht", "stehen", "stehts"]) && set.contains("an")
        let plans = set.contains("vor") && set.contains("ich") && !set.isDisjoint(with: ["habe", "hab", "hast"])
        let whatsOn = folded.contains("what's on") || folded.contains("whats on") || folded.contains("what do i have")
            || folded.contains("what have i got") || folded.contains("my schedule") || folded.contains("my agenda")
        let availability = !set.isDisjoint(with: ["frei", "zeit", "free", "busy", "verplant", "ausgebucht", "available"]) && personal

        let strong = (noun && (personal || upcoming || time != nil))
            || ((standsOn || plans || whatsOn) && (time != nil || noun || upcoming || whatsOn))
            || (availability && time != nil)
            || (upcoming && (time != nil || noun))
        if strong {
            // "Wann ist mein nächster Zahnarzttermin?" (when is my next dentist appointment?) is a search, not a week overview: without a time reference to Pi.
            if time == nil && !set.isDisjoint(with: ["wann", "when"]) { return nil }
            guard let range = time ?? CalendarRange.restOfWeek(now: now, calendar: calendar) else { return nil }
            return CalendarIntent(range: range, followUp: false)
        }
        if recentCalendarTurn, let time, words.count <= 10, isElliptic(words) {
            return CalendarIntent(range: time, followUp: true)
        }
        return nil
    }

    // MARK: Words

    /// Words that a follow-up only carries, without naming a topic of its own ("und morgen?", "Was ist am Donnerstag?").
    /// Every other word ("Wetter", "kostet", "News" ...) names a topic: then the question goes to Pi, not to the calendar.
    static let ellipticWords: Set<String> = [
        "und", "oder", "auch", "noch", "dann", "was", "wie", "wo", "wann", "ist", "sind", "am", "an", "im", "in", "um", "bis", "von", "zu", "den", "die",
        "es", "steht", "stehen", "sieht", "aus", "gibt", "gibts", "los", "hab", "habe", "hast", "ich", "mir", "mein", "meine", "frei", "zeit", "verplant",
        "vor", "bitte", "mal", "denn", "ja", "dazu", "davon", "wochenende", "woche", "tage", "tagen", "heute", "morgen", "ubermorgen", "gestern",
        "and", "what", "what's", "whats", "about", "how", "is", "on", "the", "my", "i", "have", "do", "next", "this", "last", "week", "weekend", "day",
        "days", "please", "also", "then", "for", "at", "until", "till", "from", "to", "free", "busy", "today", "tomorrow", "yesterday", "tonight",
    ]

    /// Elliptical: only time references, numbers and filler words. A topic word stops the message from counting as a calendar follow-up.
    static func isElliptic(_ words: [String]) -> Bool {
        words.allSatisfy { ellipticWords.contains($0) || weekdays[$0] != nil || nextWords.contains($0) || thisWords.contains($0)
            || lastWords.contains($0) || numbers[$0] != nil || Int($0) != nil }
    }

    static let personalWords: Set<String> = ["ich", "mich", "mir", "mein", "meine", "meinen", "meinem", "meiner", "meines", "hab", "habe", "bin",
                                             "i", "my", "me", "i'm", "i've", "mine"]

    static func isCalendarNoun(_ word: String) -> Bool {
        if ["kalender", "kalenders", "calendar", "calendars", "appointment", "appointments", "meeting", "meetings", "verabredung",
            "verabredungen", "besprechung", "besprechungen", "agenda", "events"].contains(word) { return true }
        // Also compounds: "Zahnarzttermin", "Kalendereinträge".
        return word.hasSuffix("termin") || word.hasSuffix("termine") || word.hasSuffix("terminen") || word.hasPrefix("kalendereintrag")
    }

    /// Points to documents instead of the calendar: then it is a question about the attachment.
    static func isDocumentWord(_ word: String) -> Bool {
        let exact: Set<String> = ["brief", "briefe", "briefes", "datei", "dateien", "dokument", "dokumente", "dokuments", "anhang", "anhange",
                                  "anhangen", "angehangt", "angehangten", "mail", "mails", "email", "emails", "vertrag", "vertrags", "rechnung",
                                  "rechnungen", "bescheid", "pdf", "schreiben", "tabelle", "frist", "fristen", "letter", "letters", "document",
                                  "documents", "file", "files", "attachment", "attachments", "attached", "contract", "invoice", "deadline",
                                  "deadlines", "sheet", "spreadsheet", "text", "notice", "pdfs"]
        return exact.contains(word)
    }

    /// Writing does not belong here but to preview -> confirm -> undo.
    static func isWriteWord(_ word: String) -> Bool {
        let exact: Set<String> = ["eintragen", "trag", "trage", "tragt", "eingetragen", "anlegen", "lege", "leg", "erstelle", "erstellen", "verschiebe",
                                  "verschieben", "verschieb", "losche", "loschen", "losch", "absagen", "storniere", "buche", "buchen", "einladen",
                                  "lade", "erinnere", "erinner", "add", "create", "move", "delete", "remove", "cancel", "reschedule", "book",
                                  "invite", "remind", "put", "set"]
        return exact.contains(word)
    }

    static func writePhrase(_ folded: String) -> Bool {
        ["sag ", "sage "].contains { folded.contains($0) } && folded.contains(" ab")
    }

    // MARK: Time references

    static let weekdays: [String: Int] = [
        "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7, "sonnabend": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]
    static let numbers: [String: Int] = ["zwei": 2, "drei": 3, "vier": 4, "funf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10,
                                         "vierzehn": 14, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                                         "ten": 10, "fourteen": 14]
    static let nextWords: Set<String> = ["nachste", "nachsten", "nachster", "nachstes", "kommende", "kommenden", "kommender", "next", "coming"]
    static let thisWords: Set<String> = ["diese", "dieser", "diesen", "dieses", "this"]
    static let lastWords: Set<String> = ["letzte", "letzten", "letzter", "vergangene", "vergangenen", "vorige", "vorigen", "last", "previous"]

    /// All time references of the message, combined ("heute und morgen", "Montag bis Mittwoch"); `nil` without a time reference.
    static func timeRange(words: [String], folded: String, now: Date, calendar: Calendar) -> CalendarRange? {
        var found: [CalendarRange] = []
        func add(_ range: CalendarRange?) { if let range { found.append(range) } }
        func qualifier(_ set: Set<String>) -> Bool {
            words.indices.contains { i in (words[i] == "woche" || words[i] == "week") && i > 0 && set.contains(words[i - 1]) }
        }
        let saysNextWeek = qualifier(nextWords), saysThisWeek = qualifier(thisWords), saysLastWeek = qualifier(lastWords)
        // "Montag nächste Woche" (Monday next week): the week only determines which Monday is meant.
        let namesWeekday = words.contains { weekdays[$0] != nil }

        for (i, word) in words.enumerated() {
            let previous = i > 0 ? words[i - 1] : ""
            switch word {
            case "heute", "today", "tonight", "heut":
                add(CalendarRange.day(now, calendar: calendar))
            case "gestern", "yesterday":
                add(calendar.date(byAdding: .day, value: -1, to: now).flatMap { CalendarRange.day($0, calendar: calendar) })
            case "morgen" where previous != "heute" && previous != "gestern", "tomorrow":
                add(calendar.date(byAdding: .day, value: 1, to: now).flatMap { CalendarRange.day($0, calendar: calendar) })
            case "ubermorgen":
                add(calendar.date(byAdding: .day, value: 2, to: now).flatMap { CalendarRange.day($0, calendar: calendar) })
            case "wochenende", "weekend":
                add(CalendarRange.weekend(now: now, calendar: calendar))
            case "woche", "week":
                guard !namesWeekday else { break }
                if nextWords.contains(previous) { add(CalendarRange.nextWeek(now: now, calendar: calendar)) }
                else if lastWords.contains(previous) { add(CalendarRange.lastWeek(now: now, calendar: calendar)) }
                else if !saysNextWeek && !saysLastWeek { add(CalendarRange.restOfWeek(now: now, calendar: calendar)) }
            case "tage", "tagen", "days":
                // "in den nächsten 5 Tagen", "next three days", "die nächsten Tage"
                let count = i > 0 ? (Int(previous) ?? numbers[previous]) : nil
                let before = i > 1 ? words[i - 2] : ""
                if let count, nextWords.contains(before) || ["in", "the"].contains(before) {
                    add(CalendarRange.nextDays(min(count, CalendarRange.maxDays), now: now, calendar: calendar))
                } else if nextWords.contains(previous) {
                    add(CalendarRange.nextDays(7, now: now, calendar: calendar))
                }
            default:
                guard let weekday = weekdays[word] else { break }
                if saysNextWeek, let reference = calendar.dateInterval(of: .weekOfYear, for: now)?.end {
                    add(CalendarRange.weekday(weekday, inWeekOf: reference, calendar: calendar))
                } else if saysLastWeek, let reference = calendar.dateInterval(of: .weekOfYear, for: now)?.start.addingTimeInterval(-1) {
                    add(CalendarRange.weekday(weekday, inWeekOf: reference, calendar: calendar))
                } else if saysThisWeek {
                    add(CalendarRange.weekday(weekday, inWeekOf: now, calendar: calendar))
                } else {
                    add(CalendarRange.weekday(weekday, now: now, calendar: calendar, strictlyAfterToday: nextWords.contains(previous)))
                }
            }
        }
        if folded.contains("day after tomorrow") {
            found.removeAll { $0.kind == .day }
            add(calendar.date(byAdding: .day, value: 2, to: now).flatMap { CalendarRange.day($0, calendar: calendar) })
        }
        found += explicitDates(folded, now: now, calendar: calendar)
        guard var range = found.first else { return nil }
        for other in found.dropFirst() where other != range {
            // Too far apart: better not to read at all than a guessed excerpt.
            guard let joined = range.union(other, calendar: calendar) else { return nil }
            range = joined
        }
        return range
    }

    /// "am 14.10.", "14.10.2026", "2026-10-14". Without year: this year.
    static func explicitDates(_ folded: String, now: Date, calendar: Calendar) -> [CalendarRange] {
        var result: [CalendarRange] = []
        let year = calendar.component(.year, from: now)
        let patterns = [#"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?(?![\d])"#, #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#]
        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)) {
                func group(_ n: Int) -> Int? {
                    guard let r = Range(match.range(at: n), in: folded) else { return nil }
                    return Int(folded[r])
                }
                let day: DayDate?
                if index == 0 {
                    var y = group(3) ?? year
                    if y < 100 { y += 2000 }
                    day = group(1).flatMap { d in group(2).flatMap { m in DayDate(year: y, month: m, day: d) } }
                } else {
                    day = group(1).flatMap { y in group(2).flatMap { m in group(3).flatMap { d in DayDate(year: y, month: m, day: d) } } }
                }
                if let day, let range = CalendarRange.days(from: day, through: day, calendar: calendar) { result.append(range) }
            }
        }
        return result
    }
}
