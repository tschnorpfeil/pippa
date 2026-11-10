import Foundation

/// Developer diagnostic for the memory experiment (`Pippa --memory-probe`, docs/plan-0.6.md): how much metadata do
/// Photos and Calendar show for a date window? Read only, bounded, aggregate counts only. No titles, names, identifiers,
/// coordinates or exact timestamps ever reach the report, and nothing is stored. Not a feature of the app.
public enum MemoryProbe {
    /// At most this many photos / events are looked at per source; the rest is only counted.
    public static let sampleLimit = 500
    public static let maxDays = 31

    public static let usage = """
        usage: Pippa --memory-probe --from YYYY-MM-DD --to YYYY-MM-DD
          Reads Photos and Calendar metadata for the calendar dates from (inclusive) up to to (exclusive), at most \(maxDays) days,
          in this Mac's time zone, and prints one JSON report of aggregate counts. It never asks for permissions: it uses what
          is already granted to this executable and reports the rest as not read.
        """

    // MARK: Arguments

    /// A calendar-date window `[from, to)` in one time zone.
    public struct Window: Equatable, Sendable {
        public let from: String
        public let to: String
        public let timeZone: String
        public let days: Int
        public let interval: DateInterval
    }

    public enum Invocation: Equatable, Sendable {
        case help
        case run(Window)
    }

    /// A message for the person who typed the command; fixed text, never an echo of the input.
    public struct UsageError: Error, Equatable, Sendable {
        public let message: String
    }

    /// Everything after the program name. Strict: a missing, repeated or unknown argument is an error, so a typo can never
    /// fall through to the normal app or to a read with default dates. Nothing is read here.
    public static func parse(_ arguments: [String], timeZone: TimeZone = .current) throws -> Invocation {
        var from: String?, to: String?
        var sawCommand = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h": return .help
            case "--memory-probe":
                guard !sawCommand else { throw UsageError(message: "--memory-probe given twice.") }
                sawCommand = true
            case "--from", "--to":
                guard let value = rest.popFirst() else { throw UsageError(message: "\(argument) needs a date as YYYY-MM-DD.") }
                if argument == "--from" { guard from == nil else { throw UsageError(message: "--from given twice.") }; from = value }
                else { guard to == nil else { throw UsageError(message: "--to given twice.") }; to = value }
            default: throw UsageError(message: "Unknown argument.")
            }
        }
        guard sawCommand else { throw UsageError(message: "Missing --memory-probe.") }
        guard let from else { throw UsageError(message: "Missing --from.") }
        guard let to else { throw UsageError(message: "Missing --to.") }
        return .run(try window(from: from, to: to, timeZone: timeZone))
    }

    public static func window(from: String, to: String, timeZone: TimeZone) throws -> Window {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let start = startOfDay(from, calendar) else { throw UsageError(message: "--from must be a real date as YYYY-MM-DD.") }
        guard let end = startOfDay(to, calendar) else { throw UsageError(message: "--to must be a real date as YYYY-MM-DD.") }
        // Calendar days, not 24 h blocks: a day with a clock change is one day.
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        guard days > 0 else { throw UsageError(message: "--to must be after --from (to is exclusive).") }
        guard days <= maxDays else { throw UsageError(message: "The window is at most \(maxDays) days.") }
        return Window(from: from, to: to, timeZone: timeZone.identifier, days: days, interval: DateInterval(start: start, end: end))
    }

    /// Exactly YYYY-MM-DD and a date that exists (no 2026-02-30), as the first moment of that day.
    private static func startOfDay(_ text: String, _ calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), year >= 1900 else { return nil }
        let wanted = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let noon = calendar.date(from: wanted) else { return nil }
        let got = calendar.dateComponents([.year, .month, .day], from: noon)
        guard got.year == year, got.month == month, got.day == day else { return nil }
        return calendar.startOfDay(for: noon)
    }

    /// The whole command: parse first, read only after a valid window. Exit code 2 is a usage error, and then nothing was read.
    public static func execute(_ arguments: [String], photos: PhotoSource, integrations: any AppIntegrations,
                               timeZone: TimeZone = .current) async -> (exitCode: Int32, stdout: String, stderr: String) {
        do {
            switch try parse(arguments, timeZone: timeZone) {
            case .help: return (0, usage, "")
            case .run(let window): return (0, await run(window, photos: photos, integrations: integrations).json(), "")
            }
        } catch let error as UsageError {
            return (2, "", "\(error.message)\n\(usage)")
        } catch { return (2, "", usage) }
    }

    // MARK: Reading

    /// What PhotoKit says about this process, kept apart: limited is a smaller library, not a full one.
    public enum PhotoAccess: Sendable, Equatable { case authorized, limited, notDetermined, denied, restricted }

    /// Counts over the photos of one window; only these numbers leave the reader.
    public struct PhotoSample: Sendable, Equatable {
        public var visibleTotal: Int
        public var sampled: Int
        public var withValidLocation: Int
        public var favorites: Int
        public init(visibleTotal: Int, sampled: Int, withValidLocation: Int, favorites: Int) {
            self.visibleTotal = visibleTotal; self.sampled = sampled; self.withValidLocation = withValidLocation; self.favorites = favorites
        }
    }

    /// The Photos side of the probe. `sample` is only called when `access` allows it.
    public struct PhotoSource: Sendable {
        public var access: @Sendable () -> PhotoAccess
        public var sample: @Sendable (_ interval: DateInterval, _ limit: Int) throws -> PhotoSample
        public init(access: @escaping @Sendable () -> PhotoAccess, sample: @escaping @Sendable (DateInterval, Int) throws -> PhotoSample) {
            self.access = access; self.sample = sample
        }
    }

    // MARK: Report

    public struct Report: Encodable, Equatable, Sendable {
        public struct Range: Encodable, Equatable, Sendable {
            public var from: String
            public var to: String
            public var semantics = "calendar dates, from inclusive, to exclusive"
            public var timeZone: String
            public var days: Int
        }
        /// "read", "readLimited" (Photos shows only what the person shared) and "failed" carry a read; the others are
        /// explicit non-read states, never zero counts. Calendar reports EventKit's denied and restricted as "denied".
        public enum Status: String, Encodable, Sendable { case read, readLimited, notDetermined, denied, restricted, failed }
        public struct Source: Encodable, Equatable, Sendable {
            public var status: Status
            public var scope: String?
            /// What the source offered for the window, and how many of those were looked at (`sampled` <= `sampleLimit`).
            public var visibleTotal: Int?
            public var sampled: Int?
            public var truncated: Bool?
            public var elapsedMs: Int?
            /// Counts below are over the `sampled` items, not the whole library.
            public var withValidLocation: Int?
            public var favorites: Int?
            public var withLocationText: Int?
            public var byStatus: [String: Int]?
        }
        public var probe = "memory-probe"
        public var range: Range
        public var sampleLimit: Int
        public var sampleOrder = "earliest first"
        public var photos: Source
        public var calendar: Source
        public var readElapsedMs: Int
        public var notes = [
            "Counts describe the sample of at most sampleLimit items per source, not a whole library.",
            "Photos are selected by creation date inside the window; metadata without a creation date cannot belong to a date-bounded photo window and is not counted.",
            "A calendar entry is a plan, not proof of attendance; a photo's date and location do not show who was there or what happened.",
            "The operating system's fetch has no application timeout: elapsedMs is measured, not enforced.",
        ]

        /// One JSON object, stable key order.
        public func json() -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
        }
    }

    /// Reads both sources once, in turn, and aggregates. A failure of one source never hides the other.
    public static func run(_ window: Window, photos: PhotoSource, integrations: any AppIntegrations, limit: Int = sampleLimit,
                           uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) async -> Report {
        func ms(since start: TimeInterval) -> Int { max(0, Int(((uptime() - start) * 1000).rounded())) }
        let started = uptime()
        var photoReport = readPhotos(window, photos, limit)
        photoReport.elapsedMs = photoReport.status.attemptedRead ? ms(since: started) : nil
        let calendarStarted = uptime()
        var calendarReport = await readCalendar(window, integrations, limit)
        calendarReport.elapsedMs = calendarReport.status.attemptedRead ? ms(since: calendarStarted) : nil
        return Report(range: .init(from: window.from, to: window.to, timeZone: window.timeZone, days: window.days),
                      sampleLimit: limit, photos: photoReport, calendar: calendarReport, readElapsedMs: ms(since: started))
    }

    private static func readPhotos(_ window: Window, _ source: PhotoSource, _ limit: Int) -> Report.Source {
        let limited: Bool
        switch source.access() {
        case .authorized: limited = false
        case .limited: limited = true
        case .notDetermined: return .init(status: .notDetermined)
        case .denied: return .init(status: .denied)
        case .restricted: return .init(status: .restricted)
        }
        guard let sample = try? source.sample(window.interval, limit) else { return .init(status: .failed) }
        var report = Report.Source(status: limited ? .readLimited : .read)
        if limited { report.scope = "Only the photos the person shared with this executable (limited access); counts describe that visible subset." }
        report.fill(visibleTotal: sample.visibleTotal, sampled: sample.sampled, limit: limit)
        report.withValidLocation = min(sample.withValidLocation, report.sampled ?? 0)
        report.favorites = min(sample.favorites, report.sampled ?? 0)
        return report
    }

    private static func readCalendar(_ window: Window, _ integrations: any AppIntegrations, _ limit: Int) async -> Report.Source {
        switch await integrations.access(.calendar) {
        case .granted: break
        case .notDetermined: return .init(status: .notDetermined)
        case .denied: return .init(status: .denied)
        case .unavailable: return .init(status: .failed)
        }
        do {
            let fetch = try await integrations.events(in: window.interval, limit: limit)
            let events = fetch.events.prefix(limit)
            var report = Report.Source(status: .read)
            report.fill(visibleTotal: fetch.total, sampled: events.count, limit: limit)
            report.withLocationText = events.filter { !($0.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            report.byStatus = Dictionary(grouping: events, by: { $0.status.rawValue }).mapValues(\.count)
            return report
        } catch PippaError.accessDenied {
            return .init(status: .denied)
        } catch {
            return .init(status: .failed)
        }
    }
}

extension MemoryProbe.Report.Status {
    /// A read was tried (and perhaps failed); the other states never touched the data.
    fileprivate var attemptedRead: Bool { self == .read || self == .readLimited || self == .failed }
}

extension MemoryProbe.Report.Source {
    /// `sampled` never exceeds the limit or the total, so counts over it are never read as a whole-library claim.
    fileprivate mutating func fill(visibleTotal: Int, sampled: Int, limit: Int) {
        let sampled = max(0, min(sampled, limit, max(visibleTotal, 0)))
        let total = max(visibleTotal, sampled)
        self.sampled = sampled
        self.visibleTotal = total
        truncated = total > sampled
    }
}
