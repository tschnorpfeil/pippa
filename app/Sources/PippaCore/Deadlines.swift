import Foundation

// Deadlines from letters and contracts. Further analysis: Pi with skill fristen-erkennen; the
// patterns below find deadlines without a model (letter line, overview). Each deadline carries its
// verbatim evidence passage (excerpt of the read text) and the page.

/// A found deadline.
public struct Deadline: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case payment        // pay
        case cancellation   // cancel
        case objection      // objection / appeal
        case appointment    // appointment
        case debit          // debit (info only)
        case contractEnd    // contract ends
        case generic        // other deadline
    }

    public var id: UUID
    public var kind: Kind
    /// Due date. `nil` if the text has no date and none can be computed.
    public var date: DayDate?
    /// Short and action-oriented, e.g. "Zahlen bis 31.10.2026" (pay by).
    public var title: String
    /// Verbatim from the text.
    public var quote: String
    public var source: URL?
    /// "S. 2" for PDFs.
    public var location: String?
    /// `.sure`: the date appears like this in the text. `.unsure`: computed, please check.
    public var certainty: Certainty
    /// How it was computed, e.g. "14 Tage ab dem Briefdatum 02.03.2026 gerechnet." (without "Bitte prüfen", which the UI shows).
    public var note: String?
    /// Kind of document ("Mietvertrag", "Nebenkostenabrechnung") and sender, for a meaningful reminder title.
    public var documentKind: String?
    public var sender: String?

    public init(id: UUID = UUID(), kind: Kind, date: DayDate?, title: String, quote: String, source: URL?, location: String?,
                certainty: Certainty, note: String? = nil, documentKind: String? = nil, sender: String? = nil) {
        self.id = id; self.kind = kind; self.date = date; self.title = title; self.quote = quote
        self.source = source; self.location = location; self.certainty = certainty; self.note = note
        self.documentKind = documentKind; self.sender = sender
    }

    /// Title for reminder or calendar: what to do, about what, with whom. Never a file or folder name.
    /// „Mietvertrag kündigen (Hausverwaltung Berger)“, „Nebenkosten nachzahlen (Hausverwaltung Berger)“, „Einspruch Steuerbescheid“.
    public func reminderTitle(sender override: String? = nil) -> String {
        let who = (override ?? sender).map { Heuristics.displayName($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let doc = documentKind
        let lowerQuote = quote.lowercased()
        // Kind of document (German, from the document); "Vertrag" and "Rechnung" alone say nothing and become the generic title.
        let contract = doc.flatMap { $0.lowercased().hasSuffix("vertrag") && $0 != "Vertrag" ? $0 : nil }
        let base: String
        switch kind {
        case .cancellation:
            base = contract.map { L("Cancel %@", table: "Analysis", $0) } ?? L("Cancel contract", table: "Analysis")
        case .payment:
            if lowerQuote.contains("nachzahlung") || doc == "Nebenkostenabrechnung" {
                let utilities = doc == "Nebenkostenabrechnung" || lowerQuote.contains("nebenkosten") || lowerQuote.contains("betriebskosten")
                base = utilities ? L("Pay the utilities balance", table: "Analysis") : L("Pay the balance due", table: "Analysis")
            } else {
                let bill = doc.flatMap { ["Mahnung", "Beitragsrechnung", "Steuerbescheid", "Bescheid"].contains($0) ? $0 : nil }
                base = bill.map { L("Pay %@", table: "Analysis", $0) } ?? L("Pay invoice", table: "Analysis")
            }
        case .objection: base = doc.map { L("Object to %@", table: "Analysis", $0) } ?? L("File an objection", table: "Analysis")
        case .appointment: return who.map { L("Appointment with %@", table: "Analysis", $0) } ?? L("Appointment", table: "Analysis")
        case .debit: base = L("Direct debit", table: "Analysis")
        case .contractEnd: base = contract.map { L("%@ ends", table: "Analysis", $0) } ?? L("Contract ends", table: "Analysis")
        case .generic: base = doc.map { L("Deadline: %@", table: "Analysis", $0) } ?? L("Deadline", table: "Analysis")
        }
        return who.map { "\(base) (\($0))" } ?? base
    }

    /// How many days ahead to remind: cancellation and objection 14, payment 3, appointment 1.
    public var leadDays: Int {
        switch kind {
        case .cancellation, .objection, .contractEnd: 14
        case .payment, .generic: 3
        case .appointment, .debit: 1
        }
    }

    /// What to do, without date ("Zahlen", "Kündigen" …).
    public var action: String { Self.action(kind) }

    static func action(_ kind: Kind) -> String {
        switch kind {
        case .payment: "Zahlen"
        case .cancellation: "Kündigen"
        case .objection: "Einspruch einlegen"
        case .appointment: "Termin"
        case .debit: "Abbuchung"
        case .contractEnd: "Vertrag endet"
        case .generic: "Frist"
        }
    }

    static func title(_ kind: Kind, _ date: DayDate) -> String {
        switch kind {
        case .payment: "Zahlen bis \(date.german)"
        case .cancellation: "Kündigen bis \(date.german)"
        case .objection: "Einspruch bis \(date.german)"
        case .appointment: "Termin am \(date.german)"
        case .debit: "Abbuchung am \(date.german)"
        case .contractEnd: "Vertrag endet am \(date.german)"
        case .generic: "Frist bis \(date.german)"
        }
    }
}

public extension DayDate {
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var noonUTC: Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day; c.hour = 12
        return Self.utc.date(from: c)!
    }

    private static func from(_ date: Date) -> DayDate {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return DayDate(year: c.year!, month: c.month!, day: c.day!) ?? DayDate(year: 1970, month: 1, day: 1)!
    }

    func adding(days: Int) -> DayDate { Self.from(Self.utc.date(byAdding: .day, value: days, to: noonUTC)!) }
    /// Add months; the 31st becomes the last day in shorter months.
    func adding(months: Int) -> DayDate { Self.from(Self.utc.date(byAdding: .month, value: months, to: noonUTC)!) }

    var endOfMonth: DayDate {
        let first = DayDate(year: year, month: month, day: 1)!
        return first.adding(months: 1).adding(days: -1)
    }

    var endOfQuarter: DayDate {
        let lastMonth = ((month - 1) / 3) * 3 + 3
        return DayDate(year: year, month: lastMonth, day: 1)!.endOfMonth
    }

    var endOfYear: DayDate { DayDate(year: year, month: 12, day: 31)! }

    /// Noon in the local time zone, for date pickers and calendar.
    var localNoon: Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }
}

public enum Deadlines {
    // MARK: Patterns

    static let numberWords: [String: Int] = [
        "ein": 1, "eine": 1, "einen": 1, "einem": 1, "einer": 1, "eines": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5,
        "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwölf": 12, "vierzehn": 14,
        "einundzwanzig": 21, "dreißig": 30,
    ]
    static let numberPattern = #"(\d{1,3}|ein|eine|einen|einem|einer|eines|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf|vierzehn|einundzwanzig|dreißig)"#
    static let unitPattern = #"(tagen|tages|tage|tag|wochen|woche|monaten|monate|monats|monat|jahren|jahres|jahre|jahr)\b"#

    /// "bis", "spätestens", "fällig" … shortly before a date.
    static let trigger = try! NSRegularExpression(
        pattern: #"(?i)(bis\b|spätestens|fällig|zahlbar|frist|einzureichen|eingehen|vorzulegen|termin|ablauf|endet|enden|läuft|laufzeit|vertragsende|abgebucht|abbuchung|eingezogen|einzug)"#)
    /// Document date instead of deadline: "Datum", "vom" … directly before the date.
    static let documentDateHint = try! NSRegularExpression(
        pattern: #"(?i)(datum|\bvom|ausgestellt|geboren|erstellt|gedruckt|stand)\W{0,3}(am\W{0,2})?$"#)

    static let relative = try! NSRegularExpression(
        pattern: #"(?i)\b(innerhalb|binnen|zahlungsziel:?|zahlbar in|in den nächsten)\s+(von\s+)?"# + numberPattern + #"\s+"# + unitPattern + #"\b"#)
    static let relativeAfter = try! NSRegularExpression(
        pattern: #"(?i)\b"# + numberPattern + #"\s+"# + unitPattern + #"\s+nach\s+(erhalt|zugang|eingang|rechnungsdatum|rechnungsstellung|zustellung|bekanntgabe|rechnungseingang)"#)
    static let notice = try! NSRegularExpression(
        pattern: #"(?i)(frist|kündigungsfrist)\s*(:|von|beträgt)?\s*"# + numberPattern + #"\s+"# + unitPattern
            + #"(\s+(zum\s+(monatsende|ende\s+(des|eines)\s+(kalender)?monats|quartalsende|ende\s+(des|eines)\s+(kalender)?(vierteljahres|quartals)|jahresende|ende\s+(des|eines)\s+(kalender)?jahres)))?"#)
    static let noticeBefore = try! NSRegularExpression(
        pattern: #"(?i)\b"# + numberPattern + #"\s+"# + unitPattern + #"\s+vor\s+(ablauf|ende|dem\s+ende)"#)

    // MARK: Search

    /// Deadlines in a read document. `today`: earlier dates are dropped.
    public static func find(in doc: DocumentText, today: DayDate = DayDate(Date())) -> [Deadline] {
        let text = doc.fullText
        let kind = Keywords.kind(text: text, fileName: "")      // text only: file names like "download.pdf" say nothing
        let sender = Heuristics.sender(text: text, headers: doc.headers)
        return find(pages: doc.pages, isPaged: doc.isPaged, source: doc.url, today: today).map { d in
            var d = d; d.documentKind = kind; d.sender = sender; return d
        }
    }

    public static func find(pages: [String], isPaged: Bool, source: URL?, today: DayDate = DayDate(Date())) -> [Deadline] {
        let full = pages.joined(separator: "\n\n")
        let base = Heuristics.documentDate(text: full, notAfter: today.adding(days: 60).localNoon)
        let contractEnd = contractEndDate(pages: pages, today: today)
        var out: [Deadline] = []
        for (i, page) in pages.enumerated() {
            let location = isPaged ? "S. \(i + 1)" : nil
            out += fixedDates(page, location: location, source: source, today: today)
            out += relativeDates(page, base: base, location: location, source: source, today: today)
            out += noticePeriods(page, contractEnd: contractEnd, location: location, source: source, today: today)
        }
        var seen = Set<String>()
        return out.filter { seen.insert("\($0.kind)|\($0.date?.iso ?? $0.title)").inserted }
            .sorted { ($0.date ?? DayDate(year: 2100, month: 12, day: 31)!) < ($1.date ?? DayDate(year: 2100, month: 12, day: 31)!) }
    }

    /// Date with "bis", "fällig" … before it.
    static func fixedDates(_ text: String, location: String?, source: URL?, today: DayDate) -> [Deadline] {
        var out: [Deadline] = []
        for match in GermanText.dates(in: text) where match.value >= today {
            let sentence = sentenceRange(around: match.range, in: text)
            let windowStart = text.index(match.range.lowerBound, offsetBy: -60, limitedBy: sentence.lowerBound) ?? sentence.lowerBound
            let before = String(text[windowStart..<match.range.lowerBound])
            let afterEnd = text.index(match.range.upperBound, offsetBy: 25, limitedBy: sentence.upperBound) ?? sentence.upperBound
            let after = String(text[match.range.upperBound..<max(afterEnd, match.range.upperBound)])
            let debitAfter = after.range(of: #"(?i)^\W{0,3}(\w+\s+){0,2}(abgebucht|eingezogen|abgebucht\.)"#, options: .regularExpression) != nil
            guard debitAfter || trigger.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil else { continue }
            if documentDateHint.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil { continue }
            let quote = clean(String(text[sentence]))
            let kind = debitAfter ? .debit : classify(sentence: quote.lowercased(), near: before.lowercased())
            out.append(Deadline(kind: kind, date: match.value, title: Deadline.title(kind, match.value), quote: quote,
                                source: source, location: location, certainty: .sure))
        }
        return out
    }

    /// Payment term phrases: "zahlbar innerhalb von 14 Tagen", "binnen eines Monats", "30 Tage nach Erhalt".
    static func relativeDates(_ text: String, base: DayDate?, location: String?, source: URL?, today: DayDate) -> [Deadline] {
        var out: [Deadline] = []
        let ns = NSRange(text.startIndex..., in: text)
        let hits = relative.matches(in: text, range: ns).map { ($0, 3, 4) } + relativeAfter.matches(in: text, range: ns).map { ($0, 1, 2) }
        for (m, numGroup, unitGroup) in hits {
            guard let r = Range(m.range, in: text), let n = number(text, m.range(at: numGroup)),
                  let unitRange = Range(m.range(at: unitGroup), in: text) else { continue }
            let sentence = sentenceRange(around: r, in: text)
            let quote = clean(String(text[sentence]))
            let lower = quote.lowercased()
            // Notice periods are handled by `noticePeriods`.
            if lower.contains("kündig") { continue }
            let kind = classify(sentence: lower, near: lower)
            let span = spanText(n, unit: String(text[unitRange]))
            if let base {
                let due = add(n, unit: String(text[unitRange]), to: base)
                guard due >= today else { continue }
                out.append(Deadline(kind: kind, date: due, title: Deadline.title(kind, due), quote: quote, source: source, location: location,
                                    certainty: .unsure, note: "\(span) ab dem Briefdatum \(base.german) gerechnet."))
            } else {
                out.append(Deadline(kind: kind, date: nil, title: "\(Deadline.action(kind)) innerhalb \(span)", quote: quote, source: source,
                                    location: location, certainty: .unsure, note: "Im Brief steht kein Datum, ab dem die Frist läuft."))
            }
        }
        return out
    }

    /// Notice period ("3 Monate zum Monatsende"): with contract end a date, otherwise a hint.
    static func noticePeriods(_ text: String, contractEnd: DayDate?, location: String?, source: URL?, today: DayDate) -> [Deadline] {
        var out: [Deadline] = []
        let ns = NSRange(text.startIndex..., in: text)
        let hits = notice.matches(in: text, range: ns).map { ($0, 3, 4, 6) } + noticeBefore.matches(in: text, range: ns).map { ($0, 1, 2, -1) }
        for (m, numGroup, unitGroup, anchorGroup) in hits {
            guard let r = Range(m.range, in: text), let n = number(text, m.range(at: numGroup)),
                  let unitRange = Range(m.range(at: unitGroup), in: text) else { continue }
            let sentence = sentenceRange(around: r, in: text)
            let quote = clean(String(text[sentence]))
            guard quote.lowercased().contains("kündig") else { continue }
            let unit = String(text[unitRange])
            let anchorText = anchorGroup > 0 ? Range(m.range(at: anchorGroup), in: text).map { clean(String(text[$0])) } : nil
            let anchor = anchorText?.lowercased()
            let span = spanText(n, unit: unit)
            let rule = span + (anchorText.map { " " + $0 } ?? "")
            if let end = contractEnd {
                let by = add(-n, unit: unit, to: end)
                guard by >= today else { continue }
                out.append(Deadline(kind: .cancellation, date: by, title: Deadline.title(.cancellation, by), quote: quote, source: source,
                                    location: location, certainty: .unsure,
                                    note: "\(span) vor dem Vertragsende \(end.german) gerechnet."))
            } else {
                let exit = earliestExit(from: today, n: n, unit: unit, anchor: anchor)
                out.append(Deadline(kind: .cancellation, date: nil, title: "Kündigungsfrist: \(rule)", quote: quote, source: source,
                                    location: location, certainty: .unsure,
                                    note: "Wer heute kündigt, ist zum \(exit.german) raus."))
            }
        }
        return out
    }

    /// Contract end: date after "Laufzeit bis", "endet am", "Vertragsende".
    static func contractEndDate(pages: [String], today: DayDate) -> DayDate? {
        let marker = try! NSRegularExpression(pattern: #"(?i)(laufzeit|vertragsende|endet|läuft|befristet|mindestvertragslaufzeit)"#)
        for page in pages {
            for match in GermanText.dates(in: page) where match.value > today {
                let start = page.index(match.range.lowerBound, offsetBy: -50, limitedBy: page.startIndex) ?? page.startIndex
                let before = String(page[start..<match.range.lowerBound])
                if marker.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil { return match.value }
            }
        }
        return nil
    }

    // MARK: Helpers

    static func classify(sentence: String, near: String) -> Deadline.Kind {
        if near.contains("abgebucht") || near.contains("abbuchung") || near.contains("eingezogen") || near.contains("einzug") { return .debit }
        if sentence.contains("kündig") { return .cancellation }
        // "Einwände gegen diese Abrechnung …" is not a payment target, even though "Abrechnung" contains "rechnung".
        if ["einspruch", "widerspruch", "einwand", "einwänd", "einwend", "beanstand"].contains(where: sentence.contains) { return .objection }
        if near.contains("endet") || near.contains("laufzeit") || near.contains("vertragsende") || near.contains("läuft") { return .contractEnd }
        if sentence.contains("termin") { return .appointment }
        if ["zahl", "überweis", "betrag", "fällig", "begleichen", "rechnung"].contains(where: sentence.contains) { return .payment }
        return .generic
    }

    static func number(_ text: String, _ range: NSRange) -> Int? {
        guard let r = Range(range, in: text) else { return nil }
        let word = text[r].lowercased()
        return Int(word) ?? numberWords[word]
    }

    static func unitKind(_ unit: String) -> Calendar.Component {
        let u = unit.lowercased()
        if u.hasPrefix("tag") { return .day }
        if u.hasPrefix("woche") { return .weekOfYear }
        if u.hasPrefix("jahr") { return .year }
        return .month
    }

    static func add(_ n: Int, unit: String, to date: DayDate) -> DayDate {
        switch unitKind(unit) {
        case .day: date.adding(days: n)
        case .weekOfYear: date.adding(days: 7 * n)
        case .year: date.adding(months: 12 * n)
        default: date.adding(months: n)
        }
    }

    static func spanText(_ n: Int, unit: String) -> String {
        let one = n == 1
        switch unitKind(unit) {
        case .day: return one ? "1 Tag" : "\(n) Tage"
        case .weekOfYear: return one ? "1 Woche" : "\(n) Wochen"
        case .year: return one ? "1 Jahr" : "\(n) Jahre"
        default: return one ? "1 Monat" : "\(n) Monate"
        }
    }

    /// Earliest contract end if cancelled today.
    static func earliestExit(from today: DayDate, n: Int, unit: String, anchor: String?) -> DayDate {
        let raw = add(n, unit: unit, to: today)
        guard let a = anchor else { return raw }
        if a.contains("quartal") || a.contains("vierteljahr") { return raw.endOfQuarter }
        if a.contains("jahr") { return raw.endOfYear }
        if a.contains("monat") { return raw.endOfMonth }
        return raw
    }

    static let abbreviations: Set<String> = ["z", "b", "nr", "ca", "bzw", "inkl", "gem", "abs", "s", "str", "usw", "evtl", "d", "h", "u", "a", "vgl", "ggf", "zzgl", "tel", "dr", "st"]

    /// The sentence around a match. Sentence end: ".", "!", "?" followed by whitespace, but not after numbers
    /// ("3. Oktober", "31.10.2026") or abbreviations; blank lines always separate. At most about 320 characters.
    static func sentenceRange(around range: Range<String.Index>, in text: String) -> Range<String.Index> {
        func isBoundary(_ i: String.Index) -> Bool {
            // i points at the punctuation mark
            let c = text[i]
            guard c == "." || c == "!" || c == "?" else { return false }
            let next = text.index(after: i)
            guard next == text.endIndex || text[next].isWhitespace else { return false }
            if c != "." { return true }
            // word before the period
            var j = i
            var word = ""
            while j > text.startIndex {
                let p = text.index(before: j)
                if text[p].isLetter || text[p].isNumber { word.insert(text[p], at: word.startIndex); j = p } else { break }
            }
            if word.isEmpty { return true }
            if word.allSatisfy(\.isNumber) && word.count <= 2 { return false }
            if abbreviations.contains(word.lowercased()) { return false }
            return true
        }
        func isParagraph(_ i: String.Index) -> Bool {
            guard text[i] == "\n" else { return false }
            let next = text.index(after: i)
            guard next < text.endIndex else { return true }
            if text[next] == "\n" { return true }
            // Line break after a number or punctuation before capital letters: new line in the letterhead, not a break within a sentence.
            guard i > text.startIndex else { return false }
            let prev = text[text.index(before: i)]
            return text[next].isUppercase && !(prev.isLetter && prev.isLowercase) && prev != "," && prev != "-"
        }
        var start = range.lowerBound
        var steps = 0
        while start > text.startIndex && steps < 220 {
            let p = text.index(before: start)
            if isBoundary(p) || isParagraph(p) || (text[p] == "\n" && p > text.startIndex && text[text.index(before: p)] == "\n") { break }
            start = p; steps += 1
        }
        var end = range.upperBound
        steps = 0
        while end < text.endIndex && steps < 220 {
            if isBoundary(end) { end = text.index(after: end); break }
            if isParagraph(end) { break }
            end = text.index(after: end); steps += 1
        }
        return start..<end
    }

    /// All sentences of a text (boundaries as in `sentenceRange`), whitespace collapsed.
    public static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var pos = text.startIndex
        while pos < text.endIndex {
            if text[pos].isWhitespace { pos = text.index(after: pos); continue }
            let r = sentenceRange(around: pos..<text.index(after: pos), in: text)
            let s = clean(String(text[r]))
            if !s.isEmpty { out.append(s) }
            pos = r.upperBound > pos ? r.upperBound : text.index(after: pos)
        }
        return out
    }

    /// Collapse whitespace; stays verbatim in the text after `GermanText.normalize`.
    static func clean(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Entry for reminders or calendar

/// What would be written to Reminders or the calendar. Created in code, shown in the preview
/// and written only after "Anwenden".
public struct CalendarEntry: Sendable, Hashable, Codable {
    public enum Target: String, Sendable, Codable { case reminder, calendar }
    public var target: Target
    public var title: String
    public var date: DayDate
    public var notes: String
    /// Reminder day (9 o'clock): 14, 3 or 1 day before depending on the deadline (`Deadline.leadDays`), never before today.
    public var alertDay: DayDate
    /// Reminder lead time in days (kept when the date is changed).
    public var leadDays: Int
    public init(target: Target, title: String, date: DayDate, notes: String, alertDay: DayDate, leadDays: Int = 2) {
        self.target = target; self.title = title; self.date = date; self.notes = notes; self.alertDay = alertDay; self.leadDays = leadDays
    }

    public var integration: Integration { target == .reminder ? .reminders : .calendar }

    /// An all-day appointment ends at the next local day start, also across daylight-saving changes.
    public func eventInterval(in calendar: Calendar = Calendar(identifier: .gregorian)) -> DateInterval {
        let start = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }
}

public enum CalendarEntryBuilder {
    /// Entry for a deadline. Without a date in the deadline, `fallback` applies (changeable in the preview).
    public static func entry(for d: Deadline, target: CalendarEntry.Target, sender: String?, fallback: DayDate,
                             today: DayDate = DayDate(Date())) -> CalendarEntry {
        let date = d.date ?? fallback
        return CalendarEntry(target: target, title: d.reminderTitle(sender: sender), date: date, notes: notes(for: d),
                             alertDay: alertDay(due: date, today: today, leadDays: d.leadDays), leadDays: d.leadDays)
    }

    /// Note: the verbatim evidence passage, the source and how it was computed.
    public static func notes(for d: Deadline) -> String {
        var lines = [L("“%@”", table: "Analysis", d.quote)]
        if let src = d.source {
            let place = d.location.map { src.lastPathComponent + ", " + pageLabel($0) } ?? src.lastPathComponent
            lines.append(L("From: %@", table: "Analysis", place))
        }
        if let n = d.note { lines.append(n) }
        lines.append(L("Added by Pippa.", table: "Analysis"))
        return lines.joined(separator: "\n")
    }

    /// Location "S. 2" (always like this internally) in the system language: "Page 2" or "S. 2".
    static func pageLabel(_ location: String) -> String {
        guard location.hasPrefix("S. ") else { return location }
        return L("Page %@", table: "Analysis", String(location.dropFirst(3)))
    }

    public static func alertDay(due: DayDate, today: DayDate, leadDays: Int = 2) -> DayDate {
        let early = due.adding(days: -leadDays)
        if early >= today { return early }
        return due >= today ? today : due
    }

    /// New entry with changed date: the reminder day adjusts.
    public static func with(_ e: CalendarEntry, date: DayDate, today: DayDate = DayDate(Date())) -> CalendarEntry {
        var c = e
        c.date = date
        c.alertDay = alertDay(due: date, today: today, leadDays: e.leadDays)
        return c
    }
}
