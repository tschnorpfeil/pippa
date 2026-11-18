import EventKit
import Foundation

// Small readers that exist only for Pippa's MCP server, separate from
// `AppIntegrations` so the existing integrations and their checks stay unchanged. All only read.

/// Header of a found mail with a short start of the text. Read only.
public struct MailHeader: Sendable, Equatable {
    public var subject: String
    public var sender: String
    public var date: Date?
    public var mailbox: String
    /// At most the first 400 characters of the text.
    public var preview: String
    /// Message-ID header: opens the mail in Mail, and is the `message_id` the model passes to `mail_read`.
    public var messageID: String?
    /// Not read yet in Mail.
    public var unread: Bool
    /// The account whose inbox holds it, as the person named it in Mail; `nil` from the combined inbox search.
    public var account: String?
    /// Mail's own flags (Mail.sdef `was replied to`, `was forwarded`, `flagged status`).
    public var replied: Bool
    public var forwarded: Bool
    public var flagged: Bool
    public init(subject: String, sender: String, date: Date?, mailbox: String, preview: String, messageID: String? = nil, unread: Bool = false,
                account: String? = nil, replied: Bool = false, forwarded: Bool = false, flagged: Bool = false) {
        self.subject = subject; self.sender = sender; self.date = date; self.mailbox = mailbox; self.preview = preview
        self.messageID = messageID; self.unread = unread; self.account = account
        self.replied = replied; self.forwarded = forwarded; self.flagged = flagged
    }
}

/// Which mails a search keeps by Mail's read status.
public enum MailReadStatus: String, Sendable, CaseIterable {
    case all, unread, read

    public func matches(unread: Bool) -> Bool {
        switch self {
        case .all: true
        case .unread: unread
        case .read: !unread
        }
    }
}

/// Which top-level Mail container a search reads, one child mailbox per account (Mail.sdef `inbox`, `sent mailbox`, `drafts mailbox`).
public enum MailBoxKind: String, Codable, Sendable, CaseIterable {
    case inbox, sent, drafts
}

/// An open reminder, read only.
public struct ReminderItem: Sendable, Equatable {
    public var title: String
    public var list: String
    public var due: Date?
    /// Due at a time of day (otherwise only on the day).
    public var dueHasTime: Bool
    public var notes: String?
    /// "high", "medium" or "low" (EventKit 1–4, 5, 6–9); `nil` without priority.
    public var priority: String?
    public init(title: String, list: String, due: Date? = nil, dueHasTime: Bool = false, notes: String? = nil, priority: String? = nil) {
        self.title = title; self.list = list; self.due = due; self.dueHasTime = dueHasTime; self.notes = notes; self.priority = priority
    }

    /// EventKit's 0–9 scale as a word.
    public static func priority(_ value: Int) -> String? {
        switch value {
        case 1...4: "high"
        case 5: "medium"
        case 6...9: "low"
        default: nil
        }
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
    /// Inboxes of all accounts: subject or sender contains `query` (empty: every mail); `unread` keeps only unread ones.
    func searchMail(_ query: String, unread: Bool, limit: Int) async throws -> HostFetch<MailHeader>
    /// As `searchMail(_:unread:limit:)`, filtered by read status (`read`: only mails already read).
    func searchMail(_ query: String, readStatus: MailReadStatus, limit: Int) async throws -> HostFetch<MailHeader>
    /// Reminders not done; with `dueBefore` only those due by then (those without a date are dropped).
    func openReminders(dueBefore: Date?, limit: Int) async throws -> HostFetch<ReminderItem>
    /// May Pippa search Photos (automation)? `ask: true` shows the system prompt. Starts Photos invisibly if needed.
    func photosAccess(ask: Bool) async -> IntegrationAccess
    /// Photos' own search (objects, places, people, text) for `query`; newest first.
    func searchPhotos(_ query: String, limit: Int) async throws -> HostFetch<PhotoHit>
    /// May the card show previews (PhotoKit)? `ask: true` shows the system prompt once.
    func photoPreviewAccess(ask: Bool) async -> Bool
    /// May Pippa read the library (PhotoKit)? `ask: true` shows the system prompt once.
    func photoLibraryAccess(ask: Bool) async -> IntegrationAccess
    /// The newest photos (PhotoKit), with `since` only those taken from then on; newest first.
    func recentPhotos(since: Date?, limit: Int) async throws -> HostFetch<PhotoHit>
}

extension HostDataReading {
    /// For readers that only know `unread`: read mails are every match minus the unread ones, so nothing is guessed.
    public func searchMail(_ query: String, readStatus: MailReadStatus, limit: Int) async throws -> HostFetch<MailHeader> {
        switch readStatus {
        case .all: return try await searchMail(query, unread: false, limit: limit)
        case .unread: return try await searchMail(query, unread: true, limit: limit)
        case .read:
            let wide = 1000
            let all = try await searchMail(query, unread: false, limit: wide)
            let unread = try await searchMail(query, unread: true, limit: wide)
            let read = all.items.filter { !$0.unread }
            return HostFetch(items: Array(read.prefix(limit)), total: max(read.count, all.total - unread.total))
        }
    }
}

extension SystemIntegrations: HostDataReading {
    public func searchMail(_ query: String, unread: Bool, limit: Int) async throws -> HostFetch<MailHeader> {
        try await searchMail(query, readStatus: unread ? .unread : .all, limit: limit)
    }

    public func searchMail(_ query: String, readStatus: MailReadStatus, limit: Int) async throws -> HostFetch<MailHeader> {
        guard AppleEvents.isRunning(.mail) else { throw PippaError.appNotOpen(Integration.mail.appName) }
        return try await MailSearchScript.search(query, readStatus: readStatus, limit: limit)
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
                    return ReminderItem(title: r.title ?? "", list: r.calendar?.title ?? "", due: due, dueHasTime: parts?.hour != nil,
                                        notes: r.notes.map { String($0.prefix(400)) }, priority: ReminderItem.priority(r.priority))
                })
            }
        }
        return HostFetch(items: Array(HostOrder.reminders(all).prefix(limit)), total: all.count)
    }
}

extension SystemIntegrations {
    public func photosAccess(ask: Bool) async -> IntegrationAccess { await PhotosLibrary.access(ask: ask) }

    public func searchPhotos(_ query: String, limit: Int) async throws -> HostFetch<PhotoHit> {
        guard AppleEvents.isRunning(bundle: PhotosLibrary.bundleIdentifier) else { throw PippaError.appNotOpen(PhotosLibrary.appName) }
        return try await PhotosSearchScript.search(query, limit: limit)
    }

    public func photoPreviewAccess(ask: Bool) async -> Bool { await PhotosLibrary.previewAccess(ask: ask) }

    public func photoLibraryAccess(ask: Bool) async -> IntegrationAccess { await PhotosLibrary.libraryAccess(ask: ask) }

    public func recentPhotos(since: Date?, limit: Int) async throws -> HostFetch<PhotoHit> {
        guard await PhotosLibrary.libraryAccess(ask: false) == .granted else { throw PippaError.accessDenied(PhotosLibrary.appName) }
        return PhotosLibrary.recent(since: since, limit: limit)
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
    /// Checks: Photos is not open (and could not be started).
    public var photosClosed = false
    /// Checks: automation for Photos and the previews (PhotoKit).
    public var photosPermission: IntegrationAccess = .granted
    public var previewsAllowed = true
    /// Checks: PhotoKit's permission for the newest photos.
    public var libraryPermission: IntegrationAccess = .granted
    /// Checks: what `searchPhotos` was asked for, and whether the preview prompt was shown.
    public private(set) var photoQueries: [String] = []
    public private(set) var previewAsked = false
    private var storedPhotos: [(words: [String], hit: PhotoHit)]

    public init(integrations: DemoIntegrations, mails: [MailHeader]? = nil, reminders: [ReminderItem]? = nil, now: Date = Date()) {
        self.integrations = integrations
        storedMails = mails ?? Self.sampleMails
        storedReminders = reminders ?? Self.sampleReminders(now: now)
        storedPhotos = Self.samplePhotos
    }

    public func photosAccess(ask: Bool) async -> IntegrationAccess {
        lock.withLock {
            if photosClosed { return .unavailable(L("%@ isn’t open right now.", table: "Core", PhotosLibrary.appName)) }
            if photosPermission == .notDetermined && ask { photosPermission = .granted }
            return photosPermission
        }
    }

    /// Like Photos: a word matches what is in the picture (here: invented labels), the place or the title.
    public func searchPhotos(_ query: String, limit: Int) async throws -> HostFetch<PhotoHit> {
        let (closed, allowed, photos): (Bool, Bool, [(words: [String], hit: PhotoHit)]) = lock.withLock {
            photoQueries.append(query)
            return (photosClosed, photosPermission == .granted, storedPhotos)
        }
        if closed { throw PippaError.appNotOpen(PhotosLibrary.appName) }
        guard allowed else { throw PippaError.accessDenied(PhotosLibrary.appName) }
        let found = photos.filter { entry in entry.words.contains { $0.localizedCaseInsensitiveContains(query) } }.map(\.hit)
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return HostFetch(items: Array(found.prefix(limit)), total: found.count)
    }

    public func photoPreviewAccess(ask: Bool) async -> Bool {
        lock.withLock {
            if ask { previewAsked = true }
            if ask, libraryPermission == .notDetermined { libraryPermission = previewsAllowed ? .granted : .denied }
            return previewsAllowed && libraryPermission == .granted
        }
    }

    public func photoLibraryAccess(ask: Bool) async -> IntegrationAccess {
        lock.withLock {
            if libraryPermission == .notDetermined && ask { libraryPermission = .granted }
            return libraryPermission
        }
    }

    /// Like PhotoKit: newest first by date (photos without a date last), `since` drops older ones and those without a date.
    public func recentPhotos(since: Date?, limit: Int) async throws -> HostFetch<PhotoHit> {
        let (allowed, photos) = lock.withLock { (libraryPermission == .granted, storedPhotos.map(\.hit)) }
        guard allowed else { throw PippaError.accessDenied(PhotosLibrary.appName) }
        let found = photos.filter { hit in since.map { start in hit.date.map { $0 >= start } ?? false } ?? true }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return HostFetch(items: Array(found.prefix(limit)), total: found.count)
    }

    public func searchMail(_ query: String, unread: Bool, limit: Int) async throws -> HostFetch<MailHeader> {
        try await searchMail(query, readStatus: unread ? .unread : .all, limit: limit)
    }

    public func searchMail(_ query: String, readStatus: MailReadStatus, limit: Int) async throws -> HostFetch<MailHeader> {
        guard await integrations.access(.mail) == .granted else { throw PippaError.accessDenied(Integration.mail.appName) }
        let (closed, mails) = lock.withLock { (mailClosed, storedMails) }
        if closed { throw PippaError.appNotOpen(Integration.mail.appName) }
        let found = mails.filter { m in
            (query.isEmpty || m.subject.localizedCaseInsensitiveContains(query) || m.sender.localizedCaseInsensitiveContains(query))
                && (readStatus == .all || m.unread == (readStatus == .unread))
        }
        return HostFetch(items: MailSelection.newest(found, limit: limit, date: \.date, tie: { $0.messageID ?? "" }), total: found.count)
    }

    public func openReminders(dueBefore: Date?, limit: Int) async throws -> HostFetch<ReminderItem> {
        guard await integrations.access(.reminders) == .granted else { throw PippaError.accessDenied(Integration.reminders.appName) }
        let all = lock.withLock { storedReminders }.filter { item in dueBefore.map { end in item.due.map { $0 < end } ?? false } ?? true }
        return HostFetch(items: Array(HostOrder.reminders(all).prefix(limit)), total: all.count)
    }
}

// MARK: Search mail (read only)

/// Which mails a search keeps: the newest, whatever order the source lists them in. Missing dates come last; equal dates
/// go by `tie` (larger first), then by position, so the same input always gives the same answer.
enum MailSelection {
    static func newest<T>(_ items: [T], limit: Int, date: (T) -> Date?, tie: (T) -> String) -> [T] {
        guard limit > 0 else { return [] }
        let ranked = items.enumerated().map { (index: $0.offset, item: $0.element, date: date($0.element), tie: tie($0.element)) }
        let ordered = ranked.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if a.tie != b.tie { return a.tie > b.tie }
            return a.index < b.index
        }
        return ordered.prefix(limit).map(\.item)
    }
}

/// A matching message before any text is read: Mail's own id and the date it was received (nil: Mail has none).
public struct MailSearchCandidate: Sendable, Equatable {
    public var id: Int
    public var date: Date?
    public init(id: Int, date: Date?) { self.id = id; self.date = date }
}

/// A chosen message read from Mail, with the date it was selected by (to notice that the inbox changed in between).
public struct MailSearchRow: Sendable, Equatable {
    public var id: Int
    public var date: Date?
    public var header: MailHeader
    /// Where Mail says the message is (per-account search only): the account id and the whole mailbox path.
    public var accountID: String?
    public var path: [String]?
    public init(id: Int, date: Date?, header: MailHeader, accountID: String? = nil, path: [String]? = nil) {
        self.id = id; self.date = date; self.header = header; self.accountID = accountID; self.path = path
    }
}

/// What a mail search asks of Mail, in two steps so text is read only for the chosen messages. Called inside one
/// `AppleEvents.perform`; checks replace it with a synthetic source.
public protocol MailSearchNative: Sendable {
    /// Every match (subject or sender contains `query`, empty: all; `unread`), in any order, with its date. Throws when
    /// the answer is malformed.
    func candidates(query: String, unread: Bool) throws -> [MailSearchCandidate]
    /// Every match with this read status (`read`: already read).
    func candidates(query: String, readStatus: MailReadStatus) throws -> [MailSearchCandidate]
    /// Header and start of the text of exactly these messages. A message that is gone is left out. Throws when the answer is malformed.
    func rows(ids: [Int]) throws -> [MailSearchRow]
}

extension MailSearchNative {
    /// For sources that only know `unread`: read mails are every match minus the unread ones.
    public func candidates(query: String, readStatus: MailReadStatus) throws -> [MailSearchCandidate] {
        switch readStatus {
        case .all: return try candidates(query: query, unread: false)
        case .unread: return try candidates(query: query, unread: true)
        case .read:
            let unread = Set(try candidates(query: query, unread: true).map(\.id))
            return try candidates(query: query, unread: false).filter { !unread.contains($0.id) }
        }
    }
}

/// Choose the newest matches from all matching dates, then read only those. Sorting is never left to Mail's order.
public enum MailSearchFlow {
    /// Two tries: a message arriving or leaving between the two steps changes what the first answer said.
    static let attempts = 2

    public static func search(_ native: any MailSearchNative, query: String, unread: Bool, limit: Int) throws -> HostFetch<MailHeader> {
        try search(native, query: query, readStatus: unread ? .unread : .all, limit: limit)
    }

    public static func search(_ native: any MailSearchNative, query: String, readStatus: MailReadStatus, limit: Int) throws -> HostFetch<MailHeader> {
        for _ in 0..<attempts {
            let all = try native.candidates(query: query, readStatus: readStatus)
            guard Set(all.map(\.id)).count == all.count else { throw PippaError.notAvailable }
            let chosen = MailSelection.newest(all, limit: limit, date: \.date, tie: { String(format: "%020lld", Int64($0.id)) })
            if chosen.isEmpty { return HostFetch(items: [], total: all.count) }
            let rows = Dictionary(try native.rows(ids: chosen.map(\.id)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let items = chosen.compactMap { candidate -> MailHeader? in
                guard let row = rows[candidate.id], MailAccountFlow.sameDate(row.date, candidate.date),
                      readStatus.matches(unread: row.header.unread) else { return nil }
                return row.header
            }
            if items.count == chosen.count { return HostFetch(items: items, total: all.count) }
        }
        throw PippaError.notAvailable
    }

    // MARK: Native answers

    /// `{ids, dates}` (Inbox) or `{ids, receivedDates, sentIDs, sentDates}` (Sent/Drafts, matched per Mail id so a non-missing
    /// `date sent` overrides `date received` even when a message arrived between the two bulk reads).
    public static func parseCandidates(_ reply: NSAppleEventDescriptor) throws -> [MailSearchCandidate] {
        guard reply.descriptorType == typeAEList, reply.numberOfItems == 2 || reply.numberOfItems == 4,
              let ids = reply.atIndex(1), let dates = reply.atIndex(2) else {
            throw PippaError.notAvailable
        }
        let received = try parsePairs(ids: ids, dates: dates)
        guard reply.numberOfItems == 4 else {
            return received.map { MailSearchCandidate(id: $0.id, date: $0.date) }
        }
        guard let sentIDs = reply.atIndex(3), let sentDates = reply.atIndex(4) else { throw PippaError.notAvailable }
        let sentPairs = try parsePairs(ids: sentIDs, dates: sentDates)
        var sentByID: [Int: Date] = [:]
        for pair in sentPairs {
            if let date = pair.date, sentByID[pair.id] == nil { sentByID[pair.id] = date }
        }
        return received.map { MailSearchCandidate(id: $0.id, date: sentByID[$0.id] ?? $0.date) }
    }

    static func parseIDs(_ list: NSAppleEventDescriptor) throws -> [Int] {
        guard list.descriptorType == typeAEList else { throw PippaError.notAvailable }
        let items = AppleEvents.items(list)
        guard items.count == list.numberOfItems else { throw PippaError.notAvailable }
        return try items.map(mailID)
    }

    static func parseOptionalDate(_ d: NSAppleEventDescriptor) throws -> Date? { try mailDate(d) }

    private static func parsePairs(ids: NSAppleEventDescriptor, dates: NSAppleEventDescriptor) throws -> [(id: Int, date: Date?)] {
        guard ids.descriptorType == typeAEList, dates.descriptorType == typeAEList, ids.numberOfItems == dates.numberOfItems else {
            throw PippaError.notAvailable
        }
        let idItems = AppleEvents.items(ids), dateItems = AppleEvents.items(dates)
        guard idItems.count == ids.numberOfItems, dateItems.count == dates.numberOfItems else { throw PippaError.notAvailable }
        return try zip(idItems, dateItems).map { (try mailID($0), try mailDate($1)) }
    }

    /// One row per requested id: `{id, subject, sender, date, mailbox, start, message id, unread}`, or `{}` for a message that is gone.
    /// `identity`: each row also ends with the account id and the mailbox path (`{…, acctID, {box, …}}`, per-account search).
    /// Either form may end with Mail's flags `{…, replied, forwarded, flagged}`; without them all three are false.
    public static func parseRows(_ reply: NSAppleEventDescriptor, expecting count: Int, identity: Bool = false) throws -> [MailSearchRow] {
        let base = identity ? 10 : 8
        guard reply.descriptorType == typeAEList, reply.numberOfItems == count else { throw PippaError.notAvailable }
        var rows: [MailSearchRow] = []
        for row in AppleEvents.items(reply) {
            guard row.descriptorType == typeAEList else { throw PippaError.notAvailable }
            if row.numberOfItems == 0 { continue }
            let f = AppleEvents.items(row)
            guard f.count == row.numberOfItems, f.count == base || f.count == base + 3 else { throw PippaError.notAvailable }
            let booleans: Set<DescType> = [typeBoolean, typeTrue, typeFalse]
            var flags = [false, false, false]
            if f.count == base + 3 {
                flags = try (base..<(base + 3)).map { i -> Bool in
                    guard booleans.contains(f[i].descriptorType) else { throw PippaError.notAvailable }
                    return f[i].booleanValue
                }
            }
            let text = try [1, 2, 4, 5, 6].map { i -> String in
                guard let value = f[i].stringValue, f[i].descriptorType != typeAEList else { throw PippaError.notAvailable }
                return value
            }
            guard [typeBoolean, typeTrue, typeFalse].contains(f[7].descriptorType) else { throw PippaError.notAvailable }
            let id = try mailID(f[0]), date = try mailDate(f[3])
            let messageID = text[4].trimmingCharacters(in: .whitespacesAndNewlines)
            var where_: (account: String, path: [String])?
            if identity {
                guard f[8].descriptorType != typeAEList, let account = f[8].stringValue, f[9].descriptorType == typeAEList else { throw PippaError.notAvailable }
                let path = try AppleEvents.items(f[9]).map { part -> String in
                    guard part.descriptorType != typeAEList, let name = part.stringValue else { throw PippaError.notAvailable }
                    return name
                }
                where_ = (account.trimmingCharacters(in: .whitespacesAndNewlines), path)
            }
            rows.append(MailSearchRow(id: id, date: date, header: MailHeader(
                subject: text[0], sender: text[1], date: date, mailbox: text[2], preview: text[3],
                messageID: messageID.isEmpty ? nil : messageID, unread: f[7].booleanValue, replied: flags[0], forwarded: flags[1], flagged: flags[2]),
                accountID: where_.map { $0.account.isEmpty ? nil : $0.account } ?? nil, path: where_.map { $0.path.isEmpty ? nil : $0.path } ?? nil))
        }
        return rows
    }

    private static func mailID(_ d: NSAppleEventDescriptor) throws -> Int {
        guard [typeSInt16, typeSInt32, typeSInt64, typeUInt32].contains(d.descriptorType),
              let number = d.coerce(toDescriptorType: typeSInt64), number.data.count == MemoryLayout<Int64>.size else { throw PippaError.notAvailable }
        let value = number.data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        guard value >= 0, value <= Int64(Int32.max) else { throw PippaError.notAvailable }
        return Int(value)
    }

    /// A date, or nil for `missing value` (a message Mail has no date for); anything else is malformed.
    private static func mailDate(_ d: NSAppleEventDescriptor) throws -> Date? {
        if d.descriptorType == typeNull || (d.descriptorType == typeType && d.typeCodeValue == 0x6d73_6e67) { return nil }
        guard d.descriptorType == typeLongDateTime, let date = d.dateValue else { throw PippaError.notAvailable }
        return date
    }
}

/// Searches the inbox (`inbox`: all accounts) by subject or sender. The search text goes in as a parameter,
/// never into the script text. Step one reads only ids and dates of all matches in bulk, Swift chooses the newest
/// (`MailSelection`), step two reads subject, sender and the first 400 characters of the text of those messages only.
/// [assumption] Mail answers a bulk property read of a `whose` query in one consistent order, and ids in `whose id is`;
/// neither could be proven without reading a real mailbox. Both steps are bounded by their own 20 second timeout.
enum MailSearchScript {
    static let source = """
    on searchCandidates(q, readMode)
        tell application id "com.apple.mail"
            with timeout of 20 seconds
                if q is "" and readMode is "unread" then
                    set theIDs to id of (messages of inbox whose read status is false)
                    set theDates to date received of (messages of inbox whose read status is false)
                else if q is "" and readMode is "read" then
                    set theIDs to id of (messages of inbox whose read status is true)
                    set theDates to date received of (messages of inbox whose read status is true)
                else if q is "" then
                    set theIDs to id of (messages of inbox)
                    set theDates to date received of (messages of inbox)
                else if readMode is "unread" then
                    set theIDs to id of (messages of inbox whose (subject contains q or sender contains q) and read status is false)
                    set theDates to date received of (messages of inbox whose (subject contains q or sender contains q) and read status is false)
                else if readMode is "read" then
                    set theIDs to id of (messages of inbox whose (subject contains q or sender contains q) and read status is true)
                    set theDates to date received of (messages of inbox whose (subject contains q or sender contains q) and read status is true)
                else
                    set theIDs to id of (messages of inbox whose subject contains q or sender contains q)
                    set theDates to date received of (messages of inbox whose subject contains q or sender contains q)
                end if
            end timeout
            return {theIDs as list, theDates as list}
        end tell
    end searchCandidates

    on searchRows(wantedIDs)
        set out to {}
        tell application id "com.apple.mail"
            with timeout of 20 seconds
                repeat with i from 1 to count of wantedIDs
                    set wanted to item i of wantedIDs
                    set found to (messages of inbox whose id is wanted)
                    if (count of found) is not 1 then
                        set end of out to {}
                    else
                        set m to item 1 of found
                        set theSubject to ""
                        set theSender to ""
                        set theDate to missing value
                        set boxName to ""
                        set c to ""
                        set mid to ""
                        set isUnread to false
                        set wasReplied to false
                        set wasForwarded to false
                        set isFlagged to false
                        try
                            set theSubject to (subject of m) as text
                        end try
                        try
                            set theSender to (sender of m) as text
                        end try
                        try
                            set theDate to date received of m
                        end try
                        try
                            set boxName to (name of mailbox of m) as text
                        end try
                        try
                            set c to (content of m) as text
                            if (length of c) > 400 then set c to text 1 thru 400 of c
                        end try
                        try
                            set mid to (message id of m) as text
                        end try
                        try
                            set isUnread to not (read status of m)
                        end try
                        try
                            set wasReplied to (was replied to of m) as boolean
                        end try
                        try
                            set wasForwarded to (was forwarded of m) as boolean
                        end try
                        try
                            set isFlagged to (flagged status of m) as boolean
                        end try
                        set end of out to {wanted, theSubject, theSender, theDate, boxName, c, mid, isUnread, wasReplied, wasForwarded, isFlagged}
                    end if
                end repeat
            end timeout
        end tell
        return out
    end searchRows
    """

    /// The real Mail, through Apple Events. Only inside `AppleEvents.perform`.
    struct Live: MailSearchNative {
        func candidates(query: String, unread: Bool) throws -> [MailSearchCandidate] {
            try candidates(query: query, readStatus: unread ? .unread : .all)
        }

        func candidates(query: String, readStatus: MailReadStatus) throws -> [MailSearchCandidate] {
            try MailSearchFlow.parseCandidates(try AppleEvents.call(
                MailSearchScript.source, handler: "searchCandidates",
                [NSAppleEventDescriptor(string: query), NSAppleEventDescriptor(string: readStatus.rawValue)], app: .mail))
        }

        func rows(ids: [Int]) throws -> [MailSearchRow] {
            let list = NSAppleEventDescriptor.list()
            for (i, id) in ids.enumerated() { list.insert(NSAppleEventDescriptor(int32: Int32(id)), at: i + 1) }
            return try MailSearchFlow.parseRows(try AppleEvents.call(MailSearchScript.source, handler: "searchRows", [list], app: .mail),
                                                expecting: ids.count)
        }
    }

    static func search(_ query: String, readStatus: MailReadStatus, limit: Int) async throws -> HostFetch<MailHeader> {
        try await AppleEvents.perform { () throws -> HostFetch<MailHeader> in
            try MailSearchFlow.search(Live(), query: query, readStatus: readStatus, limit: limit)
        }
    }
}
