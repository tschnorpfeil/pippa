import CryptoKit
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
    /// The whole message as Mail keeps it (RFC 822, attachments included), when Mail gave it.
    public var source: String?
    /// Mail's own flags (Mail.sdef `was replied to`, `was forwarded`, `flagged status`); false when Mail did not say.
    public var replied: Bool
    public var forwarded: Bool
    public var flagged: Bool
    /// Top-level Mail container when known (`inbox`, `sent`, `drafts`).
    public var mailboxKind: MailBoxKind?
    public var replySource: MailReplySource? {
        let target = replyTo?.trimmingCharacters(in: .whitespacesAndNewlines)
        return messageID.flatMap { MailReplySource(messageID: $0, replyTo: target.flatMap { $0.isEmpty ? nil : $0 } ?? sender, subject: subject) }
    }
    /// An explicit RFC `Reply-To` address when present (never inferred from `From`/`sender`).
    public var explicitReplyTo: String? {
        if let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let inspected = MailReplySource.inspect(headers: Data((source + "\n\n").utf8)) {
            return inspected.explicitReplyTo
        }
        guard let target = replyTo?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty,
              let targetAddr = MailAddress.parse(target).address,
              targetAddr.caseInsensitiveCompare(MailAddress.parse(sender).address ?? "") != .orderedSame else { return nil }
        return target
    }
    public var isUnsentDraft: Bool {
        if mailboxKind == .drafts { return true }
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return MailReplySource.inspect(headers: Data((source + "\n\n").utf8))?.isDraft == true
    }
    public init(subject: String, sender: String, date: Date?, body: String, attachmentNames: [String], messageID: String? = nil, replyTo: String? = nil,
                locator: MailLocator? = nil, source: String? = nil, replied: Bool = false, forwarded: Bool = false, flagged: Bool = false,
                mailboxKind: MailBoxKind? = nil) {
        self.subject = subject; self.sender = sender; self.date = date; self.body = body; self.attachmentNames = attachmentNames
        self.messageID = messageID; self.replyTo = replyTo; self.locator = locator; self.source = source
        self.replied = replied; self.forwarded = forwarded; self.flagged = flagged; self.mailboxKind = mailboxKind
    }

    /// As .eml text, so the normal flow (overview, deadlines, questions) reads it like a filed mail: Mail's own message
    /// with its attachments when Mail gave it (`MailFiling` saves them as files), otherwise a stand-in that names the
    /// attachments only.
    public var emlText: String {
        if let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return source }
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
    /// Prepare Mail for an explicitly requested search or draft, opening it in the background if needed.
    /// Never shows a permission prompt. Reading the current selection still uses `access(.mail)`.
    func prepareMailAccess() async -> IntegrationAccess
    /// Shows the system prompt if needed. Only call when the person is using the feature right now.
    func requestAccess(_ integration: Integration) async -> IntegrationAccess
    /// Removes only what Pippa created and what has not been changed since.
    func remove(_ item: CreatedItem) async throws -> RemoveResult
    func selectedMail() async throws -> MailMessage?
    /// The inbox mail with exactly this subject whose sender contains `sender` ("" = any), or `nil`. Several such mails
    /// (e.g. one in each of two accounts) throw `MailLookupAmbiguous`: which one is meant is unknown.
    func findMail(subject: String, sender: String) async throws -> MailMessage?
    /// The inbox mail whose Message-ID is exactly `messageID` (a canonical id, see `MailReplySource.canonicalMessageID`), or
    /// `nil`. Never another mail with a similar subject. Several inbox mails with this id (e.g. in two accounts) throw
    /// `MailLookupAmbiguous`: which one is meant is unknown.
    func findMail(messageID: String) async throws -> MailMessage?
    /// Creates an unsent native reply to the captured original identity. Never falls back to compose.
    func insertReply(_ draft: MailDraft) async throws -> MailInsertResult
    /// Occurrences overlapping `interval` from every event calendar, read only, sorted by start, at most `limit`
    /// (`total` says how many there were). Never asks for access; throws `accessDenied` without it.
    func events(in interval: DateInterval, limit: Int) async throws -> CalendarFetch
}

public extension AppIntegrations {
    func prepareMailAccess() async -> IntegrationAccess { await access(.mail) }
    func findMail(subject: String, sender: String) async throws -> MailMessage? { throw PippaError.notAvailable }
    func findMail(messageID: String) async throws -> MailMessage? { throw PippaError.notAvailable }
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
    /// More inbox mails for `findMail` (tests, PIPPA_DEMO), after `sampleMail`. Never selected by `selectedMail`.
    public var inboxMails: [MailMessage] = []
    /// Synthetic events (never real); `nil` = `sampleCalendar` relative to now. Tests and PIPPA_DEMO only.
    public var calendarEvents: [CalendarEvent]?
    public var calendarNames = ["Arbeit", "Privat"]
    /// Tests: calendars that refuse new events (subscriptions, birthdays).
    public var readOnlyCalendars: Set<String> = []
    /// Tests: reading fails technically (e.g. calendar database unreachable).
    public var calendarFails = false
    private var reads: [DateInterval] = []
    private let created = Date()
    /// Events created by Pippa's MCP server (appear on the next read).
    private var addedEvents: [String: CalendarEvent] = [:]
    /// Synthetic events after an update (by id), shown instead of the original on the next read.
    private var editedEvents: [String: CalendarEvent] = [:]
    /// Content fingerprint of each added entry when it was created: back there, it has its creation fingerprint again.
    private var addedContent: [String: String] = [:]
    /// Reminders with their editable fields (added by Pippa or seeded by checks), for `reminder_update`.
    private var reminderEntries: [String: ReminderSnapshot] = [:]
    /// Tests: reminder lists that refuse changes.
    public var readOnlyReminderLists: Set<String> = []
    /// Lists for `addReminder` (invented).
    public var reminderLists = ["Erinnerungen", "Privat"]
    /// Tests: what `insertReply` reports instead of a draft (error) or which result (e.g. `replyNeedsPaste`).
    public var replyFailure: MailReplyFailure?
    public var replyOutcome: MailInsertResult?
    /// Checks: Mail can be closed independently of its remembered permission.
    public var mailRunning = true
    public var mailCanLaunch = true
    private var preparedMailCount = 0
    /// Tests only: how often Mail was prepared for a search or draft.
    public var mailPreparations: Int { lock.withLock { preparedMailCount } }
    private var lookups = 0
    /// Tests only: how often a mail was looked up in the inbox (`findMail`), found or not.
    public var mailLookups: Int { lock.withLock { lookups } }

    public init(granted: Bool = false) {
        state = Dictionary(uniqueKeysWithValues: Integration.allCases.map { ($0, granted ? .granted : .notDetermined) })
        sampleMail = MailMessage(subject: "Nebenkostenabrechnung 2025", sender: "Hausverwaltung Berger <info@berger-hv.de>",
                                 date: DayDate(year: 2026, month: 10, day: 1)?.localNoon,
                                 body: "Guten Tag,\n\nanbei die Nebenkostenabrechnung 2025. Die Nachzahlung von 312,48 € ist zahlbar bis 31.10.2026.\n\nFreundliche Grüße\nHausverwaltung Berger",
                                 attachmentNames: ["Nebenkosten 2025.pdf"], messageID: "demo-nebenkosten-2025@berger-hv.de")
    }

    public func set(_ integration: Integration, _ access: IntegrationAccess) { lock.withLock { state[integration] = access } }

    public func access(_ integration: Integration) async -> IntegrationAccess {
        lock.withLock {
            if integration == .mail && !mailRunning { return .unavailable(L("%@ isn’t open right now.", table: "Core", Integration.mail.appName)) }
            return state[integration] ?? .notDetermined
        }
    }

    public func prepareMailAccess() async -> IntegrationAccess {
        lock.withLock {
            preparedMailCount += 1
            if mailCanLaunch { mailRunning = true }
        }
        return await access(.mail)
    }

    public func requestAccess(_ integration: Integration) async -> IntegrationAccess {
        lock.withLock {
            if state[integration] == .notDetermined { state[integration] = .granted }
            return state[integration] ?? .granted
        }
    }

    private func requireGranted(_ i: Integration) throws {
        guard lock.withLock({ state[i] }) == .granted else { throw PippaError.accessDenied(i.appName) }
    }

    public func remove(_ item: CreatedItem) async throws -> RemoveResult {
        lock.withLock {
            // Like EventKit: an entry changed since it was created stays.
            if let stored = items[item.identifier], let expected = item.fingerprint, stored.item.fingerprint != expected { return .changed }
            addedEvents.removeValue(forKey: item.identifier)
            reminderEntries.removeValue(forKey: item.identifier)
            return items.removeValue(forKey: item.identifier) != nil ? .removed : .gone
        }
    }

    /// Tests only: the person edits an entry Pippa created (its fingerprint changes).
    public func touch(_ identifier: String) {
        lock.withLock { items[identifier]?.item.fingerprint = "edited-\(UUID().uuidString)" }
    }

    /// Tests only: number of created entries.
    public var createdCount: Int { lock.withLock { items.count } }

    public func selectedMail() async throws -> MailMessage? {
        try requireGranted(.mail)
        return sampleMail
    }

    /// The newest mail among the sample mail and `inboxMails` with this subject whose sender contains `sender`, as
    /// `SystemIntegrations.findMail` matches the inbox.
    public func findMail(subject: String, sender: String) async throws -> MailMessage? {
        try requireGranted(.mail)
        lock.withLock { lookups += 1 }
        let matches = inboxCandidates().filter { $0.subject == subject && (sender.isEmpty || $0.sender.localizedCaseInsensitiveContains(sender)) }
        if matches.count > 1 { throw MailLookupAmbiguous() }
        return matches.first
    }

    /// Exactly the mail with this Message-ID (case-sensitive, with or without angle brackets), never a look-alike.
    public func findMail(messageID: String) async throws -> MailMessage? {
        try requireGranted(.mail)
        lock.withLock { lookups += 1 }
        guard let wanted = MailReplySource.canonicalMessageID(messageID) else { return nil }
        let matches = inboxCandidates().filter { $0.messageID.flatMap(MailReplySource.canonicalMessageID) == wanted }
        if matches.count > 1 { throw MailLookupAmbiguous() }
        return matches.first
    }

    private func inboxCandidates() -> [MailMessage] { lock.withLock { (sampleMail.map { [$0] } ?? []) + inboxMails } }

    /// Remembers the draft instead of opening a window. Never sends.
    public func insertReply(_ draft: MailDraft) async throws -> MailInsertResult {
        try requireGranted(.mail)
        if draft.isReply, draft.messageID.flatMap(MailReplySource.canonicalMessageID) == nil {
            throw MailReplyFailure.missingOriginal
        }
        let (failure, outcome) = lock.withLock { (replyFailure, replyOutcome) }
        if let failure { throw failure }
        try PippaMCPWriteLease.current?.beginDispatch()
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
        let (added, edited) = lock.withLock { (Array(addedEvents.values), editedEvents) }
        let base = (calendarEvents ?? Self.sampleCalendar(now: created)).map { edited[$0.id] ?? $0 }
        let all = (base + added)
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
            CalendarEvent(id: "demo-zahnarzt", title: "Zahnarzt (Beispiel)", start: at(0, 16), end: at(0, 17), calendar: "Privat", location: "Praxis Beispiel", color: "#34C759"),
            CalendarEvent(id: "demo-standup", title: "Team-Standup (Beispiel)", start: at(1, 9), end: at(1, 9, 30), calendar: "Arbeit", status: .confirmed, recurring: true, color: "#1BADF8"),
            CalendarEvent(id: "demo-standup", title: "Team-Standup (Beispiel)", start: at(2, 9), end: at(2, 9, 30), calendar: "Arbeit", status: .cancelled, recurring: true, color: "#1BADF8"),
            CalendarEvent(id: "demo-call", title: "Abstimmung Projekt (Beispiel)", start: at(2, 15), end: at(2, 16), calendar: "Arbeit",
                          timeZone: "America/New_York", declined: true, color: "#1BADF8"),
            CalendarEvent(id: "demo-reise", title: "Reise nach Hamburg (Beispiel)", start: dayStart(3), end: dayStart(5).addingTimeInterval(-1),
                          allDay: true, calendar: "Privat", color: "#34C759"),
            CalendarEvent(id: "demo-essen", title: "Abendessen mit Freunden (Beispiel)", start: at(4, 19), end: at(4, 22), calendar: "Privat", color: "#34C759"),
        ]
    }
}

// Create events and reminders, in memory only (tests, PIPPA_DEMO, end-to-end). Never touches real apps.
extension DemoIntegrations: HostWriting {
    public func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite {
        try requireGranted(.calendar)
        let id = "demo-\(UUID().uuidString)"
        let item = CreatedItem(integration: .calendar, identifier: id, modified: Date(), fingerprint: "demo-\(id)")
        let readOnly = readOnlyCalendars
        let calendar = try event.calendar.map { name in
            try CalendarTargetError.match(name, in: calendarNames, title: { $0 }, writable: { !readOnly.contains($0) })
        } ?? calendarNames.last ?? "Privat"
        try PippaMCPWriteLease.current?.beginDispatch()
        lock.withLock {
            items[id] = (item, event.title)
            let stored = CalendarEvent(id: id, title: event.title, start: event.start, end: event.end, allDay: event.allDay,
                                       calendar: calendar, location: event.location, notes: event.notes)
            addedEvents[id] = stored
            addedContent[id] = Self.contentFingerprint(Self.snapshot(stored))
        }
        return HostWrite(item: item, container: calendar)
    }

    public func addReminder(_ reminder: NewReminder) async throws -> HostWrite {
        try requireGranted(.reminders)
        let id = "demo-\(UUID().uuidString)"
        let item = CreatedItem(integration: .reminders, identifier: id, modified: Date(), fingerprint: "demo-\(id)")
        let wanted = reminder.list?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = wanted.flatMap { name in reminderLists.first { $0.lowercased() == name } }
        try PippaMCPWriteLease.current?.beginDispatch()
        let list = named ?? reminderLists.first ?? "Erinnerungen"
        lock.withLock {
            items[id] = (item, reminder.title)
            let entry = ReminderSnapshot(title: reminder.title, due: reminder.due, notes: reminder.notes, list: list)
            reminderEntries[id] = entry
            addedContent[id] = Self.contentFingerprint(entry)
        }
        return HostWrite(item: item, container: list, containerMatched: wanted == nil || named != nil)
    }

    public func readBack(_ item: CreatedItem) async -> CreatedItemReadBack {
        lock.withLock {
            guard let stored = items[item.identifier] else { return .gone }
            let event = addedEvents[item.identifier]
            return .found(title: stored.title, start: event?.start, end: event?.end, container: event?.calendar, fingerprint: stored.item.fingerprint)
        }
    }
}

// Update events and reminders in memory (calendar_update, reminder_update), with the same guards as EventKit.
extension DemoIntegrations {
    static func snapshot(_ e: CalendarEvent) -> CalendarEventSnapshot {
        CalendarEventSnapshot(title: e.title, start: e.start, end: e.end, allDay: e.allDay, location: e.location, notes: e.notes, calendar: e.calendar)
    }

    static func contentFingerprint<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return "demo-" + SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).hexString
    }

    /// Under the lock: the event by id, after the update guards. Added events first, then the synthetic calendar.
    private func editableEvent(_ id: String) throws -> CalendarEvent {
        let found: [CalendarEvent]
        if let added = addedEvents[id] { found = [added] }
        else { found = (calendarEvents ?? Self.sampleCalendar(now: created)).filter { $0.id == id }.map { editedEvents[$0.id] ?? $0 } }
        guard let event = found.first else { throw CalendarUpdateError.notFound }
        if found.contains(where: { !$0.attendees.isEmpty }) { throw CalendarUpdateError.hasAttendees }
        if found.count > 1 || found.contains(where: \.recurring) { throw CalendarUpdateError.isRecurring }
        if readOnlyCalendars.contains(event.calendar) { throw CalendarUpdateError.readOnly(event.calendar) }
        return event
    }

    /// Under the lock: an added entry keeps its own fingerprint (`touch` changes it); synthetic events hash their content.
    private func eventFingerprint(_ event: CalendarEvent) -> String {
        items[event.id]?.item.fingerprint ?? Self.contentFingerprint(Self.snapshot(event))
    }

    /// Under the lock: stores the event's new content, with the fingerprint EventKit would compute.
    private func store(_ event: CalendarEvent) {
        if addedEvents[event.id] != nil {
            addedEvents[event.id] = event
            let content = Self.contentFingerprint(Self.snapshot(event))
            items[event.id]?.title = event.title
            items[event.id]?.item.fingerprint = content == addedContent[event.id] ? "demo-\(event.id)" : content
        } else {
            editedEvents[event.id] = event
        }
    }

    private static func applying(_ s: CalendarEventSnapshot, to event: CalendarEvent) -> CalendarEvent {
        var e = event
        e.title = s.title; e.start = s.start; e.end = s.end; e.allDay = s.allDay; e.location = s.location; e.notes = s.notes
        return e
    }

    public func eventSnapshot(identifier: String) async throws -> EventLookup {
        try requireGranted(.calendar)
        return try lock.withLock {
            let event = try editableEvent(identifier)
            return EventLookup(identifier: event.id, snapshot: Self.snapshot(event), fingerprint: eventFingerprint(event))
        }
    }

    public func updateEvent(identifier: String, patch: CalendarEventPatch) async throws -> EventUpdateResult {
        try requireGranted(.calendar)
        let (event, before) = try lock.withLock {
            let event = try editableEvent(identifier)
            if let expected = patch.expectedFingerprint, eventFingerprint(event) != expected { throw CalendarUpdateError.changed }
            return (event, Self.snapshot(event))
        }
        try PippaMCPWriteLease.current?.beginDispatch()
        let (after, changed) = patch.applied(to: before)
        return lock.withLock {
            let updated = Self.applying(after, to: event)
            store(updated)
            return EventUpdateResult(identifier: event.id, before: before, after: after, fingerprint: eventFingerprint(updated), modified: Date(),
                                     container: event.calendar, changed: changed)
        }
    }

    public func restoreEvent(identifier: String, expectedFingerprint: String?, snapshot: CalendarEventSnapshot) async -> RunUndoOutcome {
        guard (try? requireGranted(.calendar)) != nil else { return .failed }
        return lock.withLock {
            let event: CalendarEvent
            do { event = try editableEvent(identifier) }
            catch CalendarUpdateError.notFound { return .gone }
            catch { return .changed }
            if let expectedFingerprint, eventFingerprint(event) != expectedFingerprint { return .changed }
            store(Self.applying(snapshot, to: event))
            return .undone
        }
    }

    /// Tests only: the person edits an event in Calendar (any event, synthetic or added).
    public func editEvent(_ identifier: String, _ change: (inout CalendarEvent) -> Void) {
        lock.withLock {
            guard var event = addedEvents[identifier] ?? (calendarEvents ?? Self.sampleCalendar(now: created)).first(where: { $0.id == identifier })
                .map({ editedEvents[$0.id] ?? $0 }) else { return }
            change(&event)
            store(event)
            if items[identifier] != nil { items[identifier]?.item.fingerprint = "edited-\(UUID().uuidString)" }
        }
    }

    /// Tests only: the event as a read would show it now.
    public func storedEvent(_ identifier: String) -> CalendarEvent? {
        lock.withLock {
            addedEvents[identifier] ?? (calendarEvents ?? Self.sampleCalendar(now: created)).first(where: { $0.id == identifier })
                .map { editedEvents[$0.id] ?? $0 }
        }
    }

    // Reminders

    /// Under the lock: an added reminder keeps its creation fingerprint until its content changes.
    private func reminderFingerprint(_ id: String, _ entry: ReminderSnapshot) -> String {
        items[id]?.item.fingerprint ?? Self.contentFingerprint(entry)
    }

    private func storeReminder(_ id: String, _ entry: ReminderSnapshot) {
        reminderEntries[id] = entry
        if items[id] != nil {
            let content = Self.contentFingerprint(entry)
            items[id]?.title = entry.title
            items[id]?.item.fingerprint = content == addedContent[id] ? "demo-\(id)" : content
        }
    }

    private func editableReminder(_ id: String) throws -> ReminderSnapshot {
        guard let entry = reminderEntries[id] else { throw CalendarUpdateError.notFound }
        if readOnlyReminderLists.contains(entry.list) { throw CalendarUpdateError.readOnly(entry.list) }
        return entry
    }

    public func reminderSnapshot(identifier: String) async throws -> ReminderLookup {
        try requireGranted(.reminders)
        return try lock.withLock {
            let entry = try editableReminder(identifier)
            return ReminderLookup(identifier: identifier, snapshot: entry, fingerprint: reminderFingerprint(identifier, entry))
        }
    }

    public func updateReminder(identifier: String, patch: ReminderPatch) async throws -> ReminderUpdateResult {
        try requireGranted(.reminders)
        let before = try lock.withLock {
            let entry = try editableReminder(identifier)
            if let expected = patch.expectedFingerprint, reminderFingerprint(identifier, entry) != expected { throw CalendarUpdateError.changed }
            return entry
        }
        try PippaMCPWriteLease.current?.beginDispatch()
        let (after, changed) = patch.applied(to: before)
        return lock.withLock {
            storeReminder(identifier, after)
            return ReminderUpdateResult(identifier: identifier, before: before, after: after, fingerprint: reminderFingerprint(identifier, after),
                                        modified: Date(), container: after.list, changed: changed)
        }
    }

    public func restoreReminder(identifier: String, expectedFingerprint: String?, snapshot: ReminderSnapshot) async -> RunUndoOutcome {
        guard (try? requireGranted(.reminders)) != nil else { return .failed }
        return lock.withLock {
            let entry: ReminderSnapshot
            do { entry = try editableReminder(identifier) }
            catch CalendarUpdateError.notFound { return .gone }
            catch { return .changed }
            if let expectedFingerprint, reminderFingerprint(identifier, entry) != expectedFingerprint { return .changed }
            storeReminder(identifier, snapshot)
            return .undone
        }
    }

    /// Tests only: a reminder that exists in Reminders (not created by Pippa).
    public func seedReminder(_ identifier: String, _ entry: ReminderSnapshot) { lock.withLock { reminderEntries[identifier] = entry } }

    /// Tests only: the person edits a reminder in Reminders.
    public func editReminder(_ identifier: String, _ change: (inout ReminderSnapshot) -> Void) {
        lock.withLock {
            guard var entry = reminderEntries[identifier] else { return }
            change(&entry)
            storeReminder(identifier, entry)
            if items[identifier] != nil { items[identifier]?.item.fingerprint = "edited-\(UUID().uuidString)" }
        }
    }

    /// Tests only: the reminder as Reminders has it now.
    public func storedReminder(_ identifier: String) -> ReminderSnapshot? { lock.withLock { reminderEntries[identifier] } }

    /// Tests only: the person deletes a reminder.
    public func deleteReminder(_ identifier: String) {
        lock.withLock { reminderEntries.removeValue(forKey: identifier); items.removeValue(forKey: identifier) }
    }
}
