import Foundation

// Deterministic 0-token builders for routines (DE and EN, chosen by `language` as in `MorningBriefBuilder`).
// Every draft's `sourceVersion` is a SHA-256 of what it shows. Untrusted titles and places appear only in `summary`;
// `preparedPrompt` is always a fixed sentence, so nothing read from a calendar can become an instruction.

/// Already-read inputs for the Evening Preview and the Weekly Review.
public struct RoutineDigestInput: Sendable {
    public let now: Date
    public let events: [CalendarEvent]
    public let reminders: [ReminderItem]
    public let openMatters: [ProactiveMatter]
    public let calendar: Calendar
    public let language: String?

    public init(now: Date, events: [CalendarEvent] = [], reminders: [ReminderItem] = [], openMatters: [ProactiveMatter] = [],
                calendar: Calendar = .autoupdatingCurrent, language: String? = nil) {
        self.now = now; self.events = events; self.reminders = reminders; self.openMatters = openMatters
        self.calendar = calendar; self.language = language
    }
}

/// Shared formatting for the builders.
enum RoutineDigestFormat {
    static let maxListed = 5

    struct Formatters {
        let day: DateFormatter
        let time: DateFormatter
        let de: Bool
    }

    static func formatters(de: Bool, calendar: Calendar) -> Formatters {
        let locale = Locale(identifier: de ? "de_DE" : "en_US")
        let day = DateFormatter()
        day.calendar = calendar; day.timeZone = calendar.timeZone; day.locale = locale
        day.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let time = DateFormatter()
        time.calendar = calendar; time.timeZone = calendar.timeZone; time.locale = locale
        time.dateFormat = "HH:mm"
        return Formatters(day: day, time: time, de: de)
    }

    /// Active (not cancelled, not declined) events overlapping `[start, end)`, all-day first, then by start.
    static func activeEvents(_ events: [CalendarEvent], from start: Date, to end: Date) -> [CalendarEvent] {
        events.filter { event in
            guard event.status != .cancelled, !event.declined else { return false }
            return (event.end > start || (event.end == event.start && event.start >= start)) && event.start < end
        }
        .sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            return (a.start, a.title) < (b.start, b.title)
        }
    }

    static func openMatters(_ matters: [ProactiveMatter], excluding kinds: Set<ProactiveMatterKind>) -> [ProactiveMatter] {
        matters.filter { !kinds.contains($0.kind) && ($0.state == .open || $0.state == .offered) }
            .sorted { ($0.updatedAt, $0.title) > ($1.updatedAt, $1.title) }
    }

    static func eventLine(_ event: CalendarEvent, _ f: Formatters, withDay: Bool) -> String {
        let title = RoutineText.cleanLine(event.title, fallback: f.de ? "(Ohne Titel)" : "(No title)")
        let time = event.allDay ? (f.de ? "Ganztägig" : "All day") : f.time.string(from: event.start)
        return withDay ? "• \(f.day.string(from: event.start)) \(time) \(title)" : "• \(time) \(title)"
    }

    static func more(_ extra: Int, de: Bool) -> String {
        de ? "… und \(extra) weitere" : "… and \(extra) more"
    }

    static func count(_ n: Int, de: Bool, one: (String, String), many: (String, String)) -> String {
        n == 1 ? (de ? one.0 : one.1) : "\(n) " + (de ? many.0 : many.1)
    }
}

// MARK: - Evening Preview

/// Tomorrow's appointments, what is still due today and open items. Quiet when tomorrow is empty and nothing is open.
public enum EveningPreviewBuilder {
    public static func matterKey(for dayKey: String) -> String { "evening-preview:\(dayKey)" }

    public static func draft(_ input: RoutineDigestInput) -> ProactiveMatterDraft? {
        let calendar = input.calendar
        let de = RoutineText.resolvedGerman(input.language, calendar: calendar)
        let todayStart = calendar.startOfDay(for: input.now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart),
              let dayAfter = calendar.date(byAdding: .day, value: 2, to: todayStart)
        else { return nil }
        let events = RoutineDigestFormat.activeEvents(input.events, from: tomorrow, to: dayAfter)
        let due = input.reminders.filter { ($0.due ?? .distantFuture) < tomorrow }
            .sorted { (($0.due ?? .distantFuture), $0.title) < (($1.due ?? .distantFuture), $1.title) }
        let matters = RoutineDigestFormat.openMatters(input.openMatters, excluding: [.morningBrief])
            .filter { !$0.matterKey.hasPrefix("evening-preview:") }
        guard !events.isEmpty || !due.isEmpty || !matters.isEmpty else { return nil }

        let f = RoutineDigestFormat.formatters(de: de, calendar: calendar)
        let dayKey = ProactiveMatterStore.dayKey(for: tomorrow, calendar: calendar)
        let title = (de ? "Morgen · " : "Tomorrow · ") + f.day.string(from: tomorrow)
        var sections: [String] = []
        if events.isEmpty {
            sections.append(de ? "Morgen stehen keine Termine an." : "No appointments tomorrow.")
        } else {
            var lines = [RoutineDigestFormat.count(events.count, de: de, one: ("1 Termin morgen", "1 appointment tomorrow"),
                                                   many: ("Termine morgen", "appointments tomorrow"))]
            lines += events.prefix(RoutineDigestFormat.maxListed).map { RoutineDigestFormat.eventLine($0, f, withDay: false) }
            if events.count > RoutineDigestFormat.maxListed { lines.append(RoutineDigestFormat.more(events.count - RoutineDigestFormat.maxListed, de: de)) }
            sections.append(lines.joined(separator: "\n"))
        }
        if !due.isEmpty {
            var lines = [RoutineDigestFormat.count(due.count, de: de, one: ("1 Erinnerung heute noch offen", "1 reminder still open today"),
                                                   many: ("Erinnerungen heute noch offen", "reminders still open today"))]
            for reminder in due.prefix(RoutineDigestFormat.maxListed) {
                let name = RoutineText.cleanLine(reminder.title, fallback: de ? "(Ohne Titel)" : "(No title)")
                let overdue = (reminder.due ?? .distantFuture) < todayStart
                lines.append("• \(name)" + (overdue ? (de ? " (überfällig)" : " (overdue)") : ""))
            }
            if due.count > RoutineDigestFormat.maxListed { lines.append(RoutineDigestFormat.more(due.count - RoutineDigestFormat.maxListed, de: de)) }
            sections.append(lines.joined(separator: "\n"))
        }
        if !matters.isEmpty {
            var lines = [RoutineDigestFormat.count(matters.count, de: de, one: ("1 offener Hinweis", "1 open item"),
                                                   many: ("offene Hinweise", "open items"))]
            lines += matters.prefix(RoutineDigestFormat.maxListed).map { "• " + RoutineText.cleanLine($0.title, fallback: de ? "Hinweis" : "Item") }
            if matters.count > RoutineDigestFormat.maxListed { lines.append(RoutineDigestFormat.more(matters.count - RoutineDigestFormat.maxListed, de: de)) }
            sections.append(lines.joined(separator: "\n"))
        }
        let summary = sections.joined(separator: "\n\n")
        return ProactiveMatterDraft(
            kind: .routine, matterKey: matterKey(for: dayKey), sourceRef: "routine:evening-preview:\(dayKey)",
            sourceVersion: RoutineText.sha256([dayKey, title, summary].joined(separator: "\n---\n")),
            title: title, summary: summary,
            preparedPrompt: de
                ? "Gib mir eine kurze, ruhige Vorschau auf morgen: meine Termine, was heute noch offen ist und was ich vorbereiten sollte."
                : "Give me a short, calm preview of tomorrow: my appointments, what is still open today, and anything I should prepare.")
    }
}

// MARK: - Weekly Review

/// The next seven days: appointments per day, the busiest day, overlaps, overdue and due reminders, open items.
/// Quiet for a completely empty week.
public enum WeeklyReviewBuilder {
    public struct Overlap: Sendable, Equatable {
        public let first: CalendarEvent
        public let second: CalendarEvent
    }

    public static func matterKey(for weekStartDayKey: String) -> String { "weekly-review:\(weekStartDayKey)" }

    /// Overlapping confirmed (not tentative, cancelled or declined) timed appointments, in start order.
    public static func overlaps(_ events: [CalendarEvent]) -> [Overlap] {
        let timed = events.filter { !$0.allDay && $0.status != .cancelled && $0.status != .tentative && !$0.declined && $0.end > $0.start }
            .sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
        var result: [Overlap] = []
        for (i, a) in timed.enumerated() {
            for b in timed[(i + 1)...] {
                guard b.start < a.end else { break }
                result.append(Overlap(first: a, second: b))
            }
        }
        return result
    }

    public static func draft(_ input: RoutineDigestInput) -> ProactiveMatterDraft? {
        let calendar = input.calendar
        let de = RoutineText.resolvedGerman(input.language, calendar: calendar)
        let start = calendar.startOfDay(for: input.now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return nil }
        let events = RoutineDigestFormat.activeEvents(input.events, from: start, to: end)
        let due = input.reminders.filter { ($0.due ?? .distantFuture) < end }
        let overdue = due.filter { ($0.due ?? .distantFuture) < start }
            .sorted { (($0.due ?? .distantFuture), $0.title) < (($1.due ?? .distantFuture), $1.title) }
        let matters = RoutineDigestFormat.openMatters(input.openMatters, excluding: [.morningBrief])
            .filter { !$0.matterKey.hasPrefix("weekly-review:") }
        guard !events.isEmpty || !due.isEmpty || !matters.isEmpty else { return nil }

        let f = RoutineDigestFormat.formatters(de: de, calendar: calendar)
        let weekKey = ProactiveMatterStore.dayKey(for: start, calendar: calendar)
        let title = (de ? "Wochenüberblick · ab " : "Weekly Review · from ") + f.day.string(from: start)
        var sections: [String] = []

        if events.isEmpty {
            sections.append(de ? "Keine Termine in den nächsten sieben Tagen." : "No appointments in the next seven days.")
        } else {
            var lines = [RoutineDigestFormat.count(events.count, de: de, one: ("1 Termin in 7 Tagen", "1 appointment in 7 days"),
                                                   many: ("Termine in 7 Tagen", "appointments in 7 days"))]
            // Appointments per day (by start day, within the week).
            var perDay: [(day: Date, count: Int)] = []
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
                let n = events.filter { calendar.isDate(max($0.start, start), inSameDayAs: day) }.count
                if n > 0 { perDay.append((day, n)) }
            }
            if let busiest = perDay.max(by: { $0.count < $1.count || ($0.count == $1.count && $0.day > $1.day) }) {
                lines.append((de ? "Vollster Tag: " : "Busiest day: ") + "\(f.day.string(from: busiest.day)) (\(busiest.count))")
            }
            lines.append(perDay.map { "\(f.day.string(from: $0.day)): \($0.count)" }.joined(separator: " · "))
            sections.append(lines.joined(separator: "\n"))

            let clashes = overlaps(events)
            if !clashes.isEmpty {
                var clashLines = [RoutineDigestFormat.count(clashes.count, de: de, one: ("1 Überschneidung", "1 overlap"),
                                                            many: ("Überschneidungen", "overlaps"))]
                for clash in clashes.prefix(3) {
                    let a = RoutineText.cleanLine(clash.first.title, fallback: de ? "(Ohne Titel)" : "(No title)", limit: 60)
                    let b = RoutineText.cleanLine(clash.second.title, fallback: de ? "(Ohne Titel)" : "(No title)", limit: 60)
                    clashLines.append("• \(f.day.string(from: clash.second.start)) \(f.time.string(from: clash.second.start)): \(a) ↔ \(b)")
                }
                if clashes.count > 3 { clashLines.append(RoutineDigestFormat.more(clashes.count - 3, de: de)) }
                sections.append(clashLines.joined(separator: "\n"))
            }
        }
        if !due.isEmpty {
            var lines = [RoutineDigestFormat.count(due.count, de: de, one: ("1 fällige Erinnerung", "1 due reminder"),
                                                   many: ("fällige Erinnerungen", "due reminders"))]
            if !overdue.isEmpty {
                lines.append(de ? "davon \(overdue.count) überfällig" : "\(overdue.count) of them overdue")
                lines += overdue.prefix(RoutineDigestFormat.maxListed).map {
                    "• " + RoutineText.cleanLine($0.title, fallback: de ? "(Ohne Titel)" : "(No title)") + (de ? " (überfällig)" : " (overdue)")
                }
                if overdue.count > RoutineDigestFormat.maxListed { lines.append(RoutineDigestFormat.more(overdue.count - RoutineDigestFormat.maxListed, de: de)) }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        if !matters.isEmpty {
            sections.append(RoutineDigestFormat.count(matters.count, de: de, one: ("1 offener Hinweis", "1 open item"),
                                                      many: ("offene Hinweise", "open items")))
        }
        let summary = sections.joined(separator: "\n\n")
        return ProactiveMatterDraft(
            kind: .routine, matterKey: matterKey(for: weekKey), sourceRef: "routine:weekly-review:\(weekKey)",
            sourceVersion: RoutineText.sha256([weekKey, title, summary].joined(separator: "\n---\n")),
            title: title, summary: summary,
            preparedPrompt: de
                ? "Geh mit mir ruhig durch die nächsten sieben Tage: volle Tage, Überschneidungen und was überfällig ist."
                : "Walk me calmly through the next seven days: busy days, overlaps, and what is overdue.")
    }
}

// MARK: - Calendar Radar

public struct CalendarRadarEvaluation: Sendable, Equatable {
    /// Save this for the next run (`ProactiveRoutineStore.saveSnapshot`).
    public let nextSnapshotJSON: String
    /// SHA-256 of the watched appointments only.
    public let inputHash: String
    /// `nil`: baseline, unchanged, or nothing worth saying.
    public let draft: ProactiveMatterDraft?
}

/// Compares the appointments of the next hours against the last snapshot: new ones, moved starts, changed places.
/// The first run only records a baseline; an unchanged hash stays quiet.
public enum CalendarRadarBuilder {
    static let maxListedChanges = 5

    struct Entry: Codable, Equatable {
        var identity: String
        var title: String
        var start: Double
        var end: Double
        var allDay: Bool
        var location: String?
    }

    struct Snapshot: Codable, Equatable {
        var hash: String
        var windowEnd: Double
        var events: [Entry]
    }

    public enum Change: Sendable, Equatable {
        case added(title: String, start: Date, allDay: Bool)
        case moved(title: String, from: Date, to: Date, allDay: Bool)
        case placeChanged(title: String, start: Date, location: String?)
    }

    public static func matterKey(for dayKey: String) -> String { "calendar-radar:\(dayKey)" }

    public static func evaluate(events: [CalendarEvent], previousSnapshotJSON: String?, now: Date,
                                lookaheadHours: Int = 48, calendar: Calendar = .autoupdatingCurrent,
                                language: String? = nil) -> CalendarRadarEvaluation {
        let hours = min(max(lookaheadHours, ProactiveTrigger.lookaheadRange.lowerBound), ProactiveTrigger.lookaheadRange.upperBound)
        let windowEnd = now.addingTimeInterval(TimeInterval(hours) * 3600)
        let entries = events
            .filter { $0.status != .cancelled && !$0.declined && $0.end > now && $0.start < windowEnd }
            .map { event in
                Entry(identity: identity(event, calendar: calendar), title: RoutineText.cleanLine(event.title, fallback: "", limit: 100),
                      start: event.start.timeIntervalSince1970, end: event.end.timeIntervalSince1970, allDay: event.allDay,
                      location: event.location.map { RoutineText.cleanLine($0, fallback: "", limit: 100) }.flatMap { $0.isEmpty ? nil : $0 })
            }
            .sorted { ($0.identity, $0.start) < ($1.identity, $1.start) }
        let hash = RoutineText.sha256(canonical(entries))
        let snapshot = Snapshot(hash: hash, windowEnd: windowEnd.timeIntervalSince1970, events: entries)
        let nextJSON = encode(snapshot)

        guard let previousJSON = previousSnapshotJSON,
              let previous = try? JSONDecoder().decode(Snapshot.self, from: Data(previousJSON.utf8))
        else {
            // First run (or an unreadable snapshot): baseline only, never a burst of "new" appointments.
            return CalendarRadarEvaluation(nextSnapshotJSON: nextJSON, inputHash: hash, draft: nil)
        }
        guard previous.hash != hash else {
            return CalendarRadarEvaluation(nextSnapshotJSON: nextJSON, inputHash: hash, draft: nil)
        }

        let old = Dictionary(previous.events.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        var changes: [Change] = []
        for entry in entries.sorted(by: { ($0.start, $0.title) < ($1.start, $1.title) }) {
            if let before = old[entry.identity] {
                if before.start != entry.start {
                    changes.append(.moved(title: entry.title, from: Date(timeIntervalSince1970: before.start),
                                          to: Date(timeIntervalSince1970: entry.start), allDay: entry.allDay))
                } else if before.location != entry.location {
                    changes.append(.placeChanged(title: entry.title, start: Date(timeIntervalSince1970: entry.start), location: entry.location))
                }
            } else if entry.start < previous.windowEnd {
                // Only appointments the last look would have seen count as new; the rest just moved into the window.
                changes.append(.added(title: entry.title, start: Date(timeIntervalSince1970: entry.start), allDay: entry.allDay))
            }
        }
        guard !changes.isEmpty else {
            return CalendarRadarEvaluation(nextSnapshotJSON: nextJSON, inputHash: hash, draft: nil)
        }

        let de = RoutineText.resolvedGerman(language, calendar: calendar)
        let f = RoutineDigestFormat.formatters(de: de, calendar: calendar)
        let noTitle = de ? "(Ohne Titel)" : "(No title)"
        func when(_ date: Date, _ allDay: Bool) -> String {
            f.day.string(from: date) + " " + (allDay ? (de ? "ganztägig" : "all day") : f.time.string(from: date))
        }
        var lines: [String] = []
        for change in changes.prefix(maxListedChanges) {
            switch change {
            case .added(let title, let start, let allDay):
                lines.append((de ? "• Neu: " : "• New: ") + "\(when(start, allDay)) \(title.isEmpty ? noTitle : title)")
            case .moved(let title, let from, let to, let allDay):
                lines.append((de ? "• Verschoben: " : "• Moved: ") + "\(title.isEmpty ? noTitle : title) → \(when(to, allDay))"
                             + (de ? " (vorher \(when(from, allDay)))" : " (was \(when(from, allDay)))"))
            case .placeChanged(let title, let start, let location):
                let place = location ?? (de ? "kein Ort" : "no place")
                lines.append((de ? "• Neuer Ort: " : "• New place: ") + "\(title.isEmpty ? noTitle : title), \(when(start, false)): \(place)")
            }
        }
        if changes.count > maxListedChanges { lines.append(RoutineDigestFormat.more(changes.count - maxListedChanges, de: de)) }
        let dayKey = ProactiveMatterStore.dayKey(for: now, calendar: calendar)
        let title = changes.count == 1
            ? (de ? "1 Termin hat sich geändert" : "1 appointment changed")
            : (de ? "\(changes.count) Termine haben sich geändert" : "\(changes.count) appointments changed")
        let draft = ProactiveMatterDraft(
            kind: .calendarChange, matterKey: matterKey(for: dayKey), sourceRef: "routine:calendar-radar",
            sourceVersion: hash, title: title, summary: lines.joined(separator: "\n"),
            preparedPrompt: de
                ? "Schau dir die geänderten Termine in meinem Kalender an und sag mir kurz, was das für meine nächsten Tage bedeutet."
                : "Look at the appointments that changed in my calendar and tell me briefly what that means for my next days.")
        return CalendarRadarEvaluation(nextSnapshotJSON: nextJSON, inputHash: hash, draft: draft)
    }

    /// A one-off appointment is its ID; an occurrence of a series is the ID and its day (moving within the day is a move).
    private static func identity(_ event: CalendarEvent, calendar: Calendar) -> String {
        event.recurring ? event.id + "|" + ProactiveMatterStore.dayKey(for: event.start, calendar: calendar) : event.id
    }

    private static func canonical(_ entries: [Entry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(entries)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func encode(_ snapshot: Snapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(snapshot)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

// MARK: - Reminder Radar

public struct ReminderRadarEvaluation: Sendable, Equatable {
    public let inputHash: String
    public let draft: ProactiveMatterDraft?
}

/// Overdue and due-today reminders, compared against the last hash. Quiet when none or unchanged.
public enum ReminderRadarBuilder {
    public static func matterKey(for dayKey: String) -> String { "reminder-due:\(dayKey)" }

    public static func evaluate(reminders: [ReminderItem], previousHash: String?, now: Date,
                                calendar: Calendar = .autoupdatingCurrent, language: String? = nil) -> ReminderRadarEvaluation {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86_400)
        let due = reminders.filter { ($0.due ?? .distantFuture) < tomorrow }
            .sorted { (($0.due ?? .distantFuture), $0.title) < (($1.due ?? .distantFuture), $1.title) }
        let seed = due.map { [$0.id ?? "", $0.title, $0.list, String($0.due?.timeIntervalSince1970 ?? 0)].joined(separator: "\u{1F}") }
            .joined(separator: "\u{1E}")
        let hash = RoutineText.sha256(ProactiveMatterStore.dayKey(for: now, calendar: calendar) + "\u{1D}" + seed)
        guard !due.isEmpty, hash != previousHash else {
            return ReminderRadarEvaluation(inputHash: hash, draft: nil)
        }
        let de = RoutineText.resolvedGerman(language, calendar: calendar)
        let overdue = due.filter { ($0.due ?? .distantFuture) < todayStart }
        let today = due.filter { ($0.due ?? .distantFuture) >= todayStart }
        let noTitle = de ? "(Ohne Titel)" : "(No title)"
        var sections: [String] = []
        if !overdue.isEmpty {
            var lines = [RoutineDigestFormat.count(overdue.count, de: de, one: ("1 überfällig", "1 overdue"), many: ("überfällig", "overdue"))]
            lines += overdue.prefix(RoutineDigestFormat.maxListed).map { "• " + RoutineText.cleanLine($0.title, fallback: noTitle) }
            if overdue.count > RoutineDigestFormat.maxListed { lines.append(RoutineDigestFormat.more(overdue.count - RoutineDigestFormat.maxListed, de: de)) }
            sections.append(lines.joined(separator: "\n"))
        }
        if !today.isEmpty {
            var lines = [RoutineDigestFormat.count(today.count, de: de, one: ("1 heute fällig", "1 due today"), many: ("heute fällig", "due today"))]
            lines += today.prefix(RoutineDigestFormat.maxListed).map { "• " + RoutineText.cleanLine($0.title, fallback: noTitle) }
            if today.count > RoutineDigestFormat.maxListed { lines.append(RoutineDigestFormat.more(today.count - RoutineDigestFormat.maxListed, de: de)) }
            sections.append(lines.joined(separator: "\n"))
        }
        let dayKey = ProactiveMatterStore.dayKey(for: now, calendar: calendar)
        let title = due.count == 1
            ? (de ? "1 Erinnerung ist fällig" : "1 reminder is due")
            : (de ? "\(due.count) Erinnerungen sind fällig" : "\(due.count) reminders are due")
        let draft = ProactiveMatterDraft(
            kind: .reminderDue, matterKey: matterKey(for: dayKey), sourceRef: "routine:reminder-radar",
            sourceVersion: hash, title: title, summary: sections.joined(separator: "\n\n"),
            preparedPrompt: de
                ? "Geh mit mir meine fälligen und überfälligen Erinnerungen durch und hilf mir zu entscheiden, was zuerst dran ist."
                : "Go through my due and overdue reminders with me and help me decide what to do first.")
        return ReminderRadarEvaluation(inputHash: hash, draft: draft)
    }
}

// MARK: - AI output

/// Reads a read-only routine run's answer in its strict schema:
/// `STATUS: NOTHING_NEW`, or `STATUS: READY` with `TITLE:` and `SUMMARY:` (the summary may span lines).
/// Empty answers, refusals and anything off-schema fall back to `.nothingNew`: a routine stays quiet when unsure.
public enum RoutineAIOutputParser {
    public enum Result: Sendable, Equatable {
        case nothingNew
        case prepared(title: String, summary: String)
    }

    static let maxTitle = 120
    static let maxSummary = 2000

    public static func parse(_ raw: String) -> Result {
        var text = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !RoutineText.isUnsafeScalar($0) || $0 == "\n" || $0 == "\t" }))
        text = text.replacingOccurrences(of: "\r", with: "")
        // Reasoning blocks from local models are never part of the answer.
        text = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let statusIndex = lines.firstIndex(where: { $0.uppercased().hasPrefix("STATUS:") }) else { return .nothingNew }
        let status = value(lines[statusIndex]).uppercased().replacingOccurrences(of: " ", with: "_")
        guard status == "READY" else { return .nothingNew }

        var title = ""
        var summaryLines: [String] = []
        var inSummary = false
        for line in lines[(statusIndex + 1)...] {
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE:") { title = value(line); inSummary = false; continue }
            if upper.hasPrefix("SUMMARY:") { summaryLines = [value(line)]; inSummary = true; continue }
            if upper.hasPrefix("STATUS:") { break }
            if inSummary { summaryLines.append(line) }
        }
        title = RoutineText.cleanLine(title, fallback: "", limit: maxTitle)
        let summary = String(summaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxSummary))
        guard !title.isEmpty, !summary.isEmpty, !isRefusal(title), !isRefusal(summary) else { return .nothingNew }
        return .prepared(title: title, summary: summary)
    }

    private static func value(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private static func isRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let starts = ["i can't", "i cannot", "i can not", "i'm sorry", "i am sorry", "sorry", "as an ai", "i'm unable", "i am unable",
                      "i won't", "ich kann nicht", "ich kann das nicht", "ich kann leider", "es tut mir leid", "entschuldigung", "leider kann ich"]
        return starts.contains { lower.hasPrefix($0) }
    }
}
