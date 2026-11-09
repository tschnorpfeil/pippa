import CryptoKit
import EventKit
import Foundation

final class EventKitBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: EKEventStore?

    /// Create fresh after a new permission (otherwise the old store sees nothing).
    var store: EKEventStore {
        lock.withLock {
            if let cached { return cached }
            let s = EKEventStore()
            cached = s
            return s
        }
    }

    private static func type(_ i: Integration) -> EKEntityType { i == .reminders ? .reminder : .event }

    func access(_ i: Integration) -> IntegrationAccess {
        switch EKEventStore.authorizationStatus(for: Self.type(i)) {
        case .fullAccess: .granted
        // "Add only" is not enough for undo: ask again.
        case .notDetermined, .writeOnly: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func request(_ i: Integration) async -> IntegrationAccess {
        let s = EKEventStore()
        do {
            if i == .reminders { _ = try await s.requestFullAccessToReminders() } else { _ = try await s.requestFullAccessToEvents() }
        } catch {
            // Without a prompt (missing right, or macOS gave the request to another app, e.g. Terminal) it ends here.
            DiagnosticsLog.shared.event("zugriff-fehler", ["app": i.rawValue, "fehler": String(describing: error).prefix(200).description])
            return access(i)
        }
        lock.withLock { cached = s }
        return access(i)
    }

    func remove(_ item: CreatedItem) throws -> RemoveResult {
        guard access(item.integration) == .granted else { throw PippaError.accessDenied(item.integration.appName) }
        let s = store
        guard let ci = s.calendarItem(withIdentifier: item.identifier) else { return .gone }
        if let expected = item.fingerprint, fingerprint(ci) != expected { return .changed }
        if let then = item.modified, let now = ci.lastModifiedDate, now != then { return .changed }
        if let ev = ci as? EKEvent { try s.remove(ev, span: .thisEvent, commit: true) }
        else if let r = ci as? EKReminder { try s.remove(r, commit: true) }
        else { return .gone }
        return .removed
    }

    /// Read only. All calendars for events, occurrences of recurring series as EventKit expands them; no notes,
    /// attendees or links, only what an answer needs. Never asks for permissions.
    func read(_ interval: DateInterval, limit: Int) throws -> CalendarFetch {
        guard access(.calendar) == .granted else { throw PippaError.accessDenied(Integration.calendar.appName) }
        let s = store
        s.refreshSourcesIfNecessary()
        let calendars = s.calendars(for: .event)
        guard !calendars.isEmpty else { return CalendarFetch(events: [], total: 0, calendars: []) }
        let predicate = s.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        let found = s.events(matching: predicate).sorted { $0.compareStartDate(with: $1) == .orderedAscending }
        let events = found.prefix(limit).map { ev in
            let status: CalendarEvent.Status = switch ev.status {
            case .canceled: .cancelled
            case .tentative: .tentative
            case .confirmed: .confirmed
            default: .none
            }
            let declined = ev.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            return CalendarEvent(id: ev.eventIdentifier ?? ev.calendarItemIdentifier, title: ev.title ?? "", start: ev.startDate, end: ev.endDate,
                                 allDay: ev.isAllDay, calendar: ev.calendar?.title ?? "", timeZone: ev.isAllDay ? nil : ev.timeZone?.identifier,
                                 status: status, declined: declined, recurring: ev.hasRecurrenceRules || ev.isDetached, location: ev.location,
                                 color: ev.calendar?.cgColor.flatMap(Self.hex))
        }
        return CalendarFetch(events: Array(events), total: found.count, calendars: calendars.map(\.title).sorted())
    }

    /// "#RRGGBB" in sRGB, for the calendar card.
    static func hex(_ color: CGColor) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB), let c = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let parts = c.components, parts.count >= 3 else { return nil }
        let v = parts.prefix(3).map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", v[0], v[1], v[2])
    }

    /// Content only as a hash in the journal: also detect changes within one timestamp second.
    func fingerprint(_ item: EKCalendarItem) -> String {
        var parts = [item.title ?? "", item.notes ?? "", item.url?.absoluteString ?? "", item.calendar?.calendarIdentifier ?? ""]
        if let event = item as? EKEvent {
            parts += [String(event.startDate.timeIntervalSinceReferenceDate), String(event.endDate.timeIntervalSinceReferenceDate),
                      String(event.isAllDay), event.location ?? "", event.timeZone?.identifier ?? ""]
        }
        if let reminder = item as? EKReminder {
            parts += [String(describing: reminder.dueDateComponents), String(reminder.isCompleted), String(reminder.priority)]
        }
        for alarm in item.alarms ?? [] { parts += [String(describing: alarm.absoluteDate), String(alarm.relativeOffset)] }
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
