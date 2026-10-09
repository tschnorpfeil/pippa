import EventKit
import Foundation

// Two small readers that exist only for Pippa's MCP server, separate from
// `AppIntegrations` so the existing integrations and their checks stay unchanged. Both only read.

/// Header of a found mail with a short start of the text. Read only.
public struct MailHeader: Sendable, Equatable {
    public var subject: String
    public var sender: String
    public var date: Date?
    public var mailbox: String
    /// At most the first 400 characters of the text.
    public var preview: String
    public init(subject: String, sender: String, date: Date?, mailbox: String, preview: String) {
        self.subject = subject; self.sender = sender; self.date = date; self.mailbox = mailbox; self.preview = preview
    }
}

/// An open reminder, read only.
public struct ReminderItem: Sendable, Equatable {
    public var title: String
    public var list: String
    public var due: Date?
    /// Due at a time of day (otherwise only on the day).
    public var dueHasTime: Bool
    public init(title: String, list: String, due: Date? = nil, dueHasTime: Bool = false) {
        self.title = title; self.list = list; self.due = due; self.dueHasTime = dueHasTime
    }
}

/// Result of a bounded search: at most `limit` hits, `total` says how many there were.
public struct HostFetch<Item: Sendable & Equatable>: Sendable, Equatable {
    public var items: [Item]
    public var total: Int
    public init(items: [Item], total: Int) { self.items = items; self.total = total }
}

/// Search mail and read open reminders. Never asks for permissions itself (`AppIntegrations` does that);
/// without permission it throws `PippaError.accessDenied`, without Mail open `PippaError.appNotOpen`.
public protocol HostDataReading: Sendable {
    /// Inboxes of all accounts: subject or sender contains `query`.
    func searchMail(_ query: String, limit: Int) async throws -> HostFetch<MailHeader>
    /// Reminders not done; with `dueBefore` only those due by then (those without a date are dropped).
    func openReminders(dueBefore: Date?, limit: Int) async throws -> HostFetch<ReminderItem>
}

extension SystemIntegrations: HostDataReading {
    public func searchMail(_ query: String, limit: Int) async throws -> HostFetch<MailHeader> {
        guard AppleEvents.isRunning(.mail) else { throw PippaError.appNotOpen(Integration.mail.appName) }
        return try await MailSearchScript.search(query, limit: limit)
    }

    /// Own `EKEventStore` per read: after a fresh permission an old store sees nothing.
    public func openReminders(dueBefore: Date?, limit: Int) async throws -> HostFetch<ReminderItem> {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw PippaError.accessDenied(Integration.reminders.appName) }
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: nil)
        let all: [ReminderItem] = await withCheckedContinuation { done in
            store.fetchReminders(matching: predicate) { found in
                done.resume(returning: (found ?? []).map { r in
                    let parts = r.dueDateComponents
                    let due = parts.flatMap { Calendar.autoupdatingCurrent.date(from: $0) }
                    return ReminderItem(title: r.title ?? "", list: r.calendar?.title ?? "", due: due, dueHasTime: parts?.hour != nil)
                })
            }
        }
        return HostFetch(items: Array(HostOrder.reminders(all).prefix(limit)), total: all.count)
    }
}

enum HostOrder {
    /// Due first (by date), then those without a date by title.
    static func reminders(_ items: [ReminderItem]) -> [ReminderItem] {
        items.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return (x, a.title) < (y, b.title)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }
}

/// Replacement without real Mail and real reminders: for PIPPA_DEMO=1, checks and the end-to-end run. Permissions come from
/// `DemoIntegrations`, so that "no access" is checked the same way as for the calendar.
public final class DemoHostData: HostDataReading, @unchecked Sendable {
    private let lock = NSLock()
    private let integrations: DemoIntegrations
    private var storedMails: [MailHeader]
    private var storedReminders: [ReminderItem]
    /// Checks: Mail is not open.
    public var mailClosed = false

    public init(integrations: DemoIntegrations, mails: [MailHeader]? = nil, reminders: [ReminderItem]? = nil, now: Date = Date()) {
        self.integrations = integrations
        storedMails = mails ?? Self.sampleMails
        storedReminders = reminders ?? Self.sampleReminders(now: now)
    }

    public func searchMail(_ query: String, limit: Int) async throws -> HostFetch<MailHeader> {
        guard await integrations.access(.mail) == .granted else { throw PippaError.accessDenied(Integration.mail.appName) }
        let (closed, mails) = lock.withLock { (mailClosed, storedMails) }
        if closed { throw PippaError.appNotOpen(Integration.mail.appName) }
        let found = mails.filter { $0.subject.localizedCaseInsensitiveContains(query) || $0.sender.localizedCaseInsensitiveContains(query) }
        return HostFetch(items: Array(found.prefix(limit)), total: found.count)
    }

    public func openReminders(dueBefore: Date?, limit: Int) async throws -> HostFetch<ReminderItem> {
        guard await integrations.access(.reminders) == .granted else { throw PippaError.accessDenied(Integration.reminders.appName) }
        let all = lock.withLock { storedReminders }.filter { item in dueBefore.map { end in item.due.map { $0 < end } ?? false } ?? true }
        return HostFetch(items: Array(HostOrder.reminders(all).prefix(limit)), total: all.count)
    }

    /// Freely invented (no real mails).
    public static let sampleMails: [MailHeader] = [
        MailHeader(subject: "Nebenkostenabrechnung 2025", sender: "Hausverwaltung Berger <info@berger-hv.de>",
                   date: DayDate(year: 2026, month: 10, day: 1)?.localNoon, mailbox: "Eingang",
                   preview: "Guten Tag, anbei die Nebenkostenabrechnung 2025. Die Nachzahlung von 312,48 € ist zahlbar bis 31.10.2026."),
        MailHeader(subject: "Elternabend am Donnerstag", sender: "Testschule Musterstadt <sekretariat@testschule.example>",
                   date: DayDate(year: 2026, month: 10, day: 5)?.localNoon, mailbox: "Eingang",
                   preview: "Liebe Eltern, der Elternabend der Klasse 4b findet am Donnerstag um 19:30 Uhr im Raum 12 statt."),
    ]

    /// Freely invented, relative to `now`.
    public static func sampleReminders(now: Date, calendar: Calendar = .autoupdatingCurrent) -> [ReminderItem] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return [
            ReminderItem(title: "Nebenkosten überweisen (Beispiel)", list: "Erinnerungen", due: tomorrow),
            ReminderItem(title: "Geschenk für Oma besorgen (Beispiel)", list: "Privat"),
        ]
    }
}

// MARK: Search mail (read only)

/// Searches the inbox (`inbox`: all accounts) by subject or sender. The search text goes in as a parameter,
/// never into the script text. At most `maxCount` hits are read, only the first 400 characters of the text.
/// [assumption] Mail returns a mailbox's messages newest first; the hits are sorted by date in Swift.
enum MailSearchScript {
    static let source = """
    on searchInbox(q, maxCount)
        tell application id "com.apple.mail"
            with timeout of 20 seconds
                set found to (messages of inbox whose subject contains q or sender contains q)
            end timeout
            set total to count of found
            set n to total
            if n > maxCount then set n to maxCount
            set out to {}
            repeat with i from 1 to n
                set m to item i of found
                set boxName to ""
                try
                    set boxName to (name of mailbox of m) as text
                end try
                set c to ""
                try
                    set c to (content of m) as text
                    if (length of c) > 400 then set c to text 1 thru 400 of c
                end try
                set end of out to {subject of m, sender of m, date received of m, boxName, c}
            end repeat
            return {total, out}
        end tell
    end searchInbox
    """

    static func search(_ query: String, limit: Int) async throws -> HostFetch<MailHeader> {
        try await AppleEvents.perform { () throws -> HostFetch<MailHeader> in
            let reply = try AppleEvents.call(source, handler: "searchInbox",
                                             [NSAppleEventDescriptor(string: query), NSAppleEventDescriptor(int32: Int32(limit))], app: .mail)
            let parts = AppleEvents.items(reply)
            guard parts.count == 2 else { return HostFetch(items: [], total: 0) }
            let items = AppleEvents.items(parts[1]).compactMap { row -> MailHeader? in
                let f = AppleEvents.items(row)
                guard f.count == 5 else { return nil }
                return MailHeader(subject: f[0].stringValue ?? "", sender: f[1].stringValue ?? "", date: f[2].dateValue,
                                  mailbox: f[3].stringValue ?? "", preview: f[4].stringValue ?? "")
            }
            let sorted = items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return HostFetch(items: sorted, total: Int(parts[0].int32Value))
        }
    }
}
