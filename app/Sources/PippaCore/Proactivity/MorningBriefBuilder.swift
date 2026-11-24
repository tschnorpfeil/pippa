import CryptoKit
import Foundation

/// Pure, already-read inputs for building a deterministic 0-token Morning Brief.
public struct MorningBriefInput: Sendable {
    public let day: Date
    public let events: [CalendarEvent]
    public let reminders: [ReminderItem]
    public let openMatters: [ProactiveMatter]
    public let calendar: Calendar
    public let language: String?

    public init(
        day: Date,
        events: [CalendarEvent] = [],
        reminders: [ReminderItem] = [],
        openMatters: [ProactiveMatter] = [],
        calendar: Calendar = .autoupdatingCurrent,
        language: String? = nil
    ) {
        self.day = day
        self.events = events
        self.reminders = reminders
        self.openMatters = openMatters
        self.calendar = calendar
        self.language = language
    }
}

/// Formatted Morning Brief content produced deterministically in Swift without any model call.
public struct MorningBriefContent: Codable, Sendable, Equatable {
    public let dayKey: String
    public let language: String
    public let title: String
    public let summary: String
    public let preparedPrompt: String
    public let sourceVersion: String
    public let eventCount: Int
    public let reminderCount: Int
    public let openMatterCount: Int
}

public enum MorningBriefBuildResult: Sendable, Equatable {
    case prepared(job: DurableJobRecord, matter: ProactiveMatter, dayKey: String)
    case silent(job: DurableJobRecord, dayKey: String)
    case alreadyBuilt(job: DurableJobRecord, matter: ProactiveMatter?, dayKey: String)
}

/// Builds the daily Morning Brief deterministically with 0 model tokens.
/// Uses `DurableJobStore` (`DurableJobKind.morningBriefing`, `requestKey = "morning-brief-YYYY-MM-DD"`)
/// for once-per-day idempotence and stays silent on a completely empty day.
public enum MorningBriefBuilder {
    private static let maxListedEvents = 6
    private static let maxListedReminders = 5
    private static let maxListedMatters = 5

    public static func requestKey(for dayKey: String) -> String {
        "morning-brief-\(dayKey)"
    }

    public static func matterKey(for dayKey: String) -> String {
        "morning-brief:\(dayKey)"
    }

    /// Formats the Morning Brief purely from `input`, or returns `nil` if the day has no relevant items.
    public static func format(_ input: MorningBriefInput) -> MorningBriefContent? {
        let calendar = input.calendar
        let dayStart = calendar.startOfDay(for: input.day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let dayKey = ProactiveMatterStore.dayKey(for: dayStart, calendar: calendar)
        let isGerman = resolvedLanguage(input.language, calendar: calendar) == "de"

        // Keep only non-cancelled, non-declined events overlapping today.
        let activeEvents = input.events
            .filter { event in
                guard event.status != .cancelled, !event.declined else { return false }
                let overlaps = (event.end > dayStart || (event.end == event.start && event.start >= dayStart))
                    && event.start < dayEnd
                return overlaps
            }
            .sorted { a, b in
                if a.allDay != b.allDay { return a.allDay }
                return (a.start, a.title) < (b.start, b.title)
            }

        // Keep reminders due today or overdue (drop undated or future reminders).
        let dueReminders = input.reminders
            .filter { reminder in
                guard let due = reminder.due else { return false }
                return due < dayEnd
            }
            .sorted { a, b in
                let da = a.due ?? .distantFuture
                let db = b.due ?? .distantFuture
                return (da, a.title) < (db, b.title)
            }

        // Keep open or offered non-brief proactive matters.
        let actionableMatters = input.openMatters
            .filter { matter in
                matter.kind != .morningBrief && (matter.state == .open || matter.state == .offered)
            }
            .sorted { ($0.updatedAt, $0.title) > ($1.updatedAt, $1.title) }

        guard !activeEvents.isEmpty || !dueReminders.isEmpty || !actionableMatters.isEmpty else {
            return nil
        }

        let locale = Locale(identifier: isGerman ? "de_DE" : "en_US")
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = locale
        dayFormatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let dayLabel = dayFormatter.string(from: dayStart)

        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        let title = isGerman ? "Morgenbrief · \(dayLabel)" : "Morning Brief · \(dayLabel)"
        var sections: [String] = []

        if !activeEvents.isEmpty {
            let header = isGerman
                ? (activeEvents.count == 1 ? "1 Termin" : "\(activeEvents.count) Termine")
                : (activeEvents.count == 1 ? "1 appointment" : "\(activeEvents.count) appointments")
            var lines = [header]
            for event in activeEvents.prefix(maxListedEvents) {
                let timeLabel: String
                if event.allDay {
                    timeLabel = isGerman ? "Ganztägig" : "All day"
                } else {
                    timeLabel = timeFormatter.string(from: event.start)
                }
                let cleanTitle = cleanLine(event.title, fallback: isGerman ? "(Ohne Titel)" : "(No title)")
                lines.append("• \(timeLabel) \(cleanTitle)")
            }
            if activeEvents.count > maxListedEvents {
                let extra = activeEvents.count - maxListedEvents
                lines.append(isGerman ? "… und \(extra) weitere" : "… and \(extra) more")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if !dueReminders.isEmpty {
            let header = isGerman
                ? (dueReminders.count == 1 ? "1 fällige Erinnerung" : "\(dueReminders.count) fällige Erinnerungen")
                : (dueReminders.count == 1 ? "1 due reminder" : "\(dueReminders.count) due reminders")
            var lines = [header]
            for reminder in dueReminders.prefix(maxListedReminders) {
                let cleanTitle = cleanLine(reminder.title, fallback: isGerman ? "(Ohne Titel)" : "(No title)")
                let isOverdue = reminder.due.map { $0 < dayStart } ?? false
                if isOverdue {
                    let tag = isGerman ? "überfällig" : "overdue"
                    lines.append("• \(cleanTitle) (\(tag))")
                } else {
                    lines.append("• \(cleanTitle)")
                }
            }
            if dueReminders.count > maxListedReminders {
                let extra = dueReminders.count - maxListedReminders
                lines.append(isGerman ? "… und \(extra) weitere" : "… and \(extra) more")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if !actionableMatters.isEmpty {
            let header = isGerman
                ? (actionableMatters.count == 1 ? "1 offener Hinweis" : "\(actionableMatters.count) offene Hinweise")
                : (actionableMatters.count == 1 ? "1 open item" : "\(actionableMatters.count) open items")
            var lines = [header]
            for matter in actionableMatters.prefix(maxListedMatters) {
                let cleanTitle = cleanLine(matter.title, fallback: isGerman ? "Hinweis" : "Item")
                lines.append("• \(cleanTitle)")
            }
            if actionableMatters.count > maxListedMatters {
                let extra = actionableMatters.count - maxListedMatters
                lines.append(isGerman ? "… und \(extra) weitere" : "… and \(extra) more")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        let summary = sections.joined(separator: "\n\n")
        let preparedPrompt = isGerman
            ? "Gib mir einen kurzen, ruhigen Überblick über meine heutigen Termine, fälligen Erinnerungen und offenen Hinweise."
            : "Give me a short, calm overview of my appointments, due reminders, and open items for today."

        let versionSeed = [dayKey, title, summary].joined(separator: "\n---\n")
        let sourceVersion = SHA256.hash(data: Data(versionSeed.utf8)).hexString

        return MorningBriefContent(
            dayKey: dayKey,
            language: isGerman ? "de" : "en",
            title: title,
            summary: summary,
            preparedPrompt: preparedPrompt,
            sourceVersion: sourceVersion,
            eventCount: activeEvents.count,
            reminderCount: dueReminders.count,
            openMatterCount: actionableMatters.count
        )
    }

    /// Runs the idempotent daily Morning Brief build backed by `DurableJobStore` and `ProactiveMatterStore`.
    /// Creates no proactive matter when the day is empty.
    public static func build(
        input: MorningBriefInput,
        jobStore: DurableJobStore,
        matterStore: ProactiveMatterStore,
        now: Date = Date()
    ) async throws -> MorningBriefBuildResult {
        let dayKey = ProactiveMatterStore.dayKey(for: input.day, calendar: input.calendar)
        let reqKey = requestKey(for: dayKey)
        let matKey = matterKey(for: dayKey)

        if let existingJob = try await jobStore.record(requestKey: reqKey) {
            switch existingJob.state {
            case .completed:
                let existingMatter = try await matterStore.matter(key: matKey)
                return .alreadyBuilt(job: existingJob, matter: existingMatter, dayKey: dayKey)
            case .queued:
                return try await executeQueued(
                    job: existingJob,
                    input: input,
                    dayKey: dayKey,
                    matterKey: matKey,
                    jobStore: jobStore,
                    matterStore: matterStore,
                    now: now
                )
            case .needsAttention, .failed, .cancelled:
                let retried = try await jobStore.retry(id: existingJob.id, expectedRevision: existingJob.revision)
                return try await executeQueued(
                    job: retried,
                    input: input,
                    dayKey: dayKey,
                    matterKey: matKey,
                    jobStore: jobStore,
                    matterStore: matterStore,
                    now: now
                )
            case .running:
                let existingMatter = try await matterStore.matter(key: matKey)
                return .alreadyBuilt(job: existingJob, matter: existingMatter, dayKey: dayKey)
            }
        }

        let isGerman = resolvedLanguage(input.language, calendar: input.calendar) == "de"
        let jobTitle = isGerman ? "Morgenbrief \(dayKey)" : "Morning Brief \(dayKey)"
        let payload = Data("{\"dayKey\":\"\(dayKey)\"}".utf8)
        let createdJob = try await jobStore.create(
            kind: .morningBriefing,
            requestKey: reqKey,
            title: jobTitle,
            payload: payload
        )
        if createdJob.state != .queued {
            let existingMatter = try await matterStore.matter(key: matKey)
            return .alreadyBuilt(job: createdJob, matter: existingMatter, dayKey: dayKey)
        }

        return try await executeQueued(
            job: createdJob,
            input: input,
            dayKey: dayKey,
            matterKey: matKey,
            jobStore: jobStore,
            matterStore: matterStore,
            now: now
        )
    }

    private static func executeQueued(
        job: DurableJobRecord,
        input: MorningBriefInput,
        dayKey: String,
        matterKey: String,
        jobStore: DurableJobStore,
        matterStore: ProactiveMatterStore,
        now: Date
    ) async throws -> MorningBriefBuildResult {
        let run = try await jobStore.start(id: job.id, expectedRevision: job.revision)
        do {
            guard let content = format(input) else {
                let silentData = Data("{\"silent\":true,\"dayKey\":\"\(dayKey)\"}".utf8)
                let completed = try await jobStore.finish(run: run, state: .completed, resultData: silentData)
                return .silent(job: completed, dayKey: dayKey)
            }

            let draft = ProactiveMatterDraft(
                kind: .morningBrief,
                matterKey: matterKey,
                sourceRef: requestKey(for: dayKey),
                sourceVersion: content.sourceVersion,
                title: content.title,
                summary: content.summary,
                preparedPrompt: content.preparedPrompt,
                preparedFiles: []
            )
            let upsert = try await matterStore.upsertPrepared(draft, now: now)
            let resultData = try JSONEncoder().encode(content)
            let completed = try await jobStore.finish(run: run, state: .completed, resultData: resultData)

            if case .keptClosed = upsert {
                return .silent(job: completed, dayKey: dayKey)
            }
            if let matter = upsert.matter {
                return .prepared(job: completed, matter: matter, dayKey: dayKey)
            }
            return .silent(job: completed, dayKey: dayKey)
        } catch {
            _ = try? await jobStore.finish(run: run, state: .failed, issue: String(describing: error))
            throw error
        }
    }

    private static func resolvedLanguage(_ explicit: String?, calendar: Calendar) -> String {
        let raw = (explicit ?? calendar.locale?.identifier ?? Locale.current.identifier).lowercased()
        return raw.hasPrefix("de") ? "de" : "en"
    }

    private static func cleanLine(_ raw: String, fallback: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return fallback }
        return String(collapsed.prefix(100))
    }
}
