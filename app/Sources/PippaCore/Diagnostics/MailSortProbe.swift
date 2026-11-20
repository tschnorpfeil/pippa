import Foundation

// A developer probe: compiled only into debug builds and builds with `PIPPA_PROBES` (scripts/build-app.sh), never shipped.
#if DEBUG || PIPPA_PROBES

/// What the sort probe asks Mail: the account kinds, the listing `mail_folders` uses, and headers of one mailbox.
/// Every call only reads.
public protocol MailSortProbeMail: Sendable {
    func accountKinds() async throws -> [MailMoveProbe.AccountKind]
    func folders(account: String, samples: Int) async throws -> MailFolderList
    /// Sender and deleted status of the first `limit` messages of the mailbox at `path` (`[]`: the account's inbox), and
    /// with `flags` their read and flagged status too. One bulk Apple event per property, each bounded by `eventTimeout`
    /// seconds; a timeout throws `MailAccountProblem.timeout`. Never opens, marks or changes a message.
    func headers(account: String, path: [String], limit: Int, flags: Bool, eventTimeout: Int) async throws -> [MailSortProbe.Header]
}

extension SystemIntegrations {
    /// The real Mail for `Pippa --mail-sort-probe` only.
    public var mailSortProbe: any MailSortProbeMail { MailAccountScript.Live() }
}

/// The rule `mail_sort` is planned with (docs/mail-sort.md, "The rule"), as a pure function. A sender is its bare
/// address, lowercased. A sender belongs to folder F when at least `min` of the mails read from F are from it and no
/// other folder read has one from it. An inbox mail is proposed for F when its sender belongs to F and the mail is read
/// and not flagged.
public struct MailSortRule: Sendable {
    public let min: Int
    /// Per sender: how many of the read mails of each folder are from it.
    let counts: [String: [[String]: Int]]

    public struct Filed: Sendable, Equatable {
        public var sender: String, folder: [String]
        public init(sender: String, folder: [String]) { self.sender = sender; self.folder = folder }
    }

    public enum Proposal: Sendable, Equatable { case folder([String]), unread, flagged, unreadAndFlagged, noRule }

    /// `filed`: senders already as `key` makes them.
    public init(filed: [Filed], min: Int) {
        var counts: [String: [[String]: Int]] = [:]
        for mail in filed { counts[mail.sender, default: [:]][mail.folder, default: 0] += 1 }
        self.counts = counts
        self.min = min
    }

    /// "Name <Anna.B@Example.test>" → "anna.b@example.test"; `nil` without a valid address.
    public static func key(_ sender: String) -> String? { MailAddress.parse(sender).address?.lowercased() }

    static func owner(_ byFolder: [[String]: Int], min: Int) -> [String]? {
        let present = byFolder.filter { $0.value > 0 }
        guard present.count == 1, let only = present.first, only.value >= min else { return nil }
        return only.key
    }

    public func folder(of sender: String) -> [String]? { Self.owner(counts[sender] ?? [:], min: min) }

    /// Senders that belong to a folder.
    public var sendersWithFolder: Int { counts.values.count(where: { Self.owner($0, min: min) != nil }) }

    /// Unread and flagged mails stay in the inbox whatever the sender; the reason is named only when the sender has a folder.
    public func propose(sender: String?, read: Bool, flagged: Bool) -> Proposal {
        guard let sender, let folder = folder(of: sender) else { return .noRule }
        switch (read, flagged) {
        case (true, false): return .folder(folder)
        case (false, false): return .unread
        case (true, true): return .flagged
        case (false, true): return .unreadAndFlagged
        }
    }

    /// For each filed mail, the rule built from all other filed mails: names its folder (`right`), another (`wrong`), none.
    public static func leaveOneOut(_ filed: [Filed], min: Int) -> (right: Int, wrong: Int, none: Int) {
        let rule = MailSortRule(filed: filed, min: min)
        var right = 0, wrong = 0, none = 0
        for mail in filed {
            var others = rule.counts[mail.sender] ?? [:]
            others[mail.folder, default: 0] -= 1
            switch owner(others, min: min) {
            case nil: none += 1
            case mail.folder?: right += 1
            default: wrong += 1
            }
        }
        return (right, wrong, none)
    }
}

/// Developer measurement before `mail_sort` is built (docs/mail-sort.md, build order step 1):
/// `Pippa --mail-sort-probe --account <name>`. Read-only: it lists the account's folders as `mail_folders` does, reads
/// the senders of the first messages of every folder `mail_move` may target and sender, read and flagged status of the
/// first inbox messages, and scores the sender-history rule (`MailSortRule`) on them. It prints one JSON object of
/// numbers and fixed words: never a sender, address, subject, folder name, account name or Message-ID (only the list
/// mode without `--account` names the accounts, as the move probe does). It moves, copies, makes, deletes, marks and
/// opens nothing.
public enum MailSortProbe {
    public static let perFolderDefault = 200
    public static let inboxDefault = 500
    /// Seconds per bulk Apple event about one mailbox; a mailbox that does not answer is left out and counted.
    public static let eventTimeout = 20
    /// The rule's threshold as decided, and the one to fall back to (docs/mail-sort.md).
    public static let mins = [2, 3]

    public static let usage = """
        usage: Pippa --mail-sort-probe [--account <name> [--per-folder <n>] [--inbox <n>]]
          Without --account: lists Mail's accounts with their types and exits.
          With --account: changes nothing in Mail. Lists the account's folders as mail_folders does, then reads the senders
          of the first --per-folder messages (default \(perFolderDefault)) of every folder mail_move may target (never the
          inbox, never Trash, Junk, Sent, Drafts, Outbox or a folder inside them), and sender, read and flagged status of
          the first --inbox messages (default \(inboxDefault)) of the inbox. Headers only, one Apple event per property and
          mailbox, each allowed \(eventTimeout) s; a mailbox that does not answer is left out and counted. Messages Mail
          marked deleted are skipped. Scores the sender-history rule of docs/mail-sort.md for at least \(mins.map(String.init).joined(separator: " and ")) mails
          per sender: inbox mails it would propose, mails held back, and a leave-one-out score over the filed mails.
          Prints one JSON object of numbers only: no sender, address, subject, folder or account name. The exit code is 0
          when the inbox and at least one folder were read.
        """

    /// One message's headers as the probe reads them; `read` and `flagged` are false unless asked for.
    public struct Header: Sendable, Equatable {
        public var sender: String, deleted: Bool, read: Bool, flagged: Bool
        public init(sender: String, deleted: Bool = false, read: Bool = false, flagged: Bool = false) {
            self.sender = sender; self.deleted = deleted; self.read = read; self.flagged = flagged
        }
    }

    /// The probe's own AppleScript handler, for the check that it sends no changing Apple event.
    public static var headersScript: String {
        let source = MailAccountScript.moveSource
        guard let start = source.range(of: "on accountSortHeaders("), let end = source.range(of: "end accountSortHeaders", range: start.upperBound..<source.endIndex) else { return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    public enum Invocation: Equatable, Sendable { case help, list, run(account: String, perFolder: Int, inbox: Int) }

    public struct UsageError: Error, Equatable, Sendable { public let message: String }

    /// Strict: a missing, repeated or unknown argument is an error, before Mail is asked anything.
    public static func parse(_ arguments: [String]) throws -> Invocation {
        var account: String?
        var perFolder: Int?, inbox: Int?
        var sawCommand = false
        var rest = arguments[...]
        func number(_ flag: String, _ current: Int?, _ range: ClosedRange<Int>) throws -> Int {
            guard current == nil else { throw UsageError(message: "\(flag) given twice.") }
            guard let value = rest.popFirst(), let n = Int(value), range.contains(n) else {
                throw UsageError(message: "\(flag) needs a number from \(range.lowerBound) to \(range.upperBound).")
            }
            return n
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h": return .help
            case "--mail-sort-probe":
                guard !sawCommand else { throw UsageError(message: "--mail-sort-probe given twice.") }
                sawCommand = true
            case "--account":
                guard account == nil else { throw UsageError(message: "--account given twice.") }
                guard let value = rest.popFirst(), !value.hasPrefix("--"), !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw UsageError(message: "--account needs an account name.")
                }
                account = value
            case "--per-folder": perFolder = try number("--per-folder", perFolder, 1...2000)
            case "--inbox": inbox = try number("--inbox", inbox, 1...5000)
            default: throw UsageError(message: "Unknown argument.")
            }
        }
        guard sawCommand else { throw UsageError(message: "Missing --mail-sort-probe.") }
        guard let account else {
            if perFolder != nil || inbox != nil { throw UsageError(message: "--per-folder and --inbox need --account.") }
            return .list
        }
        return .run(account: account, perFolder: perFolder ?? perFolderDefault, inbox: inbox ?? inboxDefault)
    }

    /// `mail` is only made after the arguments parsed. `pause` waits before the first event is asked again.
    public static func execute(_ arguments: [String], mail: () -> any MailSortProbeMail,
                               pause: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let invocation: Invocation
        do { invocation = try parse(arguments) } catch let error as UsageError { return (2, "", error.message + "\n" + usage) }
        catch { return (2, "", usage) }
        switch invocation {
        case .help: return (0, usage, "")
        case .list:
            var retries = 0
            let probe = mail()
            do {
                let kinds = try await MailMoveProbe.firstAccounts(probe.accountKinds, pause: pause) { retries += 1 }
                return (0, MailMoveProbe.json(["probe": "mail-sort-probe", "first_event_retries": retries,
                                               "accounts": kinds.map { ["name": $0.name, "type": $0.type, "class": $0.className] }]), "")
            } catch {
                return (1, MailMoveProbe.json(["probe": "mail-sort-probe", "first_event_retries": retries, "error": ["step": "accounts", "kind": MailMover.describe(error)]]), "")
            }
        case .run(let name, let perFolder, let inbox):
            let report = await run(account: name, mail: mail(), perFolder: perFolder, inbox: inbox, pause: pause)
            return (report["result"] as? String == "read" ? 0 : 1, MailMoveProbe.json(report), "")
        }
    }

    static func run(account name: String, mail: any MailSortProbeMail, perFolder: Int, inbox inboxLimit: Int,
                    pause: @Sendable () async -> Void) async -> [String: Any] {
        let started = ContinuousClock.now
        var report: [String: Any] = ["probe": "mail-sort-probe", "per_folder": perFolder, "inbox_limit": inboxLimit, "event_timeout_s": eventTimeout,
                                     "changed": "nothing"]
        var slowest = 0
        func finish(_ extra: [String: Any] = [:]) -> [String: Any] {
            report["seconds_total"] = (Double(MailMoveProbe.milliseconds(ContinuousClock.now - started)) / 100).rounded() / 10
            report["slowest_mailbox_ms"] = slowest
            return report.merging(extra) { _, b in b }
        }
        var retries = 0
        let kinds: [MailMoveProbe.AccountKind]
        do { kinds = try await MailMoveProbe.firstAccounts(mail.accountKinds, pause: pause) { retries += 1 } } catch {
            report["first_event_retries"] = retries
            return finish(["error": ["step": "accounts", "kind": MailMover.describe(error)]])
        }
        report["first_event_retries"] = retries
        let matches = kinds.filter { $0.id == name || $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        guard matches.count == 1, let kind = matches.first, !kind.id.isEmpty else {
            return finish(["refused": matches.isEmpty ? "unknown_account" : "ambiguous_account",
                           "next": "Run Pippa --mail-sort-probe without --account to list the accounts."])
        }
        report["account_type"] = kind.type

        // The listing mail_folders uses, without samples: only paths and roles are needed.
        let listStart = ContinuousClock.now
        let list: MailFolderList
        do { list = try await mail.folders(account: kind.id, samples: 0) } catch {
            return finish(["error": ["step": "list_folders", "kind": MailMover.describe(error)]])
        }
        report["listing_ms"] = MailMoveProbe.milliseconds(ContinuousClock.now - listStart)
        // The folders mail_move may target: not the inbox itself, nothing refused by role or lying inside a refused one.
        var targets: [[String]] = [], refused = 0
        for folder in list.folders {
            if MailFolderRole.of(folder) == .inbox { continue }
            if MailFolderRole.refused(folder, in: list.folders) != nil { refused += 1 } else { targets.append(folder.path) }
        }

        /// One mailbox's headers, timed into `slowest`; the error when Mail did not answer.
        func read(_ path: [String], limit: Int, flags: Bool) async -> Result<[Header], Error> {
            let start = ContinuousClock.now
            defer { slowest = max(slowest, MailMoveProbe.milliseconds(ContinuousClock.now - start)) }
            do { return .success(try await mail.headers(account: kind.id, path: path, limit: limit, flags: flags, eventTimeout: eventTimeout)) }
            catch { return .failure(error) }
        }

        var filed: [MailSortRule.Filed] = []
        var folderRead = 0, folderTimedOut = 0, folderFailed = 0, filedDeleted = 0, filedWithoutAddress = 0
        for path in targets {
            switch await read(path, limit: perFolder, flags: false) {
            case .success(let headers):
                folderRead += 1
                for header in headers {
                    if header.deleted { filedDeleted += 1; continue }
                    guard let sender = MailSortRule.key(header.sender) else { filedWithoutAddress += 1; continue }
                    filed.append(.init(sender: sender, folder: path))
                }
            case .failure(let error as MailAccountProblem) where error == .timeout: folderTimedOut += 1
            case .failure: folderFailed += 1
            }
        }
        report["folders"] = ["listed": list.folders.count, "not_listed": list.unnamed, "subfolders_not_listed": list.unexpanded,
                             "asked": targets.count, "read": folderRead, "timed_out": folderTimedOut, "failed": folderFailed,
                             "skipped_refused": refused]
        let bySender = Dictionary(grouping: filed, by: \.sender).mapValues { Set($0.map(\.folder)).count }
        report["filed"] = ["mails_read": filed.count, "deleted_skipped": filedDeleted, "without_address": filedWithoutAddress,
                           "distinct_senders": bySender.count, "senders_in_more_than_one_folder": bySender.values.count(where: { $0 > 1 })]

        var inboxRead = false
        var inbox: [(sender: String?, read: Bool, flagged: Bool)] = []
        switch await read([], limit: inboxLimit, flags: true) {
        case .success(let headers):
            inboxRead = true
            let live = headers.filter { !$0.deleted }
            inbox = live.map { (MailSortRule.key($0.sender), $0.read, $0.flagged) }
            report["inbox"] = ["mails_read": live.count, "deleted_skipped": headers.count - live.count]
        case .failure(let error):
            report["inbox"] = ["mails_read": 0]
            report["error"] = ["step": "inbox_headers", "kind": MailMover.describe(error)]
        }

        var rules: [String: Any] = [:]
        for min in mins {
            let rule = MailSortRule(filed: filed, min: min)
            var proposed: [[String]: Int] = [:]
            var unread = 0, flagged = 0, both = 0, noRule = 0
            for mail in inbox {
                switch rule.propose(sender: mail.sender, read: mail.read, flagged: mail.flagged) {
                case .folder(let folder): proposed[folder, default: 0] += 1
                case .unread: unread += 1
                case .flagged: flagged += 1
                case .unreadAndFlagged: both += 1
                case .noRule: noRule += 1
                }
            }
            let total = proposed.values.reduce(0, +)
            let largest = proposed.values.max() ?? 0
            let score = MailSortRule.leaveOneOut(filed, min: min)
            var entry: [String: Any] = ["senders_with_folder": rule.sendersWithFolder,
                                        "leave_one_out": ["right": score.right, "wrong": score.wrong, "none": score.none]]
            if inboxRead {
                entry.merge(["inbox_proposed": total, "held_back_only_unread": unread, "held_back_only_flagged": flagged,
                             "held_back_unread_and_flagged": both, "inbox_without_rule": noRule, "folders_receiving": proposed.count,
                             "largest_folder_share_percent": total == 0 ? 0 : Int((Double(largest) * 100 / Double(total)).rounded())]) { _, b in b }
            }
            rules["min_\(min)"] = entry
        }
        report["rule"] = rules
        report["result"] = inboxRead && folderRead > 0 ? "read" : "incomplete"
        return finish()
    }
}
#endif
