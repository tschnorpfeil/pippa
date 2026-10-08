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
    public init(title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil, notes: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.notes = notes
    }
}

/// A new reminder. `due`: year, month, day and optionally hour/minute (then due at a time of day).
public struct NewReminder: Sendable, Equatable {
    public var title: String
    public var due: DateComponents?
    public var list: String?
    public var notes: String?
    public init(title: String, due: DateComponents? = nil, list: String? = nil, notes: String? = nil) {
        self.title = title; self.due = due; self.list = list; self.notes = notes
    }
}

/// Created: the entry for undo and where it ended up.
public struct HostWrite: Sendable, Equatable {
    public var item: CreatedItem
    /// Calendar or list the entry is in.
    public var container: String
    /// `false`: the requested list did not exist, the entry is in the default list.
    public var containerMatched: Bool
    public init(item: CreatedItem, container: String, containerMatched: Bool = true) {
        self.item = item; self.container = container; self.containerMatched = containerMatched
    }
}

/// Create events and reminders. Never asks for permissions itself; without permission `PippaError.accessDenied`.
public protocol HostWriting: Sendable {
    func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite
    func addReminder(_ reminder: NewReminder) async throws -> HostWrite
}

extension SystemIntegrations: HostWriting {
    public func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite { try eventKit.addEvent(event) }
    public func addReminder(_ reminder: NewReminder) async throws -> HostWrite { try eventKit.addReminder(reminder) }
}

extension EventKitBridge {
    /// Into the default calendar for new events. No attendees, no invitation: nothing leaves the Mac.
    func addEvent(_ e: NewCalendarEvent) throws -> HostWrite {
        guard access(.calendar) == .granted else { throw PippaError.accessDenied(Integration.calendar.appName) }
        let s = store
        guard let calendar = s.defaultCalendarForNewEvents else { throw PippaError.entryFailed(L("I can’t find a calendar.", table: "Core")) }
        let ev = EKEvent(eventStore: s)
        ev.calendar = calendar
        ev.title = e.title
        ev.notes = e.notes
        ev.location = e.location
        ev.isAllDay = e.allDay
        ev.startDate = e.start
        ev.endDate = e.end
        try s.save(ev, span: .thisEvent, commit: true)
        let item = CreatedItem(integration: .calendar, identifier: ev.calendarItemIdentifier, modified: ev.lastModifiedDate, fingerprint: fingerprint(ev))
        return HostWrite(item: item, container: calendar.title)
    }

    /// Into the named list (name, case-insensitive), otherwise into the default list. With a time of day: reminder at
    /// that time; with a day only: at 9:00 (like the deadlines in the old flow).
    func addReminder(_ r: NewReminder) throws -> HostWrite {
        guard access(.reminders) == .granted else { throw PippaError.accessDenied(Integration.reminders.appName) }
        let s = store
        let wanted = r.list?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = wanted.flatMap { name in s.calendars(for: .reminder).first { $0.title.lowercased() == name } }
        guard let list = named ?? s.defaultCalendarForNewReminders() else {
            throw PippaError.entryFailed(L("I can’t find a reminders list.", table: "Core"))
        }
        let reminder = EKReminder(eventStore: s)
        reminder.calendar = list
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
        try s.save(reminder, commit: true)
        let item = CreatedItem(integration: .reminders, identifier: reminder.calendarItemIdentifier, modified: reminder.lastModifiedDate,
                               fingerprint: fingerprint(reminder))
        return HostWrite(item: item, container: list.title, containerMatched: wanted == nil || named != nil)
    }
}
