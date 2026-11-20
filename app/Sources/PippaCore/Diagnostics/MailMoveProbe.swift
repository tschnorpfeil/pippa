import Foundation

// A developer probe: compiled only into debug builds and builds with `PIPPA_PROBES` (scripts/build-app.sh), never shipped.
#if DEBUG || PIPPA_PROBES

/// What the probe needs beyond `mail_move`'s reader: the account kinds, a test folder, copies of inbox mails.
public protocol MailMoveProbeMail: MailAccountReading {
    func accountKinds() async throws -> [MailMoveProbe.AccountKind]
    /// The two test folders only, each by its exact top-level path, with their message counts. Never lists the
    /// account's other mailboxes.
    func testFolders(account: String) async throws -> [MailMoveProbe.TestFolder]
    /// `--diagnose`: the listing `mail_folders` uses, timed, as numbers only. Reads, never changes anything.
    func folderTimings(account: String, samples: Int) async throws -> MailMoveProbe.ListingTimings
    /// A top-level folder with this name; `true` when it was made now, `false` when it was there.
    func makeFolder(account: String, name: String) async throws -> Bool
    /// The Message-ID and deleted status of every mail in `path`, one of the two test folders only (an earlier run's copies).
    func messageIDs(account: String, path: [String]) async throws -> [MailMoveProbe.Listed]
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
/// back in A. It never lists the account's other mailboxes: the two folders are asked for by exact path. It prints one
/// JSON object of counts, kinds, timings and settle waits, and on a timeout which kind of Apple event did not answer:
/// never subjects, senders, addresses, account names, folder names other than its own, or Message-IDs.
/// `--diagnose` only times read-only questions (the test folders, the listing behind `mail_folders`) and changes nothing.
/// Only live messages count as in a folder; entries marked deleted (IMAP, not yet expunged) are counted apart. A mail
/// live in both test folders ("in_both") is reported and left alone: the probe never deletes mail.
public enum MailMoveProbe {
    public static let folderA = "Pippa Test A"
    public static let folderB = "Pippa Test B"
    public static let copies = 20
    /// Seconds the probe waits before it reads both test folders a last time (`--recheck`). The iCloud probe of
    /// November 2026 saw Mail answer for a test folder again about a minute after the moves.
    public static let recheckDefault = 45

    public static let usage = """
        usage: Pippa --mail-move-probe [--account <name> [--diagnose | --recheck <seconds>]]
          Without --account: lists Mail's accounts with their types and exits.
          With --account and --diagnose: changes nothing in Mail. Times only read-only questions: finding and counting
          "\(folderA)" and "\(folderB)" and listing their Message-IDs, and the folder listing mail_folders uses (how many
          mailboxes, how many Apple events timed out and of which kind, the slowest mailbox, the total). Numbers only,
          no names. Each Apple event about one mailbox may take \(MailFolderListing.eventTimeout) s.
          With --account: uses only the folders "\(folderA)" and "\(folderB)" of that account (made if missing). Everything
          in them counts as a test copy from an earlier run: mail in "\(folderB)" goes back to "\(folderA)" first, and the
          mails in "\(folderA)" are used again. Only when "\(folderA)" is empty, up to \(copies) of the inbox's oldest mails
          are copied into it (the inbox stays untouched). Moves the copies to "\(folderB)" as mail_move does, undoes the
          move and checks they are back in "\(folderA)". Entries Mail marked deleted count as gone; a mail in both folders
          is reported (in_both) and left alone, never deleted. Prints one JSON report without subjects, senders, addresses or
          Message-IDs, with lookups and milliseconds waited for Mail to settle per step. The copies stay in "\(folderA)"
          for the next run; never put other mail into the two test folders. On a timeout, the report names the step
          and the kind of Apple event that did not answer (resolve, count, list_ids, duplicate, move, locate). A lookup
          Mail does not answer within \(MailMoveSettle.lookupEventTimeout) s counts as one poll of the wait (timeouts per
          step). At the end the probe waits --recheck seconds (default \(recheckDefault)) and reads both test folders once
          more: "result" is as_intended (every copy live in "\(folderA)", none live in "\(folderB)"), not_as_intended or
          unknown, and the exit code is 0 when it is as_intended, even if earlier steps were unclear.
        """

    /// One message of a test folder: its Message-ID and whether Mail marked it deleted (not yet expunged).
    public struct Listed: Sendable, Equatable {
        public var messageID: String, deleted: Bool
        public init(messageID: String, deleted: Bool = false) { self.messageID = messageID; self.deleted = deleted }
    }

    /// The live Message-IDs of a listing, canonical.
    static func live(_ listed: [Listed]) -> [String] { listed.filter { !$0.deleted }.compactMap { MailReplySource.canonicalMessageID($0.messageID) } }

    /// The first, read-only question of every mode: asked once more after `pause` when it times out (Mail sometimes
    /// does not answer the first Apple event of a launch). Never used for a mutating event.
    static func firstAccounts(_ mail: any MailMoveProbeMail, pause: @Sendable () async -> Void, retried: () -> Void) async throws -> [AccountKind] {
        try await firstAccounts(mail.accountKinds, pause: pause, retried: retried)
    }

    /// As above, for any probe that can list the account kinds (`MailSortProbe`).
    static func firstAccounts(_ ask: () async throws -> [AccountKind], pause: @Sendable () async -> Void, retried: () -> Void) async throws -> [AccountKind] {
        do { return try await ask() } catch MailAccountProblem.timeout {
            retried()
            await pause()
            return try await ask()
        }
    }

    public struct AccountKind: Sendable, Equatable {
        public var id: String, name: String, type: String, className: String
        public init(id: String, name: String, type: String, className: String) { self.id = id; self.name = name; self.type = type; self.className = className }
    }

    /// One test folder: `count` when Mail answered, `exists` false when it is not there, `timedOut` the Apple event that
    /// did not answer ("resolve" or "count").
    public struct TestFolder: Sendable, Equatable {
        public var path: [String], count: Int?, exists: Bool, timedOut: String?
        public init(path: [String], count: Int?, exists: Bool = true, timedOut: String? = nil) {
            self.path = path; self.count = count; self.exists = exists; self.timedOut = timedOut
        }
    }

    /// `--diagnose`: the folder listing in numbers. `timeouts` per kind of Apple event: path, count, sample, subfolders.
    public struct ListingTimings: Sendable, Equatable {
        public var asked: Int, listed: Int, unnamed: Int, unexpanded: Int
        public var timeouts: [String: Int]
        public var slowestMs: Int, totalMs: Int
        public var countBoundReached: Bool, pathBoundReached: Bool
        public init(asked: Int, listed: Int, unnamed: Int, unexpanded: Int, timeouts: [String: Int], slowestMs: Int, totalMs: Int,
                    countBoundReached: Bool, pathBoundReached: Bool) {
            self.asked = asked; self.listed = listed; self.unnamed = unnamed; self.unexpanded = unexpanded; self.timeouts = timeouts
            self.slowestMs = slowestMs; self.totalMs = totalMs; self.countBoundReached = countBoundReached; self.pathBoundReached = pathBoundReached
        }
    }

    public enum Invocation: Equatable, Sendable { case help, list, run(account: String, recheck: Int), diagnose(account: String) }

    public struct UsageError: Error, Equatable, Sendable { public let message: String }

    /// Strict: a missing, repeated or unknown argument is an error, before Mail is asked anything.
    public static func parse(_ arguments: [String]) throws -> Invocation {
        var account: String?
        var recheck: Int?
        var sawCommand = false, diagnose = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h": return .help
            case "--mail-move-probe":
                guard !sawCommand else { throw UsageError(message: "--mail-move-probe given twice.") }
                sawCommand = true
            case "--diagnose":
                guard !diagnose else { throw UsageError(message: "--diagnose given twice.") }
                diagnose = true
            case "--account":
                guard account == nil else { throw UsageError(message: "--account given twice.") }
                guard let value = rest.popFirst(), !value.hasPrefix("--"), !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw UsageError(message: "--account needs an account name.")
                }
                account = value
            case "--recheck":
                guard recheck == nil else { throw UsageError(message: "--recheck given twice.") }
                guard let value = rest.popFirst(), let seconds = Int(value), (0...600).contains(seconds) else {
                    throw UsageError(message: "--recheck needs seconds from 0 to 600.")
                }
                recheck = seconds
            default: throw UsageError(message: "Unknown argument.")
            }
        }
        guard sawCommand else { throw UsageError(message: "Missing --mail-move-probe.") }
        guard let account else {
            if diagnose { throw UsageError(message: "--diagnose needs --account.") }
            if recheck != nil { throw UsageError(message: "--recheck needs --account.") }
            return .list
        }
        if diagnose, recheck != nil { throw UsageError(message: "--recheck does not go with --diagnose.") }
        return diagnose ? .diagnose(account: account) : .run(account: account, recheck: recheck ?? recheckDefault)
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
            var retries = 0
            do {
                let kinds = try await firstAccounts(mail(), pause: pause) { retries += 1 }
                return (0, json(["probe": "mail-move-probe", "first_event_retries": retries,
                                 "accounts": kinds.map { ["name": $0.name, "type": $0.type, "class": $0.className] }]), "")
            } catch {
                return (1, json(["probe": "mail-move-probe", "first_event_retries": retries, "error": ["step": "accounts", "kind": MailMover.describe(error)]]), "")
            }
        case .run(let name, let recheck):
            let directory = journalDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("pippa-mail-move-probe-\(UUID().uuidString)")
            defer { if journalDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
            let report = await run(account: name, mail: mail(), directory: directory, pause: pause, settle: settle, recheck: recheck)
            // The final state decides once the probe got that far; earlier unclear steps do not.
            let code: Int32 = if let result = report["result"] as? String { result == "as_intended" ? 0 : 1 }
                else { report["refused"] == nil && report["error"] == nil ? 0 : 1 }
            return (code, json(report), "")
        case .diagnose(let name):
            let report = await diagnose(account: name, mail: mail(), pause: pause)
            return (report["refused"] == nil && report["error"] == nil ? 0 : 1, json(report), "")
        }
    }

    // MARK: --diagnose

    /// Read-only questions, each timed; one that fails is reported and the next is still asked.
    static func diagnose(account name: String, mail: any MailMoveProbeMail, pause: @Sendable () async -> Void) async -> [String: Any] {
        var report: [String: Any] = ["probe": "mail-move-probe", "mode": "diagnose", "folders": [folderA, folderB],
                                     "event_timeout_s": MailFolderListing.eventTimeout, "count_bound_s": MailFolderListing.countBound,
                                     "path_bound_s": MailFolderListing.pathBound]
        func ms(_ start: ContinuousClock.Instant) -> Int { milliseconds(ContinuousClock.now - start) }
        var start = ContinuousClock.now
        let kinds: [AccountKind]
        var retries = 0
        do { kinds = try await firstAccounts(mail, pause: pause) { retries += 1 } } catch {
            report["first_event_retries"] = retries
            return report.merging(["error": ["step": "accounts", "kind": MailMover.describe(error), "ms": ms(start)]]) { _, b in b }
        }
        report["first_event_retries"] = retries
        report["accounts_ms"] = ms(start)
        let matches = kinds.filter { $0.id == name || $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        guard matches.count == 1, let kind = matches.first, !kind.id.isEmpty else {
            return report.merging(["refused": matches.isEmpty ? "unknown_account" : "ambiguous_account",
                                   "next": "Run Pippa --mail-move-probe without --account to list the accounts."]) { _, b in b }
        }
        report["account_type"] = kind.type
        report["account_class"] = kind.className
        var tests: [String: Any] = [:]
        start = ContinuousClock.now
        do {
            let found = try await mail.testFolders(account: kind.id)
            tests["resolve_and_count_ms"] = ms(start)
            var liveIn: [Set<String>] = []
            for folder in found {
                var entry: [String: Any] = ["exists": folder.exists]
                if let count = folder.count { entry["messages"] = count }
                if let event = folder.timedOut { entry["timeout"] = event }
                if folder.exists, folder.timedOut == nil {
                    let listStart = ContinuousClock.now
                    do {
                        let listed = try await mail.messageIDs(account: kind.id, path: folder.path)
                        let live = Self.live(listed)
                        entry["message_ids"] = listed.count
                        entry["live"] = listed.filter { !$0.deleted }.count
                        entry["deleted_status"] = listed.filter(\.deleted).count
                        entry["distinct_message_ids"] = Set(listed.compactMap { MailReplySource.canonicalMessageID($0.messageID) }).count
                        liveIn.append(Set(live))
                    }
                    catch { entry["list_ids_error"] = MailMover.describe(error) }
                    entry["list_ids_ms"] = ms(listStart)
                }
                tests[folder.path.joined(separator: "/")] = entry
            }
            // Message-IDs live in both test folders; only when both could be listed.
            if liveIn.count == 2 { tests["live_in_both"] = liveIn[0].intersection(liveIn[1]).count }
        } catch {
            tests["resolve_and_count_ms"] = ms(start)
            tests["error"] = MailMover.describe(error)
        }
        report["test_folders"] = tests
        start = ContinuousClock.now
        do {
            let t = try await mail.folderTimings(account: kind.id, samples: PippaMCPTools.folderSamples)
            report["listing"] = ["mailboxes_asked": t.asked, "folders_listed": t.listed, "not_listed": t.unnamed, "subfolders_not_listed": t.unexpanded,
                                 "timeouts": t.timeouts, "timed_out_mailboxes": t.timeouts.values.reduce(0, +),
                                 "slowest_mailbox_ms": t.slowestMs, "total_ms": t.totalMs, "call_ms": ms(start),
                                 "count_bound_reached": t.countBoundReached, "path_bound_reached": t.pathBoundReached]
        } catch {
            report["listing"] = ["error": MailMover.describe(error), "call_ms": ms(start)]
        }
        report["changed"] = "nothing"
        return report
    }

    static func milliseconds(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }

    // MARK: The run

    static func run(account name: String, mail probeMail: any MailMoveProbeMail, directory: URL, pause: @Sendable () async -> Void,
                    settle: MailMoveSettle, recheck: Int = recheckDefault) async -> [String: Any] {
        var report: [String: Any] = ["probe": "mail-move-probe", "folders": [folderA, folderB]]
        var timings: [String: Int] = [:]
        var counts: [String: Any] = [:]
        var retries = 0
        var settles: [String: Any] = [:]
        // Set once the probe picked its copies: from then on the run ends with the final read of both test folders.
        var intended: (account: String, copies: [String])?
        func finish(_ extra: [String: Any] = [:]) -> [String: Any] {
            report["timings_ms"] = timings
            report["counts"] = counts
            report["first_event_retries"] = retries
            return report.merging(extra) { _, b in b }
        }
        let witness = TimeoutWitness(probeMail)
        let mail: any MailMoveProbeMail = witness
        func timed<T>(_ step: String, _ body: () async throws -> T) async throws -> T {
            let start = ContinuousClock.now
            defer { timings[step] = milliseconds(ContinuousClock.now - start) }
            witness.clear()
            do { return try await body() } catch { throw ProbeFailure(step: step, error: error, event: witness.event) }
        }
        /// After `recheck` seconds, both test folders read once more: what the run intended is every copy live once in
        /// A and none live in B. Only once the copies were picked; before that nothing moved.
        func final(doubles: Int?) async -> [String: Any] {
            if !settles.isEmpty { report["settle"] = settles }
            guard let intended else { return finish() }
            let start = ContinuousClock.now
            await settle.sleep(.seconds(recheck))
            var folders: [String: Any] = [:]
            var live: [[String]] = []
            for (key, path) in [("a", [folderA]), ("b", [folderB])] {
                witness.clear()
                do {
                    let listed = try await mail.messageIDs(account: intended.account, path: path)
                    folders[key] = ["live": listed.filter { !$0.deleted }.count, "deleted_status": listed.filter(\.deleted).count]
                    live.append(Self.live(listed))
                } catch {
                    var entry: [String: Any] = ["error": MailMover.describe(error)]
                    if let event = witness.event { entry["event"] = event }
                    folders[key] = entry
                }
            }
            timings["recheck"] = milliseconds(ContinuousClock.now - start)
            folders["recheck_after_ms"] = recheck * 1000
            let result: String
            if live.count == 2 {
                let inA = Dictionary(grouping: live[0], by: { $0 }).mapValues(\.count), inB = Set(live[1])
                result = intended.copies.allSatisfy { inA[$0] == 1 && !inB.contains($0) } ? "as_intended" : "not_as_intended"
                if let doubles { report["in_both"] = ["before": doubles, "after": Set(live[0]).intersection(live[1]).count] }
            } else {
                result = "unknown"
            }
            folders["matches"] = result == "as_intended"
            report["recheck"] = folders
            report["result"] = result
            return finish()
        }
        do {
            let kinds = try await timed("accounts") { try await firstAccounts(mail, pause: pause) { retries += 1 } }
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
            let before = try await timed("folders") { try await mail.testFolders(account: account.id) }
            var made: [String] = []
            for path in [a, b] where !before.contains(where: { $0.path == path && $0.exists }) {
                let newly = try await timed("make_folder") { try await mail.makeFolder(account: account.id, name: path[0]) }
                if newly { made.append(path[0]) }
            }
            counts["folders_made"] = made.count
            var ready: [TestFolder] = []
            for _ in 0..<10 {
                ready = try await timed("folders") { try await mail.testFolders(account: account.id) }
                if [a, b].allSatisfy({ path in ready.contains { $0.path == path && $0.exists } }) { break }
                await pause()
            }
            guard let folderInA = ready.first(where: { $0.path == a && $0.exists }), let folderInB = ready.first(where: { $0.path == b && $0.exists }) else {
                return finish(["refused": "test_folders_not_ready", "next": "Mail did not show both test folders. Check them in Mail."])
            }
            let mover = MailMover(reader: mail, settle: settle)
            var reused = 0

            // An earlier run's copies left in B go back to A first, through the same move path (dry run, batches, settled
            // read-back by Message-ID). Entries marked deleted count as gone. A mail live in both A and B stays as it
            // is (`in_both`): the probe deletes nothing and goes on with the mails that are only in A.
            var resetB = false
            var doubles = Set<String>()
            if folderInB.count != 0 {
                let listedB = try await timed("list_b") { try await mail.messageIDs(account: account.id, path: b) }
                let inB = Self.live(listedB)
                if !inB.isEmpty {
                    let liveA = folderInA.count != 0 ? Self.live(try await timed("list_a") { try await mail.messageIDs(account: account.id, path: a) }) : []
                    doubles = Set(inB).intersection(liveA)
                    let onlyB = Array(Set(inB).subtracting(doubles)).sorted()
                    var reset: [String: Any] = ["in_b": inB.count, "deleted_in_b": listedB.count(where: \.deleted), "in_both": doubles.count]
                    if !onlyB.isEmpty {
                        resetB = true
                        let plan = try await timed("reset_dry_run") { try await mover.plan(account: account, label: "probe", source: b, target: a, messageIDs: onlyB) }
                        let back = try await timed("reset_move") { try await mover.apply(plan, journal: nil) }
                        reset.merge(["will_move": plan.entries.count, "not_found": plan.notFound, "skipped": plan.skipped,
                                     "verified": back.verified, "not_moved": back.notMoved, "unclear": back.unclear, "unclear_in_both": back.inBoth]) { _, b in b }
                        counts["reset_b_to_a"] = reset
                        settles["reset_move"] = settleJSON(back.settle)
                        guard plan.entries.count == onlyB.count, back.verified == plan.entries.count, back.failure == nil else {
                            report["in_both"] = ["before": doubles.count]
                            return finish(["refused": "test_folder_b_not_reset",
                                           "next": "Not every mail only in \(folderB) went back to \(folderA). Look at both folders in Mail; nothing else was touched and nothing was deleted."])
                        }
                    }
                    counts["reset_b_to_a"] = reset
                }
            }
            report["in_both"] = ["before": doubles.count]

            var copies: [String]
            let inA = folderInA.count != 0 || resetB ? try await timed("list_a") { try await mail.messageIDs(account: account.id, path: a) } : []
            let reusable = Self.live(inA)
            if !reusable.isEmpty {
                // Everything live in A is a test copy: move what has a Message-ID that occurs once there and is not also in B.
                let seen = Dictionary(grouping: reusable, by: { $0 }).mapValues(\.count)
                copies = seen.filter { $0.value == 1 && !doubles.contains($0.key) }.map(\.key).sorted()
                counts["copies_in_a"] = reusable.count
                counts["deleted_in_a"] = inA.count(where: \.deleted)
                counts["copies_unique"] = copies.count
                reused = copies.count
                guard !copies.isEmpty else {
                    return finish(["refused": "copies_not_found",
                                   "next": "\(folderA) holds no mail the probe can move (mails in both test folders are left alone). Nothing was moved."])
                }
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
                var copyLookups = MailMoveSettleStats()
                defer { settles["locate_copies"] = settleJSON(copyLookups) }
                for _ in 0..<10 {
                    copyLookups.lookups += 1
                    // A lookup Mail does not answer in time is one poll, not a failure.
                    do {
                        located = try await timed("locate_copies") {
                            try await mail.locate(account: account.id, path: a, messageIDs: wanted, eventTimeout: MailMoveSettle.lookupEventTimeout)
                        }.mapValues(\.live)
                    } catch let failure as ProbeFailure where failure.error as? MailAccountProblem == .timeout {
                        copyLookups.timeouts += 1
                        await pause()
                        continue
                    }
                    let found = located.values.reduce(0) { $0 + $1.count }
                    let folder = try await timed("folders") { try await mail.testFolders(account: account.id) }.first { $0.path == a }
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
            intended = (account.id, copies)

            // The same path as mail_move: dry run, plan, batches, read-back by Message-ID.
            let owner = UUID()
            let store = MailPageStore()
            _ = store.claim(owner, live: { true })
            let plan = try await timed("dry_run") {
                try await mover.plan(account: account, label: "probe", source: a, target: b, messageIDs: copies)
            }
            counts["dry_run"] = ["will_move": plan.entries.count, "not_found": plan.notFound, "skipped": plan.skipped, "in_both": plan.inBoth,
                                 "deleted_status": plan.deleted]
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
                              "not_found": outcome.notFound, "skipped": outcome.skipped, "unclear": outcome.unclear, "in_both": outcome.inBoth,
                              "deleted_status": outcome.deleted, "not_started": outcome.notStarted]
            settles["move"] = settleJSON(outcome.settle)
            report["verified"] = "\(outcome.verified) of \(outcome.attempted)"
            report["mail_ids_changed"] = outcome.idsChanged == 0 ? "no" : outcome.idsKept == 0 ? "yes" : "some"
            counts["mail_ids"] = ["kept": outcome.idsKept, "changed": outcome.idsChanged]
            if let failure = outcome.failure {
                report["move_error"] = failure
                if let event = witness.event { report["move_error_event"] = event }
            }
            if !outcome.statuses.isEmpty { counts["move_statuses"] = outcome.statuses }
            let rowsAfter = try await journal.runActions(run: runID)
            counts["journal_rows"] = tally(rowsAfter.map(\.state.rawValue))
            // As the answer's receipt does before anyone can press Undo: one more look at the unclear rows, which records
            // Mail's id in the target for the mails that did move. Undo moves back only rows with that id.
            let unclearRows = rowsAfter.filter { $0.state == .unclear && $0.object.kind == MailMover.kind }
            if !unclearRows.isEmpty {
                let found = try await timed("recheck_unclear") { await mover.recheck(unclearRows) }
                try await journal.resolveUnclearMailRows(found)
                let rows = try await journal.runActions(run: runID)
                counts["recheck_before_undo"] = ["unclear": unclearRows.count, "moved": found.values.filter { if case .moved = $0 { true } else { false } }.count,
                                                 "not_moved": found.values.filter { $0 == .notMoved }.count]
                counts["undo_without_identity"] = rows.filter { $0.object.kind == MailMover.kind && $0.state == .unclear && $0.verified != true }.count
            }

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
            counts["undo"] = ["undone": undo.undone.count, "left": undo.left.count, "failed": undo.failed.count, "unclear": undo.unclear.count,
                              "unanswered": undo.unanswered.count]
            settles["undo"] = settleJSON(undoSettle.value)
            // The same settling as the moves: a lookup Mail does not answer in time is one poll, never "not there".
            var verify = MailMoveSettleStats()
            let back = try await timed("verify_back") {
                try await mover.settled(account: account.id, source: a, target: b, copies, waitingFor: Set(copies), stats: &verify) { inA, inB in
                    inA.count == 1 && inB.isEmpty
                }
            }
            settles["verify_back"] = settleJSON(verify)
            counts["verify_back_answered"] = back.answered
            counts["back_in_a"] = copies.filter { back.here($0).count == 1 && back.there($0).isEmpty }.count
            counts["left_in_b"] = copies.reduce(0) { $0 + back.there($1).count }
            counts["deleted_status_after"] = back.deleted(copies)
            // A second Undo must find nothing to do. With rows still unclear it could move a mail again, and rows Mail did not
            // answer for are still to undo: skipped then.
            if undo.unclear.isEmpty && undo.unanswered.isEmpty {
                let again = try await journal.undoRun(runID, recipe: { _ in nil }, batch: batch)
                counts["second_undo_steps"] = again.undone.count + again.left.count + again.failed.count + again.unclear.count
            } else {
                counts["second_undo_skipped"] = undo.unclear.isEmpty ? "unanswered_rows" : "unclear_rows"
            }
            report["cleanup"] = "The copies stay in \(folderA); the next run uses them again."
            return await final(doubles: doubles.count)
        } catch let failure as ProbeFailure {
            var error: [String: Any] = ["step": failure.step, "kind": MailMover.describe(failure.error)]
            if let event = failure.event { error["event"] = event }
            report["error"] = error
            return await final(doubles: nil)
        } catch {
            report["error"] = ["step": "journal", "kind": MailMover.describe(error)]
            return await final(doubles: nil)
        }

    }

    struct ProbeFailure: Error { var step: String; var error: Error; var event: String? }

    /// Passes every call on to Mail and notes which kind of Apple event last timed out (resolve, count, list_ids,
    /// duplicate, move, locate, …), so a timeout in the report says what did not answer. Never a name or an id.
    final class TimeoutWitness: MailMoveProbeMail, @unchecked Sendable {
        private let mail: any MailMoveProbeMail
        private let lock = NSLock()
        private var last: String?
        init(_ mail: any MailMoveProbeMail) { self.mail = mail }
        var event: String? { lock.withLock { last } }
        func clear() { lock.withLock { last = nil } }
        private func note<T>(_ event: String, _ body: () async throws -> T) async throws -> T {
            do { return try await body() } catch MailAccountProblem.timeout {
                lock.withLock { last = event }
                throw MailAccountProblem.timeout
            }
        }

        func inboxAccounts() async throws -> [MailAccountInfo] { try await note("accounts") { try await mail.inboxAccounts() } }
        func candidates(account: String, query: String, unread: Bool) async throws -> [MailSearchCandidate] {
            try await note("inbox") { try await mail.candidates(account: account, query: query, unread: unread) }
        }
        func candidates(account: String, query: String, readStatus: MailReadStatus, mailbox: MailBoxKind) async throws -> [MailSearchCandidate] {
            try await note("inbox") { try await mail.candidates(account: account, query: query, readStatus: readStatus, mailbox: mailbox) }
        }
        func rows(account: String, ids: [Int]) async throws -> [MailSearchRow] { try await note("inbox_rows") { try await mail.rows(account: account, ids: ids) } }
        func rows(account: String, ids: [Int], mailbox: MailBoxKind) async throws -> [MailSearchRow] {
            try await note("inbox_rows") { try await mail.rows(account: account, ids: ids, mailbox: mailbox) }
        }
        func message(account: String, mailID: Int, messageID: String, path: [String]) async throws -> MailInboxMessage? {
            try await mail.message(account: account, mailID: mailID, messageID: messageID, path: path)
        }
        func message(account: String, mailID: Int, messageID: String, path: [String], mailbox: MailBoxKind) async throws -> MailInboxMessage? {
            try await mail.message(account: account, mailID: mailID, messageID: messageID, path: path, mailbox: mailbox)
        }
        func threadActivity(account: String, messageID: String, subject: String, since: Date?) async throws -> MailThreadActivity? {
            try await mail.threadActivity(account: account, messageID: messageID, subject: subject, since: since)
        }
        func folders(account: String, samples: Int) async throws -> MailFolderList { try await note("list_folders") { try await mail.folders(account: account, samples: samples) } }
        func locate(account: String, path: [String], messageIDs: [String]) async throws -> [String: MailLocated] {
            try await note("locate") { try await mail.locate(account: account, path: path, messageIDs: messageIDs) }
        }
        func locate(account: String, path: [String], messageIDs: [String], eventTimeout: Int) async throws -> [String: MailLocated] {
            try await note("locate") { try await mail.locate(account: account, path: path, messageIDs: messageIDs, eventTimeout: eventTimeout) }
        }
        @discardableResult
        func move(account: String, from: [String], mails: [MailMoveItem], to: [String]) async throws -> [String] {
            try await note("move") { try await mail.move(account: account, from: from, mails: mails, to: to) }
        }
        func accountKinds() async throws -> [AccountKind] { try await note("accounts") { try await mail.accountKinds() } }
        func testFolders(account: String) async throws -> [TestFolder] {
            let found = try await mail.testFolders(account: account)
            if let event = found.compactMap(\.timedOut).first {
                lock.withLock { last = event }
                throw MailAccountProblem.timeout
            }
            return found
        }
        func folderTimings(account: String, samples: Int) async throws -> ListingTimings { try await mail.folderTimings(account: account, samples: samples) }
        func makeFolder(account: String, name: String) async throws -> Bool { try await note("make_folder") { try await mail.makeFolder(account: account, name: name) } }
        func messageIDs(account: String, path: [String]) async throws -> [Listed] { try await note("list_ids") { try await mail.messageIDs(account: account, path: path) } }
        func duplicate(account: String, inboxIDs: [Int], to: [String]) async throws -> [String] {
            try await note("duplicate") { try await mail.duplicate(account: account, inboxIDs: inboxIDs, to: to) }
        }
    }

    /// Lookups (polls) and milliseconds the read-backs waited for Mail to settle in one step.
    static func settleJSON(_ s: MailMoveSettleStats) -> [String: Int] {
        ["lookups": s.lookups, "waited_ms": s.waitedMs, "longest_batch_ms": s.longestMs, "timeouts": s.timeouts]
    }

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
#endif
