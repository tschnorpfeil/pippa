import Foundation

/// The routine has a deliberately closed, read-only source set. IDs are EventKit calendar IDs,
/// not display names: renaming a list must never widen the person's selection.
public struct MorningBriefingSource: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case calendar, reminders }
    public var kind: Kind
    public var identifier: String
    public var title: String
    public var id: String { kind.rawValue + ":" + identifier }
    public init(kind: Kind, identifier: String, title: String) {
        self.kind = kind; self.identifier = identifier; self.title = title
    }
}

public struct MorningBriefingConfiguration: Codable, Sendable, Equatable {
    public var enabled = false
    public var hour = 8
    public var minute = 0
    /// Foundation weekday numbers: Sunday = 1, Monday = 2.
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public var sources: [MorningBriefingSource] = []
    public var notify = false
    public init() {}
    public var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute) && !weekdays.isEmpty
            && weekdays.isSubset(of: Set(1...7)) && !sources.isEmpty && sources.count <= 32
            && Set(sources.map(\.id)).count == sources.count
            && sources.allSatisfy { !$0.identifier.isEmpty && $0.identifier.count <= 1024 }
    }
}

public struct MorningBriefingOccurrence: Codable, Sendable, Equatable {
    /// The local civil date deliberately excludes the zone: travelling or the repeated DST hour
    /// must not create a second briefing for the same calendar date.
    public var key: String
    public var scheduledAt: Date
    public var day: DateInterval
    public var timeZone: String
}

public enum MorningBriefingSchedule {
    /// Catch up once on today's schedule, at most four hours late. Never replay missed days.
    public static let catchUpWindow: TimeInterval = 4 * 60 * 60

    public static func due(_ configuration: MorningBriefingConfiguration, now: Date,
                           calendar input: Calendar = .autoupdatingCurrent) -> MorningBriefingOccurrence? {
        guard configuration.enabled, configuration.isValid else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.timeZone
        let start = calendar.startOfDay(for: now)
        guard configuration.weekdays.contains(calendar.component(.weekday, from: start)),
              let end = calendar.date(byAdding: .day, value: 1, to: start),
              let scheduled = calendar.nextDate(after: start.addingTimeInterval(-1),
                matching: DateComponents(hour: configuration.hour, minute: configuration.minute, second: 0),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
              scheduled < end, now >= scheduled, now.timeIntervalSince(scheduled) <= catchUpWindow else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        let key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        return MorningBriefingOccurrence(key: key, scheduledAt: scheduled, day: DateInterval(start: start, end: end),
                                         timeZone: calendar.timeZone.identifier)
    }
}

public struct MorningBriefingEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: MorningBriefingSource
    public var title: String
    public var start: Date
    public var end: Date?
    public var allDay: Bool
    public var overlaps = false
    public init(id: String, source: MorningBriefingSource, title: String, start: Date, end: Date? = nil, allDay: Bool = false) {
        self.id = id; self.source = source; self.title = String(title.replacingOccurrences(of: "\n", with: " ").prefix(200))
        self.start = start; self.end = end; self.allDay = allDay
    }
}

public enum MorningBriefingReadFailure: String, Codable, Sendable, Error {
    case needsAccess, denied, unavailable, sourceMissing, interrupted
}

public struct MorningBriefingIssue: Codable, Sendable, Equatable {
    public var source: MorningBriefingSource?
    public var reason: MorningBriefingReadFailure
    public init(source: MorningBriefingSource?, reason: MorningBriefingReadFailure) { self.source = source; self.reason = reason }
}

public struct MorningBriefingRead: Sendable {
    public var entries: [MorningBriefingEntry]
    public var total: Int
    public init(entries: [MorningBriefingEntry], total: Int) { self.entries = entries; self.total = total }
}

public struct MorningBriefingResult: Codable, Sendable, Equatable {
    public var occurrence: MorningBriefingOccurrence
    public var readAt: Date
    public var entries: [MorningBriefingEntry]
    public var checkedSources: [MorningBriefingSource]
    public var issues: [MorningBriefingIssue]
    public var truncated: Bool
    public var isComplete: Bool { issues.isEmpty }
    public init(occurrence: MorningBriefingOccurrence, readAt: Date, entries: [MorningBriefingEntry],
                checkedSources: [MorningBriefingSource], issues: [MorningBriefingIssue], truncated: Bool = false) {
        self.occurrence = occurrence; self.readAt = readAt; self.entries = entries
        self.checkedSources = checkedSources; self.issues = issues; self.truncated = truncated
    }
}

/// Only this protocol reaches the routine. It cannot write, run tools, or request permissions.
public protocol MorningBriefingReading: Sendable {
    func sources(for kind: MorningBriefingSource.Kind) async throws -> [MorningBriefingSource]
    func read(_ source: MorningBriefingSource, day: DateInterval, limit: Int) async throws -> MorningBriefingRead
}

public enum MorningBriefingReader {
    public static let perSourceLimit = 60
    public static let displayLimit = 100

    public static func run(configuration: MorningBriefingConfiguration, occurrence: MorningBriefingOccurrence,
                           reader: any MorningBriefingReading, now: Date = Date(),
                           isCurrent: @escaping @Sendable () async -> Bool) async -> MorningBriefingResult? {
        guard configuration.enabled, configuration.isValid, occurrence.day.duration > 0,
              occurrence.day.duration <= 26 * 3600 else { return nil }
        var entries: [MorningBriefingEntry] = []
        var checked: [MorningBriefingSource] = []
        var issues: [MorningBriefingIssue] = []
        var truncated = false
        for source in configuration.sources {
            guard !Task.isCancelled, await isCurrent() else { return nil }
            do {
                let fetched = try await reader.read(source, day: occurrence.day, limit: perSourceLimit)
                guard !Task.isCancelled, await isCurrent() else { return nil }
                // Adapters are still checked at the boundary. Foreign sources and out-of-range facts
                // cannot enter a briefing, even when an adapter accidentally returns a wider selection.
                let selected = fetched.entries.filter { entry in
                    guard entry.source.id == source.id else { return false }
                    if source.kind == .reminders {
                        return entry.start < occurrence.day.end && entry.start >= occurrence.day.start.addingTimeInterval(-30 * 86400)
                    }
                    guard entry.start < occurrence.day.end else { return false }
                    if let end = entry.end, end > entry.start { return end > occurrence.day.start }
                    return entry.start >= occurrence.day.start
                }
                entries += selected.prefix(perSourceLimit)
                truncated = truncated || fetched.total > perSourceLimit || selected.count > perSourceLimit
                checked.append(source)
            } catch {
                guard !Task.isCancelled, await isCurrent() else { return nil }
                issues.append(MorningBriefingIssue(source: source, reason: error as? MorningBriefingReadFailure ?? .unavailable))
            }
        }
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.source.id + "|" + $0.id + "|" + String($0.start.timeIntervalSinceReferenceDate)).inserted }
            .sorted { ($0.start, $0.title, $0.id) < ($1.start, $1.title, $1.id) }
        truncated = truncated || entries.count > displayLimit
        entries = Array(entries.prefix(displayLimit))
        for i in entries.indices where entries[i].source.kind == .calendar && !entries[i].allDay {
            guard let end = entries[i].end, end > entries[i].start else { continue }
            entries[i].overlaps = entries.indices.contains { j in
                j != i && entries[j].source.kind == .calendar && !entries[j].allDay
                    && entries[j].start < end && (entries[j].end ?? entries[j].start) > entries[i].start
            }
        }
        return MorningBriefingResult(occurrence: occurrence, readAt: now, entries: entries,
                                     checkedSources: checked, issues: issues, truncated: truncated)
    }
}
