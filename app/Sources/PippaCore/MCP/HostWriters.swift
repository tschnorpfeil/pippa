import EventKit
import Foundation

// Create events and reminders for Pippa's MCP server. Separate from `AppIntegrations`
// (the old flow with all-day deadlines stays unchanged there), but with the same EventKit store and the same
// fingerprint: `AppIntegrations.remove` later removes only what is unchanged since it was created.

/// A new event, as Pippa's server computed it from the tool call (the model never computes dates).
public struct NewCalendarEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String?
    public var notes: String?
    /// Name of the target calendar (case-insensitive); `nil` = the default calendar for new events.
    public var calendar: String?
    public init(title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil, notes: String? = nil, calendar: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.notes = notes
        self.calendar = calendar
    }
}

/// A named target calendar that cannot be used. Thrown before anything is saved: never a silent fallback.
public enum CalendarTargetError: Error, Equatable {
    /// `writable`: the calendars one can add to, for the local answer.
    case notFound(String, writable: [String])
    case ambiguous(String)
    case readOnly(String)

    public var status: String {
        switch self {
        case .notFound: "not_found"
        case .ambiguous: "ambiguous"
        case .readOnly: "invalid_arguments"
        }
    }

    var receiptReason: String {
        switch self {
        case .notFound: "notFound"
        case .ambiguous: "ambiguous"
        case .readOnly: "readOnly"
        }
    }

    /// Exactly one calendar with this name (case-insensitive) that allows changes.
    static func match<C>(_ name: String, in calendars: [C], title: (C) -> String, writable: (C) -> Bool) throws -> C {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = calendars.filter { title($0).localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        guard let only = found.first else {
            throw notFound(wanted, writable: calendars.filter(writable).map(title).sorted())
        }
        guard found.count == 1 else { throw ambiguous(wanted) }
        guard writable(only) else { throw readOnly(title(only)) }
        return only
    }
}

/// A new reminder. `due`: year, month, day and optionally hour/minute (then due at a time of day).
public struct NewReminder: Sendable, Equatable, Codable {
    public var title: String
    public var due: DateComponents?
    public var list: String?
    public var notes: String?
    public init(title: String, due: DateComponents? = nil, list: String? = nil, notes: String? = nil) {
        self.title = title; self.due = due; self.list = list; self.notes = notes
    }
}

/// Created: the entry for undo and where it ended up.
public struct HostWrite: Sendable, Equatable, Codable {
    public var item: CreatedItem
    /// Calendar or list the entry is in.
    public var container: String
    public var containerIdentifier: String?
    /// `false`: the requested list did not exist, the entry is in the default list.
    public var containerMatched: Bool
    public init(item: CreatedItem, container: String, containerMatched: Bool = true, containerIdentifier: String? = nil) {
        self.item = item; self.container = container; self.containerMatched = containerMatched; self.containerIdentifier = containerIdentifier
    }
}

/// An event or reminder as the store has it now, read by its EventKit identifier (run journal verification).
public enum CreatedItemReadBack: Sendable, Equatable {
    case found(title: String, start: Date?, end: Date?, container: String?, fingerprint: String?)
    case gone
    /// No permission or no store: nothing could be read, so nothing is confirmed.
    case unavailable
}

// MARK: Updating events and reminders

/// An event's editable fields as they were (journaled before an update, restored by Undo).
public struct CalendarEventSnapshot: Sendable, Equatable, Codable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String?
    public var notes: String?
    /// The calendar's title (never changed by an update).
    public var calendar: String
    public init(title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil, notes: String? = nil, calendar: String) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.notes = notes
        self.calendar = calendar
    }
}

/// What to change on an event, already computed by Pippa's server. `nil` = leave as it is.
public struct CalendarEventPatch: Sendable, Equatable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var allDay: Bool?
    public var location: String?
    public var notes: String?
    /// The fingerprint Pippa saw when she computed the patch: anything else at save time refuses (`.changed`).
    public var expectedFingerprint: String?
    public init(title: String? = nil, start: Date? = nil, end: Date? = nil, allDay: Bool? = nil, location: String? = nil,
                notes: String? = nil, expectedFingerprint: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.notes = notes
        self.expectedFingerprint = expectedFingerprint
    }

    /// The snapshot with this patch applied, and the names of the fields that actually change.
    public func applied(to s: CalendarEventSnapshot) -> (CalendarEventSnapshot, [String]) {
        var after = s
        if let title { after.title = title }
        if let start { after.start = start }
        if let end { after.end = end }
        if let allDay { after.allDay = allDay }
        if let location { after.location = location }
        if let notes { after.notes = notes }
        var changed: [String] = []
        if after.title != s.title { changed.append("title") }
        if after.start != s.start || after.end != s.end || after.allDay != s.allDay { changed.append("time") }
        if after.location != s.location { changed.append("location") }
        if after.notes != s.notes { changed.append("notes") }
        return (after, changed)
    }
}

/// An event as the store has it now, by its identifier, after the update guards passed.
public struct EventLookup: Sendable, Equatable {
    /// The identifier Undo uses (EventKit's `calendarItemIdentifier`).
    public var identifier: String
    public var snapshot: CalendarEventSnapshot
    public var fingerprint: String?
    public init(identifier: String, snapshot: CalendarEventSnapshot, fingerprint: String?) {
        self.identifier = identifier; self.snapshot = snapshot; self.fingerprint = fingerprint
    }
}

public struct EventUpdateResult: Sendable, Equatable {
    public var identifier: String
    public var before: CalendarEventSnapshot
    public var after: CalendarEventSnapshot
    /// Fingerprint and modification time right after the save: Undo restores only while they still match.
    public var fingerprint: String?
    public var modified: Date?
    public var container: String
    public var changed: [String]
    public init(identifier: String, before: CalendarEventSnapshot, after: CalendarEventSnapshot, fingerprint: String?, modified: Date?,
                container: String, changed: [String]) {
        self.identifier = identifier; self.before = before; self.after = after; self.fingerprint = fingerprint; self.modified = modified
        self.container = container; self.changed = changed
    }
}

/// An update that must not happen. Thrown before anything is saved; never a silent fallback.
public enum CalendarUpdateError: Error, Equatable {
    case notFound
    /// The event has attendees: changing it could send updates to other people.
    case hasAttendees
    /// The event belongs to a recurring series (or is a detached occurrence of one).
    case isRecurring
    /// The calendar or list does not allow changes.
    case readOnly(String)
    /// It changed between Pippa's look and the save.
    case changed

    public var status: String {
        switch self {
        case .notFound: "not_found"
        case .hasAttendees: "has_attendees"
        case .isRecurring: "recurring"
        case .readOnly: "read_only"
        case .changed: "changed"
        }
    }

    var receiptReason: String {
        switch self {
        case .notFound: "notFound"
        case .hasAttendees: "hasAttendees"
        case .isRecurring: "recurring"
        case .readOnly: "readOnly"
        case .changed: "changed"
        }
    }
}

/// A reminder's editable fields as they were (journaled before an update, restored by Undo).
public struct ReminderSnapshot: Sendable, Equatable, Codable {
    public var title: String
    /// Year, month, day and optionally hour/minute; `nil` = no due date.
    public var due: DateComponents?
    public var notes: String?
    public var isCompleted: Bool
    /// The list's title (never changed by an update).
    public var list: String
    /// Absolute alarm dates (relative alarms are never touched).
    public var alarms: [Date]
    public init(title: String, due: DateComponents? = nil, notes: String? = nil, isCompleted: Bool = false, list: String, alarms: [Date] = []) {
        self.title = title; self.due = due.map(Self.normalized); self.notes = notes; self.isCompleted = isCompleted; self.list = list
        self.alarms = alarms
    }

    /// Only year, month, day, hour and minute: EventKit adds calendar and other parts that would never compare equal.
    public static func normalized(_ c: DateComponents) -> DateComponents {
        DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute)
    }
}

/// What to change on a reminder. `nil` = leave as it is; `clearDue` removes the due date.
public struct ReminderPatch: Sendable, Equatable {
    public var title: String?
    public var due: DateComponents?
    public var clearDue: Bool
    public var notes: String?
    public var completed: Bool?
    public var expectedFingerprint: String?
    public init(title: String? = nil, due: DateComponents? = nil, clearDue: Bool = false, notes: String? = nil, completed: Bool? = nil,
                expectedFingerprint: String? = nil) {
        self.title = title; self.due = due.map(ReminderSnapshot.normalized); self.clearDue = clearDue; self.notes = notes
        self.completed = completed; self.expectedFingerprint = expectedFingerprint
    }

    /// The snapshot with this patch applied (alarms are the writer's business), and the fields that actually change.
    public func applied(to s: ReminderSnapshot) -> (ReminderSnapshot, [String]) {
        var after = s
        if let title { after.title = title }
        if clearDue { after.due = nil } else if let due { after.due = due }
        if let notes { after.notes = notes }
        if let completed { after.isCompleted = completed }
        var changed: [String] = []
        if after.title != s.title { changed.append("title") }
        if after.due != s.due { changed.append("due") }
        if after.notes != s.notes { changed.append("notes") }
        if after.isCompleted != s.isCompleted { changed.append("completed") }
        return (after, changed)
    }

    /// When the reminder alerts for a due date: at its time of day, else at 9:00 (as `addReminder`).
    static func alertDate(_ due: DateComponents?) -> Date? {
        guard var alert = due else { return nil }
        if alert.hour == nil { alert.hour = 9; alert.minute = 0 }
        return Calendar(identifier: .gregorian).date(from: alert)
    }
}

public struct ReminderLookup: Sendable, Equatable {
    public var identifier: String
    public var snapshot: ReminderSnapshot
    public var fingerprint: String?
    public init(identifier: String, snapshot: ReminderSnapshot, fingerprint: String?) {
        self.identifier = identifier; self.snapshot = snapshot; self.fingerprint = fingerprint
    }
}

public struct ReminderUpdateResult: Sendable, Equatable {
    public var identifier: String
    public var before: ReminderSnapshot
    public var after: ReminderSnapshot
    public var fingerprint: String?
    public var modified: Date?
    public var container: String
    public var changed: [String]
    public init(identifier: String, before: ReminderSnapshot, after: ReminderSnapshot, fingerprint: String?, modified: Date?,
                container: String, changed: [String]) {
        self.identifier = identifier; self.before = before; self.after = after; self.fingerprint = fingerprint; self.modified = modified
        self.container = container; self.changed = changed
    }
}

/// Create events and reminders. Never asks for permissions itself; without permission `PippaError.accessDenied`.
public protocol HostWriting: Sendable {
    func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite
    func addReminder(_ reminder: NewReminder) async throws -> HostWrite
    func reminderTarget(for reminder: NewReminder) async throws -> NativeReminderTarget
    func addReminder(_ reminder: NewReminder, target: NativeReminderTarget, marker: URL) async throws -> HostWrite
    func lookupReminder(marker: URL, target: NativeReminderTarget, identifier: String?) async -> NativeReminderLookup
    /// Reads what Pippa created back from the store, never from the object she saved. `container`: the calendar or
    /// list identifier for reminders, the calendar title for events.
    func readBack(_ item: CreatedItem) async -> CreatedItemReadBack
    /// The event by identifier, only if it may be updated: refuses (`CalendarUpdateError`) attendees, recurring series and
    /// read-only calendars. Read only.
    func eventSnapshot(identifier: String) async throws -> EventLookup
    /// Saves the patch after checking the same guards again, and the patch's expected fingerprint.
    func updateEvent(identifier: String, patch: CalendarEventPatch) async throws -> EventUpdateResult
    /// Undo: puts `snapshot` back only while the event still has `expectedFingerprint` (else `.changed`; deleted: `.gone`).
    func restoreEvent(identifier: String, expectedFingerprint: String?, snapshot: CalendarEventSnapshot) async -> RunUndoOutcome
    func reminderSnapshot(identifier: String) async throws -> ReminderLookup
    func updateReminder(identifier: String, patch: ReminderPatch) async throws -> ReminderUpdateResult
    func restoreReminder(identifier: String, expectedFingerprint: String?, snapshot: ReminderSnapshot) async -> RunUndoOutcome
}

extension HostWriting {
    // Older/custom hosts cannot silently bypass durable target and identity requirements.
    public func reminderTarget(for reminder: NewReminder) async throws -> NativeReminderTarget { throw PippaError.notAvailable }
    public func addReminder(_ reminder: NewReminder, target: NativeReminderTarget, marker: URL) async throws -> HostWrite { throw PippaError.notAvailable }
    public func lookupReminder(marker: URL, target: NativeReminderTarget, identifier: String?) async -> NativeReminderLookup { .unavailable }
    /// A writer that cannot read back confirms nothing.
    public func readBack(_ item: CreatedItem) async -> CreatedItemReadBack { .unavailable }
    // Writers without update support refuse; Undo of a row they cannot see fails rather than guessing.
    public func eventSnapshot(identifier: String) async throws -> EventLookup { throw PippaError.notAvailable }
    public func updateEvent(identifier: String, patch: CalendarEventPatch) async throws -> EventUpdateResult { throw PippaError.notAvailable }
    public func restoreEvent(identifier: String, expectedFingerprint: String?, snapshot: CalendarEventSnapshot) async -> RunUndoOutcome { .failed }
    public func reminderSnapshot(identifier: String) async throws -> ReminderLookup { throw PippaError.notAvailable }
    public func updateReminder(identifier: String, patch: ReminderPatch) async throws -> ReminderUpdateResult { throw PippaError.notAvailable }
    public func restoreReminder(identifier: String, expectedFingerprint: String?, snapshot: ReminderSnapshot) async -> RunUndoOutcome { .failed }
}

extension SystemIntegrations: HostWriting {
    public func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite { try eventKit.addEvent(event) }
    public func addReminder(_ reminder: NewReminder) async throws -> HostWrite { try eventKit.addReminder(reminder) }
    public func reminderTarget(for reminder: NewReminder) async throws -> NativeReminderTarget { try eventKit.reminderTarget(for: reminder) }
    public func addReminder(_ reminder: NewReminder, target: NativeReminderTarget, marker: URL) async throws -> HostWrite {
        try eventKit.addReminder(reminder, target: target, marker: marker)
    }
    public func lookupReminder(marker: URL, target: NativeReminderTarget, identifier: String?) async -> NativeReminderLookup {
        await eventKit.lookupReminder(marker: marker, target: target, identifier: identifier)
    }
    public func readBack(_ item: CreatedItem) async -> CreatedItemReadBack { eventKit.readBack(item) }
    public func eventSnapshot(identifier: String) async throws -> EventLookup { try eventKit.eventSnapshot(identifier: identifier) }
    public func updateEvent(identifier: String, patch: CalendarEventPatch) async throws -> EventUpdateResult {
        try eventKit.updateEvent(identifier: identifier, patch: patch)
    }
    public func restoreEvent(identifier: String, expectedFingerprint: String?, snapshot: CalendarEventSnapshot) async -> RunUndoOutcome {
        eventKit.restoreEvent(identifier: identifier, expectedFingerprint: expectedFingerprint, snapshot: snapshot)
    }
    public func reminderSnapshot(identifier: String) async throws -> ReminderLookup { try eventKit.reminderSnapshot(identifier: identifier) }
    public func updateReminder(identifier: String, patch: ReminderPatch) async throws -> ReminderUpdateResult {
        try eventKit.updateReminder(identifier: identifier, patch: patch)
    }
    public func restoreReminder(identifier: String, expectedFingerprint: String?, snapshot: ReminderSnapshot) async -> RunUndoOutcome {
        eventKit.restoreReminder(identifier: identifier, expectedFingerprint: expectedFingerprint, snapshot: snapshot)
    }
}

extension EventKitBridge {
    func readBack(_ item: CreatedItem) -> CreatedItemReadBack {
        guard access(item.integration) == .granted else { return .unavailable }
        guard let found = store.calendarItem(withIdentifier: item.identifier) else { return .gone }
        if let event = found as? EKEvent {
            return .found(title: event.title ?? "", start: event.startDate, end: event.endDate, container: event.calendar?.title,
                          fingerprint: fingerprint(event))
        }
        return .found(title: found.title ?? "", start: nil, end: nil, container: found.calendar?.calendarIdentifier, fingerprint: fingerprint(found))
    }

    /// Into the named calendar, else the default calendar for new events. No attendees, no invitation: nothing leaves the Mac.
    func addEvent(_ e: NewCalendarEvent) throws -> HostWrite {
        guard access(.calendar) == .granted else { throw PippaError.accessDenied(Integration.calendar.appName) }
        let s = store
        let named = try e.calendar.map { name in
            try CalendarTargetError.match(name, in: s.calendars(for: .event), title: \.title, writable: \.allowsContentModifications)
        }
        guard let calendar = named ?? s.defaultCalendarForNewEvents else { throw PippaError.entryFailed(L("I can’t find a calendar.", table: "Core")) }
        let ev = EKEvent(eventStore: s)
        ev.calendar = calendar
        ev.title = e.title
        ev.notes = e.notes
        ev.location = e.location
        ev.isAllDay = e.allDay
        ev.startDate = e.start
        ev.endDate = e.end
        try PippaMCPWriteLease.current?.beginDispatch()
        try s.save(ev, span: .thisEvent, commit: true)
        let item = CreatedItem(integration: .calendar, identifier: ev.calendarItemIdentifier, modified: ev.lastModifiedDate, fingerprint: fingerprint(ev))
        return HostWrite(item: item, container: calendar.title)
    }

    /// Into the named list (name, case-insensitive), otherwise into the default list. With a time of day: reminder at
    /// that time; with a day only: at 9:00 (like the deadlines in the old flow).
    func reminderTarget(for r: NewReminder) throws -> NativeReminderTarget {
        guard access(.reminders) == .granted else { throw PippaError.accessDenied(Integration.reminders.appName) }
        let s = store
        let wanted = r.list?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = wanted.flatMap { name in s.calendars(for: .reminder).first { $0.title.lowercased() == name } }
        guard let list = named ?? s.defaultCalendarForNewReminders() else {
            throw PippaError.entryFailed(L("I can’t find a reminders list.", table: "Core"))
        }
        return NativeReminderTarget(identifier: list.calendarIdentifier, title: list.title, matched: wanted == nil || named != nil)
    }

    func addReminder(_ r: NewReminder) throws -> HostWrite {
        try addReminder(r, target: reminderTarget(for: r), marker: nil)
    }

    func addReminder(_ r: NewReminder, target: NativeReminderTarget, marker: URL?) throws -> HostWrite {
        guard access(.reminders) == .granted else { throw PippaError.accessDenied(Integration.reminders.appName) }
        let s = store
        guard let list = s.calendar(withIdentifier: target.identifier), list.allowedEntityTypes.contains(.reminder), list.allowsContentModifications else {
            throw PippaError.entryFailed(L("I can’t find a reminders list.", table: "Core"))
        }
        let reminder = EKReminder(eventStore: s)
        reminder.calendar = list
        reminder.url = marker
        reminder.title = r.title
        reminder.notes = r.notes
        if var due = r.due {
            let cal = Calendar(identifier: .gregorian)
            due.calendar = cal
            reminder.dueDateComponents = due
            var alert = due
            if alert.hour == nil { alert.hour = 9; alert.minute = 0 }
            if let date = cal.date(from: alert) { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        }
        try PippaMCPWriteLease.current?.beginDispatch()
        try s.save(reminder, commit: true)
        let item = CreatedItem(integration: .reminders, identifier: reminder.calendarItemIdentifier, modified: reminder.lastModifiedDate,
                               fingerprint: fingerprint(reminder))
        return HostWrite(item: item, container: list.title, containerMatched: target.matched, containerIdentifier: list.calendarIdentifier)
    }
}
