import Foundation

/// Outcome of one calendar read. "No access", "technical error" and "nothing in the calendar" stay separate:
/// only `.read` with empty days means that really nothing is in the period.
public enum CalendarReadResult: Sendable, Equatable {
    case read(CalendarDigest)
    /// Never asked (or only "Add only" allowed): first the sentence with the benefit, then the system prompt.
    case needsAccess
    /// Denied or restricted; changeable only in System Settings.
    case denied
    /// Technical error, with a sentence for the person. Never says the calendar is empty.
    case failed(String)

    /// Only after a real read with zero events.
    public static var emptyText: String { L("Nothing in your calendar for this period.", table: "Calendar") }

    public static var failureText: String {
        L("I couldn’t read your calendar just now. That doesn’t mean it’s empty. Please try again.", table: "Calendar")
    }
}

/// Reads appointments of a period, read only, bounded, without ever asking for permissions itself.
public enum CalendarReader {
    /// Hard cap on occurrences per read; more are reported as „N von M“, never silently dropped.
    public static let limit = 60

    public static func read(_ range: CalendarRange, from integrations: any AppIntegrations, now: Date = Date(),
                            calendar: Calendar = .autoupdatingCurrent) async -> CalendarReadResult {
        guard range.end > range.start else { return .failed(failureText) }
        switch await integrations.access(.calendar) {
        case .granted: break
        case .notDetermined: return .needsAccess
        case .denied: return .denied
        case .unavailable(let why): return .failed(why)
        }
        do {
            let fetch = try await integrations.events(in: range.interval, limit: limit)
            DiagnosticsLog.shared.event("kalender-gelesen", ["termine": String(fetch.total), "kalender": String(fetch.calendars.count)])
            return .read(CalendarDigest.make(fetch, range: range, now: now, calendar: calendar))
        } catch PippaError.accessDenied {
            return .denied
        } catch {
            DiagnosticsLog.shared.event("kalender-fehler", [:])
            return .failed(failureText)
        }
    }

    private static var failureText: String { CalendarReadResult.failureText }

    /// Answer to `read_calendar`: compute the period in code, read, return as checked data.
    public static func toolReply(_ request: CalendarToolRequest, from integrations: any AppIntegrations, now: Date = Date(),
                                 calendar: Calendar = .autoupdatingCurrent) async -> CalendarToolReply {
        guard let range = CalendarRange.resolve(request, now: now, calendar: calendar) else { return CalendarToolReply(status: .invalidRange) }
        switch await read(range, from: integrations, now: now, calendar: calendar) {
        case .read(let digest):
            let payload = try? JSONSerialization.data(withJSONObject: digest.toolPayload(), options: [.sortedKeys])
            return payload.map { CalendarToolReply(status: .ok, payload: $0, card: digest.card) } ?? CalendarToolReply(status: .failed)
        case .needsAccess: return CalendarToolReply(status: .needsAccess)
        case .denied: return CalendarToolReply(status: .denied)
        case .failed: return CalendarToolReply(status: .failed)
        }
    }
}
