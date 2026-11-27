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
    /// The message with this Mail id in this account's inbox, only when its Message-ID and whole mailbox path match, with where it is.
    func message(account: String, mailID: Int, messageID: String, path: [String]) async throws -> MailInboxMessage?
    /// As `candidates(account:query:unread:)`, by read status and in the account's Inbox, Sent or Drafts.
    func candidates(account: String, query: String, readStatus: MailReadStatus, mailbox: MailBoxKind) async throws -> [MailSearchCandidate]
    /// As `rows(account:ids:)`, in the account's Inbox, Sent or Drafts.
    func rows(account: String, ids: [Int], mailbox: MailBoxKind) async throws -> [MailSearchRow]
    /// As `rows(account:ids:mailbox:)`; `headerOnly`: sender, subject, date, Message-ID, read status and where it is,
    /// without the start of the text or other flags (header-only `mail_search` pages).
    func rows(account: String, ids: [Int], mailbox: MailBoxKind, headerOnly: Bool) async throws -> [MailSearchRow]
    /// As `message(account:mailID:messageID:path:)`, in the account's Inbox, Sent or Drafts.
    func message(account: String, mailID: Int, messageID: String, path: [String], mailbox: MailBoxKind) async throws -> MailInboxMessage?
    /// Whether this account's Sent or Drafts already hold a reply to this message (`nil`: this reader cannot tell).
    func threadActivity(account: String, messageID: String, subject: String, since: Date?) async throws -> MailThreadActivity?
    /// Every mailbox of this account with its whole path, message count, role and up to `samples` mails (sender, subject),
    /// as far as Mail answered within `MailFolderListing`'s bounds; what is missing is counted in the list.
    func folders(account: String, samples: Int) async throws -> MailFolderList
    /// Mail's ids of the messages in the mailbox at `path` that carry each Message-ID (MailMove.swift), live ones apart
    /// from ones marked deleted. Never Mail's id as identity: it changes on Exchange when a mail moves.
    /// `MailMoveProblem.noFolder` when the mailbox is gone.
    func locate(account: String, path: [String], messageIDs: [String]) async throws -> [String: MailLocated]
    /// As `locate(account:path:messageIDs:)`, each Apple event bounded by `eventTimeout` seconds
    /// (`MailMoveSettle.lookupEventTimeout` while Pippa waits for Mail to settle).
    func locate(account: String, path: [String], messageIDs: [String], eventTimeout: Int) async throws -> [String: MailLocated]
    /// Moves these messages from `from` to `to`, each only when its Mail id still carries its Message-ID. One mutating
    /// Apple Event; what happened is read back with `locate`, never taken from this call (its statuses are diagnostics).
    @discardableResult
    func move(account: String, from: [String], mails: [MailMoveItem], to: [String]) async throws -> [String]
}

extension MailAccountReading {
    /// Readers that know only the inbox and `unread`: read mails are every match minus the unread ones; Sent and Drafts fail.
    public func candidates(account: String, query: String, readStatus: MailReadStatus, mailbox: MailBoxKind) async throws -> [MailSearchCandidate] {
        guard mailbox == .inbox else { throw MailAccountProblem.failed }
        switch readStatus {
        case .all: return try await candidates(account: account, query: query, unread: false)
        case .unread: return try await candidates(account: account, query: query, unread: true)
        case .read:
            let unread = Set(try await candidates(account: account, query: query, unread: true).map(\.id))
            return try await candidates(account: account, query: query, unread: false).filter { !unread.contains($0.id) }
        }
    }

    public func rows(account: String, ids: [Int], mailbox: MailBoxKind) async throws -> [MailSearchRow] {
        guard mailbox == .inbox else { throw MailAccountProblem.failed }
        return try await rows(account: account, ids: ids)
    }

    /// Readers without a header-only read read the whole row.
    public func rows(account: String, ids: [Int], mailbox: MailBoxKind, headerOnly: Bool) async throws -> [MailSearchRow] {
        try await rows(account: account, ids: ids, mailbox: mailbox)
    }

    public func message(account: String, mailID: Int, messageID: String, path: [String], mailbox: MailBoxKind) async throws -> MailInboxMessage? {
        guard mailbox == .inbox else { throw MailAccountProblem.failed }
        return try await message(account: account, mailID: mailID, messageID: messageID, path: path)
    }

    public func threadActivity(account: String, messageID: String, subject: String, since: Date?) async throws -> MailThreadActivity? { nil }

    /// Readers that cannot list, find or move: nothing is listed or moved.
    public func folders(account: String, samples: Int) async throws -> MailFolderList { throw MailAccountProblem.failed }
    public func locate(account: String, path: [String], messageIDs: [String]) async throws -> [String: MailLocated] { throw MailAccountProblem.failed }
    /// Readers without their own event timeout look up as usual.
    public func locate(account: String, path: [String], messageIDs: [String], eventTimeout: Int) async throws -> [String: MailLocated] {
        try await locate(account: account, path: path, messageIDs: messageIDs)
    }
    @discardableResult
    public func move(account: String, from: [String], mails: [MailMoveItem], to: [String]) async throws -> [String] { throw MailAccountProblem.failed }
}

/// What this account's Sent and Drafts say about a message: a reply was sent, a reply draft waits, and whether each
/// mailbox was searched completely (so an unsearched remainder is never reported as `false`).
public struct MailThreadActivity: Sendable, Equatable {
    public var sentReply: Bool
    public var draft: Bool
    public var sentComplete: Bool
    public var draftsComplete: Bool
    public init(sentReply: Bool, draft: Bool, sentComplete: Bool = true, draftsComplete: Bool = true) {
        self.sentReply = sentReply
        self.draft = draft
        self.sentComplete = sentComplete
        self.draftsComplete = draftsComplete
    }

    public var isComplete: Bool { (sentComplete || sentReply) && (draftsComplete || draft) }
}

/// Is a mail in Sent or Drafts a confirmed reply to the original? Only when its `In-Reply-To` or `References` header
/// names the original's exact Message-ID and its own Message-ID is not the original's. Subject prefixes only prioritize
/// which candidates are inspected first.
public enum MailThreadMatch {
    public static let maxCandidates = 40
    static let replyPrefixes = ["re:", "aw:", "antw:", "sv:"]
    static let prefixes = replyPrefixes + ["wg:", "fwd:", "fw:"]

    /// The subject without reply and forward prefixes, whitespace collapsed.
    public static func core(_ subject: String) -> String {
        var text = subject.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return text
    }

    /// True only when an unfolded `In-Reply-To` or `References` header contains `messageID` as an exact canonical Message-ID.
    public static func referencesMessageID(headers: String, messageID: String) -> Bool {
        guard let wanted = MailReplySource.canonicalMessageID(messageID), !headers.isEmpty else { return false }
        let normalized = headers.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var values: [String] = []
        var currentKey: String?
        var currentValue = ""
        func flush() {
            if let key = currentKey, key == "in-reply-to" || key == "references" { values.append(currentValue) }
            currentKey = nil
            currentValue = ""
        }
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); break }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if currentKey != nil { currentValue += " " + line.trimmingCharacters(in: .whitespaces) }
            } else {
                flush()
                guard let colon = line.firstIndex(of: ":") else { continue }
                currentKey = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                currentValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        for value in values {
            var cursor = value.startIndex
            while let open = value[cursor...].firstIndex(of: "<"),
                  let close = value[value.index(after: open)...].firstIndex(of: ">") {
                let inside = String(value[value.index(after: open)..<close])
                if !inside.contains("<"), MailReplySource.canonicalMessageID(inside) == wanted { return true }
                cursor = value.index(after: close)
            }
            for token in value.split(whereSeparator: { $0.isWhitespace || $0 == "," }) where !token.contains("<") && !token.contains(">") {
                if MailReplySource.canonicalMessageID(String(token)) == wanted { return true }
            }
        }
        return false
    }

    /// Chooses up to `limit` candidates to inspect in Sent or Drafts without hiding changed-subject replies behind a subject
    /// filter. `complete` is true only when every message in the mailbox was selected.
    public static func selectCandidates(all: [MailSearchCandidate], coreMatches: Set<Int>, since: Date?,
                                        limit: Int = maxCandidates) -> (ids: [Int], complete: Bool) {
        guard limit > 0, !all.isEmpty else { return ([], all.isEmpty) }
        let ordered = MailSelection.newest(all, limit: all.count, date: \.date, tie: { String(format: "%020lld", Int64($0.id)) })
        if ordered.count <= limit { return (ordered.map(\.id), true) }
        var chosen: [Int] = []
        var seen = Set<Int>()
        func add(_ candidate: MailSearchCandidate) {
            guard chosen.count < limit, seen.insert(candidate.id).inserted else { return }
            chosen.append(candidate.id)
        }
        let coreBudget = max(1, limit / 2)
        for c in ordered where coreMatches.contains(c.id) && chosen.count < coreBudget { add(c) }
        if let cutoff = since?.addingTimeInterval(-60) {
            for c in ordered where c.date == nil || c.date! >= cutoff { add(c) }
        }
        for c in ordered { add(c) }
        return (chosen, chosen.count == all.count)
    }

    /// Confirmed thread activity requires an exact `In-Reply-To` or `References` match on a distinct message.
    public static func isConfirmedReply(headers: String, ownMessageID: String?, to messageID: String) -> Bool {
        guard let wanted = MailReplySource.canonicalMessageID(messageID) else { return false }
        let own = ownMessageID.flatMap(MailReplySource.canonicalMessageID)
            ?? MailReplySource.capture(headers: Data(headers.utf8))?.messageID
        guard own != wanted else { return false }
        return referencesMessageID(headers: headers, messageID: messageID)
    }

    /// Drops a trailing unterminated header line when `all headers` was clipped before the blank header terminator.
    public static func completeHeaderLines(_ headers: String) -> String {
        guard !headers.isEmpty else { return "" }
        if headers.contains("\r\n\r\n") || headers.contains("\n\n") { return headers }
        guard let newline = headers.lastIndex(where: \.isNewline) else { return "" }
        return String(headers[..<newline])
    }
}

extension SystemIntegrations {
    /// Mail one account at a time (MailAccountScript.swift).
    public var mailAccounts: any MailAccountReading { MailAccountScript.Live() }
}

/// How one account's part of a search went.
public struct MailAccountCoverage: Sendable, Equatable {
    public enum Status: String, Sendable { case ok, timeout, denied, failed, cancelled, duplicate_candidates }
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
    var readStatus: MailReadStatus = .all
    var mailbox: MailBoxKind = .inbox
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
    /// The top-level container the search read (Inbox, Sent or Drafts).
    var mailbox: MailBoxKind = .inbox
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
    /// The same for an answer with an extended budget (an online AI with the tools of the AI on this Mac).
    public static let extendedRowsPerAnswer = 300
    private let lock = NSLock()
    private var owner: UUID?
    private var limit = MailPageStore.rowsPerAnswer
    private var snapshots: [String: MailSnapshot] = [:]
    /// `owed`/`gone`: rows a page gave only to `structuredContent` beyond its text, charged when that cursor is taken;
    /// `pair`: the page's other cursor (text and structured pages end at different rows), taken away with this one.
    private var cursors: [String: (snapshot: String, offset: Int, owed: Int, gone: Int, pair: String?)] = [:]
    private var refs: [String: MailRef] = [:]
    /// `mail_move` dry runs of this answer, each usable once (MailMove.swift).
    private var plans: [String: MailMovePlan] = [:]
    /// Previews delivered, and previews held by pages still reading Mail.
    private var delivered = 0, reserved = 0
    private var claimed = false

    public init() {}

    /// The answer `turn` takes the store, dropping an earlier answer's state. `live` runs under the store's lock: an
    /// answer that is no longer the running one can never take the store back from a newer one.
    func claim(_ turn: UUID?, extended: Bool = false, live: () -> Bool) -> Bool {
        lock.withLock {
            guard live() else { return false }
            if owner != turn { owner = turn; snapshots = [:]; cursors = [:]; refs = [:]; plans = [:]; delivered = 0; reserved = 0 }
            limit = extended ? Self.extendedRowsPerAnswer : Self.rowsPerAnswer
            claimed = true
            return true
        }
    }

    /// Previews the owning answer may show in all (`rowsPerAnswer` or `extendedRowsPerAnswer`).
    func rowLimit(turn: UUID?) -> Int { owned(turn) { limit } ?? Self.rowsPerAnswer }

    private func owned<T>(_ turn: UUID?, _ body: () -> T) -> T? { lock.withLock { owner == turn ? body() : nil } }

    func owns(_ turn: UUID?) -> Bool { lock.withLock { owner == turn } }

    func requiresRef(_ turn: UUID?) -> Bool { owned(turn) { claimed } ?? false }

    /// Previews this answer may still show (`nil`: another answer owns the store).
    func available(turn: UUID?) -> Int? { owned(turn) { max(0, limit - delivered - reserved) } }

    func save(_ snapshot: MailSnapshot, turn: UUID?) -> Bool { owned(turn) { snapshots[snapshot.id] = snapshot; return true } ?? false }

    /// Takes the cursor: it works once, so a repeated or parallel use reads nothing. `restore` gives it back when its page fails.
    /// Continuing after a page's structured rows charges those rows now, so a script stays within the same budget.
    func takeCursor(_ token: String, turn: UUID?) -> (snapshot: MailSnapshot, offset: Int)? {
        owned(turn) { () -> (snapshot: MailSnapshot, offset: Int)? in
            guard let c = cursors.removeValue(forKey: token), var snapshot = snapshots[c.snapshot] else { return nil }
            if let pair = c.pair { cursors.removeValue(forKey: pair) }
            delivered += c.owed
            snapshot.gone += c.gone
            snapshots[c.snapshot] = snapshot
            return (snapshot, c.offset)
        } ?? nil
    }

    func restoreCursor(_ token: String, snapshot: String, offset: Int, turn: UUID?) {
        _ = owned(turn) { cursors[token] = (snapshot, offset, 0, 0, nil) }
    }

    /// Holds up to `wanted` previews for a page before it reads Mail; parallel pages never pass `rowsPerAnswer` together.
    func reserve(_ wanted: Int, turn: UUID?) -> (granted: Int, left: Int, exhausted: Bool)? {
        owned(turn) {
            let granted = min(max(0, wanted), max(0, limit - delivered - reserved))
            reserved += granted
            return (granted, limit - delivered - reserved, delivered >= limit)
        }
    }

    func release(_ held: Int, turn: UUID?) { _ = owned(turn) { reserved = max(0, reserved - held) } }

    /// Records what a page actually delivered: only those rows count, the rest of the held previews go back; its
    /// references become valid, mails gone since the search add up, and the next cursor (when more remain) starts right
    /// after the last delivered entry. `false`: another answer owns the store, nothing was recorded.
    /// `structured`: the cursor after the rows only `structuredContent` showed, when that page went further than the text.
    func settle(snapshot: String, held: Int, rows: Int, refs new: [String: MailRef], gone: Int, problems: [MailAccountInfo: MailAccountCoverage.Status], cursor: (token: String, offset: Int)?,
                structured: (token: String, offset: Int, owed: Int, gone: Int)? = nil, turn: UUID?, live: () -> Bool) -> Bool {
        owned(turn) {
            guard live() else { return false }
            reserved = max(0, reserved - held)
            delivered += rows
            refs.merge(new) { a, _ in a }
            if var updated = snapshots[snapshot] {
                updated.gone += gone
                for i in updated.coverage.indices {
                    if let problem = problems[updated.coverage[i].account] { updated.coverage[i].status = problem }
                }
                snapshots[snapshot] = updated
            }
            if let cursor { cursors[cursor.token] = (snapshot, cursor.offset, 0, 0, structured?.token) }
            if let structured { cursors[structured.token] = (snapshot, structured.offset, structured.owed, structured.gone, cursor?.token) }
            return true
        } ?? false
    }

    func ref(_ token: String, turn: UUID?) -> MailRef? { owned(turn) { refs[token] } ?? nil }

    func savePlan(_ plan: MailMovePlan, turn: UUID?) -> Bool { owned(turn) { plans[plan.id] = plan; return true } ?? false }

    /// Takes the plan: it works once. `restorePlan` gives it back only when nothing was dispatched.
    func takePlan(_ token: String, turn: UUID?) -> MailMovePlan? { owned(turn) { plans.removeValue(forKey: token) } ?? nil }

    func restorePlan(_ plan: MailMovePlan, turn: UUID?) { _ = owned(turn) { plans[plan.id] = plan } }

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
        let rounds = perAccount.map(\.count).max() ?? 0
        while inWindow.count < w && round < rounds {
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

    /// Distinguish accounts with the same visible name using their IDs.
    static func labels(_ accounts: [MailAccountInfo]) -> [String] {
        let names = accounts.map { PippaMCPTools.clip($0.name.trimmingCharacters(in: .whitespacesAndNewlines), 60, bytes: 160) }
        let groups = Dictionary(grouping: accounts.indices, by: { names[$0].lowercased() })
        return accounts.indices.map { i in
            let name = names[i]
            let twins = groups[name.lowercased(), default: []]
            guard twins.count > 1 || name.isEmpty else { return name }
            let ids = twins.map { accounts[$0].id }
            let rawID = accounts[i].id
            // Use a visible ID prefix if it distinguishes the whole group. For IDs with a long
            // shared prefix or control characters, use their order by exact ID within the group.
            let prefix = String(rawID.prefix(13))
            let safe = !prefix.isEmpty && prefix.utf8.allSatisfy { (33...126).contains($0) }
                && Set(ids.map { String($0.prefix(13)).lowercased() }).count == ids.count
            let identity = safe ? prefix : "#\((twins.sorted { (accounts[$0].id, $0) < (accounts[$1].id, $1) }.firstIndex(of: i) ?? 0) + 1)"
            let suffix = "(\(identity))"
            if name.isEmpty { return suffix }
            let stem = PippaMCPTools.clip(name, 59 - suffix.count, bytes: 159 - suffix.utf8.count)
            return "\(stem) \(suffix)"
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
