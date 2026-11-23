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

    /// Read only. All calendars for events, occurrences of recurring series as EventKit expands them, with organizer,
    /// attendees, link and notes (`CalendarDigest` clips them). Never asks for permissions.
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
            let selfStatus = ev.attendees?.first(where: \.isCurrentUser).flatMap { Self.status($0.participantStatus) }
            let attendees = (ev.attendees ?? []).compactMap { p -> CalendarEvent.Attendee? in
                guard let name = Self.name(p) else { return nil }
                return CalendarEvent.Attendee(name: name, status: Self.status(p.participantStatus), isCurrentUser: p.isCurrentUser)
            }
            return CalendarEvent(id: ev.eventIdentifier ?? ev.calendarItemIdentifier, title: ev.title ?? "", start: ev.startDate, end: ev.endDate,
                                 allDay: ev.isAllDay, calendar: ev.calendar?.title ?? "", timeZone: ev.isAllDay ? nil : ev.timeZone?.identifier,
                                 status: status, declined: declined, recurring: ev.hasRecurrenceRules || ev.isDetached, location: ev.location,
                                 color: ev.calendar?.cgColor.flatMap(Self.hex), organizer: ev.organizer.flatMap(Self.name),
                                 selfStatus: selfStatus, attendees: attendees, url: ev.url?.absoluteString, notes: ev.notes)
        }
        return CalendarFetch(events: Array(events), total: found.count, calendars: calendars.map(\.title).sorted())
    }

    static func status(_ s: EKParticipantStatus) -> CalendarEvent.ParticipantStatus? {
        switch s {
        case .accepted: .accepted
        case .tentative: .tentative
        case .pending: .pending
        case .declined: .declined
        default: nil
        }
    }

    /// The participant's name, else the address without "mailto:".
    static func name(_ p: EKParticipant) -> String? {
        if let name = p.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let address = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored])
        return address.isEmpty ? nil : address.removingPercentEncoding ?? address
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
        return SHA256.hash(data: data).hexString
    }
}

// MARK: Updating events and reminders (calendar_update, reminder_update) and their Undo

extension EventKitBridge {
    /// By `calendarItemIdentifier` (what the journal keeps) or `eventIdentifier` (what `calendar_read` shows).
    private func findEvent(_ identifier: String) -> EKEvent? {
        let s = store
        return s.calendarItem(withIdentifier: identifier) as? EKEvent ?? s.event(withIdentifier: identifier)
    }

    /// Fail closed: attendees could get an update, a series could change beyond this one occurrence, and a read-only
    /// calendar would refuse or sync back. Checked on every look, before every save and before every Undo.
    private func guardEditable(_ ev: EKEvent) throws {
        if !(ev.attendees ?? []).isEmpty { throw CalendarUpdateError.hasAttendees }
        if ev.hasRecurrenceRules || ev.isDetached { throw CalendarUpdateError.isRecurring }
        guard let calendar = ev.calendar, calendar.allowsContentModifications else {
            throw CalendarUpdateError.readOnly(ev.calendar?.title ?? "")
        }
    }

    private static func snapshot(_ ev: EKEvent) -> CalendarEventSnapshot {
        CalendarEventSnapshot(title: ev.title ?? "", start: ev.startDate, end: ev.endDate, allDay: ev.isAllDay, location: ev.location,
                              notes: ev.notes, calendar: ev.calendar?.title ?? "")
    }

    func eventSnapshot(identifier: String) throws -> EventLookup {
        guard access(.calendar) == .granted else { throw PippaError.accessDenied(Integration.calendar.appName) }
        guard let ev = findEvent(identifier) else { throw CalendarUpdateError.notFound }
        try guardEditable(ev)
        return EventLookup(identifier: ev.calendarItemIdentifier, snapshot: Self.snapshot(ev), fingerprint: fingerprint(ev))
    }

    func updateEvent(identifier: String, patch: CalendarEventPatch) throws -> EventUpdateResult {
        guard access(.calendar) == .granted else { throw PippaError.accessDenied(Integration.calendar.appName) }
        guard let ev = findEvent(identifier) else { throw CalendarUpdateError.notFound }
        try guardEditable(ev)
        if let expected = patch.expectedFingerprint, fingerprint(ev) != expected { throw CalendarUpdateError.changed }
        let before = Self.snapshot(ev)
        let (wanted, changed) = patch.applied(to: before)
        Self.apply(wanted, to: ev)
        try PippaMCPWriteLease.current?.beginDispatch()
        try store.save(ev, span: .thisEvent, commit: true)
        return EventUpdateResult(identifier: ev.calendarItemIdentifier, before: before, after: Self.snapshot(ev), fingerprint: fingerprint(ev),
                                 modified: ev.lastModifiedDate, container: ev.calendar?.title ?? "", changed: changed)
    }

    func restoreEvent(identifier: String, expectedFingerprint: String?, snapshot: CalendarEventSnapshot) -> RunUndoOutcome {
        guard access(.calendar) == .granted else { return .failed }
        guard let ev = findEvent(identifier) else { return .gone }
        // Attendees or a series added since: never touched by Undo either.
        guard (try? guardEditable(ev)) != nil else { return .changed }
        if let expectedFingerprint, fingerprint(ev) != expectedFingerprint { return .changed }
        Self.apply(snapshot, to: ev)
        do { try store.save(ev, span: .thisEvent, commit: true) } catch { return .failed }
        return .undone
    }

    private static func apply(_ s: CalendarEventSnapshot, to ev: EKEvent) {
        if ev.title != s.title { ev.title = s.title }
        if ev.isAllDay != s.allDay { ev.isAllDay = s.allDay }
        if ev.startDate != s.start { ev.startDate = s.start }
        if ev.endDate != s.end { ev.endDate = s.end }
        if ev.location != s.location { ev.location = s.location }
        if ev.notes != s.notes { ev.notes = s.notes }
    }

    // Reminders

    private func findReminder(_ identifier: String) -> EKReminder? { store.calendarItem(withIdentifier: identifier) as? EKReminder }

    private static func snapshot(_ r: EKReminder) -> ReminderSnapshot {
        ReminderSnapshot(title: r.title ?? "", due: r.dueDateComponents, notes: r.notes, isCompleted: r.isCompleted,
                         list: r.calendar?.title ?? "", alarms: (r.alarms ?? []).compactMap(\.absoluteDate))
    }

    private func guardEditable(_ r: EKReminder) throws {
        guard let list = r.calendar, list.allowsContentModifications else { throw CalendarUpdateError.readOnly(r.calendar?.title ?? "") }
    }

    func reminderSnapshot(identifier: String) throws -> ReminderLookup {
        guard access(.reminders) == .granted else { throw PippaError.accessDenied(Integration.reminders.appName) }
        guard let r = findReminder(identifier) else { throw CalendarUpdateError.notFound }
        try guardEditable(r)
        return ReminderLookup(identifier: r.calendarItemIdentifier, snapshot: Self.snapshot(r), fingerprint: fingerprint(r))
    }

    func updateReminder(identifier: String, patch: ReminderPatch) throws -> ReminderUpdateResult {
        guard access(.reminders) == .granted else { throw PippaError.accessDenied(Integration.reminders.appName) }
        guard let r = findReminder(identifier) else { throw CalendarUpdateError.notFound }
        try guardEditable(r)
        if let expected = patch.expectedFingerprint, fingerprint(r) != expected { throw CalendarUpdateError.changed }
        let before = Self.snapshot(r)
        var (wanted, changed) = patch.applied(to: before)
        if changed.contains("due") {
            // The alert Pippa sets with a due date moves with it; other alarms stay as they are.
            let old = ReminderPatch.alertDate(before.due)
            wanted.alarms = before.alarms.filter { $0 != old } + (ReminderPatch.alertDate(wanted.due).map { [$0] } ?? [])
        }
        Self.apply(wanted, to: r)
        try PippaMCPWriteLease.current?.beginDispatch()
        try store.save(r, commit: true)
        return ReminderUpdateResult(identifier: r.calendarItemIdentifier, before: before, after: Self.snapshot(r), fingerprint: fingerprint(r),
                                    modified: r.lastModifiedDate, container: r.calendar?.title ?? "", changed: changed)
    }

    func restoreReminder(identifier: String, expectedFingerprint: String?, snapshot: ReminderSnapshot) -> RunUndoOutcome {
        guard access(.reminders) == .granted else { return .failed }
        guard let r = findReminder(identifier) else { return .gone }
        guard (try? guardEditable(r)) != nil else { return .changed }
        if let expectedFingerprint, fingerprint(r) != expectedFingerprint { return .changed }
        Self.apply(snapshot, to: r)
        do { try store.save(r, commit: true) } catch { return .failed }
        return .undone
    }

    private static func apply(_ s: ReminderSnapshot, to r: EKReminder) {
        if r.title != s.title { r.title = s.title }
        if r.notes != s.notes { r.notes = s.notes }
        if r.dueDateComponents.map(ReminderSnapshot.normalized) != s.due {
            r.dueDateComponents = s.due.map { due in var c = due; c.calendar = Calendar(identifier: .gregorian); return c }
        }
        let absolute = (r.alarms ?? []).compactMap(\.absoluteDate)
        if absolute != s.alarms {
            for alarm in r.alarms ?? [] where alarm.absoluteDate != nil { r.removeAlarm(alarm) }
            for date in s.alarms { r.addAlarm(EKAlarm(absoluteDate: date)) }
        }
        // Completing sets completionDate; uncompleting clears it (EventKit does both through isCompleted).
        if r.isCompleted != s.isCompleted { r.isCompleted = s.isCompleted }
    }
}
