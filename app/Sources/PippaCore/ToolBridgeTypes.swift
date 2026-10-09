import Foundation

// FLOW-10 "Read calendar": Pi asks via Pippa's MCP tool for a kind of period; the host (Swift) computes it,
// reads EventKit itself and returns finished days and times formatted in code (PippaMCPTools).
// The agent never gets access to EventKit and never asks for permissions itself.

/// Untrusted request from the calendar tool. `period`: today, tomorrow, rest_of_week, next_week, weekend, next_days (with `days`)
/// or dates (with `start`/`end` as YYYY-MM-DD). Anything else is refused as `invalid_range`.
public struct CalendarToolRequest: Sendable, Equatable {
    public var period: String
    public var start: String?
    public var end: String?
    public var days: Int?
    public init(period: String, start: String? = nil, end: String? = nil, days: Int? = nil) {
        self.period = period; self.start = start; self.end = end; self.days = days
    }
}

public struct CalendarToolReply: Sendable, Equatable {
    public enum Status: String, Sendable {
        case ok
        /// Never asked: the app offers the permission (button), never the tool itself.
        case needsAccess = "needs_access"
        case denied, failed
        case invalidRange = "invalid_range"
    }
    public var status: Status
    /// On `ok`: JSON object from `CalendarDigest.toolPayload` (source, period, days, events), otherwise empty.
    public var payload: Data?
    public init(status: Status, payload: Data? = nil) { self.status = status; self.payload = payload }
}
