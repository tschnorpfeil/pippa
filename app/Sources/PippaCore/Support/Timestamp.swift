import Foundation

/// `2026-11-09T12:30:00Z`: the time stamp of the log, the lock file and the release marker.
public enum Timestamp {
    public static func iso8601(_ date: Date = Date()) -> String { date.formatted(Date.ISO8601FormatStyle()) }
}
