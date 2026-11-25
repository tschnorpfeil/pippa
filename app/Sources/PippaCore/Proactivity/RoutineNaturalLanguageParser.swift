import Foundation

/// A routine as understood from one sentence, for the person to confirm before anything is saved.
public struct ParsedRoutineDraft: Sendable, Equatable {
    public enum Confidence: String, Sendable, Equatable {
        /// Time and task were stated explicitly.
        case high
        /// Something was filled in from a default (for example the time of "every morning").
        case medium
    }

    public let title: String
    public let instruction: String
    public let template: ProactiveRoutineTemplate
    public let trigger: ProactiveTrigger
    public let humanSummary: String
    public let confidence: Confidence

    public init(title: String, instruction: String, template: ProactiveRoutineTemplate, trigger: ProactiveTrigger,
                humanSummary: String, confidence: Confidence) {
        self.title = title; self.instruction = instruction; self.template = template; self.trigger = trigger
        self.humanSummary = humanSummary; self.confidence = confidence
    }
}

/// Deterministic English and German parser for routine requests ("every weekday at 8 …", "jeden Montag um 9 …",
/// "when a new file arrives …", 5-field cron). 0 tokens. Ordinary questions are never routines.
public enum RoutineNaturalLanguageParser {
    // MARK: Public API

    /// The routine `raw` describes, or `nil` when it describes none (or a one-off in the past).
    public static func parse(_ raw: String, now: Date = Date(), language: String = "en",
                             calendar: Calendar = .autoupdatingCurrent) -> ParsedRoutineDraft? {
        let text = normalize(raw)
        guard !text.isEmpty, text.count <= 2000 else { return nil }
        guard let match = matchTrigger(text, now: now, calendar: calendar, allowOnce: true) else { return nil }
        let task = cleanTask(text, removing: match.spans)
        let template = match.template ?? detectTemplate(text)
        let de = RoutineText.isGerman(language)
        let instruction: String
        let title: String
        if let defaults = templateDefaults(template, de: de) {
            instruction = task.isEmpty ? defaults.instruction : capitalizedFirst(task)
            title = defaults.title
        } else {
            guard !task.isEmpty else { return nil }
            instruction = capitalizedFirst(task)
            title = makeTitle(task)
        }
        let trigger = match.trigger.normalized
        return ParsedRoutineDraft(title: title, instruction: instruction, template: template, trigger: trigger,
                                  humanSummary: trigger.humanSummary(language: language, calendar: calendar),
                                  confidence: match.usedDefault ? .medium : .high)
    }

    /// Strict: `true` only for recurring, scheduled or reactive wording ("every …", "weekdays", "jeden …", "täglich",
    /// "alle 2 Stunden", "whenever a new file …", "am 1. jeden Monats") with an actual task or built-in template,
    /// or a valid 5-field cron expression with a task. Questions ("What's on my calendar tomorrow?") and one-off
    /// reminders ("remind me tomorrow at 9") are `false`.
    public static func looksLikeRoutineRequest(_ raw: String) -> Bool {
        let text = normalize(raw)
        guard !text.isEmpty, text.count <= 2000 else { return false }
        if isPlainQuestion(text) { return false }
        guard let match = matchTrigger(text, now: Date(), calendar: .autoupdatingCurrent, allowOnce: false) else { return false }
        let task = cleanTask(text, removing: match.spans)
        let template = match.template ?? detectTemplate(text)
        return !task.isEmpty || templateDefaults(template, de: false) != nil
    }

    /// Common 5-field cron patterns (`min hour dom mon dow`): `0 8 * * *`, `30 8 * * 1-5`, `0 9 * * 1,3,5`,
    /// `0 9 1 * *`, `*/30 * * * *`, `0 */2 * * *`. Anything else (months, mixed day fields, steps on days) is `nil`.
    public static func parseCron(_ expression: String) -> ProactiveSchedule? {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { return nil }
        let (minute, hour, dom, month, dow) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        guard month == "*" else { return nil }

        // Intervals: */N minutes, or */N hours (the minute is ignored), or every hour / minute.
        if dom == "*", dow == "*" {
            if minute.hasPrefix("*/"), hour == "*", let n = Int(minute.dropFirst(2)), (1...59).contains(n) {
                return .interval(minutes: n)
            }
            if minute == "*", hour == "*" { return .interval(minutes: 1) }
            if let m = Int(minute), (0...59).contains(m) {
                if hour == "*" { return .interval(minutes: 60) }
                if hour.hasPrefix("*/"), let n = Int(hour.dropFirst(2)), (1...23).contains(n) { return .interval(minutes: n * 60) }
            }
        }
        guard let m = Int(minute), (0...59).contains(m), let h = Int(hour), (0...23).contains(h) else { return nil }
        switch (dom, dow) {
        case ("*", "*"):
            return .daily(hour: h, minute: m)
        case ("*", _):
            guard let days = cronWeekdays(dow) else { return nil }
            if days == ProactiveSchedule.workWeek { return .weekdays(hour: h, minute: m) }
            if days == Array(1...7) { return .daily(hour: h, minute: m) }
            return .weekly(weekdays: days, hour: h, minute: m)
        case (_, "*"):
            guard let d = Int(dom), (1...31).contains(d) else { return nil }
            return .monthly(day: d, hour: h, minute: m)
        default:
            return nil
        }
    }

    // MARK: Matching

    private struct TriggerMatch {
        var trigger: ProactiveTrigger
        var template: ProactiveRoutineTemplate?
        var usedDefault: Bool
        var spans: [Range<String.Index>]
    }

    private static func matchTrigger(_ text: String, now: Date, calendar: Calendar, allowOnce: Bool) -> TriggerMatch? {
        // 1. Cron: the first five tokens.
        let tokens = text.split(whereSeparator: \.isWhitespace)
        if tokens.count >= 5 {
            let head = tokens.prefix(5).joined(separator: " ")
            if tokens.prefix(5).allSatisfy({ $0.allSatisfy { "0123456789*/,-".contains($0) } }), let schedule = parseCron(head),
               let range = firstRange(#"^(?:\S+\s+){4}\S+"#, in: text) {
                return TriggerMatch(trigger: .schedule(schedule), template: nil, usedDefault: false, spans: [range])
            }
        }

        let time = extractTime(text)
        func schedule(_ s: ProactiveSchedule, _ span: Range<String.Index>, defaulted: Bool) -> TriggerMatch {
            TriggerMatch(trigger: .schedule(s), template: nil, usedDefault: defaulted, spans: [span] + (time.map { [$0.span] } ?? []))
        }
        let hm = (hour: time?.hour, minute: time?.minute ?? 0)

        // 2. Intervals.
        if let match = firstMatch(#"\b(?:every|alle)\s+(\d{1,4})\s*(hours?|hrs?|h|stunden|stunde|std\.?|minutes?|mins?|minuten|min\.?)(?=\s|$|[.,!;:])"#, in: text),
           let n = Int(match.groups[0] ?? "") {
            let unit = (match.groups[1] ?? "").lowercased()
            let minutes = unit.hasPrefix("h") || unit.hasPrefix("st") ? n * 60 : n
            return TriggerMatch(trigger: .schedule(.interval(minutes: minutes)), template: nil, usedDefault: false, spans: [match.range])
        }
        if let range = firstRange(#"\b(?:hourly|every hour|each hour|stündlich|jede stunde)\b"#, in: text) {
            return TriggerMatch(trigger: .schedule(.interval(minutes: 60)), template: nil, usedDefault: false, spans: [range])
        }
        if let range = firstRange(#"\b(?:every half hour|every half an hour|alle halbe stunde|jede halbe stunde)\b"#, in: text) {
            return TriggerMatch(trigger: .schedule(.interval(minutes: 30)), template: nil, usedDefault: false, spans: [range])
        }

        // 3. Weekdays (before single weekday names: "monday to friday" names Monday too).
        if let range = firstRange(#"\b(?:on weekdays|every weekday|each weekday|weekdays|monday (?:to|through|-) friday|mon-fri|werktags|an werktagen|jeden werktag|unter der woche|montag bis freitag|mo-fr)\b"#, in: text) {
            return schedule(.weekdays(hour: hm.hour ?? 8, minute: hm.minute), range, defaulted: hm.hour == nil)
        }

        // 4. Named weekdays with a recurrence cue.
        if let weekly = weeklyMatch(text) {
            return schedule(.weekly(weekdays: weekly.days, hour: hm.hour ?? 9, minute: hm.minute), weekly.span, defaulted: hm.hour == nil)
        }

        // 5. Monthly.
        if let range = firstRange(#"\b(?:monthly|every month|each month|monatlich|jeden monat)\b"#, in: text) {
            var day = 1
            var spans = [range]
            if let dayMatch = firstMatch(#"\b(?:on the\s+(\d{1,2})(?:st|nd|rd|th)?(?!\d)|am\s+(\d{1,2})\.(?!\d))"#, in: text),
               let value = Int(dayMatch.groups[0] ?? dayMatch.groups[1] ?? ""), (1...31).contains(value) {
                day = value
                spans.append(dayMatch.range)
            }
            var match = schedule(.monthly(day: day, hour: hm.hour ?? 9, minute: hm.minute), range, defaulted: hm.hour == nil)
            match.spans += spans.dropFirst()
            return match
        }

        if let match = firstMatch(#"\b(?:on the|every|each)\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s+(?:of\s+)?(?:every|each|the)\s+month)?\b"#, in: text),
           let day = Int(match.groups[0] ?? ""), (1...31).contains(day),
           text[match.range].lowercased().contains("month") || text[match.range].lowercased().hasPrefix("on the") {
            return schedule(.monthly(day: day, hour: hm.hour ?? 9, minute: hm.minute), match.range, defaulted: hm.hour == nil)
        }
        if let match = firstMatch(#"\bam\s+(\d{1,2})\.\s*(?:eines\s+)?(?:jeden|jedes)\s+monats\b"#, in: text),
           let day = Int(match.groups[0] ?? ""), (1...31).contains(day) {
            return schedule(.monthly(day: day, hour: hm.hour ?? 9, minute: hm.minute), match.range, defaulted: hm.hour == nil)
        }
        // 6. Every morning / evening.
        if let range = firstRange(#"\b(?:every morning|each morning|every single morning|jeden morgen|jeden früh|immer morgens)\b"#, in: text) {
            return schedule(.daily(hour: hm.hour ?? 8, minute: hm.minute), range, defaulted: hm.hour == nil)
        }
        if let range = firstRange(#"\b(?:every evening|each evening|every night|each night|jeden abend|immer abends)\b"#, in: text) {
            var hour = hm.hour ?? 18
            // "every evening at 6" / "jeden Abend um 6 Uhr" means 18:00.
            if let explicit = time, explicit.meridiem == nil, explicit.hour < 12, explicit.hour >= 1 { hour = explicit.hour + 12 }
            return schedule(.daily(hour: hour, minute: hm.minute), range, defaulted: hm.hour == nil)
        }

        // 7. Daily.
        if let range = firstRange(#"\b(?:every day|each day|every single day|daily|jeden tag|täglich|alle tage)\b"#, in: text) {
            return schedule(.daily(hour: hm.hour ?? 9, minute: hm.minute), range, defaulted: hm.hour == nil)
        }

        // 8. Weekly without a named day: Mondays.
        if let range = firstRange(#"\b(?:weekly|every week|each week|wöchentlich|jede woche)\b"#, in: text) {
            return schedule(.weekly(weekdays: [2], hour: hm.hour ?? 9, minute: hm.minute), range, defaulted: hm.hour == nil)
        }

        // 9. Reactive watchers (checked after explicit schedules so e.g. "Every Friday at 9 check overdue reminders" keeps Friday 09:00).
        if let prepMatch = firstMatch(#"\b(?:(\d{1,3})\s*(?:minutes?|mins?|minuten|min\.?)\s+)?(?:before\s+(?:every|each|my|an?)\s+(?:meeting|meetings|appointment|appointments)|vor\s+(?:jedem|meinen|einem)\s+(?:termin|terminen|meeting|meetings))\b"#, in: text) {
            let lead = prepMatch.groups[0].flatMap(Int.init) ?? 30
            return TriggerMatch(trigger: .upcomingMeeting(leadMinutes: lead), template: .meetingPrep, usedDefault: prepMatch.groups[0] == nil, spans: [prepMatch.range])
        }
        for (pattern, template) in reactivePatterns {
            if let range = firstRange(pattern, in: text) {
                let trigger: ProactiveTrigger
                switch template {
                case .folderWatch: trigger = .folder(path: "", bookmark: nil)
                case .calendarRadar: trigger = .calendarChange(lookaheadHours: 48)
                default: trigger = .reminderDue
                }
                return TriggerMatch(trigger: trigger, template: template, usedDefault: false, spans: [range])
            }
        }

        // 10. One-offs: only when parsing an explicit routine, never for `looksLikeRoutineRequest`.
        guard allowOnce else { return nil }
        if let match = firstMatch(#"\bin\s+(\d{1,4})\s*(hours?|hrs?|stunden?|minutes?|mins?|minuten?)\b"#, in: text),
           let n = Int(match.groups[0] ?? ""), n > 0 {
            let unit = (match.groups[1] ?? "").lowercased()
            let seconds = TimeInterval(unit.hasPrefix("h") || unit.hasPrefix("st") ? n * 3600 : n * 60)
            return TriggerMatch(trigger: .schedule(.once(at: now.addingTimeInterval(seconds))), template: nil, usedDefault: false,
                                spans: [match.range])
        }
        if let range = firstRange(#"\b(?:tomorrow|morgen|today|tonight|heute(?: abend)?)\b"#, in: text) {
            let word = String(text[range]).lowercased()
            let dayOffset = word == "tomorrow" || word == "morgen" ? 1 : 0
            var hour = hm.hour ?? (word == "tonight" || word == "heute abend" ? 19 : 9)
            if (word == "tonight" || word == "heute abend"), let explicit = time, explicit.meridiem == nil, (1..<12).contains(explicit.hour) {
                hour = explicit.hour + 12
            }
            let today = calendar.startOfDay(for: now)
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  let at = calendar.date(bySettingHour: hour, minute: hm.minute, second: 0, of: day),
                  at > now
            else { return nil }
            return schedule(.once(at: at), range, defaulted: hm.hour == nil)
        }
        return nil
    }

    private static let reactivePatterns: [(String, ProactiveRoutineTemplate)] = [
        (#"\b(?:when(?:ever)?|if|each time|every time)\s+(?:a\s+|an\s+|any\s+)?new\s+(?:file|files|document|documents|download|downloads|pdf|pdfs)\b"#, .folderWatch),
        (#"\b(?:wenn|sobald|immer wenn|jedes mal wenn)\s+(?:eine\s+|ein\s+)?(?:neue|neuer|neues)\s+(?:datei|dateien|dokument|dokumente|download|downloads|pdf|pdfs)\b"#, .folderWatch),
        (#"\b(?:for|on)\s+(?:every|each)\s+new\s+(?:file|document|download)\b"#, .folderWatch),
        (#"\b(?:when(?:ever)?|if|watch(?:\s+for)?|alert(?:\s+me)?\s+(?:on|about|when)|notify(?:\s+me)?\s+(?:on|about|when))\s+(?:my\s+|a\s+|an\s+|the\s+)?(?:calendar|appointments?|meetings?|events?)\s+(?:changes?|change|moves?|is moved|are moved|gets? moved|is added|are added|gets? added)\b"#, .calendarRadar),
        (#"\b(?:watch(?:\s+for)?|alert(?:\s+me)?\s+(?:on|about)|notify(?:\s+me)?\s+(?:on|about)|track)\s+(?:my\s+)?calendar changes?\b"#, .calendarRadar),
        (#"\b(?:wenn|sobald|immer wenn)\s+sich\s+(?:ein\s+|mein\s+|meine\s+|der\s+|die\s+)?(?:termin|termine|kalender|meeting|meetings)\s+(?:ändert|ändern|verschiebt|verschieben)\b"#, .calendarRadar),
        (#"\b(?:melde|beobachte|achte auf|warne(?:\s+mich)?\s+bei)\s+(?:kalenderänderungen|terminänderungen|geänderte[n]?\s+termine[n]?)\b"#, .calendarRadar),
        (#"\b(?:kalenderänderungen|terminänderungen)\s+(?:melden|überwachen)\b"#, .calendarRadar),
        (#"\b(?:when(?:ever)?|if|alert(?:\s+me)?\s+when|notify(?:\s+me)?\s+when)\s+(?:a\s+|my\s+|any\s+)?reminders?\s+(?:is\s+|are\s+|comes?\s+|becomes?\s+|gets?\s+)?(?:due|overdue)\b"#, .reminderRadar),
        (#"\b(?:watch(?:\s+for)?|alert(?:\s+me)?\s+(?:on|about)|notify(?:\s+me)?\s+(?:on|about))\s+(?:due|overdue)\s+reminders?\b"#, .reminderRadar),
        (#"\b(?:wenn|sobald|immer wenn)\s+(?:eine\s+|meine\s+)?erinnerung(?:en)?\s+(?:fällig|überfällig)\b"#, .reminderRadar),
        (#"\b(?:fällige|überfällige)\s+erinnerung(?:en)?\s+(?:melden|überwachen)\b"#, .reminderRadar),
        (#"\b(?:melde|beobachte|achte auf)\s+(?:fällige|überfällige)\s+erinnerung(?:en)?\b"#, .reminderRadar),
    ]

    private static let weekdayWords: [(String, Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7),
        ("sonntag", 1), ("montag", 2), ("dienstag", 3), ("mittwoch", 4), ("donnerstag", 5), ("freitag", 6), ("samstag", 7), ("sonnabend", 7),
    ]

    /// "every Monday and Thursday", "on Mondays", "Mondays and Thursdays", "jeden Montag und Donnerstag", "montags und donnerstags".
    private static func weeklyMatch(_ text: String) -> (days: [Int], span: Range<String.Index>)? {
        let names = weekdayWords.map(\.0).joined(separator: "|")
        // A recurrence cue followed by a list of day names.
        let listed = #"\b(?:every|each|on|jeden|jede|immer)\s+((?:(?:\#(names))s?(?:\s*(?:,|and|und|&)\s*)?)+)"#
        let adverb = #"\b((?:(?:\#(names))s(?:\s*(?:,|and|und|&)\s*)?)+)\b"#
        var days: [Int] = []
        var span: Range<String.Index>?
        if let match = firstMatch(listed, in: text), let list = match.groups[0] {
            let isPlural = firstRange(#"(?:\#(names))s\b"#, in: list) != nil
            let cue = text[match.range].split(separator: " ").first.map { $0.lowercased() } ?? ""
            // "on Monday" alone is a one-off date; "on Mondays" recurs.
            if cue != "on" || isPlural {
                days = weekdayWords.filter { list.range(of: "\\b\($0.0)s?\\b", options: [.regularExpression, .caseInsensitive]) != nil }.map(\.1)
                span = match.range
            }
        }
        if days.isEmpty, let match = firstMatch(adverb, in: text), let list = match.groups[0] {
            days = weekdayWords.filter { list.range(of: "\\b\($0.0)s\\b", options: [.regularExpression, .caseInsensitive]) != nil }.map(\.1)
            span = match.range
        }
        guard !days.isEmpty, let span else { return nil }
        return (ProactiveSchedule.normalizedWeekdays(days), span)
    }

    // MARK: Time

    private struct TimeMatch {
        var hour: Int
        var minute: Int
        var meridiem: String?
        var span: Range<String.Index>
    }

    /// "at 8", "at 8:30", "at 8am", "at 6 pm", "um 8", "um 8:30 uhr", "um 18.30", "8am", "18 uhr".
    private static func extractTime(_ text: String) -> TimeMatch? {
        let patterns = [
            #"\b(?:at|um|gegen)\s+(\d{1,2})(?:[:.](\d{2}))?(?!\d)(?:\s*(am|pm|a\.m\.|p\.m\.|uhr|h\b))?"#,
            #"\b(\d{1,2})(?:[:.](\d{2}))?(?!\d)\s*(am|pm|a\.m\.|p\.m\.|uhr)\b"#,
            #"\b(\d{1,2})[:](\d{2})(?!\d)\b()"#,
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern, in: text), var hour = Int(match.groups[0] ?? "") else { continue }
            let minute = Int(match.groups[1] ?? "") ?? 0
            let suffix = (match.groups[2] ?? "").lowercased().replacingOccurrences(of: ".", with: "")
            var meridiem: String?
            if suffix == "am" || suffix == "pm" {
                guard (1...12).contains(hour) else { continue }
                meridiem = suffix
                if suffix == "pm", hour < 12 { hour += 12 }
                if suffix == "am", hour == 12 { hour = 0 }
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { continue }
            return TimeMatch(hour: hour, minute: minute, meridiem: meridiem, span: match.range)
        }
        return nil
    }

    // MARK: Task and templates

    private static func detectTemplate(_ text: String) -> ProactiveRoutineTemplate {
        let checks: [(String, ProactiveRoutineTemplate)] = [
            (#"\b(?:morning brief|morning briefing|daily brief|daily briefing|morgenbrief|morgen-briefing|tagesüberblick|überblick über (?:meinen|den) tag|overview of my day)\b"#, .morningBrief),
            (#"\b(?:weekly review|week ahead|review (?:of )?my week|wochenrückblick|wochenüberblick|wochenvorschau|überblick über (?:meine|die) woche)\b"#, .weeklyReview),
            (#"\b(?:evening preview|preview (?:of )?tomorrow|tomorrow'?s (?:appointments|schedule|agenda)|what'?s (?:on|coming up|happening) tomorrow|abendvorschau|vorschau auf morgen|was morgen ansteht)\b"#, .eveningPreview),
            (#"\b(?:follow up|follow-up|nachfassen|nachhaken)\b"#, .followUp),
        ]
        for (pattern, template) in checks where firstRange(pattern, in: text) != nil { return template }
        return .customCheck
    }

    private static func templateDefaults(_ template: ProactiveRoutineTemplate, de: Bool) -> (title: String, instruction: String)? {
        switch template {
        case .morningBrief:
            return (de ? "Morgenbrief" : "Morning Brief",
                    de ? "Ein ruhiger Überblick über die Termine, fälligen Erinnerungen und offenen Hinweise des Tages."
                       : "A calm overview of the day's appointments, due reminders and open items.")
        case .eveningPreview:
            return (de ? "Abendvorschau" : "Evening Preview",
                    de ? "Was morgen ansteht und was heute noch offen ist." : "What's on tomorrow and what is still open today.")
        case .weeklyReview:
            return (de ? "Wochenüberblick" : "Weekly Review",
                    de ? "Die nächsten sieben Tage mit Überschneidungen und überfälligen Erinnerungen."
                       : "The next seven days with overlaps and overdue reminders.")
        case .folderWatch:
            return (de ? "Ordner beobachten" : "Watch Folder",
                    de ? "Neue Dateien in diesem Ordner zum Ansehen vorbereiten." : "Prepare new files in this folder for a look.")
        case .calendarRadar:
            return (de ? "Terminradar" : "Calendar Radar",
                    de ? "Melden, wenn ein Termin dazukommt, sich verschiebt oder den Ort wechselt."
                       : "Speak up when an appointment is added, moved or changes place.")
        case .meetingPrep:
            return (de ? "Termin-Vorbereitung" : "Meeting Prep",
                    de ? "Ort, Zeit und passende offene Erinnerungen vor dem Termin bereitlegen."
                       : "Prepare time, place and matching open reminders before an appointment.")
        case .reminderRadar:
            return (de ? "Erinnerungsradar" : "Reminder Radar",
                    de ? "Melden, wenn Erinnerungen überfällig oder heute fällig werden." : "Speak up when reminders become overdue or due today.")
        case .followUp, .customCheck:
            return nil
        }
    }

    /// The task without the trigger and time phrases and without polite or reminder lead-ins.
    private static func cleanTask(_ text: String, removing spans: [Range<String.Index>]) -> String {
        let sorted = spans
            .filter { $0.lowerBound < $0.upperBound && $0.upperBound <= text.endIndex }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for span in sorted {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        var task = text
        for span in merged.reversed() {
            task.replaceSubrange(span, with: " ")
        }
        task = task.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let leadIns = [
            #"^(?:hey |hi |hallo )?pippa[,:]?\s*"#,
            #"^(?:please|bitte|could you|can you|would you|kannst du|könntest du|würdest du)\s+"#,
            #"^(?:remind me to|remind me|erinnere mich daran,?\s*(?:dass\s+)?|erinnere mich an|erinnere mich|send me|give me|schick mir|gib mir|zeig mir|show me)\s+"#,
            #"^(?:and|then|und|dann|,|:|-)\s*"#,
            #"^(?:arrives|arrive|appears|lands|comes in|kommt|ankommt|landet|erscheint)[,:]?\s*"#,
            #"^(?:in my downloads|in meinen downloads|in downloads)[,:]?\s*"#,
            #"^(?:to)\s+"#,
        ]
        for _ in 0..<4 {
            for pattern in leadIns {
                if let range = task.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { task.removeSubrange(range) }
            }
        }
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:!?-"))
        task = task.trimmingCharacters(in: trimSet)
        for pattern in [#"\s+(?:bitte|please)$"#, #"\s+(?:um|at)$"#, #"\s+uhr$"#] {
            if let range = task.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { task.removeSubrange(range) }
        }
        return RoutineText.cleanLine(task.trimmingCharacters(in: trimSet), fallback: "", limit: 500)
    }

    private static func makeTitle(_ task: String) -> String {
        let words = task.split(separator: " ")
        var title = ""
        for word in words {
            let next = title.isEmpty ? String(word) : title + " " + word
            if next.count > 48 { break }
            title = next
        }
        if title.isEmpty { title = String(task.prefix(48)) }
        return capitalizedFirst(title)
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: Helpers

    /// Single-spaced, without control or bidi characters; case is kept for the task and matched case-insensitively.
    private static func normalize(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { RoutineText.isUnsafeScalar($0) ? " " : Character($0) }
        return String(scalars)
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Interrogatives about the person's data, not a request to set something up.
    private static func isPlainQuestion(_ text: String) -> Bool {
        let questionStart = #"^(?:what|what's|whats|when|where|which|who|why|how|is|are|do|does|did|have|has|can|could|would|should|was|wann|wo|wer|wie|warum|welche|welcher|welches|ist|sind|habe|hab|hast|gibt|steht|stehen|kannst|könntest|würdest|soll|sollte)\b"#
        return text.hasSuffix("?") && text.range(of: questionStart, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Cron day-of-week field ("1-5", "1,3,5", "0", "7", "mon-fri" not supported) as `Calendar` weekdays.
    private static func cronWeekdays(_ field: String) -> [Int]? {
        var days: Set<Int> = []
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            if bounds.count == 1, let d = bounds[0], (0...7).contains(d) {
                days.insert(d % 7 + 1)
            } else if bounds.count == 2, let a = bounds[0], let b = bounds[1], (0...7).contains(a), (0...7).contains(b), a <= b {
                for d in a...b { days.insert(d % 7 + 1) }
            } else {
                return nil
            }
        }
        return days.isEmpty ? nil : days.sorted()
    }

    private struct RegexMatch {
        var range: Range<String.Index>
        var groups: [String?]
    }

    private static func firstMatch(_ pattern: String, in text: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, range: ns), let range = Range(result.range, in: text) else { return nil }
        var groups: [String?] = []
        if result.numberOfRanges > 1 {
            for i in 1..<result.numberOfRanges {
                let r = result.range(at: i)
                groups.append(r.location == NSNotFound ? nil : Range(r, in: text).map { String(text[$0]) })
            }
        }
        return RegexMatch(range: range, groups: groups)
    }

    private static func firstRange(_ pattern: String, in text: String) -> Range<String.Index>? {
        firstMatch(pattern, in: text)?.range
    }
}
