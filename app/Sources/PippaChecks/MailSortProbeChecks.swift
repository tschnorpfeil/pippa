import Foundation
import PippaCore

/// `Pippa --mail-sort-probe` and `MailSortRule` against an invented Mail: never the real Mail. Names, addresses and
/// folder names are recognizable so the report can be searched for them.
final class FakeSortProbeMail: MailSortProbeMail, @unchecked Sendable {
    static let accountName = "Erfundenes Konto Sortieren"
    let kinds = [MailMoveProbe.AccountKind(id: "acct-erfunden", name: accountName, type: "imap", className: "imap account")]
    var list: MailFolderList
    /// path → headers; `[]` is the inbox.
    var boxes: [[String]: [MailSortProbe.Header]]
    var timeouts: Set<[String]> = []
    let kindTimeouts = LockedBox(0)
    let asked = LockedBox<[(path: [String], flags: Bool, limit: Int)]>([])

    init(list: MailFolderList, boxes: [[String]: [MailSortProbe.Header]]) { self.list = list; self.boxes = boxes }

    func accountKinds() async throws -> [MailMoveProbe.AccountKind] {
        if kindTimeouts.value > 0 { kindTimeouts.mutate { $0 -= 1 }; throw MailAccountProblem.timeout }
        return kinds
    }
    func folders(account: String, samples: Int) async throws -> MailFolderList { list }
    func headers(account: String, path: [String], limit: Int, flags: Bool, eventTimeout: Int) async throws -> [MailSortProbe.Header] {
        asked.mutate { $0.append((path, flags, limit)) }
        if timeouts.contains(path) { throw MailAccountProblem.timeout }
        guard let box = boxes[path] else { throw MailMoveProblem.noFolder }
        return Array(box.prefix(limit)).map { flags ? $0 : MailSortProbe.Header(sender: $0.sender, deleted: $0.deleted) }
    }
}

func runMailSortProbeChecks() async {
    typealias H = MailSortProbe.Header
    let reisen = ["Erfunden Reisen"], verein = ["Erfunden Verein"], langsam = ["Erfunden Langsam"]
    let papierkorb = ["Erfunden Papierkorb"], darin = ["Erfunden Papierkorb", "Erfunden Rechnungen"], gesendet = ["Erfunden Gesendet"]
    let alpha = "Alpha Erfunden <Alpha.Erfunden@beispiel.test>", beta = "beta.erfunden@beispiel.test"
    let geteilt = "Geteilt Erfunden <geteilt.erfunden@beispiel.test>", gamma = "gamma.erfunden@beispiel.test", delta = "delta.erfunden@beispiel.test"
    let names = [FakeSortProbeMail.accountName, "Erfunden", "beispiel.test", "Alpha", "alpha.erfunden", "beta.erfunden", "geteilt", "gamma", "delta"]
    func world() -> FakeSortProbeMail {
        let list = MailFolderList(folders: [
            MailFolderInfo(path: ["INBOX"], count: 9, role: .inbox), MailFolderInfo(path: reisen, count: 6), MailFolderInfo(path: verein, count: 4),
            MailFolderInfo(path: langsam, count: nil, gap: .slow), MailFolderInfo(path: papierkorb, count: 3, role: .trash),
            MailFolderInfo(path: darin, count: 2), MailFolderInfo(path: gesendet, count: 2, role: .sent)])
        let fake = FakeSortProbeMail(list: list, boxes: [
            // Alpha three times (and once marked deleted), Beta once, Geteilt once: Geteilt is also filed in Verein.
            reisen: [H(sender: alpha), H(sender: alpha.uppercased()), H(sender: "alpha.erfunden@beispiel.test"), H(sender: alpha, deleted: true),
                     H(sender: beta), H(sender: geteilt)],
            verein: [H(sender: gamma), H(sender: gamma), H(sender: geteilt), H(sender: geteilt)],
            langsam: [H(sender: delta), H(sender: delta), H(sender: delta)],
            papierkorb: [H(sender: delta), H(sender: delta), H(sender: delta)], darin: [H(sender: delta), H(sender: delta)],
            gesendet: [H(sender: delta), H(sender: delta)],
            []: [H(sender: alpha, read: true), H(sender: alpha, read: false), H(sender: gamma, read: true, flagged: true),
                 H(sender: gamma, read: true), H(sender: geteilt, read: true), H(sender: beta, read: true), H(sender: delta, read: true),
                 H(sender: "Nur ein Name", read: true), H(sender: alpha, deleted: true, read: true)]])
        fake.timeouts = [langsam]
        return fake
    }
    func probe(_ fake: FakeSortProbeMail, _ arguments: [String]) async -> (exitCode: Int32, stdout: String, stderr: String, json: [String: Any]) {
        let result = await MailSortProbe.execute(["--mail-sort-probe"] + arguments, mail: { fake }, pause: {})
        let json = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any] ?? [:]
        return (result.exitCode, result.stdout, result.stderr, json)
    }
    func section(_ json: [String: Any], _ key: String) -> [String: Any] { json[key] as? [String: Any] ?? [:] }

    check("Mail sort rule: at least two read mails from one address in one folder only; another folder's mail takes the sender away; unread and flagged stay") {
        let a = "a@beispiel.test", b = "b@beispiel.test", c = "c@beispiel.test"
        let filed: [MailSortRule.Filed] = [.init(sender: a, folder: reisen), .init(sender: a, folder: reisen), .init(sender: b, folder: reisen),
                                           .init(sender: c, folder: reisen), .init(sender: c, folder: reisen), .init(sender: c, folder: verein)]
        let two = MailSortRule(filed: filed, min: 2), three = MailSortRule(filed: filed, min: 3)
        return MailSortRule.key("Alpha <A@Beispiel.TEST>") == a && MailSortRule.key("nur ein Name") == nil
            && two.folder(of: a) == reisen && two.folder(of: b) == nil && two.folder(of: c) == nil && three.folder(of: a) == nil
            && two.sendersWithFolder == 1 && three.sendersWithFolder == 0
            && two.propose(sender: a, read: true, flagged: false) == .folder(reisen) && two.propose(sender: a, read: false, flagged: false) == .unread
            && two.propose(sender: a, read: true, flagged: true) == .flagged && two.propose(sender: a, read: false, flagged: true) == .unreadAndFlagged
            && two.propose(sender: c, read: true, flagged: false) == .noRule && two.propose(sender: nil, read: true, flagged: false) == .noRule
            && two.propose(sender: c, read: false, flagged: false) == .noRule
    }

    check("Mail sort rule: leave-one-out counts right, wrong and none for each filed mail") {
        let a = "a@beispiel.test", s = "s@beispiel.test"
        // a: 3 in Reisen → each left out still leaves 2: right ×3 at min 2, none at min 3.
        // s: 1 in Reisen, 2 in Verein → left out of Reisen names Verein (wrong); left out of Verein leaves two folders (none).
        let filed: [MailSortRule.Filed] = Array(repeating: .init(sender: a, folder: reisen), count: 3)
            + [.init(sender: s, folder: reisen), .init(sender: s, folder: verein), .init(sender: s, folder: verein)]
        let two = MailSortRule.leaveOneOut(filed, min: 2), three = MailSortRule.leaveOneOut(filed, min: 3)
        let empty = MailSortRule.leaveOneOut([], min: 2)
        return (two.right, two.wrong, two.none) == (3, 1, 2) && (three.right, three.wrong, three.none) == (0, 0, 6)
            && (empty.right, empty.wrong, empty.none) == (0, 0, 0)
    }

    await checkAsync("Mail sort probe: wrong arguments print usage without asking Mail; no --account lists accounts after a first-event retry") {
        let made = LockedBox(0)
        let fake = world()
        func run(_ arguments: [String]) async -> (exitCode: Int32, stdout: String, stderr: String) {
            await MailSortProbe.execute(arguments, mail: { made.mutate { $0 += 1 }; return fake }, pause: {})
        }
        let help = await run(["--mail-sort-probe", "--help"])
        let wrong = [await run(["--mail-sort-probe", "--acount", "x"]), await run(["--mail-sort-probe", "--account"]),
                     await run(["--mail-sort-probe", "--per-folder", "10"]), await run(["--mail-sort-probe", "--account", "x", "--inbox", "0"]),
                     await run(["--mail-sort-probe", "--account", "x", "--per-folder", "5", "--per-folder", "6"]), await run(["--account", "x"])]
        let untouched = made.value == 0 && fake.asked.value.isEmpty
        let parsed = try? MailSortProbe.parse(["--mail-sort-probe", "--account", "x", "--per-folder", "50"])
        fake.kindTimeouts.mutate { $0 = 1 }
        let list = await run(["--mail-sort-probe"])
        let listed = (try? JSONSerialization.jsonObject(with: Data(list.stdout.utf8))) as? [String: Any]
        return help.exitCode == 0 && help.stdout.contains("usage: Pippa --mail-sort-probe") && untouched
            && wrong.allSatisfy { $0.exitCode == 2 && $0.stderr.contains("usage:") && $0.stdout.isEmpty }
            && parsed == .run(account: "x", perFolder: 50, inbox: MailSortProbe.inboxDefault)
            && list.exitCode == 0 && listed?["first_event_retries"] as? Int == 1 && (listed?["accounts"] as? [[String: Any]])?.count == 1
            && fake.asked.value.isEmpty
    }

    await checkAsync("Mail sort probe: reads only allowed folders and the inbox, leaves out and counts a timed-out folder, scores the rule, prints no name") {
        let fake = world()
        let result = await probe(fake, ["--account", "erfundenes konto sortieren", "--per-folder", "50", "--inbox", "100"])
        let folders = section(result.json, "folders"), filed = section(result.json, "filed"), inbox = section(result.json, "inbox")
        let rule = section(result.json, "rule")
        let two = rule["min_2"] as? [String: Any] ?? [:], three = rule["min_3"] as? [String: Any] ?? [:]
        let looTwo = two["leave_one_out"] as? [String: Int] ?? [:], looThree = three["leave_one_out"] as? [String: Int] ?? [:]
        let asked = fake.asked.value
        // Folders without flags and with --per-folder, the inbox last with flags and --inbox; never Trash, inside it, or Sent.
        let order = asked.map(\.path) == [reisen, verein, langsam, []]
            && asked.dropLast().allSatisfy { !$0.flags && $0.limit == 50 } && asked.last.map { $0.flags && $0.limit == 100 } == true
        let leaked = names.filter { result.stdout.localizedCaseInsensitiveContains($0) }
        if !leaked.isEmpty { print("  leaked: \(leaked)") }
        return result.exitCode == 0 && result.json["result"] as? String == "read" && result.json["changed"] as? String == "nothing" && order
            && folders["asked"] as? Int == 3 && folders["read"] as? Int == 2 && folders["timed_out"] as? Int == 1 && folders["skipped_refused"] as? Int == 3
            && folders["failed"] as? Int == 0 && folders["listed"] as? Int == 7
            && filed["mails_read"] as? Int == 9 && filed["deleted_skipped"] as? Int == 1 && filed["distinct_senders"] as? Int == 4
            && filed["senders_in_more_than_one_folder"] as? Int == 1
            && inbox["mails_read"] as? Int == 8 && inbox["deleted_skipped"] as? Int == 1
            && two["senders_with_folder"] as? Int == 2 && two["inbox_proposed"] as? Int == 2 && two["held_back_only_unread"] as? Int == 1
            && two["held_back_only_flagged"] as? Int == 1 && two["inbox_without_rule"] as? Int == 4 && two["folders_receiving"] as? Int == 2
            && two["largest_folder_share_percent"] as? Int == 50
            && looTwo == ["right": 3, "wrong": 1, "none": 5] && looThree == ["right": 0, "wrong": 0, "none": 9]
            && three["senders_with_folder"] as? Int == 1 && three["inbox_proposed"] as? Int == 1 && three["folders_receiving"] as? Int == 1
            && three["largest_folder_share_percent"] as? Int == 100
            && result.json["seconds_total"] is Double && result.json["slowest_mailbox_ms"] is Int && leaked.isEmpty && result.stderr.isEmpty
    }

    await checkAsync("Mail sort probe: an inbox or every folder Mail does not answer for fails the run, named by step only; unknown accounts are refused") {
        let slowInbox = world()
        slowInbox.timeouts = [[]]
        let noInbox = await probe(slowInbox, ["--account", FakeSortProbeMail.accountName])
        let error = section(noInbox.json, "error")
        let slowFolders = world()
        slowFolders.timeouts = [reisen, verein, langsam]
        let noFolder = await probe(slowFolders, ["--account", FakeSortProbeMail.accountName])
        let unknown = await probe(world(), ["--account", "Kein Konto"])
        return noInbox.exitCode == 1 && noInbox.json["result"] as? String == "incomplete" && error["step"] as? String == "inbox_headers"
            && error["kind"] as? String == "timeout" && section(noInbox.json, "rule")["min_2"] != nil
            && noFolder.exitCode == 1 && section(noFolder.json, "folders")["timed_out"] as? Int == 3 && section(noFolder.json, "inbox")["mails_read"] as? Int == 8
            && unknown.exitCode == 1 && unknown.json["refused"] as? String == "unknown_account" && !unknown.stdout.contains("Kein Konto")
    }

    check("Mail sort probe: its AppleScript handler only reads (no move, copy, delete, make, mark, open or send)") {
        let script = MailSortProbe.headersScript
        let forbidden = [#"\bmove\b"#, #"\bduplicate\b"#, #"\bdelete\b"#, #"\bmake\b"#, #"\bopen\b"#, #"\bsend\b"#, #"set (read|flagged|deleted|junk mail) status"#,
                         #"\bset\s+\w+\s+of\b"#]
        return script.contains("sender of messages 1 thru k of box") && script.contains("with timeout of perEvent seconds")
            && forbidden.allSatisfy { script.range(of: $0, options: [.regularExpression, .caseInsensitive]) == nil }
    }
}
