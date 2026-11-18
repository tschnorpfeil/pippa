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
    /// Header and start of the text of exactly these messages of this account's inbox; a message that is gone is left out.
    func rows(account: String, ids: [Int]) async throws -> [MailSearchRow]
    /// The message with this Mail id in this account's inbox, only when its Message-ID is exactly `messageID` (when given).
    func message(account: String, mailID: Int, messageID: String?) async throws -> MailMessage?
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
}

/// A reference to exactly one message, valid for the answer it was given in.
struct MailRef: Sendable, Equatable {
    var account: MailAccountInfo
    var label: String
    var mailID: Int
    var messageID: String?
    var date: Date?
    var mailbox: String
}

/// Snapshots, cursors and mail references of the running answer. Everything from an earlier answer is gone, so an old
/// cursor or reference is stale rather than pointing at whatever the inbox holds now.
public final class MailPageStore: @unchecked Sendable {
    /// Preview rows `mail_search` may return in one answer, over all its pages.
    public static let rowsPerAnswer = 100
    private let lock = NSLock()
    private var owner: UUID?
    private var snapshots: [String: MailSnapshot] = [:]
    private var cursors: [String: (snapshot: String, offset: Int)] = [:]
    private var refs: [String: MailRef] = [:]
    private var rows = 0

    public init() {}

    private func scoped<T>(_ turn: UUID?, _ body: () -> T) -> T {
        lock.withLock {
            if owner != turn { owner = turn; snapshots = [:]; cursors = [:]; refs = [:]; rows = 0 }
            return body()
        }
    }

    func remainingRows(turn: UUID?) -> Int { scoped(turn) { max(0, Self.rowsPerAnswer - rows) } }

    func save(_ snapshot: MailSnapshot, turn: UUID?) { scoped(turn) { snapshots[snapshot.id] = snapshot } }

    func cursor(_ token: String, turn: UUID?) -> (snapshot: MailSnapshot, offset: Int)? {
        scoped(turn) { cursors[token].flatMap { c in snapshots[c.snapshot].map { ($0, c.offset) } } }
    }

    /// Records what a page actually delivered: its rows count against the budget, its references become valid, and
    /// the next cursor (when more remain) starts right after the last delivered entry.
    func deliver(snapshot: String, rows delivered: Int, refs new: [String: MailRef], next offset: Int?, turn: UUID?) -> String? {
        scoped(turn) {
            rows += delivered
            refs.merge(new) { a, _ in a }
            guard let offset else { return nil }
            let token = Self.token("c")
            cursors[token] = (snapshot, offset)
            return token
        }
    }

    func ref(_ token: String, turn: UUID?) -> MailRef? { scoped(turn) { refs[token] } }

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
    /// Every account's matches in one order: newest first, then by account id and the larger Mail id, so equal dates and
    /// equal Mail ids in two accounts never swap or collide. The first `page` entries include each account's newest
    /// ones (an equal share, at least one) where the page has room, so a small account is not hidden behind a busy one.
    static func order(_ lists: [(account: MailAccountInfo, label: String, candidates: [MailSearchCandidate])], page: Int) -> [MailPageEntry] {
        let entries = lists.flatMap { list in list.candidates.map { MailPageEntry(account: list.account, label: list.label, id: $0.id, date: $0.date) } }
        let all = entries.sorted(by: before)
        let filled = lists.filter { !$0.candidates.isEmpty }
        guard page > 0, !filled.isEmpty else { return all }
        let share = max(1, page / filled.count)
        var chosen = Set<Key>()
        var reserved: [MailPageEntry] = []
        for list in filled {
            let newest = all.filter { $0.account == list.account }.prefix(share)
            reserved += newest
        }
        for entry in reserved.sorted(by: before).prefix(page) { chosen.insert(Key(entry)) }
        for entry in all where chosen.count < page { chosen.insert(Key(entry)) }
        let first = all.filter { chosen.contains(Key($0)) }
        return first + all.filter { !chosen.contains(Key($0)) }
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
        func name(_ a: MailAccountInfo) -> String { a.name.trimmingCharacters(in: .whitespacesAndNewlines) }
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
