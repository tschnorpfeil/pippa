import Foundation

// Connections to apps on the Mac: Reminders, Calendar (EventKit) and Mail (Apple Events, read only).
// Everything sits behind `AppIntegrations`, so `StubEngine`, PIPPA_DEMO=1 and tests run with
// `DemoIntegrations` without touching real calendars or mail.

public enum Integration: String, Sendable, CaseIterable, Codable {
    case reminders, calendar, mail

    /// Name of the app, as people know it.
    public var appName: String {
        switch self {
        case .reminders: L("Reminders", table: "Core")
        case .calendar: L("Calendar", table: "Core")
        case .mail: L("Mail", table: "Core")
        }
    }

    /// Area in System Settings → Privacy & Security.
    public var settingsURL: URL {
        let anchor = switch self {
        case .reminders: "Privacy_Reminders"
        case .calendar: "Privacy_Calendars"
        case .mail: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    public var bundleIdentifier: String {
        switch self {
        case .reminders: "com.apple.reminders"
        case .calendar: "com.apple.iCal"
        case .mail: "com.apple.mail"
        }
    }
}

public enum IntegrationAccess: Sendable, Equatable {
    case granted
    /// Never asked before: first a friendly sentence, then the system prompt.
    case notDetermined
    case denied
    /// Not available right now, with a short reason (e.g. "Mail ist nicht offen").
    case unavailable(String)
}

/// Entry created by Pippa, remembered for undo.
public struct CreatedItem: Sendable, Hashable, Codable {
    public var integration: Integration
    public var identifier: String
    /// Modification time right after creation; changed later = no longer our state.
    public var modified: Date?
    public var fingerprint: String?
    public init(integration: Integration, identifier: String, modified: Date?, fingerprint: String? = nil) {
        self.integration = integration; self.identifier = identifier; self.modified = modified; self.fingerprint = fingerprint
    }
}

public enum RemoveResult: Sendable, Equatable {
    case removed
    /// Already gone (e.g. deleted by the person).
    case gone
    /// Changed in the meantime: stays as it is.
    case changed
}

/// A mail, read only.
public struct MailMessage: Sendable, Hashable {
    public var subject: String
    public var sender: String
    public var date: Date?
    public var body: String
    public var attachmentNames: [String]
    /// Identifier of the mail in Mail (`message id`) at read time; so Insert replies to exactly this mail.
    public var messageID: String?
    public var replyTo: String?
    /// Where Mail showed this message at Call (account, mailbox, Mail's id). A hint for Insert, never shown.
    public var locator: MailLocator?
    public var replySource: MailReplySource? {
        let target = replyTo?.trimmingCharacters(in: .whitespacesAndNewlines)
        return messageID.flatMap { MailReplySource(messageID: $0, replyTo: target.flatMap { $0.isEmpty ? nil : $0 } ?? sender, subject: subject) }
    }
    public init(subject: String, sender: String, date: Date?, body: String, attachmentNames: [String], messageID: String? = nil, replyTo: String? = nil,
                locator: MailLocator? = nil) {
        self.subject = subject; self.sender = sender; self.date = date; self.body = body; self.attachmentNames = attachmentNames
        self.messageID = messageID; self.replyTo = replyTo; self.locator = locator
    }

    /// As .eml text, so the normal flow (overview, deadlines, questions) reads it like a filed mail.
    /// Attachments appear by name only (empty parts); their content is not read.
    public var emlText: String {
        let boundary = "pippa-mail-boundary-7f3a"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        func header(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["From: \(header(sender))", "Subject: \(header(subject))"]
        if let source = replySource { lines.append("Message-ID: <\(source.messageID)>") }
        if let replyTo, !replyTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("Reply-To: \(header(replyTo))") }
        if let date { lines.append("Date: \(f.string(from: date))") }
        lines += ["MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"\(boundary)\"", "",
                  "--\(boundary)", "Content-Type: text/plain; charset=utf-8", "", body.replacingOccurrences(of: "\r\n", with: "\n")]
        for name in attachmentNames {
            let safe = header(name).replacingOccurrences(of: "\"", with: "'")
            lines += ["--\(boundary)", "Content-Type: application/octet-stream; name=\"\(safe)\"",
                      "Content-Disposition: attachment; filename=\"\(safe)\"", ""]
        }
        lines.append("--\(boundary)--")
        return lines.joined(separator: "\n") + "\n"
    }

    /// File name for filing: subject, sanitized.
    public var fileName: String {
        let base = Naming.sanitize(subject, maxLength: 60)
        return (base.isEmpty ? "Mail" : base) + ".eml"
    }
}

/// Access to other apps. Reading is free; writing only after approval in the preview (the UI
/// calls `add` only after "Anwenden"). No sending, no deleting of others' things.
public protocol AppIntegrations: Sendable {
    func access(_ integration: Integration) async -> IntegrationAccess
    /// Shows the system prompt if needed. Only call when the person is using the feature right now.
    func requestAccess(_ integration: Integration) async -> IntegrationAccess
    func add(_ entry: CalendarEntry, tag: URL) async throws -> CreatedItem
    /// Removes only what Pippa created and what has not been changed since.
    func remove(_ item: CreatedItem) async throws -> RemoveResult
    func selectedMail() async throws -> MailMessage?
    /// Creates an unsent native reply to the captured original identity. Never falls back to compose.
    func insertReply(_ draft: MailDraft) async throws -> MailInsertResult
    /// Occurrences overlapping `interval` from every event calendar, read only, sorted by start, at most `limit`
    /// (`total` says how many there were). Never asks for access; throws `accessDenied` without it.
    func events(in interval: DateInterval, limit: Int) async throws -> CalendarFetch
}

public extension AppIntegrations {
    func insertReply(_ draft: MailDraft) async throws -> MailInsertResult { throw PippaError.notAvailable }
    func events(in interval: DateInterval, limit: Int) async throws -> CalendarFetch { throw PippaError.notAvailable }
}

/// Stand-in without real apps: for PIPPA_DEMO=1, StubEngine and tests. Keeps everything in memory.
public final class DemoIntegrations: AppIntegrations, @unchecked Sendable {
    private let lock = NSLock()
    private var state: [Integration: IntegrationAccess]
    private var items: [String: (item: CreatedItem, title: String)] = [:]
    private var drafts: [MailDraft] = []
    public var sampleMail: MailMessage?
    /// Synthetic events (never real); `nil` = `sampleCalendar` relative to now. Tests and PIPPA_DEMO only.
    public var calendarEvents: [CalendarEvent]?
    public var calendarNames = ["Arbeit", "Privat"]
    /// Tests: reading fails technically (e.g. calendar database unreachable).
    public var calendarFails = false
    private var reads: [DateInterval] = []
    private let created = Date()
    /// Events created by Pippa's MCP server (appear on the next read) and, in tests, "changed by hand".
    private var addedEvents: [String: CalendarEvent] = [:]
    private var edited: Set<String> = []
    /// Lists for `addReminder` (invented).
    public var reminderLists = ["Erinnerungen", "Privat"]
    /// Tests: what `insertReply` reports instead of a draft (error) or which result (e.g. `replyNeedsPaste`).
    public var replyFailure: MailReplyFailure?
    public var replyOutcome: MailInsertResult?

    public init(granted: Bool = false) {
        state = Dictionary(uniqueKeysWithValues: Integration.allCases.map { ($0, granted ? .granted : .notDetermined) })
        sampleMail = MailMessage(subject: "Nebenkostenabrechnung 2025", sender: "Hausverwaltung Berger <info@berger-hv.de>",
                                 date: DayDate(year: 2026, month: 10, day: 1)?.localNoon,
                                 body: "Guten Tag,\n\nanbei die Nebenkostenabrechnung 2025. Die Nachzahlung von 312,48 € ist zahlbar bis 31.10.2026.\n\nFreundliche Grüße\nHausverwaltung Berger",
                                 attachmentNames: ["Nebenkosten 2025.pdf"], messageID: "demo-nebenkosten-2025@berger-hv.de")
    }

    public func set(_ integration: Integration, _ access: IntegrationAccess) { lock.withLock { state[integration] = access } }

    public func access(_ integration: Integration) async -> IntegrationAccess { lock.withLock { state[integration] ?? .notDetermined } }

    public func requestAccess(_ integration: Integration) async -> IntegrationAccess {
        lock.withLock {
            if state[integration] == .notDetermined { state[integration] = .granted }
            return state[integration] ?? .granted
        }
    }

    private func requireGranted(_ i: Integration) throws {
        guard lock.withLock({ state[i] }) == .granted else { throw PippaError.accessDenied(i.appName) }
    }

    public func add(_ entry: CalendarEntry, tag: URL) async throws -> CreatedItem {
        try requireGranted(entry.integration)
        let item = CreatedItem(integration: entry.integration, identifier: "demo-\(UUID().uuidString)", modified: Date())
        lock.withLock { items[item.identifier] = (item, entry.title) }
        return item
    }

    public func remove(_ item: CreatedItem) async throws -> RemoveResult {
        lock.withLock {
            // Like EventKitBridge.remove: changed since creation → stays.
            if edited.contains(item.identifier), items[item.identifier] != nil { return .changed }
            addedEvents.removeValue(forKey: item.identifier)
            return items.removeValue(forKey: item.identifier) != nil ? .removed : .gone
        }
    }

    /// Tests only: the person changes a created entry in the app (afterwards undo no longer removes it).
    public func simulateEdit(_ identifier: String) { lock.withLock { _ = edited.insert(identifier) } }

    /// Tests only: title of a still-existing entry created by Pippa.
    public func createdTitle(_ identifier: String) -> String? { lock.withLock { items[identifier]?.title } }

    /// Tests only: number of created entries.
    public var createdCount: Int { lock.withLock { items.count } }

    public func selectedMail() async throws -> MailMessage? {
        try requireGranted(.mail)
        return sampleMail
    }

    /// Remembers the draft instead of opening a window. Never sends.
    public func insertReply(_ draft: MailDraft) async throws -> MailInsertResult {
        try requireGranted(.mail)
        if draft.isReply, draft.messageID.flatMap(MailReplySource.canonicalMessageID) == nil {
            throw MailReplyFailure.missingOriginal
        }
        let (failure, outcome) = lock.withLock { (replyFailure, replyOutcome) }
        if let failure { throw failure }
        lock.withLock { drafts.append(draft) }
        return outcome ?? (draft.isReply ? .reply : .newMessage)
    }

    /// Tests only: inserted drafts in order.
    public var insertedDrafts: [MailDraft] { lock.withLock { drafts } }

    /// Like EventKit: all occurrences overlapping the range, sorted by start, at most `limit`.
    public func events(in interval: DateInterval, limit: Int) async throws -> CalendarFetch {
        try requireGranted(.calendar)
        lock.withLock { reads.append(interval) }
        if calendarFails { throw PippaError.entryFailed("demo") }
        let added = lock.withLock { Array(addedEvents.values) }
        let all = ((calendarEvents ?? Self.sampleCalendar(now: created)) + added)
            .filter { ($0.end > interval.start || ($0.end == $0.start && $0.start >= interval.start)) && $0.start < interval.end }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        return CalendarFetch(events: Array(all.prefix(limit)), total: all.count, calendars: calendarNames)
    }

    /// Tests only: which ranges were read (no reading without access).
    public var calendarReads: [DateInterval] { lock.withLock { reads } }

    /// Synthetic week around `now`, freely invented (no real calendar data).
    public static func sampleCalendar(now: Date, calendar: Calendar = .autoupdatingCurrent) -> [CalendarEvent] {
        let today = calendar.startOfDay(for: now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: day, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }
        func dayStart(_ day: Int) -> Date { calendar.date(byAdding: .day, value: day, to: today) ?? today }
        return [
            CalendarEvent(id: "demo-zahnarzt", title: "Zahnarzt (Beispiel)", start: at(0, 16), end: at(0, 17), calendar: "Privat", location: "Praxis Beispiel"),
            CalendarEvent(id: "demo-standup", title: "Team-Standup (Beispiel)", start: at(1, 9), end: at(1, 9, 30), calendar: "Arbeit", status: .confirmed, recurring: true),
            CalendarEvent(id: "demo-standup", title: "Team-Standup (Beispiel)", start: at(2, 9), end: at(2, 9, 30), calendar: "Arbeit", status: .cancelled, recurring: true),
            CalendarEvent(id: "demo-call", title: "Abstimmung Projekt (Beispiel)", start: at(2, 15), end: at(2, 16), calendar: "Arbeit",
                          timeZone: "America/New_York", declined: true),
            CalendarEvent(id: "demo-reise", title: "Reise nach Hamburg (Beispiel)", start: dayStart(3), end: dayStart(5).addingTimeInterval(-1),
                          allDay: true, calendar: "Privat"),
            CalendarEvent(id: "demo-essen", title: "Abendessen mit Freunden (Beispiel)", start: at(4, 19), end: at(4, 22), calendar: "Privat"),
        ]
    }
}


// Create events and reminders, in memory only (tests, PIPPA_DEMO, end-to-end). Never touches real apps.
extension DemoIntegrations: HostWriting {
    public func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite {
        try requireGranted(.calendar)
        let id = "demo-\(UUID().uuidString)"
        let item = CreatedItem(integration: .calendar, identifier: id, modified: Date(), fingerprint: "demo-\(id)")
        let calendar = calendarNames.last ?? "Privat"
        lock.withLock {
            items[id] = (item, event.title)
            addedEvents[id] = CalendarEvent(id: id, title: event.title, start: event.start, end: event.end, allDay: event.allDay,
                                            calendar: calendar, location: event.location)
        }
        return HostWrite(item: item, container: calendar)
    }

    public func addReminder(_ reminder: NewReminder) async throws -> HostWrite {
        try requireGranted(.reminders)
        let id = "demo-\(UUID().uuidString)"
        let item = CreatedItem(integration: .reminders, identifier: id, modified: Date(), fingerprint: "demo-\(id)")
        let wanted = reminder.list?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = wanted.flatMap { name in reminderLists.first { $0.lowercased() == name } }
        lock.withLock { items[id] = (item, reminder.title) }
        return HostWrite(item: item, container: named ?? reminderLists.first ?? "Erinnerungen", containerMatched: wanted == nil || named != nil)
    }
}
