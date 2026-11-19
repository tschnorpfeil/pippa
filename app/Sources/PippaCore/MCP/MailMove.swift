import Foundation

// Moving mail between folders of one account (docs/pippa-1.0.md "Tools in 1.0", "Journal, verification and undo for
// whole runs"). The engine is shared by `mail_move` (PippaMCPMailMove.swift) and `Pippa --mail-move-probe`: a dry run
// looks every mail up by its RFC Message-ID, the moves go in batches of 10, every mail of a batch is looked up again in
// the source and the target folder until Mail settled (`MailMoveSettle`), and a mail found in neither makes the batch
// unclear and stops the run. Undo goes back in the same batches with the same settling. Mail's own id
// is only a handle for the next Apple Event: it changes on Exchange when a mail moves.
//
// Only live messages count as "in a folder". On IMAP (iCloud) Mail moves by copy plus delete, and a copy it marked
// deleted (`deleted status`) may stay listed until the server expunges it: such entries are counted apart
// (`MailLocated.deleted`) and never moved. A mail live in both folders after the bound is unclear ("in both folders"):
// Pippa never deletes mail and never repeats the move.
//
// A lookup Mail did not answer in time is "not known yet": never "not there", never a failure of the move. Mail that
// still did not answer after the bound leaves the mail unclear (`noAnswerNote`), and `recheck` looks once more later.

/// One mailbox of an account, as Mail lists it.
public struct MailFolderInfo: Sendable, Equatable {
    public var path: [String]
    /// Messages in it; `nil` when Mail did not say.
    public var count: Int?
    /// What Mail uses it for, when Mail or its name says so (never a target for `mail_move`).
    public var role: MailFolderRole?
    /// Up to two mails as Mail lists them first: sender and subject only.
    public var samples: [MailFolderSample]
    /// Why `count` and `samples` are missing, when the listing left them out (`nil`: Mail was asked and answered).
    public var gap: MailFolderGap?
    public init(path: [String], count: Int?, role: MailFolderRole? = nil, samples: [MailFolderSample] = [], gap: MailFolderGap? = nil) {
        self.path = path; self.count = count; self.role = role; self.samples = samples; self.gap = gap
    }

    /// The path the model reads and writes: names joined with "/".
    public var display: String { path.joined(separator: "/") }
}

public enum MailFolderGap: String, Sendable, Equatable {
    /// Mail did not answer the count or a sample within `MailFolderListing.eventTimeout`.
    case slow
    /// The listing passed `MailFolderListing.countBound`: path only, Mail was not asked for count or samples.
    case pathOnly = "path_only"
}

/// Every mailbox of one account, as far as Mail answered in time.
public struct MailFolderList: Sendable, Equatable {
    public var folders: [MailFolderInfo]
    /// Mailboxes Mail did not name in time, or that the listing did not reach (`MailFolderListing.pathBound`, 500
    /// mailboxes): they are not in `folders`.
    public var unnamed: Int
    /// Listed mailboxes whose subfolders Mail did not list in time: more folders may exist under them.
    public var unexpanded: Int
    public init(folders: [MailFolderInfo], unnamed: Int = 0, unexpanded: Int = 0) { self.folders = folders; self.unnamed = unnamed; self.unexpanded = unexpanded }

    /// Every mailbox of the account is in `folders` (counts may still be missing, see `MailFolderInfo.gap`).
    public var allListed: Bool { unnamed == 0 && unexpanded == 0 }
}

/// Bounds of the folder listing (`accountFolders`). One mailbox that Mail does not answer for must not cost the whole
/// listing: each question about one mailbox (its path, its count, one sample, its subfolders) is one Apple event with
/// its own timeout, and a timeout (-1712) leaves only that mailbox incomplete.
public enum MailFolderListing {
    /// Seconds per Apple event about one mailbox. Mail answers these in well under a second when it is well.
    public static let eventTimeout = 5
    /// Seconds after the listing started from which the remaining mailboxes get their path only, no count or samples.
    public static let countBound = 20
    /// Seconds after the listing started from which the remaining mailboxes are not asked at all, only counted.
    public static let pathBound = 40
}

public struct MailFolderSample: Sendable, Equatable {
    public var sender: String
    public var subject: String
    public init(sender: String, subject: String) { self.sender = sender; self.subject = subject }
}

public enum MailFolderRole: String, Sendable, Equatable {
    case inbox, sent, drafts, trash, junk, outbox

    /// The roles a mail is never moved into: Sent, Drafts, Trash, Junk, Outbox.
    public var refusedAsTarget: Bool { self != .inbox }

    /// Names Mail and mail servers give these mailboxes, in English and German. Fails closed: a folder of the person's
    /// own with one of these names is not a target either.
    static let names: [String: MailFolderRole] = {
        var map: [String: MailFolderRole] = [:]
        for name in ["inbox", "posteingang"] { map[name] = .inbox }
        for name in ["sent", "sent messages", "sent items", "sent mail", "gesendet", "gesendete objekte", "gesendete elemente", "gesendete e-mails"] { map[name] = .sent }
        for name in ["drafts", "draft", "entwürfe", "entwurf"] { map[name] = .drafts }
        for name in ["trash", "deleted messages", "deleted items", "deleted", "bin", "papierkorb", "gelöschte objekte", "gelöschte elemente", "gelöscht"] { map[name] = .trash }
        for name in ["junk", "junk e-mail", "junk email", "junk mail", "spam", "werbung", "unerwünscht", "bulk mail"] { map[name] = .junk }
        for name in ["outbox", "postausgang"] { map[name] = .outbox }
        return map
    }()

    /// Mail's own role first, then the folder's last name.
    public static func of(_ folder: MailFolderInfo) -> MailFolderRole? {
        folder.role ?? folder.path.last.flatMap { names[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] }
    }

    /// The refused role of `folder` or of any folder it lies in (`Deleted Items/Rechnungen` is inside Trash): each level
    /// by Mail's role when `folders` lists it, else by its name. `nil`: an ordinary folder, a possible target.
    public static func refused(_ folder: MailFolderInfo, in folders: [MailFolderInfo]) -> MailFolderRole? {
        for depth in stride(from: folder.path.count, through: 1, by: -1) {
            let prefix = Array(folder.path.prefix(depth))
            let level = depth == folder.path.count ? folder : folders.first { $0.path == prefix } ?? MailFolderInfo(path: prefix, count: nil)
            if let role = of(level), role.refusedAsTarget { return role }
        }
        return nil
    }
}

/// The messages of one mailbox that carry one Message-ID, by Mail's id: `live` ones are in the folder, `deleted` ones
/// are marked deleted and only wait to be expunged (IMAP). Only `live` counts as being in the folder.
public struct MailLocated: Sendable, Equatable {
    public var live: [Int]
    public var deleted: [Int]
    public init(live: [Int] = [], deleted: [Int] = []) { self.live = live; self.deleted = deleted }
}

/// One mail for a move: Mail's id in the source folder right now, and the Message-ID it must still carry.
public struct MailMoveItem: Sendable, Equatable {
    public var mailID: Int
    public var messageID: String
    public init(mailID: Int, messageID: String) { self.mailID = mailID; self.messageID = messageID }
}

public enum MailMoveProblem: Error, Sendable, Equatable {
    /// The mailbox at that path is no longer there.
    case noFolder
}

/// A dry run that `mail_move` can apply once, in the answer that made it (`MailPageStore.takePlan`).
public struct MailMovePlan: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var messageID: String
        public var mailID: Int
        public init(messageID: String, mailID: Int) { self.messageID = messageID; self.mailID = mailID }
    }
    public var id: String
    public var account: MailAccountInfo
    public var label: String
    public var source: [String]
    public var target: [String]
    public var entries: [Entry]
    /// Mails of the request that are no longer in the source folder.
    public var notFound: Int
    /// Mails that are not moved, by reason: `no_message_id`, `duplicate` (the Message-ID occurs more than once in the
    /// source), `already_in_target` (live in the target while still live in the source).
    public var skipped: [String: Int]
    /// Of `already_in_target`: also still live in the source. Pippa leaves both and deletes neither.
    public var inBoth = 0
    /// Mails whose lookup found entries marked deleted (not yet expunged) in source or target: never counted, never moved.
    public var deleted = 0
}

/// What a move did, from the read-back only.
public struct MailMoveOutcome: Sendable, Equatable {
    /// Moved and found exactly once in the target folder, gone from the source.
    public var verified = 0
    /// Mails whose batch was dispatched.
    public var attempted = 0
    /// Still in the source after their batch: Mail did not move them.
    public var notMoved = 0
    /// Not in the source any more when their batch was to start.
    public var notFound = 0
    public var skipped: [String: Int] = [:]
    /// Neither (or both) in source and target after the move: the batch is unclear.
    public var unclear = 0
    /// Of `unclear`: live in both folders after the bound (IMAP copied but did not delete). Pippa deletes neither.
    public var inBoth = 0
    /// Mails whose last read-back found entries marked deleted (not yet expunged): never counted as there.
    public var deleted = 0
    /// Of `unclear`: Mail did not answer the read-back in time, so where they are is not known yet (`noAnswerNote`).
    public var noAnswer = 0
    /// Of `unclear`: Stop ended the read-back before these mails, reported moved, showed up (`unverifiedNote`).
    public var notChecked = 0
    public var unclearBatch: Int?
    /// Mails of batches that never started (Stop, an unclear batch, an error).
    public var notStarted = 0
    public var batches = 0
    public var stopped = false
    /// Mail's error that ended the run, if any (Mail not open, access, timeout).
    public var failure: String?
    /// Per verified mail: did Mail give it a new id in the target folder (Exchange)?
    public var idsKept = 0
    public var idsChanged = 0
    /// What Mail's move step said per mail ("moved", "changed", "gone", an error number), counted. Diagnostics only.
    public var statuses: [String: Int] = [:]
    /// The read-backs' waits for Mail to settle, over all batches.
    public var settle = MailMoveSettleStats()
    public init() {}
}

/// How long a read-back waits for Mail to show what it moved. On IMAP (iCloud) a moved mail shows up in the target
/// folder a moment after Mail answered "moved", so one lookup right after the move is too early. The read-back looks the
/// batch up again every `interval` until every mail Mail reported as moved is in its new folder, or `bound` passed.
/// Polling is a lookup, never a repeated move. Checks inject `sleep` and `now` and run in milliseconds.
public struct MailMoveSettle: Sendable {
    /// One lookup of a batch of 10 takes Mail about as long on IMAP; a shorter pause would mostly add Apple Events.
    public static let interval: Duration = .seconds(1)
    /// Per batch. The iCloud probe saw the late mail within a few seconds; 20 s leaves room for a slow server while a
    /// batch that never settles holds the run for 20 s only, and then counts as unclear.
    public static let bound: Duration = .seconds(20)
    /// Seconds each Apple event of a lookup may take while Pippa waits for Mail to settle. The iCloud probe of
    /// November 2026 saw Mail not answer the lookup of one folder for 30 s and more right after moves (and an Undo),
    /// while the other folder answered in 0.3 s; the first event after Mail's launch sometimes stalls too. A short
    /// timeout turns such a stall into one poll that is not known yet, and the wait goes on.
    public static let lookupEventTimeout = 8
    /// The bound once a lookup of the wait timed out: long enough to outlast such a stall of 30 s and more and still
    /// read where the mails are. Without timeouts `bound` stays.
    public static let boundAfterTimeout: Duration = .seconds(60)
    public var sleep: @Sendable (Duration) async -> Void
    /// A monotonic time, only differences count.
    public var now: @Sendable () -> Duration
    public init(sleep: @escaping @Sendable (Duration) async -> Void, now: @escaping @Sendable () -> Duration) { self.sleep = sleep; self.now = now }

    /// The longest the answer's receipt waits for a `mail_move` still reading back (`MailMoveRuns.wait`): one read-back
    /// after a timeout, plus its last poll.
    public static let receiptBound: Duration = boundAfterTimeout + .seconds(2 * lookupEventTimeout)

    private static let start = ContinuousClock.now
    public static let live = MailMoveSettle(sleep: { try? await Task.sleep(for: $0) }, now: { start.duration(to: .now) })
}

/// `mail_move` calls still running, per answer. Each runs as its own task: the read-back of a batch whose move was sent
/// is never cut by the cancellation of the answer's request (a dropped connection); Stop still ends its wait (the rest
/// is unclear). The answer's receipt waits for them (`wait`), at most `MailMoveSettle.receiptBound`.
public final class MailMoveRuns: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [UUID: [UUID: Task<Void, Never>]] = [:]
    public init() {}

    func run<T: Sendable>(_ run: UUID?, _ work: @escaping @Sendable () async -> T) async -> T {
        let task = Task { await work() }
        guard let run else { return await task.value }
        let key = UUID()
        lock.withLock { running[run, default: [:]][key] = Task { _ = await task.value } }
        let value = await task.value
        lock.withLock {
            running[run]?[key] = nil
            if running[run]?.isEmpty == true { running[run] = nil }
        }
        return value
    }

    /// Returns when every `mail_move` of `run` finished, or after `bound`.
    public func wait(_ run: UUID, bound: Duration = MailMoveSettle.receiptBound) async {
        let tasks = lock.withLock { Array((running[run] ?? [:]).values) }
        guard !tasks.isEmpty else { return }
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
            func resume() { lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { continuation = nil }; return continuation }?.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once(continuation)
            Task { for task in tasks { await task.value }; once.resume() }
            Task { try? await Task.sleep(for: bound); once.resume() }
        }
    }
}

public struct MailMoveSettleStats: Sendable, Equatable {
    /// Lookups of source and target (one per poll), counting the first.
    public var lookups = 0
    public var waitedMs = 0
    /// The longest wait of one batch.
    public var longestMs = 0
    /// Lookups Mail did not answer within `MailMoveSettle.lookupEventTimeout` (each one poll).
    public var timeouts = 0
    public init() {}
    mutating func add(_ other: MailMoveSettleStats) {
        lookups += other.lookups; waitedMs += other.waitedMs; longestMs = max(longestMs, other.longestMs); timeouts += other.timeouts
    }
}

/// One lookup of some Message-IDs in a move's source and target folder.
struct MailFound {
    var src: [String: MailLocated]
    var tgt: [String: MailLocated]
    /// `false`: Mail did not answer the last lookup in time; `src` and `tgt` are the last answer before it (empty when
    /// there was none). A mail not where it should be in them is not known yet, never "not there".
    var answered = true
    /// The wait ended because of Stop before every awaited mail arrived and before the bound: what has not arrived is
    /// not known yet, never "not moved".
    var cutShort = false
    /// Live in the source (the folder the mail comes from).
    func here(_ id: String) -> [Int] { src[id]?.live ?? [] }
    /// Live in the target.
    func there(_ id: String) -> [Int] { tgt[id]?.live ?? [] }
    /// How many of `ids` have entries marked deleted in either folder.
    func deleted(_ ids: [String]) -> Int {
        Set(ids).filter { !(src[$0]?.deleted ?? []).isEmpty || !(tgt[$0]?.deleted ?? []).isEmpty }.count
    }
}

/// The engine. Checks hand it a synthetic `MailAccountReading`; the app and the probe the real Mail.
public struct MailMover: Sendable {
    public static let batchSize = 10
    /// More mails than this in one `mail_move` call need a dry run and its plan.
    public static let directLimit = 20
    public static let kind = "mail.move"

    let reader: any MailAccountReading
    let settle: MailMoveSettle
    public init(reader: any MailAccountReading, settle: MailMoveSettle = .live) { self.reader = reader; self.settle = settle }

    // MARK: Dry run

    /// Every mail looked up by Message-ID in source and target. Nothing moves. `mailIDs` (in the order of `messageIDs`):
    /// Mail's id the search gave each mail; a mail with that Message-ID in the source under another id is not the
    /// searched mail and is skipped (`other_mail`). Message-IDs compare exactly.
    public func plan(account: MailAccountInfo, label: String, source: [String], target: [String], messageIDs: [String?],
                     mailIDs: [Int]? = nil) async throws -> MailMovePlan {
        var skipped: [String: Int] = [:]
        var wanted: [String] = []
        var seen = Set<String>()
        var searched: [String: Int] = [:]
        for (index, raw) in messageIDs.enumerated() {
            guard let id = raw.flatMap(MailReplySource.canonicalMessageID) else { skipped["no_message_id", default: 0] += 1; continue }
            // The same mail named twice is one mail.
            guard seen.insert(id).inserted else { continue }
            wanted.append(id)
            if let mailIDs, index < mailIDs.count { searched[id] = mailIDs[index] }
        }
        let found = try await lookup(account: account.id, source: source, target: target, wanted)
        var entries: [MailMovePlan.Entry] = []
        var notFound = 0, inBoth = 0
        for id in wanted {
            let here = found.here(id), there = found.there(id)
            if here.isEmpty { notFound += 1 }
            else if here.count > 1 { skipped["duplicate", default: 0] += 1 }
            else if let mailID = searched[id], here[0] != mailID { skipped["other_mail", default: 0] += 1 }
            else if !there.isEmpty {
                // Live in the target and still live in the source: in both folders.
                skipped["already_in_target", default: 0] += 1
                inBoth += 1
            }
            else { entries.append(.init(messageID: id, mailID: here[0])) }
        }
        return MailMovePlan(id: MailPageStore.token("p"), account: account, label: label, source: source, target: target,
                            entries: entries, notFound: notFound, skipped: skipped, inBoth: inBoth, deleted: found.deleted(wanted))
    }

    // MARK: Apply

    /// Where the moves are written down: rows go in planned before the first batch and dispatched (on disk) before their
    /// batch's Apple Event. `nil` journal: no run (checks without an answer).
    public struct Journal: Sendable {
        public var executor: Executor
        public var run: UUID
        public init(executor: Executor, run: UUID) { self.executor = executor; self.run = run }
    }

    /// The batches. Before each: the lease and `live` (Stop, a newer answer); then a fresh lookup in source and target, the
    /// journal rows dispatched, one move, and the read-back by Message-ID. Never retries a move. Throws only when the
    /// journal cannot take the rows before anything moved.
    public func apply(_ plan: MailMovePlan, journal: Journal?, live: @Sendable () -> Bool = { true },
                      afterBatch: (@Sendable (Int) async -> Void)? = nil) async throws -> MailMoveOutcome {
        var outcome = MailMoveOutcome()
        outcome.notFound = plan.notFound
        outcome.skipped = plan.skipped
        let lease = PippaMCPWriteLease.current
        let fromName = plan.source.joined(separator: "/"), toName = plan.target.joined(separator: "/")
        var rows: [String: UUID] = [:]
        if let journal {
            let drafts = plan.entries.map { entry in
                var object = RunObject.mailMessage(kind: Self.kind, account: plan.account.id, mailbox: fromName, messageID: entry.messageID)
                object.fields["from"] = Self.encode(plan.source)
                object.fields["to"] = Self.encode(plan.target)
                object.fields["mailID"] = String(entry.mailID)
                return RunActionDraft(tool: "mail_move", actionClass: .undoable, object: object,
                                      before: ["mailbox": fromName], after: ["mailbox": toName], label: "\(fromName) → \(toName)")
            }
            let planned = try await journal.executor.planRunActions(run: journal.run, drafts)
            for (entry, row) in zip(plan.entries, planned) { rows[entry.messageID] = row.id }
        }
        func drop(_ ids: [String]) async {
            guard let journal else { return }
            let gone = ids.compactMap { rows.removeValue(forKey: $0) }
            if !gone.isEmpty { try? await journal.executor.dropRunActions(gone) }
        }
        let batches = stride(from: 0, to: plan.entries.count, by: Self.batchSize).map { Array(plan.entries[$0..<min($0 + Self.batchSize, plan.entries.count)]) }
        var index = 0
        var dispatched = Set<String>()
        while index < batches.count {
            let batch = batches[index]
            let rest = batches[index...].reduce(0) { $0 + $1.count }
            do { try lease?.check() } catch { outcome.stopped = true; outcome.notStarted = rest; break }
            guard live() else { outcome.stopped = true; outcome.notStarted = rest; break }
            let ids = batch.map(\.messageID)
            // Fresh: the folder may have changed since the dry run or the last batch.
            let before: MailFound
            do { before = try await lookup(account: plan.account.id, source: plan.source, target: plan.target, ids) }
            catch { outcome.failure = Self.describe(error); outcome.notStarted = rest; break }
            var eligible: [MailMoveItem] = []
            var leftOut: [String] = []
            for entry in batch {
                let id = entry.messageID
                let here = before.here(id), there = before.there(id)
                if here.isEmpty { outcome.notFound += 1; leftOut.append(id) }
                else if here.count > 1 { outcome.skipped["duplicate", default: 0] += 1; leftOut.append(id) }
                // Only the mail the dry run found: another mail that carries the same Message-ID stays.
                else if here[0] != entry.mailID { outcome.skipped["other_mail", default: 0] += 1; leftOut.append(id) }
                else if !there.isEmpty { outcome.skipped["already_in_target", default: 0] += 1; leftOut.append(id) }
                else { eligible.append(MailMoveItem(mailID: here[0], messageID: id)) }
            }
            await drop(leftOut)
            index += 1
            guard !eligible.isEmpty else { continue }
            if let journal {
                let ids = eligible.compactMap { rows[$0.messageID] }
                do { try await journal.executor.dispatchRunActions(ids) }
                catch { outcome.failure = "journal"; outcome.notStarted = rest; break }
            }
            dispatched.formUnion(eligible.map(\.messageID))
            outcome.batches += 1
            outcome.attempted += eligible.count
            var moveError: Error?
            var reported = Set<String>()
            // A move that timed out is not a move that failed: Mail may still carry it out after Pippa stopped waiting.
            // The read-back waits for every mail of the batch, and one still in the source counts as unclear, never as
            // not moved (its row stays, so undo can still find it).
            var timedOut = false
            do {
                let statuses = try await reader.move(account: plan.account.id, from: plan.source, mails: eligible, to: plan.target)
                for (item, status) in zip(eligible, statuses) {
                    let word = status.allSatisfy({ $0.isNumber || $0 == "-" }) || ["moved", "changed", "gone"].contains(status) ? status : "other"
                    outcome.statuses[word, default: 0] += 1
                    if status == "moved" { reported.insert(item.messageID) }
                }
            } catch {
                moveError = error
                timedOut = error as? MailAccountProblem == .timeout
            }
            // The read-back belongs to the move, also after Stop: it runs outside the lease. It waits until every mail
            // Mail reported as moved is in the target; Stop ends the wait at once and what is missing then is unclear.
            let after: MailFound
            let waiting = timedOut ? Set(eligible.map(\.messageID)) : reported
            do {
                after = try await PippaMCPWriteLease.$current.withValue(nil) {
                    try await settled(account: plan.account.id, source: plan.source, target: plan.target, eligible.map(\.messageID),
                                      waitingFor: waiting, stats: &outcome.settle,
                                      stopped: { Task.isCancelled || !live() || (lease.map { (try? $0.check()) == nil } ?? false) }) { src, tgt in
                        tgt.count == 1 && src.isEmpty
                    }
                }
            } catch {
                if let journal { try? await journal.executor.unclearRunActions(eligible.compactMap { rows[$0.messageID] }, note: Self.unverifiedNote) }
                outcome.unclear += eligible.count
                outcome.unclearBatch = outcome.batches
                outcome.failure = Self.describe(moveError ?? error)
                outcome.notStarted = rest - batch.count
                break
            }
            var results: [RunActionResult] = []
            var unmoved: [String] = [], doubled: [UUID] = [], unanswered: [UUID] = [], unchecked: [UUID] = []
            var unclearHere = 0, movedHere = 0
            outcome.deleted += after.deleted(eligible.map(\.messageID))
            for item in eligible {
                let there = after.there(item.messageID), here = after.here(item.messageID)
                if there.count == 1 && here.isEmpty {
                    movedHere += 1
                    if there[0] == item.mailID { outcome.idsKept += 1 } else { outcome.idsChanged += 1 }
                    if let id = rows[item.messageID] {
                        var object = RunObject.mailMessage(kind: Self.kind, account: plan.account.id, mailbox: fromName, messageID: item.messageID)
                        object.fields["from"] = Self.encode(plan.source)
                        object.fields["to"] = Self.encode(plan.target)
                        object.fields["mailID"] = String(there[0])
                        results.append(RunActionResult(id: id, verified: true, object: object, after: ["mailbox": toName]))
                    }
                } else if !after.answered {
                    // Mail did not answer the read-back in time: not known yet. Unclear, never retried.
                    unclearHere += 1
                    outcome.noAnswer += 1
                    if let id = rows[item.messageID] { unanswered.append(id) }
                } else if after.cutShort && waiting.contains(item.messageID) {
                    // Stop ended the wait before this mail, reported moved, showed up: not known yet, never "not moved".
                    unclearHere += 1
                    outcome.notChecked += 1
                    if let id = rows[item.messageID] { unchecked.append(id) }
                } else if there.isEmpty && here.count == 1 && !timedOut {
                    unmoved.append(item.messageID)
                } else if !there.isEmpty && !here.isEmpty {
                    // Copied but not deleted (IMAP), still after the bound: in both folders. Pippa deletes neither copy.
                    unclearHere += 1
                    outcome.inBoth += 1
                    if let id = rows[item.messageID] { doubled.append(id) }
                } else {
                    unclearHere += 1
                    if let id = rows[item.messageID] { results.append(RunActionResult(id: id, verified: false)) }
                }
            }
            if let journal, !results.isEmpty { _ = try? await journal.executor.completeRunActions(results) }
            if let journal, !doubled.isEmpty { try? await journal.executor.unclearRunActions(doubled, note: Self.inBothNote) }
            if let journal, !unanswered.isEmpty { try? await journal.executor.unclearRunActions(unanswered, note: Self.noAnswerNote) }
            if let journal, !unchecked.isEmpty { try? await journal.executor.unclearRunActions(unchecked, note: Self.unverifiedNote) }
            if after.cutShort { outcome.stopped = true }
            await drop(unmoved)
            outcome.verified += movedHere
            outcome.notMoved += unmoved.count
            if unclearHere > 0 {
                outcome.unclear += unclearHere
                outcome.unclearBatch = outcome.batches
                if let moveError { outcome.failure = Self.describe(moveError) }
                outcome.notStarted = rest - batch.count
                break
            }
            // Mail refused the whole batch (access, timeout): nothing changed, and the next batch would fail the same way.
            if let moveError, movedHere == 0 {
                outcome.failure = Self.describe(moveError)
                if moveError is CancellationError { outcome.stopped = true }
                outcome.notStarted = rest - batch.count
                break
            }
            await afterBatch?(outcome.batches)
        }
        // Batches that never started leave no rows.
        await drop(rows.keys.filter { !dispatched.contains($0) })
        return outcome
    }

    /// The journal's note on a row whose mail is live in both folders.
    public static let inBothNote = "in_both"
    /// The journal's note on a move row whose read-back Mail did not answer in time: where the mail is, is not known.
    public static let noAnswerNote = "no_answer"
    /// The same for a row whose move back (Undo) Mail did not confirm in time.
    public static let undoNoAnswerNote = "undo_no_answer"
    /// A move row whose read-back ended before it was checked (Stop, an error): where the mail is, is not known.
    public static let unverifiedNote = "unverified"

    private func lookup(account: String, source: [String], target: [String], _ ids: [String], eventTimeout: Int? = nil) async throws -> MailFound {
        guard !ids.isEmpty else { return MailFound(src: [:], tgt: [:]) }
        func one(_ path: [String]) async throws -> [String: MailLocated] {
            if let eventTimeout { return try await reader.locate(account: account, path: path, messageIDs: ids, eventTimeout: eventTimeout) }
            return try await reader.locate(account: account, path: path, messageIDs: ids)
        }
        let src = try await one(source)
        let tgt = try await one(target)
        return MailFound(src: src, tgt: tgt)
    }

    /// Looks `ids` up in source and target until every id of `waitingFor` is `arrived`, the bound passed or `stopped`.
    /// The last lookup is the answer; whatever has not arrived is for the caller to judge (unclear, left, failed). A
    /// lookup Mail does not answer within `lookupEventTimeout` counts as one poll and the wait goes on, then up to
    /// `boundAfterTimeout`; when the last poll was not answered the result says so (`MailFound.answered`).
    func settled(account: String, source: [String], target: [String], _ ids: [String], waitingFor: Set<String>,
                 stats: inout MailMoveSettleStats, stopped: () -> Bool = { false },
                 arrived: ([Int], [Int]) -> Bool) async throws -> MailFound {
        let start = settle.now()
        var waited = MailMoveSettleStats()
        defer {
            let d = settle.now() - start
            waited.waitedMs = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
            waited.longestMs = waited.waitedMs
            stats.add(waited)
        }
        func done(_ r: MailFound) -> Bool {
            r.answered && waitingFor.allSatisfy { arrived(r.here($0), r.there($0)) }
        }
        var result = MailFound(src: [:], tgt: [:], answered: false)
        func poll() async throws {
            waited.lookups += 1
            do { result = try await lookup(account: account, source: source, target: target, ids, eventTimeout: MailMoveSettle.lookupEventTimeout) }
            catch MailAccountProblem.timeout { waited.timeouts += 1; result.answered = false }
        }
        try await poll()
        while !done(result) {
            if stopped() { result.cutShort = true; break }
            let elapsed = settle.now() - start
            let bound = waited.timeouts > 0 ? MailMoveSettle.boundAfterTimeout : MailMoveSettle.bound
            guard elapsed < bound else { break }
            await settle.sleep(min(MailMoveSettle.interval, bound - elapsed))
            if stopped() { result.cutShort = true; break }
            try await poll()
        }
        return result
    }

    // MARK: Undo

    /// Puts the moved mails of one run back, `rows` in undo order (newest first). Consecutive rows of one account and
    /// folder pair go together, up to `batchSize`: one settled lookup, one move, one settled read-back per batch. A mail
    /// goes back only when its Message-ID is exactly once in the target folder and not in the source; anything else
    /// stays and counts as left (`changed`). A row the move left unclear is looked up again: in the target it goes back
    /// like the others, in the source it was never moved (`nothing`). Live in both folders, before or after the move
    /// back, is `inBoth`: nothing more is moved and nothing deleted. A row an earlier Undo left unclear because Mail did
    /// not answer (`undoNoAnswerNote`) and that is now in the source only is `undone`. Mail not answering the lookups in
    /// time after the move back, or the move back timing out, is `unclear`: nothing is retried. Mail not answering the
    /// lookup before the move back is `unanswered`: nothing moved, the row stays as it was. Only unclear rows wait for
    /// Mail to settle before the move back; a done row's mail not in the target is left at once. `failed`
    /// only when Mail returned an error for the move back, or the mail is in neither folder afterwards. Only live
    /// messages count; `deleted` counts the mails whose lookups also found entries marked deleted.
    public func undo(_ rows: [RunAction]) async -> (outcomes: [UUID: RunUndoOutcome], settle: MailMoveSettleStats, deleted: Int) {
        var outcomes: [UUID: RunUndoOutcome] = [:]
        var stats = MailMoveSettleStats()
        var deleted = 0
        struct Pair: Equatable { var account: String, from: [String], to: [String] }
        var batches: [(pair: Pair, rows: [(row: RunAction, id: String)])] = []
        for row in rows {
            guard let account = row.object.fields["account"], let id = row.object.fields["messageID"],
                  let from = row.object.fields["from"].flatMap(Self.decode), let to = row.object.fields["to"].flatMap(Self.decode) else {
                outcomes[row.id] = .failed; continue
            }
            let pair = Pair(account: account, from: from, to: to)
            if let last = batches.last, last.pair == pair, last.rows.count < Self.batchSize, !last.rows.contains(where: { $0.id == id }) {
                batches[batches.count - 1].rows.append((row, id))
            } else {
                batches.append((pair, [(row, id)]))
            }
        }
        for (pair, batch) in batches {
            let ids = batch.map(\.id)
            var sent = false
            do {
                // A done row was seen in the target; an unclear one may not show there yet: wait until it is in one folder only.
                let unsettled = Set(batch.filter { $0.row.state == .unclear }.map(\.id))
                let before = try await settled(account: pair.account, source: pair.from, target: pair.to, ids, waitingFor: unsettled, stats: &stats) { src, tgt in
                    (tgt.count == 1 && src.isEmpty) || (src.count == 1 && tgt.isEmpty)
                }
                // Mail did not say where they are: nothing moves back on an old answer, and every row stays as it was.
                guard before.answered else {
                    for (row, _) in batch { outcomes[row.id] = .unanswered }
                    continue
                }
                var eligible: [(row: RunAction, item: MailMoveItem)] = []
                for (row, id) in batch {
                    let there = before.there(id), here = before.here(id)
                    if there.count == 1 && here.isEmpty { eligible.append((row, MailMoveItem(mailID: there[0], messageID: id))) }
                    else if row.state == .unclear && here.count == 1 && there.isEmpty {
                        outcomes[row.id] = row.note == Self.undoNoAnswerNote ? .undone : .nothing
                    }
                    else if !here.isEmpty && !there.isEmpty { outcomes[row.id] = .inBoth }
                    else { outcomes[row.id] = .changed }
                }
                guard !eligible.isEmpty else { deleted += before.deleted(ids); continue }
                var errors = Set<String>(), reported = Set<String>()
                // As in `apply`: a move back that timed out may still be carried out; the read-back waits for all.
                var timedOut = false
                sent = true
                do {
                    let statuses = try await reader.move(account: pair.account, from: pair.to, mails: eligible.map(\.item), to: pair.from)
                    for (entry, status) in zip(eligible, statuses) {
                        if status == "moved" { reported.insert(entry.item.messageID) }
                        else if status.allSatisfy({ $0.isNumber || $0 == "-" }) { errors.insert(entry.item.messageID) }
                    }
                } catch MailAccountProblem.timeout {
                    timedOut = true
                } catch {
                    errors.formUnion(eligible.map(\.item.messageID))
                }
                let after = try await settled(account: pair.account, source: pair.from, target: pair.to, eligible.map(\.item.messageID),
                                              waitingFor: timedOut ? Set(eligible.map(\.item.messageID)) : reported, stats: &stats) { src, tgt in
                    src.count == 1 && tgt.isEmpty
                }
                deleted += after.deleted(ids)
                for (row, item) in eligible {
                    let back = after.here(item.messageID), still = after.there(item.messageID)
                    if back.count == 1 && still.isEmpty { outcomes[row.id] = .undone }
                    // Mail did not answer the read-back in time: not known yet, never failed.
                    else if !after.answered { outcomes[row.id] = .unclear }
                    // Copied back but not deleted from the target after the bound: Pippa deletes neither copy.
                    else if !back.isEmpty && !still.isEmpty { outcomes[row.id] = .inBoth }
                    else if timedOut { outcomes[row.id] = .unclear }
                    // Mail did not move it and said no error: it stays in the target, as it was.
                    else if still.count == 1 && back.isEmpty && !errors.contains(item.messageID) { outcomes[row.id] = .changed }
                    else { outcomes[row.id] = .failed }
                }
            } catch MailMoveProblem.noFolder where !sent {
                // A folder is gone before anything moved back: the mails stay where they are.
                for (row, _) in batch where outcomes[row.id] == nil { outcomes[row.id] = .changed }
            } catch {
                for (row, _) in batch where outcomes[row.id] == nil { outcomes[row.id] = .failed }
            }
        }
        return (outcomes, stats, deleted)
    }

    // MARK: Later look

    /// What one more look at an unclear row found (`recheck`).
    public enum Recheck: Sendable, Equatable {
        /// The move happened: live once in the target and not in the source; `mailID` is Mail's id there now.
        case moved(mailID: Int)
        /// The move did not happen: live once in the source, not in the target.
        case notMoved
        /// The move back (an Undo Mail did not confirm in time) happened: live once in the source only.
        case undone
        /// The move back did not happen: live once in the target only, as after the move.
        case notUndone
    }

    /// One more look at a run's unclear mail rows, later and without anyone asking: one lookup per folder pair (source
    /// and target once, with `lookupEventTimeout`), no settling and never a move. A row whose mail is not live in exactly
    /// one of the two folders, or that Mail did not answer for, gets no entry and stays unclear.
    public func recheck(_ rows: [RunAction]) async -> [UUID: Recheck] {
        struct Pair: Hashable { var account: String, from: [String], to: [String] }
        var groups: [Pair: [(row: RunAction, id: String)]] = [:]
        var order: [Pair] = []
        for row in rows where row.state == .unclear && row.object.kind == Self.kind {
            guard let account = row.object.fields["account"], let id = row.object.fields["messageID"],
                  let from = row.object.fields["from"].flatMap(Self.decode), let to = row.object.fields["to"].flatMap(Self.decode) else { continue }
            let pair = Pair(account: account, from: from, to: to)
            if groups[pair] == nil { order.append(pair) }
            groups[pair, default: []].append((row, id))
        }
        var out: [UUID: Recheck] = [:]
        for pair in order {
            let members = groups[pair] ?? []
            let ids = Array(Set(members.map(\.id))).sorted()
            guard let found = try? await lookup(account: pair.account, source: pair.from, target: pair.to, ids,
                                                eventTimeout: MailMoveSettle.lookupEventTimeout) else { continue }
            for (row, id) in members {
                let here = found.here(id), there = found.there(id)
                let back = row.note == Self.undoNoAnswerNote
                if there.count == 1 && here.isEmpty { out[row.id] = back ? .notUndone : .moved(mailID: there[0]) }
                else if here.count == 1 && there.isEmpty { out[row.id] = back ? .undone : .notMoved }
            }
        }
        return out
    }

    // MARK: Helpers

    static func encode(_ path: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(path)) ?? Data("[]".utf8), as: UTF8.self)
    }
    static func decode(_ text: String) -> [String]? {
        guard let path = try? JSONDecoder().decode([String].self, from: Data(text.utf8)), !path.isEmpty else { return nil }
        return path
    }

    /// A short reason without anything from the mails: the error's kind only.
    static func describe(_ error: Error) -> String {
        switch error {
        case PippaError.accessDenied: "denied"
        case PippaError.appNotOpen: "not_open"
        case MailAccountProblem.timeout: "timeout"
        case MailMoveProblem.noFolder: "no_folder"
        case is CancellationError: "stopped"
        default: "failed"
        }
    }
}
