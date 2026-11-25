import Foundation

/// Pure schedule math for routines: next fire dates, slot keys and whether a slot is due now.
/// Local wall-clock times; DST gaps fire at the next existing time, repeated hours fire once (the first).
public enum ProactiveScheduleCalculator {
    /// Default catch-up after sleep or a paused Mac: at most the newest missed slot within this window runs.
    public static let defaultCatchUpWindow: TimeInterval = 12 * 3600

    /// `YYYY-MM-DD-HHmm` in `calendar`'s time zone; names one slot of one routine (`routine_runs` is unique on it).
    public static func slotKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d-%02d%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
    }

    /// The first fire date strictly after `reference`, or `nil` when the schedule never fires again.
    public static func nextFireDate(for schedule: ProactiveSchedule, after reference: Date,
                                    calendar: Calendar = .autoupdatingCurrent) -> Date? {
        switch schedule.normalized {
        case .daily(let hour, let minute):
            return next(after: reference, DateComponents(hour: hour, minute: minute, second: 0), calendar)
        case .weekdays(let hour, let minute):
            return ProactiveSchedule.workWeek
                .compactMap { next(after: reference, DateComponents(hour: hour, minute: minute, second: 0, weekday: $0), calendar) }
                .min()
        case .weekly(let weekdays, let hour, let minute):
            return weekdays
                .compactMap { next(after: reference, DateComponents(hour: hour, minute: minute, second: 0, weekday: $0), calendar) }
                .min()
        case .monthly(let day, let hour, let minute):
            return nextMonthly(day: day, hour: hour, minute: minute, after: reference, calendar: calendar)
        case .interval(let minutes):
            return reference.addingTimeInterval(TimeInterval(minutes * 60))
        case .once(let at):
            return at > reference ? at : nil
        }
    }

    public struct DueEvaluation: Sendable, Equatable {
        /// The slot that is due (for `interval`: the moment of this run).
        public let slotDate: Date
        public let slotKey: String
        /// The fire date after this run, for `ProactiveRoutine.nextRunAt`.
        public let nextFireDate: Date?
        /// `once`: switch the routine off after this run.
        public let disableAfterFire: Bool

        public init(slotDate: Date, slotKey: String, nextFireDate: Date?, disableAfterFire: Bool) {
            self.slotDate = slotDate; self.slotKey = slotKey; self.nextFireDate = nextFireDate; self.disableAfterFire = disableAfterFire
        }
    }

    /// The slot due at `now`, or `nil`. Anti-stampede: after sleeping through several slots only the newest one within
    /// `catchUpWindow` runs; slots older than that, slots before the routine existed and the slot already run
    /// (`lastSlotKey`) never do.
    public static func evaluateDue(
        schedule: ProactiveSchedule,
        lastSlotKey: String?,
        lastRunAt: Date?,
        createdAt: Date,
        now: Date,
        catchUpWindow: TimeInterval = defaultCatchUpWindow,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DueEvaluation? {
        let window = max(catchUpWindow, 0)
        switch schedule.normalized {
        case .once(let at):
            guard at <= now, lastSlotKey == nil, now.timeIntervalSince(at) <= max(window, 24 * 3600) else { return nil }
            return DueEvaluation(slotDate: at, slotKey: slotKey(for: at, calendar: calendar), nextFireDate: nil, disableAfterFire: true)
        case .interval(let minutes):
            let interval = TimeInterval(minutes * 60)
            guard (lastRunAt ?? createdAt).addingTimeInterval(interval) <= now else { return nil }
            let key = slotKey(for: now, calendar: calendar)
            guard key != lastSlotKey else { return nil }
            return DueEvaluation(slotDate: now, slotKey: key, nextFireDate: now.addingTimeInterval(interval), disableAfterFire: false)
        case let normalized:
            // Walk forward from the oldest moment that may still be caught up; keep the newest slot not after `now`.
            let lowerBound = max(now.addingTimeInterval(-window), createdAt)
            guard lowerBound <= now else { return nil }
            var cursor = lowerBound.addingTimeInterval(-1)
            var latest: Date?
            // Daily cadence at most, so a 12 h window holds a handful of slots; the bound only guards odd windows.
            for _ in 0..<512 {
                guard let next = nextFireDate(for: normalized, after: cursor, calendar: calendar), next <= now else { break }
                latest = next
                cursor = next
            }
            guard let slot = latest else { return nil }
            let key = slotKey(for: slot, calendar: calendar)
            guard key != lastSlotKey else { return nil }
            return DueEvaluation(slotDate: slot, slotKey: key, nextFireDate: nextFireDate(for: normalized, after: now, calendar: calendar),
                                 disableAfterFire: false)
        }
    }

    // MARK: Private

    private static func next(after reference: Date, _ components: DateComponents, _ calendar: Calendar) -> Date? {
        calendar.nextDate(after: reference, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }

    /// `day` clamped to each month's last day (31 → 30 April, 28/29 February).
    private static func nextMonthly(day: Int, hour: Int, minute: Int, after reference: Date, calendar: Calendar) -> Date? {
        let start = calendar.dateComponents([.year, .month], from: reference)
        guard let firstOfMonth = calendar.date(from: DateComponents(year: start.year, month: start.month, day: 1)) else { return nil }
        for offset in 0..<14 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: firstOfMonth),
                  let days = calendar.range(of: .day, in: .month, for: month)
            else { continue }
            let c = calendar.dateComponents([.year, .month], from: month)
            let target = min(day, days.upperBound - 1)
            guard let dayStart = calendar.date(from: DateComponents(year: c.year, month: c.month, day: target)) else { continue }
            // The time of day through the same DST policy as the other schedules.
            guard let candidate = next(after: dayStart.addingTimeInterval(-1), DateComponents(hour: hour, minute: minute, second: 0), calendar),
                  calendar.isDate(candidate, inSameDayAs: dayStart)
            else { continue }
            if candidate > reference { return candidate }
        }
        return nil
    }
}
