import CryptoKit
import Foundation

/// What a routine is about. Built-in templates have deterministic 0-token builders; `customCheck` runs the
/// person's own instruction (`RoutineExecutionMode`).
public enum ProactiveRoutineTemplate: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case morningBrief
    case eveningPreview
    case weeklyReview
    case folderWatch
    case calendarRadar
    case meetingPrep
    case reminderRadar
    case followUp
    case customCheck
}

/// When a scheduled routine fires, always in the person's local time zone.
/// Weekdays use `Calendar` numbering: 1 = Sunday, 2 = Monday … 7 = Saturday.
public enum ProactiveSchedule: Codable, Sendable, Equatable, Hashable {
    case daily(hour: Int, minute: Int)
    /// Monday through Friday (`ProactiveSchedule.workWeek`).
    case weekdays(hour: Int, minute: Int)
    /// `weekdays` in `1...7`, sorted and deduplicated; empty falls back to Monday.
    case weekly(weekdays: [Int], hour: Int, minute: Int)
    /// `day` in `1...31`; months without that day fire on their last day.
    case monthly(day: Int, hour: Int, minute: Int)
    /// `minutes` in `15...1440`.
    case interval(minutes: Int)
    case once(at: Date)

    public static let workWeek = [2, 3, 4, 5, 6]
    public static let intervalRange = 15...1440

    /// The same schedule with every value inside its valid range.
    public var normalized: ProactiveSchedule {
        switch self {
        case .daily(let hour, let minute):
            return .daily(hour: Self.clampHour(hour), minute: Self.clampMinute(minute))
        case .weekdays(let hour, let minute):
            return .weekdays(hour: Self.clampHour(hour), minute: Self.clampMinute(minute))
        case .weekly(let weekdays, let hour, let minute):
            return .weekly(weekdays: Self.normalizedWeekdays(weekdays), hour: Self.clampHour(hour), minute: Self.clampMinute(minute))
        case .monthly(let day, let hour, let minute):
            return .monthly(day: min(max(day, 1), 31), hour: Self.clampHour(hour), minute: Self.clampMinute(minute))
        case .interval(let minutes):
            return .interval(minutes: Self.clampInterval(minutes))
        case .once:
            return self
        }
    }

    public static func normalizedWeekdays(_ weekdays: [Int]) -> [Int] {
        let valid = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
        return valid.isEmpty ? [2] : valid
    }

    public static func clampInterval(_ minutes: Int) -> Int {
        min(max(minutes, intervalRange.lowerBound), intervalRange.upperBound)
    }

    static func clampHour(_ value: Int) -> Int { min(max(value, 0), 23) }
    static func clampMinute(_ value: Int) -> Int { min(max(value, 0), 59) }
}

/// What makes a routine run: a schedule, or a zero-token watcher noticing a change.
public enum ProactiveTrigger: Codable, Sendable, Equatable, Hashable {
    case schedule(ProactiveSchedule)
    /// New files in a folder. An empty `path` means the person still has to choose the folder.
    case folder(path: String, bookmark: Data?)
    /// Appointments in the next `lookaheadHours` (`1...168`) that are new, moved or have a new place.
    case calendarChange(lookaheadHours: Int)
    /// Confirmed timed appointments starting within `leadMinutes` (`5...120`, default 30).
    case upcomingMeeting(leadMinutes: Int)
    /// Reminders that are overdue or due today.
    case reminderDue

    public static let lookaheadRange = 1...168
    public static let meetingLeadRange = 5...120

    public var normalized: ProactiveTrigger {
        switch self {
        case .schedule(let schedule): return .schedule(schedule.normalized)
        case .folder: return self
        case .calendarChange(let hours):
            return .calendarChange(lookaheadHours: min(max(hours, Self.lookaheadRange.lowerBound), Self.lookaheadRange.upperBound))
        case .upcomingMeeting(let minutes):
            return .upcomingMeeting(leadMinutes: min(max(minutes, Self.meetingLeadRange.lowerBound), Self.meetingLeadRange.upperBound))
        case .reminderDue: return self
        }
    }

    /// The trigger in plain everyday words, for lists and confirmations.
    public func humanSummary(language: String, calendar: Calendar = .autoupdatingCurrent) -> String {
        let de = RoutineText.isGerman(language)
        switch normalized {
        case .schedule(let schedule):
            return Self.summary(schedule, de: de, calendar: calendar)
        case .folder(let path, _):
            let name = URL(fileURLWithPath: path).lastPathComponent
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.isEmpty || name == "/" {
                return de ? "Neue Dateien in einem Ordner" : "New files in a folder"
            }
            return de ? "Neue Dateien in \(name)" : "New files in \(name)"
        case .calendarChange:
            return de ? "Wenn sich Termine ändern" : "When appointments change"
        case .upcomingMeeting(let minutes):
            return de ? "\(minutes) Min vor Terminen" : "\(minutes) min before appointments"
        case .reminderDue:
            return de ? "Wenn Erinnerungen fällig werden" : "When reminders come due"
        }
    }

    private static func summary(_ schedule: ProactiveSchedule, de: Bool, calendar: Calendar) -> String {
        switch schedule {
        case .daily(let hour, let minute):
            let time = RoutineText.time(hour, minute)
            return de ? "Täglich um \(time)" : "Every day at \(time)"
        case .weekdays(let hour, let minute):
            let time = RoutineText.time(hour, minute)
            return de ? "Werktags um \(time)" : "Weekdays at \(time)"
        case .weekly(let weekdays, let hour, let minute):
            let time = RoutineText.time(hour, minute)
            if weekdays == ProactiveSchedule.workWeek {
                return de ? "Werktags um \(time)" : "Weekdays at \(time)"
            }
            if weekdays == Array(1...7) {
                return de ? "Täglich um \(time)" : "Every day at \(time)"
            }
            // Monday first, as people read a week.
            let names = RoutineText.mondayFirst(weekdays).map { RoutineText.weekdayShort($0, de: de) }.joined(separator: ", ")
            return de ? "\(names) um \(time)" : "\(names) at \(time)"
        case .monthly(let day, let hour, let minute):
            let time = RoutineText.time(hour, minute)
            return de ? "Am \(day). jeden Monats um \(time)" : "Monthly on day \(day) at \(time)"
        case .interval(let minutes):
            if minutes % 60 == 0 {
                let hours = minutes / 60
                if hours == 1 { return de ? "Stündlich" : "Every hour" }
                return de ? "Alle \(hours) Stunden" : "Every \(hours) hours"
            }
            return de ? "Alle \(minutes) Minuten" : "Every \(minutes) minutes"
        case .once(let date):
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let time = RoutineText.time(c.hour ?? 0, c.minute ?? 0)
            let day = c.day ?? 1, month = c.month ?? 1, year = c.year ?? 1970
            if de { return String(format: "Einmalig am %02d.%02d.%04d um ", day, month, year) + time }
            return "Once on \(day) \(RoutineText.monthShort(month)) \(year) at \(time)"
        }
    }
}

/// How a routine prepares its result.
public enum RoutineExecutionMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// A Swift builder, 0 model tokens.
    case deterministic
    /// Prepares a prompt the person can open in the chat; nothing runs before that.
    case prepareForChat
    /// The AI on this Mac with read-only tools (`PippaPiLaunch.Capabilities.readOnly`, `PippaMCPHost.readOnly`).
    case localAIReadOnly
}

/// Where a routine's result may appear.
public enum RoutineDeliveryMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Pippa Island (within the daily budget) and the Desk.
    case islandAndDesk
    /// Only the Desk: never interrupts, never counts against the daily budget.
    case deskOnly
}

public enum RoutineRunOutcome: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// Something new was prepared as a matter.
    case prepared
    /// Ran, nothing new: stays quiet.
    case silent
    /// Ran, but delivery waits (quiet hours, Focus, budget).
    case held
    case failed
    /// Not run (disabled, slot too old, missing folder).
    case skipped
}

/// One person-defined or built-in proactive routine.
public struct ProactiveRoutine: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var instruction: String
    public var template: ProactiveRoutineTemplate
    public var trigger: ProactiveTrigger {
        didSet {
            let normalized = trigger.normalized
            if trigger != normalized { trigger = normalized }
        }
    }
    public var executionMode: RoutineExecutionMode
    public var deliveryMode: RoutineDeliveryMode
    public var enabled: Bool
    /// Stay quiet when the input is unchanged since the last run (`lastInputHash`).
    public var onlyWhenNew: Bool
    /// `builtin.*` for starter routines, unique in the store; `nil` for the person's own.
    public var builtInKey: String?
    public var lastInputHash: String?
    public var lastSlotKey: String?
    public var lastRunAt: Date?
    public var lastOutcome: RoutineRunOutcome?
    public var lastSummary: String?
    public var nextRunAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        instruction: String,
        template: ProactiveRoutineTemplate,
        trigger: ProactiveTrigger,
        executionMode: RoutineExecutionMode = .deterministic,
        deliveryMode: RoutineDeliveryMode = .islandAndDesk,
        enabled: Bool = true,
        onlyWhenNew: Bool = true,
        builtInKey: String? = nil,
        lastInputHash: String? = nil,
        lastSlotKey: String? = nil,
        lastRunAt: Date? = nil,
        lastOutcome: RoutineRunOutcome? = nil,
        lastSummary: String? = nil,
        nextRunAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.template = template
        self.trigger = trigger.normalized
        self.executionMode = executionMode
        self.deliveryMode = deliveryMode
        self.enabled = enabled
        self.onlyWhenNew = onlyWhenNew
        self.builtInKey = builtInKey
        self.lastInputHash = lastInputHash
        self.lastSlotKey = lastSlotKey
        self.lastRunAt = lastRunAt
        self.lastOutcome = lastOutcome
        self.lastSummary = lastSummary
        self.nextRunAt = nextRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// The matter kind its results are filed and muted under.
    public var matterKind: ProactiveMatterKind {
        switch template {
        case .morningBrief: return .morningBrief
        case .folderWatch: return .watchedFile
        case .calendarRadar: return .calendarChange
        case .reminderRadar: return .reminderDue
        case .followUp: return .followUp
        case .eveningPreview, .weeklyReview, .meetingPrep, .customCheck: return .routine
        }
    }

    public func humanTriggerSummary(language: String, calendar: Calendar = .autoupdatingCurrent) -> String {
        trigger.humanSummary(language: language, calendar: calendar)
    }

    // MARK: Built-in routines

    public static let morningBriefKey = "builtin.morning_brief"
    public static let eveningPreviewKey = "builtin.evening_preview"
    public static let weeklyReviewKey = "builtin.weekly_review"
    public static let calendarRadarKey = "builtin.calendar_radar"
    public static let meetingPrepKey = "builtin.meeting_prep"
    public static let reminderRadarKey = "builtin.reminder_radar"
    public static let watchedFolderKey = "builtin.watched_folder"

    /// A stable ID per built-in key, so installing the starter packs twice upserts instead of duplicating.
    public static func builtInID(for key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("pippa.routine." + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The starter routines in `language`. Only the Morning Brief starts on, mirroring `ProactivitySettings`;
    /// everything else waits for the person's choice. All are 0-token builders.
    public static func starterPacks(language: String, now: Date = Date()) -> [ProactiveRoutine] {
        let de = RoutineText.isGerman(language)
        func make(_ key: String, _ title: String, _ instruction: String, _ template: ProactiveRoutineTemplate,
                  _ trigger: ProactiveTrigger, enabled: Bool, delivery: RoutineDeliveryMode = .islandAndDesk) -> ProactiveRoutine {
            ProactiveRoutine(id: builtInID(for: key), title: title, instruction: instruction, template: template, trigger: trigger,
                             executionMode: .deterministic, deliveryMode: delivery, enabled: enabled, onlyWhenNew: true,
                             builtInKey: key, createdAt: now)
        }
        return [
            make(morningBriefKey,
                 de ? "Morgenbrief" : "Morning Brief",
                 de ? "Ein ruhiger Überblick über die Termine, fälligen Erinnerungen und offenen Hinweise des Tages."
                    : "A calm overview of the day's appointments, due reminders and open items.",
                 .morningBrief, .schedule(.daily(hour: 8, minute: 0)), enabled: true),
            make(eveningPreviewKey,
                 de ? "Abendvorschau" : "Evening Preview",
                 de ? "Was morgen ansteht und was heute noch offen ist, damit nichts überrascht."
                    : "What's on tomorrow and what is still open today, so nothing comes as a surprise.",
                 .eveningPreview, .schedule(.daily(hour: 18, minute: 0)), enabled: false),
            make(weeklyReviewKey,
                 de ? "Wochenüberblick" : "Weekly Review",
                 de ? "Die nächsten sieben Tage: wie voll jeder Tag ist, Überschneidungen und überfällige Erinnerungen."
                    : "The next seven days: how full each day is, overlaps and overdue reminders.",
                 .weeklyReview, .schedule(.weekly(weekdays: [1], hour: 18, minute: 0)), enabled: false),
            make(calendarRadarKey,
                 de ? "Terminradar" : "Calendar Radar",
                 de ? "Meldet sich nur, wenn in den nächsten zwei Tagen ein Termin dazukommt, sich verschiebt oder den Ort wechselt."
                    : "Speaks up only when an appointment in the next two days is added, moved or changes place.",
                 .calendarRadar, .calendarChange(lookaheadHours: 48), enabled: false, delivery: .deskOnly),
            make(meetingPrepKey,
                 de ? "Termin-Vorbereitung" : "Meeting Prep",
                 de ? "Legt 30 Minuten vor einem Termin Ort, Zeit und passende offene Erinnerungen bereit."
                    : "Prepares time, place and matching open reminders 30 minutes before an appointment.",
                 .meetingPrep, .upcomingMeeting(leadMinutes: 30), enabled: false, delivery: .deskOnly),
            make(reminderRadarKey,
                 de ? "Erinnerungsradar" : "Reminder Radar",
                 de ? "Meldet sich, wenn Erinnerungen überfällig oder heute fällig werden."
                    : "Speaks up when reminders become overdue or due today.",
                 .reminderRadar, .reminderDue, enabled: false, delivery: .deskOnly),
        ]
    }

    /// The built-in folder watcher for a folder the person chose (`path` may be empty until they choose one).
    public static func watchedFolder(path: String, bookmark: Data? = nil, language: String, enabled: Bool = true,
                                     now: Date = Date()) -> ProactiveRoutine {
        let de = RoutineText.isGerman(language)
        return ProactiveRoutine(
            id: builtInID(for: watchedFolderKey),
            title: de ? "Ordner beobachten" : "Watch Folder",
            instruction: de ? "Neue Dateien in diesem Ordner zum Ansehen vorbereiten." : "Prepare new files in this folder for a look.",
            template: .folderWatch, trigger: .folder(path: path, bookmark: bookmark), executionMode: .deterministic,
            deliveryMode: .islandAndDesk, enabled: enabled, onlyWhenNew: true, builtInKey: watchedFolderKey, createdAt: now)
    }
}

/// One run of a routine for one slot (`ProactiveScheduleCalculator.slotKey`).
public struct RoutineRunRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let routineID: UUID
    public let routineTitle: String
    public let slotKey: String
    public let outcome: RoutineRunOutcome
    public let matterID: UUID?
    public let inputHash: String?
    public let detail: String?
    public let startedAt: Date
    public let finishedAt: Date

    public init(id: UUID = UUID(), routineID: UUID, routineTitle: String, slotKey: String, outcome: RoutineRunOutcome,
                matterID: UUID? = nil, inputHash: String? = nil, detail: String? = nil, startedAt: Date, finishedAt: Date) {
        self.id = id; self.routineID = routineID; self.routineTitle = routineTitle; self.slotKey = slotKey
        self.outcome = outcome; self.matterID = matterID; self.inputHash = inputHash; self.detail = detail
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

/// Small deterministic text helpers shared by routines, the parser and the builders (no `L(...)`: product text in
/// both languages is chosen by `language`, as in `MorningBriefBuilder`).
enum RoutineText {
    static func isGerman(_ language: String?) -> Bool {
        (language ?? "").lowercased().hasPrefix("de")
    }

    static func resolvedGerman(_ language: String?, calendar: Calendar) -> Bool {
        let raw = (language ?? calendar.locale?.identifier ?? Locale.current.identifier).lowercased()
        return raw.hasPrefix("de")
    }

    static func time(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    static func weekdayShort(_ weekday: Int, de: Bool) -> String {
        let en = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let ge = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
        let index = min(max(weekday, 1), 7) - 1
        return de ? ge[index] : en[index]
    }

    static func monthShort(_ month: Int) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return names[min(max(month, 1), 12) - 1]
    }

    /// Calendar weekdays (1 = Sunday) in Monday-first order.
    static func mondayFirst(_ weekdays: [Int]) -> [Int] {
        weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
    }

    /// One line, collapsed whitespace, no control or bidi characters, at most `limit` characters.
    static func cleanLine(_ raw: String, fallback: String, limit: Int = 100) -> String {
        let scrubbed = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !isUnsafeScalar($0) || $0 == "\n" || $0 == "\t" }))
        let collapsed = scrubbed
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return fallback }
        return String(collapsed.prefix(limit))
    }

    /// Control characters, bidi overrides/isolates and zero-width characters.
    static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x061C, 0xFEFF: return true
        default: return false
        }
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).hexString
    }
}
