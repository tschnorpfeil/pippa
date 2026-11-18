import Foundation

// Mail search across several accounts, read only: which accounts answered, a fixed snapshot to page through, and
// host-owned references that open exactly one message again. Native steps come from `MailAccountReading`
// (MailAccountScript.swift); checks replace it with synthetic accounts.

/// One Mail account with an inbox: Mail's own account id and the name the person gave it.
public struct MailAccountInfo: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Why an account was not read. Never an empty inbox.
public enum MailAccountProblem: Error, Sendable, Equatable {
    case timeout, failed
}

/// Several inbox mails carry the Message-ID that was asked for: nothing is opened without a `mail_ref`.
public struct MailLookupAmbiguous: Error, Sendable, Equatable {
    public init() {}
}

/// What a mail search asks of Mail, one account at a time. Never asks for permissions; without one it throws
/// `PippaError.accessDenied`. `MailAccountProblem.timeout` when Mail did not answer in time.
public protocol MailAccountReading: Sendable {
    /// Accounts whose inbox Mail lists, in Mail's order. An inbox without a known account has an empty id.
    func inboxAccounts() async throws -> [MailAccountInfo]
    /// Every match in this account's inbox (subject or sender contains `query`, empty: all; `unread`), with its date.
    func candidates(account: String, query: String, unread: Bool) async throws -> [MailSearchCandidate]
    /// Header and start of the text of exactly these messages of this account's inbox, each with the account id and
    /// mailbox path Mail reports for it; a message that is gone is left out.
    func rows(account: String, ids: [Int]) async throws -> [MailSearchRow]
    /// The message with this Mail id in this account's inbox, only when its Message-ID is exactly `messageID`, with where it is.
    func message(account: String, mailID: Int, messageID: String) async throws -> MailInboxMessage?
}

extension SystemIntegrations {
    /// Mail one account at a time (MailAccountScript.swift).
    public var mailAccounts: any MailAccountReading { MailAccountScript.Live() }
}

/// How one account's part of a search went.
public struct MailAccountCoverage: Sendable, Equatable {
    public enum Status: String, Sendable { case ok, timeout, denied, failed, cancelled }
    public var account: MailAccountInfo
    /// Unique among the accounts of this search: the name, with the start of the id when two share a name.
    public var label: String
    public var status: Status
    /// Matches in this account's inbox; `nil` when it was not read.
    public var total: Int?
}

/// One mail of a page, before it is shown: its place in the snapshot and what Mail returned (`nil`: changed or gone).
struct MailPageEntry: Sendable, Equatable {
    var account: MailAccountInfo
    var label: String
    var id: Int
    var date: Date?
}

/// A search fixed at its first page: the order of every match, so later pages have no gaps and no repeats.
struct MailSnapshot: Sendable {
    var id: String
    var query: String
    var unread: Bool
    var account: String?
    var entries: [MailPageEntry]
    var coverage: [MailAccountCoverage]
    /// The order mixes accounts so each one is reached within the previews of an answer: not newest first overall.
    var balanced = false
    /// Mails that changed or left the inbox on the pages so far: never shown, so the search is not complete.
    var gone = 0
}

/// A reference to exactly one message, valid for the answer it was given in: Mail's account id, the whole mailbox path,
/// the Mail id and the Message-ID, all as Mail reported them for this row. A row missing any of them gets no reference.
struct MailRef: Sendable, Equatable {
    var account: MailAccountInfo
    var label: String
    var mailID: Int
    var messageID: String
    var date: Date?
    var path: [String]
}

/// One message read by its account, with where Mail says it is: the account id and the whole mailbox path.
public struct MailInboxMessage: Sendable {
    public var message: MailMessage
    public var accountID: String
    public var path: [String]
    public init(message: MailMessage, accountID: String, path: [String]) { self.message = message; self.accountID = accountID; self.path = path }
}

/// Snapshots, cursors and mail references of the running answer. Everything from an earlier answer is gone, so an old
/// cursor or reference is stale rather than pointing at whatever the inbox holds now. Only the running answer takes the
/// store over (`claim`); every later step of a search checks it still owns it, so an answer that resumes after a newer
/// one began is refused and never clears the newer one's cursors, references or previews.
public final class MailPageStore: @unchecked Sendable {
    /// Preview rows `mail_search` may return in one answer, over all its pages.
    public static let rowsPerAnswer = 100
    private let lock = NSLock()
    private var owner: UUID?
    private var snapshots: [String: MailSnapshot] = [:]
    private var cursors: [String: (snapshot: String, offset: Int)] = [:]
    private var refs: [String: MailRef] = [:]
    /// Previews delivered, and previews held by pages still reading Mail.
    private var delivered = 0, reserved = 0

    public init() {}

    /// The answer `turn` takes the store, dropping an earlier answer's state. `live` runs under the store's lock: an
    /// answer that is no longer the running one can never take the store back from a newer one.
    func claim(_ turn: UUID?, live: () -> Bool) -> Bool {
        lock.withLock {
            guard live() else { return false }
            if owner != turn { owner = turn; snapshots = [:]; cursors = [:]; refs = [:]; delivered = 0; reserved = 0 }
            return true
        }
    }

    private func owned<T>(_ turn: UUID?, _ body: () -> T) -> T? { lock.withLock { owner == turn ? body() : nil } }

    func owns(_ turn: UUID?) -> Bool { lock.withLock { owner == turn } }

    /// Previews this answer may still show (`nil`: another answer owns the store).
    func available(turn: UUID?) -> Int? { owned(turn) { max(0, Self.rowsPerAnswer - delivered - reserved) } }

    func save(_ snapshot: MailSnapshot, turn: UUID?) -> Bool { owned(turn) { snapshots[snapshot.id] = snapshot; return true } ?? false }

    /// Takes the cursor: it works once, so a repeated or parallel use reads nothing. `restore` gives it back when its page fails.
    func takeCursor(_ token: String, turn: UUID?) -> (snapshot: MailSnapshot, offset: Int)? {
        owned(turn) { () -> (snapshot: MailSnapshot, offset: Int)? in
            guard let c = cursors.removeValue(forKey: token), let snapshot = snapshots[c.snapshot] else { return nil }
            return (snapshot, c.offset)
        } ?? nil
    }

    func restoreCursor(_ token: String, snapshot: String, offset: Int, turn: UUID?) {
        _ = owned(turn) { cursors[token] = (snapshot, offset) }
    }

    /// Holds up to `wanted` previews for a page before it reads Mail; parallel pages never pass `rowsPerAnswer` together.
    func reserve(_ wanted: Int, turn: UUID?) -> (granted: Int, left: Int)? {
        owned(turn) {
            let granted = min(max(0, wanted), max(0, Self.rowsPerAnswer - delivered - reserved))
            reserved += granted
            return (granted, Self.rowsPerAnswer - delivered - reserved)
        }
    }

    func release(_ held: Int, turn: UUID?) { _ = owned(turn) { reserved = max(0, reserved - held) } }

    /// Records what a page actually delivered: only those rows count, the rest of the held previews go back; its
    /// references become valid, mails gone since the search add up, and the next cursor (when more remain) starts right
    /// after the last delivered entry. `false`: another answer owns the store, nothing was recorded.
    func settle(snapshot: String, held: Int, rows: Int, refs new: [String: MailRef], gone: Int, cursor: (token: String, offset: Int)?,
                turn: UUID?) -> Bool {
        owned(turn) {
            reserved = max(0, reserved - held)
            delivered += rows
            refs.merge(new) { a, _ in a }
            snapshots[snapshot]?.gone += gone
            if let cursor { cursors[cursor.token] = (snapshot, cursor.offset) }
            return true
        } ?? false
    }

    func ref(_ token: String, turn: UUID?) -> MailRef? { owned(turn) { refs[token] } ?? nil }

    static func token(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }

    /// The shape of a token this store hands out (letters and digits only, short).
    static func isToken(_ text: String, prefix: String) -> Bool {
        text.count == 13 && text.hasPrefix(prefix) && text.dropFirst().allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }
}

/// Choosing and ordering, without Mail.
enum MailAccountFlow {
    /// Every account's matches in one order. Sorted newest first, then by account id and the larger Mail id, so equal
    /// dates and equal Mail ids in two accounts never swap or collide. When several accounts have matches, the first
    /// `window` entries (the previews this answer can still show) take each account's newest ones in turns, and the first
    /// `page` of them include each account's newest (an equal share, at least one): a small account is never hidden behind
    /// a busy one. `balanced`: this changed the newest-first order, so the result must not claim the newest overall.
    static func order(_ lists: [(account: MailAccountInfo, label: String, candidates: [MailSearchCandidate])], page: Int, window: Int)
        -> (entries: [MailPageEntry], balanced: Bool) {
        let entries = lists.flatMap { list in list.candidates.map { MailPageEntry(account: list.account, label: list.label, id: $0.id, date: $0.date) } }
        let all = entries.sorted(by: before)
        let filled = lists.filter { !$0.candidates.isEmpty }
        let w = min(window, all.count)
        guard page > 0, w > 0, filled.count > 1 else { return (all, false) }
        let perAccount = filled.map { list in all.filter { $0.account == list.account } }
        var inWindow = Set<Key>()
        var round = 0
        while inWindow.count < w {
            for entry in perAccount.compactMap({ round < $0.count ? $0[round] : nil }).sorted(by: before) where inWindow.count < w { inWindow.insert(Key(entry)) }
            round += 1
        }
        let windowed = all.filter { inWindow.contains(Key($0)) }
        let first = min(page, w)
        let share = max(1, first / filled.count)
        var chosen = Set<Key>()
        let newest = perAccount.flatMap { list in list.filter { inWindow.contains(Key($0)) }.prefix(share) }
        for entry in newest.sorted(by: before).prefix(first) { chosen.insert(Key(entry)) }
        for entry in windowed where chosen.count < first { chosen.insert(Key(entry)) }
        let ordered = windowed.filter { chosen.contains(Key($0)) } + windowed.filter { !chosen.contains(Key($0)) } + all.filter { !inWindow.contains(Key($0)) }
        return (ordered, ordered.prefix(w).map(Key.init) != all.prefix(w).map(Key.init))
    }

    private struct Key: Hashable {
        var account: String, id: Int
        init(_ e: MailPageEntry) { account = e.account.id; id = e.id }
    }

    static func before(_ a: MailPageEntry, _ b: MailPageEntry) -> Bool {
        switch (a.date, b.date) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.account.id != b.account.id { return a.account.id < b.account.id }
        return a.id > b.id
    }

    /// Names that tell accounts apart: accounts with the same (or no) name get the shortest start of their id, at least
    /// 8 characters, that differs between them.
    static func labels(_ accounts: [MailAccountInfo]) -> [String] {
        // Clipped first, so two names that only differ after the cut still get their ids.
        func name(_ a: MailAccountInfo) -> String { PippaMCPTools.clip(a.name.trimmingCharacters(in: .whitespacesAndNewlines), 60, bytes: 160) }
        return accounts.map { account in
            let twins = accounts.filter { name($0) == name(account) }
            if twins.count == 1 && !name(account).isEmpty { return name(account) }
            let longest = twins.map(\.id.count).max() ?? 0
            let length = (min(8, longest)...max(8, longest)).first { n in Set(twins.map { $0.id.prefix(n) }).count == twins.count } ?? longest
            let id = account.id.isEmpty ? "?" : String(account.id.prefix(length))
            return name(account).isEmpty ? "(\(id))" : "\(name(account)) (\(id))"
        }
    }

    static func status(_ error: Error) -> MailAccountCoverage.Status {
        switch error {
        case PippaError.accessDenied: return .denied
        case MailAccountProblem.timeout: return .timeout
        case is CancellationError: return .cancelled
        default: return .failed
        }
    }

    static func sameDate(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) < 1
        default: return false
        }
    }
}
