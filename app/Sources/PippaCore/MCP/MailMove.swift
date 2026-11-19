import Foundation

// Moving mail between folders of one account (docs/pippa-1.0.md "Tools in 1.0", "Journal, verification and undo for
// whole runs"). The engine is shared by `mail_move` (PippaMCPMailMove.swift) and `Pippa --mail-move-probe`: a dry run
// looks every mail up by its RFC Message-ID, the moves go in batches of 10, every mail of a batch is looked up again in
// the source and the target folder, and a mail found in neither makes the batch unclear and stops the run. Mail's own id
// is only a handle for the next Apple Event: it changes on Exchange when a mail moves.

/// One mailbox of an account, as Mail lists it.
public struct MailFolderInfo: Sendable, Equatable {
    public var path: [String]
    /// Messages in it; `nil` when Mail did not say.
    public var count: Int?
    /// What Mail uses it for, when Mail or its name says so (never a target for `mail_move`).
    public var role: MailFolderRole?
    /// Up to two mails as Mail lists them first: sender and subject only.
    public var samples: [MailFolderSample]
    public init(path: [String], count: Int?, role: MailFolderRole? = nil, samples: [MailFolderSample] = []) {
        self.path = path; self.count = count; self.role = role; self.samples = samples
    }

    /// The path the model reads and writes: names joined with "/".
    public var display: String { path.joined(separator: "/") }
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
    /// source), `already_in_target`.
    public var skipped: [String: Int]
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
    public init() {}
}

/// The engine. Checks hand it a synthetic `MailAccountReading`; the app and the probe the real Mail.
public struct MailMover: Sendable {
    public static let batchSize = 10
    /// More mails than this in one `mail_move` call need a dry run and its plan.
    public static let directLimit = 20
    public static let kind = "mail.move"

    let reader: any MailAccountReading
    public init(reader: any MailAccountReading) { self.reader = reader }

    // MARK: Dry run

    /// Every mail looked up by Message-ID in source and target. Nothing moves.
    public func plan(account: MailAccountInfo, label: String, source: [String], target: [String], messageIDs: [String?]) async throws -> MailMovePlan {
        var skipped: [String: Int] = [:]
        var wanted: [String] = []
        var seen = Set<String>()
        for raw in messageIDs {
            guard let id = raw.flatMap(MailReplySource.canonicalMessageID) else { skipped["no_message_id", default: 0] += 1; continue }
            // The same mail named twice is one mail.
            if seen.insert(id).inserted { wanted.append(id) }
        }
        let (src, tgt) = try await lookup(account: account.id, source: source, target: target, wanted)
        var entries: [MailMovePlan.Entry] = []
        var notFound = 0
        for id in wanted {
            let here = src[id] ?? [], there = tgt[id] ?? []
            if here.isEmpty { notFound += 1 }
            else if here.count > 1 { skipped["duplicate", default: 0] += 1 }
            else if !there.isEmpty { skipped["already_in_target", default: 0] += 1 }
            else { entries.append(.init(messageID: id, mailID: here[0])) }
        }
        return MailMovePlan(id: MailPageStore.token("p"), account: account, label: label, source: source, target: target,
                            entries: entries, notFound: notFound, skipped: skipped)
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
            let before: (src: [String: [Int]], tgt: [String: [Int]])
            do { before = try await lookup(account: plan.account.id, source: plan.source, target: plan.target, ids) }
            catch { outcome.failure = Self.describe(error); outcome.notStarted = rest; break }
            var eligible: [MailMoveItem] = []
            var leftOut: [String] = []
            for id in ids {
                let here = before.src[id] ?? [], there = before.tgt[id] ?? []
                if here.isEmpty { outcome.notFound += 1; leftOut.append(id) }
                else if here.count > 1 { outcome.skipped["duplicate", default: 0] += 1; leftOut.append(id) }
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
            do {
                for status in try await reader.move(account: plan.account.id, from: plan.source, mails: eligible, to: plan.target) {
                    let word = status.allSatisfy({ $0.isNumber || $0 == "-" }) || ["moved", "changed", "gone"].contains(status) ? status : "other"
                    outcome.statuses[word, default: 0] += 1
                }
            } catch { moveError = error }
            // The read-back belongs to the move, also after Stop: it runs outside the lease.
            let after: (src: [String: [Int]], tgt: [String: [Int]])
            do {
                after = try await PippaMCPWriteLease.$current.withValue(nil) {
                    try await lookup(account: plan.account.id, source: plan.source, target: plan.target, eligible.map(\.messageID))
                }
            } catch {
                if let journal { try? await journal.executor.unclearRunActions(eligible.compactMap { rows[$0.messageID] }, note: "unverified") }
                outcome.unclear += eligible.count
                outcome.unclearBatch = outcome.batches
                outcome.failure = Self.describe(moveError ?? error)
                outcome.notStarted = rest - batch.count
                break
            }
            var results: [RunActionResult] = []
            var unmoved: [String] = []
            var unclearHere = 0, movedHere = 0
            for item in eligible {
                let there = after.tgt[item.messageID] ?? [], here = after.src[item.messageID] ?? []
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
                } else if there.isEmpty && here.count == 1 {
                    unmoved.append(item.messageID)
                } else {
                    unclearHere += 1
                    if let id = rows[item.messageID] { results.append(RunActionResult(id: id, verified: false)) }
                }
            }
            if let journal, !results.isEmpty { _ = try? await journal.executor.completeRunActions(results) }
            await drop(unmoved)
            outcome.verified += movedHere
            outcome.notMoved += unmoved.count
            if unclearHere > 0 {
                outcome.unclear += unclearHere
                outcome.unclearBatch = outcome.batches
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

    private func lookup(account: String, source: [String], target: [String], _ ids: [String]) async throws -> (src: [String: [Int]], tgt: [String: [Int]]) {
        guard !ids.isEmpty else { return ([:], [:]) }
        let src = try await reader.locate(account: account, path: source, messageIDs: ids)
        let tgt = try await reader.locate(account: account, path: target, messageIDs: ids)
        return (src, tgt)
    }

    // MARK: Undo

    /// Puts one moved mail back: only when its Message-ID is exactly once in the target folder and not in the source;
    /// anything else stays and counts as left. Checked by Message-ID afterwards.
    public static func undo(_ row: RunAction, reader: any MailAccountReading) async -> RunUndoOutcome {
        guard let account = row.object.fields["account"], let id = row.object.fields["messageID"],
              let from = row.object.fields["from"].flatMap(decode), let to = row.object.fields["to"].flatMap(decode) else { return .failed }
        do {
            let there = try await reader.locate(account: account, path: to, messageIDs: [id])[id] ?? []
            let here = try await reader.locate(account: account, path: from, messageIDs: [id])[id] ?? []
            guard there.count == 1, here.isEmpty else { return .changed }
            try? await reader.move(account: account, from: to, mails: [MailMoveItem(mailID: there[0], messageID: id)], to: from)
            let back = try await reader.locate(account: account, path: from, messageIDs: [id])[id] ?? []
            let still = try await reader.locate(account: account, path: to, messageIDs: [id])[id] ?? []
            return back.count == 1 && still.isEmpty ? .undone : .failed
        } catch MailMoveProblem.noFolder {
            return .changed
        } catch {
            return .failed
        }
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
