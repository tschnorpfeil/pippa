import Foundation
import PippaCore

/// `Pippa --mail-send-probe` against a fake Mail (`FakeMailSend` plus an account list): never the real Mail. Names,
/// addresses and texts are recognizable so the report can be searched for them.
final class FakeSendProbeMail: MailSendProbeMail, @unchecked Sendable {
    let mail = FakeMailSend()
    static let own = "geheim.person@example.test"
    static let accountName = "Geheimkonto Privat"
    let kinds = [MailMoveProbe.AccountKind(id: "acct-geheim", name: accountName, type: "imap", className: "imap account"),
                 MailMoveProbe.AccountKind(id: "acct-arbeit", name: "Arbeit Vertraulich", type: "iCloud", className: "iCloud account")]
    var addresses: [String: [String]] = ["acct-geheim": [own, "zweite.adresse@example.test"], "acct-arbeit": ["arbeit.person@example.test"]]
    /// The draft window as Mail makes it: from the account's own address with a recognizable name.
    var sender = "Geheim Person <\(own)>"
    /// Runs on the new window right after `mail_draft` made it (the person or Mail changing it).
    var afterInsert: ((inout MailOutgoing) -> Void)?
    let kindTimeouts = LockedBox(0)
    var addressesTimeOut = false
    var readBackUnreadable = false
    let calls = LockedBox(0)

    func accountKinds() async throws -> [MailMoveProbe.AccountKind] {
        calls.mutate { $0 += 1 }
        if kindTimeouts.value > 0 { kindTimeouts.mutate { $0 -= 1 }; throw MailAccountProblem.timeout }
        return kinds
    }
    func accountAddresses(account: String) async throws -> [String] {
        calls.mutate { $0 += 1 }
        if addressesTimeOut { throw MailAccountProblem.timeout }
        return addresses[account] ?? []
    }
    func sentMailbox(address: String) async throws -> String { calls.mutate { $0 += 1 }; return "found" }
    func insertDraft(_ draft: MailDraft) async throws -> MailDraftInsert {
        calls.mutate { $0 += 1 }
        let made = try await mail.insertDraft(draft)
        let sender = sender, change = afterInsert
        mail.edit(mail.lastID) { $0.sender = sender; change?(&$0) }
        return made
    }
    func outgoing(_ id: Int, process: Int32) async throws -> MailOutgoingLookup {
        calls.mutate { $0 += 1 }
        return readBackUnreadable ? .unreadable : try await mail.outgoing(id, process: process)
    }
    func send(_ id: Int, process: Int32, expected: MailOutgoing) async throws -> MailSendDispatch {
        calls.mutate { $0 += 1 }
        return try await mail.send(id, process: process, expected: expected)
    }
    func sentMessageIDs(subject: String, from address: String, since: Date) async throws -> Set<String> {
        calls.mutate { $0 += 1 }
        return try await mail.sentMessageIDs(subject: subject, from: address, since: since)
    }
    func sent(subject: String, from address: String, since: Date) async throws -> [MailSentEntry] {
        calls.mutate { $0 += 1 }
        return try await mail.sent(subject: subject, from: address, since: since)
    }
}

func runMailSendProbeChecks() async {
    let hosts = LockedBox(0)
    func host() -> PippaMCPHost {
        hosts.mutate { $0 += 1 }
        let demo = DemoIntegrations(granted: true)
        return PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo), askForAccess: false)
    }
    /// The fake clock for the looks into Sent: each wait moves it on.
    func settle() -> MailMoveSettle {
        let clock = LockedBox<Duration>(.zero)
        return MailMoveSettle(sleep: { d in clock.mutate { $0 += d } }, now: { clock.value })
    }
    func probe(_ fake: FakeSendProbeMail, _ arguments: [String]) async -> (exitCode: Int32, stdout: String, stderr: String, json: [String: Any]) {
        let result = await MailSendProbe.execute(["--mail-send-probe"] + arguments, mail: { fake }, host: host,
                                                 journalDirectory: dir("send-probe-\(UUID().uuidString)"), pause: {}, settle: settle())
        let json = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any] ?? [:]
        return (result.exitCode, result.stdout, result.stderr, json)
    }
    func section(_ json: [String: Any], _ key: String) -> [String: Any] { json[key] as? [String: Any] ?? [:] }

    await checkAsync("Mail send probe: --help and wrong arguments print usage without touching Mail; no --account lists accounts after a first-event retry") {
        let made = LockedBox(0)
        let fake = FakeSendProbeMail()
        func run(_ arguments: [String]) async -> (exitCode: Int32, stdout: String, stderr: String) {
            await MailSendProbe.execute(arguments, mail: { made.mutate { $0 += 1 }; return fake }, host: host, pause: {})
        }
        let hostsBefore = hosts.value
        let help = await run(["--mail-send-probe", "--help"])
        let wrong = [await run(["--mail-send-probe", "--acount", "Privat"]), await run(["--mail-send-probe", "--account", "A", "--account", "B", "--send"]),
                     await run(["--mail-send-probe", "--account"]), await run(["--mail-send-probe", "--account", "A"]),
                     await run(["--mail-send-probe", "--account", "A", "--read-only", "--send"]), await run(["--mail-send-probe", "--send"]),
                     await run(["--mail-send-probe", "--account", "A", "--send", "--send"]), await run(["--mail-send-probe", "--to", "x@example.test"])]
        let untouched = made.value == 0 && fake.calls.value == 0 && hosts.value == hostsBefore
        fake.kindTimeouts.mutate { $0 = 1 }
        let list = await run(["--mail-send-probe"])
        let listed = (try? JSONSerialization.jsonObject(with: Data(list.stdout.utf8))) as? [String: Any]
        let accounts = listed?["accounts"] as? [[String: Any]] ?? []
        return help.exitCode == 0 && help.stdout.contains("usage: Pippa --mail-send-probe") && help.stdout.contains("--read-only") && help.stderr.isEmpty
            && wrong.allSatisfy { $0.exitCode == 2 && $0.stderr.contains("usage:") && $0.stdout.isEmpty } && untouched
            && list.exitCode == 0 && listed?["first_event_retries"] as? Int == 1 && accounts.count == 2
            && fake.mail.sendCallCount == 0 && hosts.value == hostsBefore
    }

    await checkAsync("Mail send probe: --read-only makes one draft to the account's own address, reads it back and Sent's snapshot, and sends nothing") {
        let fake = FakeSendProbeMail()
        let result = await probe(fake, ["--account", "geheimkonto privat", "--read-only"])
        let draft = section(result.json, "draft"), back = section(result.json, "read_back"), sent = section(result.json, "sent")
        let window = try await fake.mail.outgoing(fake.mail.lastID, process: 4242)
        guard case .found(let open) = window else { return false }
        return result.exitCode == 0 && result.json["result"] as? String == "as_intended" && result.json["mode"] as? String == "read_only"
            && fake.mail.sendCallCount == 0 && fake.mail.sendCount == 0 && result.json["send_events"] as? Int == 0 && result.json["send"] == nil
            && result.json["sent_anything"] as? Bool == false && result.json["draft_window"] as? String == "left_open_unsent"
            && open.to == [FakeSendProbeMail.own] && open.body == MailSendProbe.body && open.subject.hasPrefix("Pippa test ")
            && draft["created"] as? Bool == true && draft["id_present"] as? Bool == true && draft["mail_process_recorded"] as? Bool == true
            && back["has_sender"] as? Bool == true && back["sender_is_account"] as? Bool == true && back["recipients"] as? Int == 1
            && back["recipients_are_own"] as? Bool == true && back["subject_length"] as? Int == open.subject.count
            && back["body_length"] as? Int == MailSendProbe.body.count && back["attachments"] as? Int == 0
            && sent["mailbox"] as? String == "found" && sent["snapshot_read"] as? Bool == true && sent["snapshot_ms"] is Int
            && result.json["account_addresses"] as? Int == 2
    }

    await checkAsync("Mail send probe: --send sends exactly once, to the account's own address, after one card; Sent found, rows done, a second send refused") {
        let fake = FakeSendProbeMail()
        let leaving = LockedBox<[MailOutgoing]>([])
        fake.mail.beforeSend = { id in
            if case .found(let mail)? = try? await fake.mail.outgoing(id, process: 4242) { leaving.mutate { $0.append(mail) } }
        }
        // Looks into Sent: the probe's own snapshot, mail_send's snapshot, then two looks after the send event.
        fake.mail.visibleFrom = 4
        let result = await probe(fake, ["--account", FakeSendProbeMail.accountName, "--send"])
        let send = section(result.json, "send")
        if result.exitCode != 0 { print("  report: \(result.stdout)") }
        return result.exitCode == 0 && result.json["result"] as? String == "as_intended"
            && fake.mail.sendCount == 1 && fake.mail.sendCallCount == 1 && leaving.value.count == 1
            && leaving.value[0].recipients == [FakeSendProbeMail.own] && leaving.value[0].body == MailSendProbe.body
            && send["gate_asked"] as? Bool == true && send["cards"] as? Int == 1 && send["card_fields_non_empty"] as? Bool == true
            && send["card_matched_probe_mail"] as? Bool == true && send["draft_unchanged_before_send"] as? Bool == true
            && send["send_event"] as? String == "sent" && send["found_in_sent"] as? Bool == true && send["found_in_sent_ms"] is Int
            && send["sent_lookups"] as? Int == 2 && send["outcome"] as? String == "done"
            && send["journal_rows"] as? [String: Int] == ["done": 1] && send["second_send_status"] as? String == "already_sent"
            && send["second_send_refused"] as? Bool == true && result.json["send_events"] as? Int == 1
    }

    await checkAsync("Mail send probe: never found in Sent ends unclear with its reason, exit 1, and the second send is still refused") {
        let fake = FakeSendProbeMail()
        fake.mail.visibleFrom = .max
        let result = await probe(fake, ["--account", FakeSendProbeMail.accountName, "--send"])
        let send = section(result.json, "send")
        return result.exitCode == 1 && result.json["result"] as? String == "not_as_intended" && fake.mail.sendCallCount == 1
            && send["outcome"] as? String == "unclear" && send["why"] as? String == "notInSent" && send["found_in_sent"] as? Bool == false
            && send["journal_rows"] as? [String: Int] == ["unclear": 1] && send["second_send_refused"] as? Bool == true
    }

    await checkAsync("Mail send probe: a recipient or sender that is not the account's own is refused before the card; nothing is sent") {
        func refused(_ change: @escaping (inout MailOutgoing) -> Void, sender: String? = nil) async -> (String?, Int, Bool) {
            let fake = FakeSendProbeMail()
            fake.afterInsert = change
            if let sender { fake.sender = sender }
            let result = await probe(fake, ["--account", FakeSendProbeMail.accountName, "--send"])
            return (result.json["refused"] as? String, fake.mail.sendCallCount, result.exitCode == 1 && result.json["send"] == nil)
        }
        let stranger = await refused { $0.to = ["fremd@example.test"] }
        let extraCc = await refused { $0.cc = ["fremd@example.test"] }
        let twoOwn = await refused { $0.to.append("zweite.adresse@example.test") }
        let otherAccount = await refused({ _ in }, sender: "Arbeit <arbeit.person@example.test>")
        let otherText = await refused { $0.body += "\nPS: noch etwas" }
        return stranger.0 == "recipient_not_own" && extraCc.0 == "recipient_not_own" && twoOwn.0 == "recipient_not_own"
            && otherAccount.0 == "sender_not_this_account" && otherText.0 == "draft_not_probe_mail"
            && [stranger, extraCc, twoOwn, otherAccount, otherText].allSatisfy { $0.1 == 0 && $0.2 }
    }

    await checkAsync("Mail send probe: the report holds no address, name, subject or text, in either mode or on refusal") {
        var outputs: [String] = []
        for arguments in [["--read-only"], ["--send"]] {
            let fake = FakeSendProbeMail()
            outputs.append((await probe(fake, ["--account", FakeSendProbeMail.accountName] + arguments)).stdout)
        }
        let refusing = FakeSendProbeMail()
        refusing.afterInsert = { $0.to = ["fremd@example.test"] }
        outputs.append((await probe(refusing, ["--account", FakeSendProbeMail.accountName, "--send"])).stdout)
        let forbidden = ["@", "example.test", "geheim", "Geheim", "Arbeit", "Vertraulich", "Person", "fremd", "Pippa test ", MailSendProbe.body, "acct-"]
        let leaks = forbidden.filter { word in outputs.contains { $0.contains(word) } }
        if !leaks.isEmpty { print("  leaked: \(leaks)") }
        return outputs.count == 3 && outputs.allSatisfy { $0.contains("\"probe\" : \"mail-send-probe\"") } && leaks.isEmpty
    }

    await checkAsync("Mail send probe: a timed-out or unreadable read names the step and the event kind; nothing is sent") {
        let slow = FakeSendProbeMail()
        slow.addressesTimeOut = true
        let addresses = await probe(slow, ["--account", FakeSendProbeMail.accountName, "--send"])
        let unreadable = FakeSendProbeMail()
        unreadable.readBackUnreadable = true
        let back = await probe(unreadable, ["--account", FakeSendProbeMail.accountName, "--send"])
        let first = FakeSendProbeMail()
        first.kindTimeouts.mutate { $0 = 1 }
        let retried = await probe(first, ["--account", FakeSendProbeMail.accountName, "--read-only"])
        let a = section(addresses.json, "error"), b = section(back.json, "error")
        return addresses.exitCode == 1 && a["step"] as? String == "addresses" && a["kind"] as? String == "timeout" && a["event"] as? String == "addresses"
            && back.exitCode == 1 && b["step"] as? String == "read_back" && b["kind"] as? String == "unreadable" && b["event"] as? String == "read_draft"
            && retried.exitCode == 0 && retried.json["first_event_retries"] as? Int == 1
            && slow.mail.sendCallCount == 0 && unreadable.mail.sendCallCount == 0
    }

    check("Mail send probe: its yes is set only on the probe's own host; no server, tool or app code reaches the probe") {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL })
            .filter({ $0.pathExtension == "swift" }) else { return false }
        var mentions: Set<String> = [], setters: Set<String> = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            let relative = String(file.path.dropFirst(sources.path.count + 1))
            if relative.hasPrefix("PippaChecks/") { continue }
            if text.contains("MailSendProbe") { mentions.insert(relative) }
            if relative.hasPrefix("PippaCore/"), text.contains("confirmAction =") { setters.insert(relative) }
        }
        // The probe file, its compile check, the developer command and the flag in main: nothing in MCP or the app's server.
        let allowed: Set<String> = ["PippaCore/Diagnostics/MailSendProbe.swift", "PippaCore/Integrations/IntegrationScripts.swift",
                                    "Pippa/App/MailSendProbeCommand.swift", "Pippa/main.swift"]
        if !mentions.isSubset(of: allowed) || setters != ["PippaCore/Diagnostics/MailSendProbe.swift"] { print("  mentions: \(mentions.sorted()), setters: \(setters.sorted())") }
        return mentions.isSubset(of: allowed) && mentions.contains("Pippa/main.swift") && setters == ["PippaCore/Diagnostics/MailSendProbe.swift"]
            && !PippaMCPTools.toolNames.contains { $0.contains("probe") }
    }
}
