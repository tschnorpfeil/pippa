import Foundation

/// What the probe needs beyond `mail_move`'s reader: the account kinds, a test folder, copies of inbox mails.
public protocol MailMoveProbeMail: MailAccountReading {
    func accountKinds() async throws -> [MailMoveProbe.AccountKind]
    /// A top-level folder with this name; `true` when it was made now, `false` when it was there.
    func makeFolder(account: String, name: String) async throws -> Bool
    /// The Message-ID of every mail in `path`, one of the two test folders only (an earlier run's copies).
    func messageIDs(account: String, path: [String]) async throws -> [String]
    /// Copies of these inbox mails into `to`; the inbox stays as it is. One status per mail (diagnostics only).
    func duplicate(account: String, inboxIDs: [Int], to: [String]) async throws -> [String]
}

extension SystemIntegrations {
    /// The real Mail for `Pippa --mail-move-probe` only.
    public var mailMoveProbe: any MailMoveProbeMail { MailAccountScript.Live() }
}

/// Developer diagnostic before `mail_move` meets real accounts (docs/pippa-1.0.md, "Open: how Mail moves behave per
/// account type"): `Pippa --mail-move-probe --account <name>`. It touches only two folders, "Pippa Test A" and "Pippa Test
/// B". Whatever is in them is a test copy of an earlier run: copies left in B go back to A first, and the copies in A are
/// used again; only an empty A gets up to 20 copies of the inbox's oldest mails (copies, never moves). It moves the copies
/// A → B through `MailMover` (dry run, plan, batches, settled check by Message-ID), undoes the run and checks they are
/// back in A. It prints one JSON object of counts, kinds, timings and settle waits: never subjects, senders, addresses,
/// account names or Message-IDs.
public enum MailMoveProbe {
    public static let folderA = "Pippa Test A"
    public static let folderB = "Pippa Test B"
    public static let copies = 20

    public static let usage = """
        usage: Pippa --mail-move-probe [--account <name>]
          Without --account: lists Mail's accounts with their types and exits.
          With --account: uses only the folders "\(folderA)" and "\(folderB)" of that account (made if missing). Everything
          in them counts as a test copy from an earlier run: mail in "\(folderB)" goes back to "\(folderA)" first, and the
          mails in "\(folderA)" are used again. Only when "\(folderA)" is empty, up to \(copies) of the inbox's oldest mails
          are copied into it (the inbox stays untouched). Moves the copies to "\(folderB)" as mail_move does, undoes the
          move and checks they are back in "\(folderA)". Prints one JSON report without subjects, senders, addresses or
          Message-IDs, with lookups and milliseconds waited for Mail to settle per step. The copies stay in "\(folderA)"
          for the next run; never put other mail into the two test folders.
        """

    public struct AccountKind: Sendable, Equatable {
        public var id: String, name: String, type: String, className: String
        public init(id: String, name: String, type: String, className: String) { self.id = id; self.name = name; self.type = type; self.className = className }
    }

    public enum Invocation: Equatable, Sendable { case help, list, run(account: String) }

    public struct UsageError: Error, Equatable, Sendable { public let message: String }

    /// Strict: a missing, repeated or unknown argument is an error, before Mail is asked anything.
    public static func parse(_ arguments: [String]) throws -> Invocation {
        var account: String?
        var sawCommand = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h": return .help
            case "--mail-move-probe":
                guard !sawCommand else { throw UsageError(message: "--mail-move-probe given twice.") }
                sawCommand = true
            case "--account":
                guard account == nil else { throw UsageError(message: "--account given twice.") }
                guard let value = rest.popFirst(), !value.hasPrefix("--"), !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw UsageError(message: "--account needs an account name.")
                }
                account = value
            default: throw UsageError(message: "Unknown argument.")
            }
        }
        guard sawCommand else { throw UsageError(message: "Missing --mail-move-probe.") }
        return account.map { .run(account: $0) } ?? .list
    }

    /// `mail` is only made after the arguments parsed. `pause` waits between read-backs while Mail settles copies.
    public static func execute(_ arguments: [String], mail: () -> any MailMoveProbeMail, journalDirectory: URL? = nil,
                               pause: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) },
                               settle: MailMoveSettle = .live) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let invocation: Invocation
        do { invocation = try parse(arguments) } catch let error as UsageError { return (2, "", error.message + "\n" + usage) }
        catch { return (2, "", usage) }
        switch invocation {
        case .help: return (0, usage, "")
        case .list:
            do {
                let kinds = try await mail().accountKinds()
                return (0, json(["probe": "mail-move-probe", "accounts": kinds.map { ["name": $0.name, "type": $0.type, "class": $0.className] }]), "")
            } catch {
                return (1, json(["probe": "mail-move-probe", "error": ["step": "accounts", "kind": MailMover.describe(error)]]), "")
            }
        case .run(let name):
            let directory = journalDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("pippa-mail-move-probe-\(UUID().uuidString)")
            defer { if journalDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
            let report = await run(account: name, mail: mail(), directory: directory, pause: pause, settle: settle)
            return (report["refused"] == nil && report["error"] == nil ? 0 : 1, json(report), "")
        }
    }

    // MARK: The run

    static func run(account name: String, mail: any MailMoveProbeMail, directory: URL, pause: @Sendable () async -> Void,
                    settle: MailMoveSettle) async -> [String: Any] {
        var report: [String: Any] = ["probe": "mail-move-probe", "folders": [folderA, folderB]]
        var timings: [String: Int] = [:]
        var counts: [String: Any] = [:]
        func finish(_ extra: [String: Any] = [:]) -> [String: Any] {
            report["timings_ms"] = timings
            report["counts"] = counts
            return report.merging(extra) { _, b in b }
        }
        func timed<T>(_ step: String, _ body: () async throws -> T) async throws -> T {
            let start = ContinuousClock.now
            defer { let d = ContinuousClock.now - start; timings[step] = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
            do { return try await body() } catch { throw ProbeFailure(step: step, error: error) }
        }
        do {
            let kinds = try await timed("accounts") { try await mail.accountKinds() }
            let matches = kinds.filter { $0.id == name || $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
            guard matches.count == 1, let kind = matches.first, !kind.id.isEmpty else {
                return finish(["refused": matches.isEmpty ? "unknown_account" : "ambiguous_account",
                               "next": "Run Pippa --mail-move-probe without --account to list the accounts."])
            }
            report["account_type"] = kind.type
            report["account_class"] = kind.className
            let account = MailAccountInfo(id: kind.id, name: kind.name)
            let a = [folderA], b = [folderB]
            // Only these two folders, made when missing. They exist for this probe alone: whatever is in them is a test
            // copy from an earlier run, and the probe uses it again instead of asking anyone to delete the folders.
            let before = try await timed("folders") { try await mail.folders(account: account.id, samples: 0) }
            var made: [String] = []
            for path in [a, b] where !before.contains(where: { $0.path == path }) {
                let newly = try await timed("make_folder") { try await mail.makeFolder(account: account.id, name: path[0]) }
                if newly { made.append(path[0]) }
            }
            counts["folders_made"] = made.count
            var ready: [MailFolderInfo] = []
            for _ in 0..<10 {
                ready = try await timed("folders") { try await mail.folders(account: account.id, samples: 0) }
                if [a, b].allSatisfy({ path in ready.contains { $0.path == path } }) { break }
                await pause()
            }
            guard let folderInA = ready.first(where: { $0.path == a }), let folderInB = ready.first(where: { $0.path == b }) else {
                return finish(["refused": "test_folders_not_ready", "next": "Mail did not show both test folders. Check them in Mail."])
            }
            let mover = MailMover(reader: mail, settle: settle)
            var settles: [String: Any] = [:]
            var reused = 0

            // An earlier run's copies left in B go back to A first, through the same move path (dry run, batches, settled
            // read-back by Message-ID).
            var resetB = false
            if folderInB.count != 0 {
                let inB = try await timed("list_b") { try await mail.messageIDs(account: account.id, path: b) }
                if !inB.isEmpty {
                    resetB = true
                    let plan = try await timed("reset_dry_run") { try await mover.plan(account: account, label: "probe", source: b, target: a, messageIDs: inB) }
                    let back = try await timed("reset_move") { try await mover.apply(plan, journal: nil) }
                    counts["reset_b_to_a"] = ["in_b": inB.count, "will_move": plan.entries.count, "not_found": plan.notFound, "skipped": plan.skipped,
                                              "verified": back.verified, "not_moved": back.notMoved, "unclear": back.unclear]
                    settles["reset_move"] = settleJSON(back.settle)
                    guard plan.entries.count == inB.count, back.verified == plan.entries.count, back.failure == nil else {
                        return finish(["refused": "test_folder_b_not_reset",
                                       "next": "Not every mail in \(folderB) went back to \(folderA). Look at both folders in Mail; nothing else was touched."])
                    }
                }
            }

            var copies: [String]
            let inA = folderInA.count != 0 || resetB ? try await timed("list_a") { try await mail.messageIDs(account: account.id, path: a) } : []
            let reusable = inA.compactMap(MailReplySource.canonicalMessageID)
            if !reusable.isEmpty {
                // Everything in A is a test copy: move what has a Message-ID that occurs once there.
                let seen = Dictionary(grouping: reusable, by: { $0 }).mapValues(\.count)
                copies = seen.filter { $0.value == 1 }.map(\.key).sorted()
                counts["copies_in_a"] = inA.count
                counts["copies_unique"] = copies.count
                reused = copies.count
                guard !copies.isEmpty else { return finish(["refused": "copies_not_found", "next": "\(folderA) holds no mail the probe can move. Nothing was moved."]) }
            } else {
                // The oldest inbox mails with a Message-ID, copied into A.
                let candidates = try await timed("inbox") { try await mail.candidates(account: account.id, query: "", readStatus: .all, mailbox: .inbox) }
                let oldest = candidates.sorted { ($0.date ?? .distantFuture, $0.id) < ($1.date ?? .distantFuture, $1.id) }.prefix(Self.copies).map(\.id)
                let rows = try await timed("inbox_rows") { try await mail.rows(account: account.id, ids: Array(oldest)) }
                var picked: [(id: Int, messageID: String)] = []
                for row in rows { if let id = row.header.messageID.flatMap(MailReplySource.canonicalMessageID) { picked.append((row.id, id)) } }
                counts["inbox_mails"] = candidates.count
                counts["picked"] = picked.count
                counts["picked_without_message_id"] = rows.count - picked.count
                guard !picked.isEmpty else { return finish(["refused": "no_inbox_mail", "next": "The inbox has no mail with a Message-ID to copy."]) }
                let copyStatuses = try await timed("duplicate") { try await mail.duplicate(account: account.id, inboxIDs: picked.map(\.id), to: a) }
                counts["duplicate_statuses"] = tally(copyStatuses)
                let wanted = Array(Set(picked.map(\.messageID))).sorted()
                var located: [String: [Int]] = [:]
                var settled = false
                for _ in 0..<10 {
                    located = try await timed("locate_copies") { try await mail.locate(account: account.id, path: a, messageIDs: wanted) }
                    let found = located.values.reduce(0) { $0 + $1.count }
                    let folder = try await timed("folders") { try await mail.folders(account: account.id, samples: 0) }.first { $0.path == a }
                    // A was empty: everything in it now must be one of the copies made now.
                    if let total = folder?.count, total > found { return finish(["refused": "test_folder_has_other_mail", "next": "\(folderA) holds mail the probe did not copy. Nothing was moved."]) }
                    if found >= copyStatuses.filter({ $0 == "copied" }).count, folder?.count == found { settled = true; break }
                    await pause()
                }
                copies = wanted.filter { (located[$0] ?? []).count == 1 }
                counts["copies_in_a"] = located.values.reduce(0) { $0 + $1.count }
                counts["copies_unique"] = copies.count
                guard settled, !copies.isEmpty else { return finish(["refused": "copies_not_found", "next": "Mail did not show the copies in \(folderA). Nothing was moved."]) }
            }
            report["reused_copies"] = reused

            // The same path as mail_move: dry run, plan, batches, read-back by Message-ID.
            let owner = UUID()
            let store = MailPageStore()
            _ = store.claim(owner, live: { true })
            let plan = try await timed("dry_run") {
                try await mover.plan(account: account, label: "probe", source: a, target: b, messageIDs: copies)
            }
            counts["dry_run"] = ["will_move": plan.entries.count, "not_found": plan.notFound, "skipped": plan.skipped]
            guard store.savePlan(plan, turn: owner), let applied = store.takePlan(plan.id, turn: owner), store.takePlan(plan.id, turn: owner) == nil else {
                return finish(["error": ["step": "plan", "kind": "failed"]])
            }
            let journal = try Executor(baseDirectory: directory)
            let runID = UUID()
            let scope = PippaMCPWriteScope(turnID: runID)
            let lease = scope.lease(action: "mailMove")
            let outcome = try await timed("move") {
                try await PippaMCPWriteLease.$current.withValue(lease) {
                    try await mover.apply(applied, journal: .init(executor: journal, run: runID))
                }
            }
            _ = lease.finish(nil)
            counts["move"] = ["batches": outcome.batches, "attempted": outcome.attempted, "verified": outcome.verified, "not_moved": outcome.notMoved,
                              "not_found": outcome.notFound, "skipped": outcome.skipped, "unclear": outcome.unclear, "not_started": outcome.notStarted]
            settles["move"] = settleJSON(outcome.settle)
            report["verified"] = "\(outcome.verified) of \(outcome.attempted)"
            report["mail_ids_changed"] = outcome.idsChanged == 0 ? "no" : outcome.idsKept == 0 ? "yes" : "some"
            counts["mail_ids"] = ["kept": outcome.idsKept, "changed": outcome.idsChanged]
            if let failure = outcome.failure { report["move_error"] = failure }
            if !outcome.statuses.isEmpty { counts["move_statuses"] = outcome.statuses }
            let rowsAfter = try await journal.runActions(run: runID)
            counts["journal_rows"] = tally(rowsAfter.map(\.state.rawValue))

            // Undo as the receipt does it: mail moves go back in batches, unclear rows are looked at once more.
            let undoSettle = SettleTally()
            let batch: @Sendable (String) -> RunUndoBatchRecipe? = { kind in
                guard kind == MailMover.kind else { return nil }
                return { rows in
                    let result = await mover.undo(rows)
                    undoSettle.add(result.settle)
                    return result.outcomes
                }
            }
            let undo = try await timed("undo") { try await journal.undoRun(runID, recipe: { _ in nil }, batch: batch) }
            counts["undo"] = ["undone": undo.undone.count, "left": undo.left.count, "failed": undo.failed.count]
            settles["undo"] = settleJSON(undoSettle.value)
            let backA = try await timed("verify_back") { try await mail.locate(account: account.id, path: a, messageIDs: copies) }
            let stillB = try await timed("verify_back") { try await mail.locate(account: account.id, path: b, messageIDs: copies) }
            counts["back_in_a"] = copies.filter { (backA[$0] ?? []).count == 1 && (stillB[$0] ?? []).isEmpty }.count
            counts["left_in_b"] = stillB.values.reduce(0) { $0 + $1.count }
            let again = try await journal.undoRun(runID, recipe: { _ in nil }, batch: batch)
            counts["second_undo_steps"] = again.undone.count + again.left.count + again.failed.count
            report["settle"] = settles
            report["cleanup"] = "The copies stay in \(folderA); the next run uses them again."
            return finish()
        } catch let failure as ProbeFailure {
            return finish(["error": ["step": failure.step, "kind": MailMover.describe(failure.error)]])
        } catch {
            return finish(["error": ["step": "journal", "kind": MailMover.describe(error)]])
        }
    }

    struct ProbeFailure: Error { var step: String; var error: Error }

    /// Lookups (polls) and milliseconds the read-backs waited for Mail to settle in one step.
    static func settleJSON(_ s: MailMoveSettleStats) -> [String: Int] { ["lookups": s.lookups, "waited_ms": s.waitedMs, "longest_batch_ms": s.longestMs] }

    private final class SettleTally: @unchecked Sendable {
        private let lock = NSLock()
        private var stats = MailMoveSettleStats()
        func add(_ other: MailMoveSettleStats) { lock.withLock { stats.add(other) } }
        var value: MailMoveSettleStats { lock.withLock { stats } }
    }

    /// Status words and Mail's error numbers, counted. Never a mail's content.
    static func tally(_ values: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for value in values { out[value.allSatisfy { $0.isNumber || $0 == "-" } || ["moved", "copied", "gone", "changed", "done", "unclear", "undone", "dispatched", "planned", "undo_failed"].contains(value) ? value : "other", default: 0] += 1 }
        return out
    }

    static func json(_ value: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data("{}".utf8), as: UTF8.self)
    }
}
