import Foundation
import PiRPC
import PippaCore

/// `mail_folders`, `mail_search` with header-only rows, `mail_move` and `Pippa --mail-move-probe` against a synthetic Mail:
/// accounts, folders and mails live in memory, moves are what the fake does with them. No real Mail, no model.
final class FakeFolderMail: MailMoveProbeMail, @unchecked Sendable {
    struct Stored: Sendable {
        var id: Int
        var messageID: String?
        var subject: String
        var sender: String
        var date: Date?
    }
    private let lock = NSLock()
    private var accountList: [MailAccountInfo]
    private var kinds: [String: (type: String, className: String)] = [:]
    /// account → path → mails.
    private var boxes: [String: [[String]: [Stored]]] = [:]
    private var roles: [String: [[String]: MailFolderRole]] = [:]
    private var order: [String: [[String]]] = [:]
    private var nextID = 50_000
    private(set) var moveCalls: [[MailMoveItem]] = []
    private(set) var duplicateCalls = 0
    private(set) var locateCalls = 0
    /// The folders the probe listed by Message-ID.
    private(set) var listedPaths: [[String]] = []
    /// IMAP: a moved mail shows up in its new folder only after this many lookups of that folder.
    var lagLookups = 0
    /// A moved mail with this Message-ID never shows up anywhere (until `release`).
    var neverArrive: String?
    private var pending: [(account: String, path: [String], mail: Stored, remaining: Int)] = []
    /// The n-th move call (1-based) loses its first mail: gone from the source, never in the target.
    var loseInCall: Int?
    /// Mail gives a moved mail a new id (Exchange).
    var newIDsOnMove = false
    /// Says "moved" but leaves this Message-ID where it was.
    var silentlyKeep: String?
    /// Runs inside each move call, before anything moves (journal on disk? Stop?).
    var onMove: (@Sendable (Int, [MailMoveItem]) async -> Void)?
    /// Every call throws this.
    var failAll: Error?
    /// After the probe's copies: puts a foreign mail into this folder.
    var foreignAfterDuplicate: [String]?
    /// The listing: Mail does not answer in time for the count of these folders (`MailFolderGap.slow`).
    var slowFolders: Set<[String]> = []
    /// The listing: from this many folders on, the count bound is reached (`MailFolderGap.pathOnly`).
    var countBoundAfter: Int?
    /// The listing: mailboxes Mail did not name in time, and listed ones whose subfolders it did not list.
    var unnamedFolders = 0, unexpandedFolders = 0
    /// The probe's test folders: this Apple event ("resolve" or "count") times out.
    var testFolderTimeout: String?
    /// The move Apple event times out without moving anything (Mail may still do it later).
    var moveTimesOut = false
    private(set) var folderCalls = 0

    init(_ accounts: [MailAccountInfo]) { accountList = accounts }

    func add(_ account: String, _ path: [String], role: MailFolderRole? = nil, mails: [Stored] = [], type: String = "imap") {
        lock.withLock {
            if boxes[account]?[path] == nil { order[account, default: []].append(path) }
            boxes[account, default: [:]][path, default: []] += mails
            if let role { roles[account, default: [:]][path] = role }
            kinds[account] = (type, type == "iCloud" ? "iCloud account" : "imap account")
        }
    }
    func edit(_ account: String, _ path: [String], _ change: (inout [Stored]) -> Void) { lock.withLock { change(&boxes[account, default: [:]][path, default: []]) } }
    func mails(_ account: String, _ path: [String]) -> [Stored] { lock.withLock { boxes[account]?[path] ?? [] } }
    func ids(_ account: String, _ path: [String]) -> [String] { mails(account, path).compactMap(\.messageID).sorted() }

    private func fail() throws { if let failAll { throw failAll } }

    // MARK: Reading (MailAccountReading)

    func inboxAccounts() async throws -> [MailAccountInfo] { try fail(); return lock.withLock { accountList } }

    func candidates(account: String, query: String, unread: Bool) async throws -> [MailSearchCandidate] {
        try fail()
        return mails(account, ["INBOX"]).filter { query.isEmpty || $0.subject.contains(query) }.map { MailSearchCandidate(id: $0.id, date: $0.date) }
    }

    func rows(account: String, ids: [Int]) async throws -> [MailSearchRow] {
        try fail()
        let inbox = mails(account, ["INBOX"])
        return ids.compactMap { id in
            inbox.first { $0.id == id }.map {
                MailSearchRow(id: id, date: $0.date, header: MailHeader(subject: $0.subject, sender: $0.sender, date: $0.date, mailbox: "INBOX",
                                                                         preview: "Text \($0.subject)", messageID: $0.messageID),
                              accountID: account, path: ["INBOX"])
            }
        }
    }

    func message(account: String, mailID: Int, messageID: String, path: [String]) async throws -> MailInboxMessage? { nil }

    func folders(account: String, samples: Int) async throws -> MailFolderList {
        try fail()
        return lock.withLock {
            folderCalls += 1
            let folders = (order[account] ?? []).enumerated().map { index, path in
                let list = boxes[account]?[path] ?? []
                if let after = countBoundAfter, index >= after { return MailFolderInfo(path: path, count: nil, role: roles[account]?[path], gap: .pathOnly) }
                if slowFolders.contains(path) { return MailFolderInfo(path: path, count: nil, role: roles[account]?[path], gap: .slow) }
                return MailFolderInfo(path: path, count: list.count, role: roles[account]?[path],
                                      samples: list.prefix(samples).map { MailFolderSample(sender: $0.sender, subject: $0.subject) })
            }
            return MailFolderList(folders: folders, unnamed: unnamedFolders, unexpanded: unexpandedFolders)
        }
    }

    /// Mails still on their way show up now: in their new folder, or in `path` instead.
    func release(into path: [String]? = nil) {
        lock.withLock {
            for entry in pending { boxes[entry.account, default: [:]][path ?? entry.path, default: []].append(entry.mail) }
            pending = []
        }
    }

    func locate(account: String, path: [String], messageIDs: [String]) async throws -> [String: [Int]] {
        try fail()
        return try lock.withLock {
            locateCalls += 1
            var waiting: [(account: String, path: [String], mail: Stored, remaining: Int)] = []
            for var entry in pending {
                guard entry.account == account, entry.path == path else { waiting.append(entry); continue }
                if entry.remaining == 0 { boxes[account, default: [:]][path, default: []].append(entry.mail); continue }
                entry.remaining -= 1
                waiting.append(entry)
            }
            pending = waiting
            guard let list = boxes[account]?[path] else { throw MailMoveProblem.noFolder }
            var out: [String: [Int]] = [:]
            for id in messageIDs { out[id] = list.filter { $0.messageID.flatMap(MailReplySource.canonicalMessageID) == id }.map(\.id) }
            return out
        }
    }

    @discardableResult
    func move(account: String, from: [String], mails: [MailMoveItem], to: [String]) async throws -> [String] {
        try fail()
        let call = lock.withLock { moveCalls.append(mails); return moveCalls.count }
        await onMove?(call, mails)
        if moveTimesOut { throw MailAccountProblem.timeout }
        return try lock.withLock {
            guard boxes[account]?[from] != nil, boxes[account]?[to] != nil else { throw MailMoveProblem.noFolder }
            var statuses: [String] = []
            for (i, item) in mails.enumerated() {
                guard let index = boxes[account]![from]!.firstIndex(where: { $0.id == item.mailID }),
                      boxes[account]![from]![index].messageID == item.messageID else { statuses.append("gone"); continue }
                statuses.append("moved")
                if item.messageID == silentlyKeep { continue }
                var mail = boxes[account]![from]!.remove(at: index)
                if loseInCall == call && i == 0 { continue }
                if newIDsOnMove { nextID += 1; mail.id = nextID }
                if item.messageID == neverArrive { pending.append((account, to, mail, Int.max)) }
                else if lagLookups > 0 { pending.append((account, to, mail, lagLookups)) }
                else { boxes[account]![to]!.append(mail) }
            }
            return statuses
        }
    }

    // MARK: The probe's extra steps

    func accountKinds() async throws -> [MailMoveProbe.AccountKind] {
        try fail()
        return lock.withLock { accountList.map { MailMoveProbe.AccountKind(id: $0.id, name: $0.name, type: kinds[$0.id]?.type ?? "imap", className: kinds[$0.id]?.className ?? "imap account") } }
    }

    func testFolders(account: String) async throws -> [MailMoveProbe.TestFolder] {
        try fail()
        return lock.withLock {
            [MailMoveProbe.folderA, MailMoveProbe.folderB].map { name in
                if let event = testFolderTimeout { return MailMoveProbe.TestFolder(path: [name], count: nil, exists: event == "count", timedOut: event) }
                guard let list = boxes[account]?[[name]] else { return MailMoveProbe.TestFolder(path: [name], count: nil, exists: false) }
                return MailMoveProbe.TestFolder(path: [name], count: list.count)
            }
        }
    }

    func folderTimings(account: String, samples: Int) async throws -> MailMoveProbe.ListingTimings {
        let list = try await folders(account: account, samples: samples)
        let slow = list.folders.filter { $0.gap == .slow }.count
        return MailMoveProbe.ListingTimings(asked: list.folders.count + list.unnamed, listed: list.folders.count, unnamed: list.unnamed,
                                            unexpanded: list.unexpanded, timeouts: ["path": list.unnamed, "count": slow, "sample": 0, "subfolders": list.unexpanded],
                                            slowestMs: slow > 0 ? 5000 : 12, totalMs: 300, countBoundReached: list.folders.contains { $0.gap == .pathOnly },
                                            pathBoundReached: false)
    }

    func makeFolder(account: String, name: String) async throws -> Bool {
        try fail()
        if lock.withLock({ boxes[account]?[[name]] != nil }) { return false }
        add(account, [name])
        return true
    }

    func messageIDs(account: String, path: [String]) async throws -> [String] {
        try fail()
        lock.withLock { listedPaths.append(path) }
        return mails(account, path).map { $0.messageID ?? "" }
    }

    func duplicate(account: String, inboxIDs: [Int], to: [String]) async throws -> [String] {
        try fail()
        let statuses: [String] = lock.withLock {
            duplicateCalls += 1
            return inboxIDs.map { id in
                guard let mail = boxes[account]?[["INBOX"]]?.first(where: { $0.id == id }) else { return "gone" }
                nextID += 1
                var copy = mail; copy.id = nextID
                boxes[account]![to, default: []].append(copy)
                return "copied"
            }
        }
        if let foreign = foreignAfterDuplicate {
            edit(account, foreign) { $0.append(Stored(id: 99_999, messageID: "foreign@x.example", subject: "Fremd", sender: "x@x.example", date: nil)) }
        }
        return statuses
    }
}

/// The settle wait's clock for checks: sleeping only advances it, so a 20 s bound passes in microseconds.
final class FakeSettleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    private(set) var sleeps = 0
    /// Runs at each sleep (Stop during the wait).
    var onSleep: (@Sendable () -> Void)?
    var now: Duration { lock.withLock { time } }
    var settle: MailMoveSettle {
        MailMoveSettle(sleep: { [self] d in lock.withLock { time += d; sleeps += 1 }; onSleep?() }, now: { [self] in now })
    }
}

extension MCPCheckContext {
    func mailMoveChecks() async {
        let privat = MailAccountInfo(id: "ACC-PRIVAT-0001", name: "Privat")
        let arbeit = MailAccountInfo(id: "ACC-ARBEIT-0002", name: "Arbeit")
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func mail(_ n: Int, messageID: String? = nil, prefix: String = "Rechnung") -> FakeFolderMail.Stored {
            FakeFolderMail.Stored(id: n, messageID: messageID ?? "m\(n)@x.example", subject: "\(prefix) \(n)", sender: "Absender \(n) <a\(n)@x.example>",
                                  date: base.addingTimeInterval(Double(n) * 60))
        }
        /// Privat: inbox with `inbox` mails, Rechnungen, Archiv/2025 and the five role folders; Arbeit: inbox and Projekte.
        func fakeMail(inbox: Int = 30) -> FakeFolderMail {
            let fake = FakeFolderMail([privat, arbeit])
            fake.add(privat.id, ["INBOX"], role: .inbox, mails: (1...inbox).map { mail($0) })
            fake.add(privat.id, ["Rechnungen"], mails: [mail(900, prefix: "Alt")])
            fake.add(privat.id, ["Archiv", "2025"])
            fake.add(privat.id, ["Deleted Messages"], role: .trash)
            fake.add(privat.id, ["Junk"], role: .junk)
            fake.add(privat.id, ["Sent Messages"], role: .sent)
            fake.add(privat.id, ["Drafts"], role: .drafts)
            fake.add(privat.id, ["Outbox"])
            fake.add(arbeit.id, ["INBOX"], role: .inbox, mails: [mail(1, messageID: "w1@x.example", prefix: "Projekt")])
            fake.add(arbeit.id, ["Projekte"])
            return fake
        }
        struct World {
            let tools: PippaMCPTools
            let host: PippaMCPHost
            let turn: PippaMCPTurn
            let journal: Executor
            let demo: DemoIntegrations
            let clock: FakeSettleClock
        }
        func world(_ fake: FakeFolderMail) throws -> World {
            let demo = DemoIntegrations(granted: true)
            var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                                    askForAccess: false, now: { now }, calendar: berlin)
            host.mailAccounts = fake
            let clock = FakeSettleClock()
            host.mailMoveSettle = clock.settle
            host.turns = PippaMCPTurns()
            host.mailFiles = dir("mail-move-\(UUID().uuidString)")
            let journal = try Executor(baseDirectory: root.appendingPathComponent("mail-move-journal-\(UUID().uuidString)"))
            host.reminderJournal = journal
            host.requiresReminderJournal = true
            let turn = PippaMCPTurn()
            host.turns.begin(turn)
            return World(tools: PippaMCPTools(host: host), host: host, turn: turn, journal: journal, demo: demo, clock: clock)
        }
        func data(_ r: (json: [String: Any], isError: Bool, bytes: Int)) -> [String: Any] { r.json["data"] as? [String: Any] ?? [:] }
        /// The mail_refs of the inbox, newest first, from one header-only search.
        func refs(_ w: World, account: String = "Privat", limit: Int = 100) async -> [String] {
            let r = await call(w.tools, "mail_search", ["account": account, "limit": limit])
            return (data(r)["mails"] as? [[String: Any]] ?? []).compactMap { $0["mail_ref"] as? String }
        }

        // MARK: A1 mail_folders

        await checkAsync("mail_folders: the tree per account with counts, roles and two samples from the reader") {
            let w = try world(fakeMail())
            let r = await call(w.tools, "mail_folders")
            let accounts = data(r)["accounts"] as? [[String: Any]] ?? []
            let privatFolders = accounts.first { $0["account"] as? String == "Privat" }?["folders"] as? [[String: Any]] ?? []
            let inbox = privatFolders.first { $0["path"] as? String == "INBOX" }
            let samples = inbox?["samples"] as? [[String: Any]] ?? []
            let one = await call(w.tools, "mail_folders", ["account": "Arbeit"])
            let oneAccounts = data(one)["accounts"] as? [[String: Any]] ?? []
            return !r.isError && accounts.count == 2 && privatFolders.map { $0["path"] as? String ?? "" }.contains("Archiv/2025")
                && inbox?["count"] as? Int == 30 && inbox?["role"] as? String == "inbox" && samples.count == 2
                && samples[0]["subject"] as? String == "Rechnung 1" && samples[0]["from"] as? String != nil
                && privatFolders.first { $0["path"] as? String == "Outbox" }?["role"] as? String == "outbox"
                && privatFolders.first { $0["path"] as? String == "Deleted Messages" }?["role"] as? String == "trash"
                && r.json["untrusted"] as? Bool == true && oneAccounts.count == 1 && oneAccounts[0]["account"] as? String == "Arbeit"
        }
        await checkAsync("mail_folders: 200 folders stay under the byte cap: samples go first, then folders, and the result says what is left out") {
            let fake = FakeFolderMail([privat])
            for n in 1...200 {
                fake.add(privat.id, ["Projekte", "Kunde \(n) mit einem längeren Namen"], mails: [mail(n, prefix: "Angebot für Kunde \(n) mit Anhang"), mail(n + 1000)])
            }
            let w = try world(fake)
            let r = await call(w.tools, "mail_folders")
            let folders = (data(r)["accounts"] as? [[String: Any]])?.first?["folders"] as? [[String: Any]] ?? []
            let omitted = data(r)["folders_omitted"] as? Int ?? 0
            let samplesOmitted = data(r)["samples_omitted"] as? Int ?? 0
            let next = r.json["next"] as? String ?? ""
            return !r.isError && r.bytes <= PippaMCPTools.maxResultBytes && samplesOmitted > 0 && folders.count + omitted == 200
                && data(r)["folders"] as? Int == 200 && next.contains("Samples are left out")
                && (omitted == 0 || next.contains("\(omitted) folders at the end are left out"))
                && folders.allSatisfy { $0["count"] as? Int == 2 }
        }

        await checkAsync("mail_folders: one folder Mail does not answer for in time is listed without count or samples, the others are complete, and the result names the gap") {
            let fake = fakeMail()
            fake.slowFolders = [["Rechnungen"]]
            let w = try world(fake)
            let r = await call(w.tools, "mail_folders", ["account": "Privat"])
            let folders = (data(r)["accounts"] as? [[String: Any]])?.first?["folders"] as? [[String: Any]] ?? []
            let slow = folders.first { $0["path"] as? String == "Rechnungen" }
            let others = folders.filter { $0["path"] as? String != "Rechnungen" }
            let next = r.json["next"] as? String ?? ""
            return !r.isError && folders.count == 8 && slow?["count"] == nil && slow?["samples"] == nil && slow?["incomplete"] as? String == "slow"
                && others.allSatisfy { $0["count"] is Int && $0["incomplete"] == nil }
                && others.first { $0["path"] as? String == "INBOX" }?["samples"] as? [[String: Any]] != nil
                && data(r)["folders_incomplete"] as? Int == 1 && next.contains("Counts and samples are missing for 1 folders")
                && next.contains("Never say such a folder is empty") && !next.contains("did not list every folder")
        }
        await checkAsync("mail_folders: past the listing's count bound the rest has paths only; mailboxes Mail did not name are counted, never silent") {
            let fake = fakeMail()
            fake.countBoundAfter = 3
            fake.unnamedFolders = 2
            fake.unexpandedFolders = 1
            let w = try world(fake)
            let r = await call(w.tools, "mail_folders", ["account": "Privat"])
            let account = (data(r)["accounts"] as? [[String: Any]])?.first ?? [:]
            let folders = account["folders"] as? [[String: Any]] ?? []
            let next = r.json["next"] as? String ?? ""
            return !r.isError && folders.count == 8 && folders.prefix(3).allSatisfy { $0["count"] is Int && $0["incomplete"] == nil }
                && folders.dropFirst(3).allSatisfy { $0["count"] == nil && $0["samples"] == nil && $0["incomplete"] as? String == "path_only" && $0["path"] is String }
                && folders.contains { $0["path"] as? String == "Deleted Messages" && $0["role"] as? String == "trash" }
                && account["folders_not_listed"] as? Int == 2 && account["subfolders_not_listed"] as? Int == 1
                && data(r)["folders_incomplete"] as? Int == 5 && next.contains("ran out of time before 5 more were counted")
                && next.contains("Mail did not list every folder in time") && next.contains("Never say a folder does not exist")
        }
        await checkAsync("mail_folders: Mail's answer with gaps parses strictly: slow and path-only folders lose count and samples, unnamed ones are counted") {
            func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
                let l = NSAppleEventDescriptor.list()
                for (i, item) in items.enumerated() { l.insert(item, at: i + 1) }
                return l
            }
            func text(_ s: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: s) }
            func int(_ n: Int) -> NSAppleEventDescriptor { NSAppleEventDescriptor(int32: Int32(n)) }
            func folder(_ path: [String], _ count: Int, gap: String) -> NSAppleEventDescriptor {
                list([list(path.map(text)), int(count), text(""), list([list([text("a@x.example"), text("Hallo")])]), text(gap)])
            }
            let payload = list([list([folder(["INBOX"], 3, gap: ""), folder(["Archiv", "2025"], 7, gap: "slow"), folder(["Neu"], -1, gap: "path_only")]), int(2), int(1)])
            let parsed = try MailMoveParse.folders(payload)
            let wrongGap = (try? MailMoveParse.folders(list([list([folder(["INBOX"], 3, gap: "later")]), int(0), int(0)]))) == nil
            let oldShape = (try? MailMoveParse.folders(list([folder(["INBOX"], 3, gap: "")]))) == nil
            return parsed.folders.map(\.path) == [["INBOX"], ["Archiv", "2025"], ["Neu"]] && parsed.folders[0].count == 3 && parsed.folders[0].samples.count == 1
                && parsed.folders[1].count == nil && parsed.folders[1].samples.isEmpty && parsed.folders[1].gap == .slow
                && parsed.folders[2].count == nil && parsed.folders[2].gap == .pathOnly && parsed.unnamed == 2 && parsed.unexpanded == 1
                && !parsed.allListed && wrongGap && oldShape
        }

        // MARK: A2 mail_search with limit 100

        await checkAsync("mail_search: limit 100 returns header-only rows (ref, sender, subject, date) as many as fit, with a cursor") {
            let fake = fakeMail(inbox: 150)
            let w = try world(fake)
            let r = await call(w.tools, "mail_search", ["account": "Privat", "limit": 100])
            let rows = data(r)["mails"] as? [[String: Any]] ?? []
            let keys = Set(rows.flatMap(\.keys))
            let cursor = data(r)["cursor"] as? String
            let next = cursor.map { _ in () }
            var all = rows.count
            if let cursor {
                let more = await call(w.tools, "mail_search", ["cursor": cursor, "limit": 100])
                all += (data(more)["mails"] as? [[String: Any]] ?? []).count
            }
            let twenty = await call(try world(fakeMail(inbox: 150)).tools, "mail_search", ["account": "Privat", "limit": 20])
            let twentyKeys = Set((data(twenty)["mails"] as? [[String: Any]] ?? []).flatMap(\.keys))
            let over = await call(w.tools, "mail_search", ["limit": 101])
            return !r.isError && r.bytes <= PippaMCPTools.maxResultBytes && rows.count > 20 && rows.count < 100 && next != nil
                && keys == ["mail_ref", "from", "subject", "date"] && data(r)["read_depth"] as? String == "header_only"
                && rows.allSatisfy { $0["mail_ref"] is String } && all == 100
                && twentyKeys.isSuperset(of: ["start", "unread", "mailbox"]) && data(twenty)["read_depth"] as? String == "header_and_start"
                && over.json["status"] as? String == "invalid_arguments"
        }

        // MARK: A3 dry run and plan

        await checkAsync("mail_move: a dry run moves nothing, counts per folder and gives a plan; the plan moves exactly those mails") {
            let fake = fakeMail()
            let w = try world(fake)
            let picked = Array(await refs(w).prefix(25))
            let dry = await call(w.tools, "mail_move", ["refs": picked, "to": "Rechnungen", "dry_run": true])
            let plan = data(dry)["plan"] as? String ?? ""
            let unmoved = fake.moveCalls.isEmpty && fake.mails(privat.id, ["INBOX"]).count == 30 && fake.mails(privat.id, ["Rechnungen"]).count == 1
            let moves = data(dry)["moves"] as? [String: Int]
            let applied = await call(w.tools, "mail_move", ["plan": plan])
            let moved = Set(fake.ids(privat.id, ["Rechnungen"])), expected = Set((6...30).map { "m\($0)@x.example" } + ["m900@x.example"])
            return !dry.isError && dry.json["done"] as? Bool == true && dry.json["dry_run"] as? Bool == true && unmoved
                && moves == ["Rechnungen": 25] && data(dry)["moved"] as? Int == 0 && plan.count == 13 && plan.hasPrefix("p")
                && !applied.isError && data(applied)["verified"] as? String == "25 of 25" && moved == expected
                && fake.mails(privat.id, ["INBOX"]).count == 5
        }
        await checkAsync("mail_move: a used plan, a made-up plan and a plan from another answer are refused; nothing moves") {
            let fake = fakeMail()
            let w = try world(fake)
            let picked = Array(await refs(w).prefix(5))
            let plan = data(await call(w.tools, "mail_move", ["refs": picked, "to": "Rechnungen", "dry_run": true]))["plan"] as? String ?? ""
            _ = await call(w.tools, "mail_move", ["plan": plan])
            let calls = fake.moveCalls.count
            let again = await call(w.tools, "mail_move", ["plan": plan])
            let made = await call(w.tools, "mail_move", ["plan": "p000000000000"])
            let other = data(await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(3)), "to": "Rechnungen", "dry_run": true]))["plan"] as? String ?? ""
            w.host.turns.begin(PippaMCPTurn())
            let later = await call(w.tools, "mail_move", ["plan": other])
            let mixed = await call(w.tools, "mail_move", ["plan": other, "to": "Rechnungen"])
            return again.isError && again.json["status"] as? String == "stale_plan" && made.json["status"] as? String == "stale_plan"
                && later.json["status"] as? String == "stale_plan" && mixed.json["status"] as? String == "invalid_arguments"
                && fake.moveCalls.count == calls && fake.mails(privat.id, ["INBOX"]).count == 25
        }

        // MARK: A4 more than 20 without a plan

        await checkAsync("mail_move: more than 20 refs without a plan are refused with a sentence that says how to go on") {
            let fake = fakeMail()
            let w = try world(fake)
            let picked = Array(await refs(w).prefix(21))
            let r = await call(w.tools, "mail_move", ["refs": picked, "to": "Rechnungen"])
            let error = r.json["error"] as? String ?? ""
            let twenty = await call(w.tools, "mail_move", ["refs": Array(picked.prefix(20)), "to": "Archiv/2025"])
            return r.isError && r.json["status"] as? String == "plan_required" && r.json["dispatched"] as? Bool == false
                && error.contains("dry_run true") && error.contains("only the plan") && fake.moveCalls.count == 2
                && data(twenty)["verified"] as? String == "20 of 20"
        }

        // MARK: A5 batches and verification

        await checkAsync("mail_move: batches of 10, each checked by Message-ID; verified n of m comes from the read-back, not from Mail's answer") {
            let fake = fakeMail()
            fake.silentlyKeep = "m10@x.example"
            let w = try world(fake)
            let plan = data(await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(25)), "to": "Rechnungen", "dry_run": true]))["plan"] as? String ?? ""
            let r = await call(w.tools, "mail_move", ["plan": plan])
            return fake.moveCalls.map(\.count) == [10, 10, 5] && data(r)["verified"] as? String == "24 of 25" && data(r)["moved"] as? Int == 24
                && data(r)["not_moved"] as? Int == 1 && r.json["done"] as? Bool == true
                && fake.ids(privat.id, ["INBOX"]).contains("m10@x.example")
        }

        // MARK: A6 outside the happy path

        await checkAsync("mail_move: a mail lost in batch 2 makes it unclear, batch 3 never starts, batch 1 stays done, and the result says not to retry") {
            let fake = fakeMail()
            fake.loseInCall = 2
            let w = try world(fake)
            let plan = data(await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(25)), "to": "Rechnungen", "dry_run": true]))["plan"] as? String ?? ""
            let r = await call(w.tools, "mail_move", ["plan": plan])
            let rows = try await w.journal.runActions(run: w.turn.id)
            let states = Dictionary(grouping: rows, by: \.state).mapValues(\.count)
            let next = r.json["next"] as? String ?? "", tell = r.json["tell"] as? String ?? ""
            return fake.moveCalls.count == 2 && r.json["state"] as? String == "unclear" && data(r)["unclear_batch"] as? Int == 2
                && data(r)["unclear"] as? Int == 1 && data(r)["moved"] as? Int == 19 && data(r)["not_started"] as? Int == 5
                && states == [.done: 19, .unclear: 1] && next.contains("do not retry") && tell.contains("Mail")
                && fake.mails(privat.id, ["Rechnungen"]).count == 20
        }
        await checkAsync("mail_move: Mail giving moved mails new ids (Exchange) still verifies by Message-ID") {
            let fake = fakeMail()
            fake.newIDsOnMove = true
            let w = try world(fake)
            let r = await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(15)), "to": "Rechnungen"])
            let ids = Set(fake.mails(privat.id, ["Rechnungen"]).map(\.id))
            return data(r)["verified"] as? String == "15 of 15" && ids.allSatisfy { $0 > 50_000 || $0 == 900 }
        }
        await checkAsync("mail_move: Stop between batches starts no further batch; the moved ones stay done") {
            let fake = fakeMail()
            let w = try world(fake)
            let turn = w.turn
            fake.onMove = { call, _ in if call == 1 { turn.cancelWrites() } }
            let plan = data(await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(25)), "to": "Rechnungen", "dry_run": true]))["plan"] as? String ?? ""
            let r = await call(w.tools, "mail_move", ["plan": plan])
            let rows = try await w.journal.runActions(run: w.turn.id)
            return fake.moveCalls.count == 1 && data(r)["moved"] as? Int == 10 && data(r)["not_started"] as? Int == 15
                && r.json["complete"] as? Bool == false && rows.count == 10 && rows.allSatisfy { $0.state == .done && $0.verified == true }
        }
        await checkAsync("mail_move: Mail not open or access denied moves nothing and says the existing sentences") {
            // Refs come from a search before Mail was closed or access was taken away.
            let open = fakeMail()
            let o = try world(open)
            let someRefs = Array(await refs(o).prefix(3))
            open.failAll = PippaError.appNotOpen("Mail")
            let closed = await call(o.tools, "mail_move", ["refs": someRefs, "to": "Rechnungen"])
            let denied = fakeMail()
            let d = try world(denied)
            let deniedRefs = Array(await refs(d).prefix(3))
            d.demo.set(.mail, .denied)
            let refused = await call(d.tools, "mail_move", ["refs": deniedRefs, "to": "Rechnungen"])
            let deniedFolders = await call(d.tools, "mail_folders")
            return closed.isError && closed.json["tell"] as? String == L("Open %@ first. Then ask again.", table: "MCP", "Mail")
                && refused.isError && refused.json["status"] as? String == "denied" && refused.json["tell"] as? String == PippaMCPTools.denied(.mail)
                && open.moveCalls.isEmpty && denied.moveCalls.isEmpty && denied.mails(privat.id, ["INBOX"]).count == 30
                && deniedFolders.json["tell"] as? String == PippaMCPTools.denied(.mail)
        }
        await checkAsync("mail_move: access denied after the refs were given moves nothing and says the existing sentence") {
            let fake = fakeMail()
            let w = try world(fake)
            let someRefs = Array(await refs(w).prefix(3))
            fake.failAll = PippaError.accessDenied("Mail")
            let r = await call(w.tools, "mail_move", ["refs": someRefs, "to": "Rechnungen"])
            return r.isError && r.json["status"] as? String == "denied" && r.json["tell"] as? String == PippaMCPTools.denied(.mail)
                && fake.moveCalls.isEmpty
        }

        // MARK: A7 journal and Undo

        await checkAsync("mail_move journal: one row per moved mail, dispatched on disk before Mail is asked; Undo moves back only what is still there; a second Undo does nothing") {
            let fake = fakeMail()
            let w = try world(fake)
            let run = w.turn.id, journal = w.journal
            let seen = LockedBox<[Bool]>([])
            fake.onMove = { _, items in
                let rows = (try? await journal.runActions(run: run)) ?? []
                let ids = Set(items.map(\.messageID))
                let batch = rows.filter { ids.contains($0.object.fields["messageID"] ?? "") }
                seen.mutate { $0.append(batch.count == items.count && batch.allSatisfy { $0.state == .dispatched }) }
            }
            let plan = data(await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(25)), "to": "Rechnungen", "dry_run": true]))["plan"] as? String ?? ""
            _ = await call(w.tools, "mail_move", ["plan": plan])
            let rows = try await journal.runActions(run: run)
            let summary = await w.host.runSummaries([run])[run]
            fake.onMove = nil
            // The person moves two mails on to another folder before pressing Undo: those stay.
            fake.edit(privat.id, ["Rechnungen"]) { $0.removeAll { ["m30@x.example", "m29@x.example"].contains($0.messageID ?? "") } }
            fake.edit(privat.id, ["Archiv", "2025"]) { $0.append(mail(29)); $0.append(mail(30)) }
            let report = try await w.host.undoRun(run)
            let second = try await w.host.undoRun(run)
            let inbox = fake.ids(privat.id, ["INBOX"])
            return seen.value == [true, true, true] && rows.count == 25 && rows.allSatisfy { $0.state == .done && $0.tool == "mail_move" && $0.actionClass == .undoable }
                && rows.allSatisfy { $0.before == ["mailbox": "INBOX"] && $0.after == ["mailbox": "Rechnungen"] }
                && summary == RunSummary(run: run, changes: 25, checked: 25, undoable: 25, mailMoves: 25)
                && report.undone.count == 23 && report.left.count == 2 && report.failed.isEmpty
                && second.undone.isEmpty && second.left.isEmpty && second.failed.isEmpty
                && inbox.count == 28 && !inbox.contains("m30@x.example") && fake.ids(privat.id, ["Rechnungen"]) == ["m900@x.example"]
        }

        // MARK: A7b settling (IMAP shows moved mails a moment later)

        await checkAsync("mail_move settle: moved mails that show up in the target only after 3 lookups verify n of n; the wait polls, never moves again") {
            let fake = fakeMail()
            fake.lagLookups = 3
            let w = try world(fake)
            let r = await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(15)), "to": "Rechnungen"])
            let rows = try await w.journal.runActions(run: w.turn.id)
            return data(r)["verified"] as? String == "15 of 15" && r.json["done"] as? Bool == true && data(r)["unclear"] == nil
                && fake.moveCalls.map(\.count) == [10, 5] && rows.count == 15 && rows.allSatisfy { $0.state == .done }
                && w.clock.sleeps == 6 && w.clock.now == .seconds(6) && fake.mails(privat.id, ["Rechnungen"]).count == 16
        }
        await checkAsync("mail_move settle: a moved mail that never shows up is unclear after the 20 s bound, the rest of the batch verified") {
            let fake = fakeMail()
            fake.lagLookups = 2
            fake.neverArrive = "m28@x.example"
            let w = try world(fake)
            let started = ContinuousClock.now
            let r = await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(5)), "to": "Rechnungen"])
            let took = ContinuousClock.now - started
            let rows = try await w.journal.runActions(run: w.turn.id)
            let states = Dictionary(grouping: rows, by: \.state).mapValues(\.count)
            return r.json["state"] as? String == "unclear" && data(r)["unclear"] as? Int == 1 && data(r)["moved"] as? Int == 4
                && states == [.done: 4, .unclear: 1] && fake.moveCalls.count == 1
                && w.clock.now == MailMoveSettle.bound && w.clock.sleeps == 20 && took < .seconds(5)
        }
        await checkAsync("mail_move settle: Stop during the wait ends it at once; what is missing then is unclear, never moved again") {
            let fake = fakeMail()
            fake.lagLookups = 5
            let w = try world(fake)
            let turn = w.turn
            w.clock.onSleep = { turn.cancelWrites() }
            let r = await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(5)), "to": "Rechnungen"])
            return r.json["state"] as? String == "unclear" && data(r)["unclear"] as? Int == 5 && w.clock.sleeps == 1
                // Dry run, the batch's fresh lookup, and the one read-back before Stop ended the wait (2 locates each).
                && fake.moveCalls.count == 1 && fake.locateCalls == 2 + 2 + 2
        }
        await checkAsync("mail_move Undo: 12 mails in two folders go back in one batch per folder, with settling, in a bounded number of Mail calls") {
            let fake = fakeMail()
            let w = try world(fake)
            let picked = await refs(w)
            _ = await call(w.tools, "mail_move", ["refs": Array(picked.prefix(6)), "to": "Rechnungen"])
            _ = await call(w.tools, "mail_move", ["refs": Array(picked.dropFirst(6).prefix(6)), "to": "Archiv/2025"])
            fake.lagLookups = 2
            let moves = fake.moveCalls.count, lookups = fake.locateCalls, waited = w.clock.now
            let report = try await w.host.undoRun(w.turn.id)
            let undoMoves = Array(fake.moveCalls.dropFirst(moves))
            // Per batch: one lookup before (2 locates), one move, and 3 polls of the read-back (6 locates).
            return report.undone.count == 12 && report.left.isEmpty && report.failed.isEmpty
                && undoMoves.map(\.count) == [6, 6] && fake.locateCalls - lookups == 2 * (2 + 6)
                && w.clock.now - waited == .seconds(4) && fake.mails(privat.id, ["INBOX"]).count == 30
                && fake.mails(privat.id, ["Archiv", "2025"]).isEmpty
        }
        await checkAsync("mail_move Undo: a mail not in the target after the bound is left, not failed; Mail's error on the move back is failed") {
            let fake = fakeMail()
            let w = try world(fake)
            _ = await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(4)), "to": "Rechnungen"])
            fake.edit(privat.id, ["Rechnungen"]) { $0.removeAll { $0.messageID == "m30@x.example" } }
            let report = try await w.host.undoRun(w.turn.id)
            let failing = fakeMail()
            let f = try world(failing)
            _ = await call(f.tools, "mail_move", ["refs": Array(await refs(f).prefix(3)), "to": "Rechnungen"])
            failing.onMove = { _, _ in failing.failAll = MailAccountProblem.timeout }
            let failed = try await f.host.undoRun(f.turn.id)
            return report.undone.count == 3 && report.left.count == 1 && report.failed.isEmpty
                && report.left.first?.object.fields["messageID"] == "m30@x.example"
                && failed.failed.count == 3 && failed.undone.isEmpty && failed.left.isEmpty
        }
        await checkAsync("mail_move Undo: a row the move left unclear is looked at once more: in the target it goes back, in the source nothing is undone") {
            func unclearRun(_ into: [String]?) async throws -> (RunUndoReport, [RunAction], FakeFolderMail) {
                let fake = fakeMail()
                fake.neverArrive = "m28@x.example"
                let w = try world(fake)
                _ = await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(5)), "to": "Rechnungen"])
                fake.neverArrive = nil
                fake.release(into: into)
                let report = try await w.host.undoRun(w.turn.id)
                return (report, try await w.journal.runActions(run: w.turn.id), fake)
            }
            let (late, lateRows, lateFake) = try await unclearRun(nil)
            let (back, backRows, backFake) = try await unclearRun(["INBOX"])
            let untouched = backRows.first { $0.object.fields["messageID"] == "m28@x.example" }
            return late.undone.count == 5 && late.left.isEmpty && late.failed.isEmpty && lateRows.allSatisfy { $0.state == .undone }
                && lateFake.mails(privat.id, ["INBOX"]).count == 30
                && back.undone.count == 4 && back.left.isEmpty && back.failed.isEmpty
                && untouched?.state == .undone && untouched?.note == "not_moved" && backFake.mails(privat.id, ["INBOX"]).count == 30
                && backFake.moveCalls.last?.count == 4
        }

        // MARK: A8 refusals and skips

        await checkAsync("mail_move: unknown folder, another account's folder, two accounts' refs and an old search's ref are refused before anything moves") {
            let fake = fakeMail()
            let w = try world(fake)
            let mine = Array(await refs(w).prefix(2))
            let unknown = await call(w.tools, "mail_move", ["refs": mine, "to": "Steuer"])
            let foreign = await call(w.tools, "mail_move", ["refs": mine, "to": "Projekte"])
            let all = await call(w.tools, "mail_search", ["limit": 40])
            let rows = data(all)["mails"] as? [[String: Any]] ?? []
            let both = [rows.first { $0["account"] as? String == "Arbeit" }?["mail_ref"] as? String, rows.first { $0["account"] as? String == "Privat" }?["mail_ref"] as? String].compactMap { $0 }
            let mixed = await call(w.tools, "mail_move", ["refs": both, "to": "Rechnungen"])
            w.host.turns.begin(PippaMCPTurn())
            let old = await call(w.tools, "mail_move", ["refs": mine, "to": "Rechnungen", "dry_run": true])
            return unknown.json["status"] as? String == "unknown_folder" && foreign.json["status"] as? String == "cross_account"
                && both.count == 2 && mixed.json["status"] as? String == "cross_account" && old.json["status"] as? String == "stale_ref"
                && [unknown, foreign, mixed, old].allSatisfy { $0.isError && $0.json["dispatched"] as? Bool == false } && fake.moveCalls.isEmpty
        }
        await checkAsync("mail_move: when Mail did not list every folder in time, only an exact path is a target; a near match is refused, nothing moves") {
            let fake = fakeMail()
            fake.unnamedFolders = 1
            let w = try world(fake)
            let mine = Array(await refs(w).prefix(2))
            let near = await call(w.tools, "mail_move", ["refs": mine, "to": "rechnungen"])
            let missing = await call(w.tools, "mail_move", ["refs": mine, "to": "Steuer"])
            let nothing = fake.moveCalls.isEmpty
            let exact = await call(w.tools, "mail_move", ["refs": mine, "to": "Rechnungen"])
            return near.json["status"] as? String == "folders_incomplete" && missing.json["status"] as? String == "folders_incomplete"
                && near.isError && near.json["dispatched"] as? Bool == false && nothing && data(exact)["verified"] as? String == "2 of 2"
        }
        await checkAsync("mail_move: a move Mail times out on is unclear, never not moved: rows stay for undo, and the read-back waits for every mail of the batch") {
            let fake = fakeMail()
            fake.moveTimesOut = true
            let w = try world(fake)
            let r = await call(w.tools, "mail_move", ["refs": Array(await refs(w).prefix(3)), "to": "Rechnungen"])
            let rows = try await w.journal.runActions(run: w.turn.id)
            let states = Dictionary(grouping: rows, by: \.state).mapValues(\.count)
            return r.json["state"] as? String == "unclear" && data(r)["unclear"] as? Int == 3 && (data(r)["not_moved"] as? Int ?? 0) == 0
                && states == [.unclear: 3] && fake.moveCalls.count == 1 && w.clock.sleeps > 0 && fake.ids(privat.id, ["INBOX"]).count == 30
        }
        await checkAsync("mail_move: Trash, Junk, Sent, Drafts and Outbox are never targets") {
            let fake = fakeMail()
            let w = try world(fake)
            let mine = Array(await refs(w).prefix(2))
            var statuses: [String] = []
            for target in ["Deleted Messages", "Junk", "Sent Messages", "Drafts", "Outbox"] {
                statuses.append((await call(w.tools, "mail_move", ["refs": mine, "to": target, "dry_run": true])).json["status"] as? String ?? "")
            }
            return statuses == Array(repeating: "target_not_allowed", count: 5) && fake.moveCalls.isEmpty
        }
        await checkAsync("mail_move: a Message-ID twice in the inbox, a mail already in the target and a mail without Message-ID are skipped and reported") {
            let fake = fakeMail()
            fake.edit(privat.id, ["INBOX"]) { $0.append(mail(31, messageID: "m1@x.example")) }
            fake.edit(privat.id, ["Rechnungen"]) { $0.append(mail(70, messageID: "m2@x.example")) }
            let w = try world(fake)
            let all = await call(w.tools, "mail_search", ["account": "Privat", "limit": 100])
            let rows = data(all)["mails"] as? [[String: Any]] ?? []
            let wanted = rows.filter { ["Rechnung 1", "Rechnung 2", "Rechnung 3", "Rechnung 31"].contains($0["subject"] as? String ?? "") }.compactMap { $0["mail_ref"] as? String }
            let dry = await call(w.tools, "mail_move", ["refs": wanted, "to": "Rechnungen", "dry_run": true])
            let r = await call(w.tools, "mail_move", ["refs": wanted, "to": "Rechnungen"])
            let plan = try await MailMover(reader: fake).plan(account: privat, label: "Privat", source: ["INBOX"], target: ["Rechnungen"],
                                                              messageIDs: [nil, "kein-message-id", "m3@x.example"])
            return wanted.count == 4 && data(dry)["skipped"] as? [String: Int] == ["duplicate": 1, "already_in_target": 1]
                && data(dry)["moves"] as? [String: Int] == ["Rechnungen": 1] && data(r)["verified"] as? String == "1 of 1"
                && data(r)["skipped"] as? [String: Int] == ["duplicate": 1, "already_in_target": 1]
                && plan.skipped == ["no_message_id": 2] && plan.entries.isEmpty && plan.notFound == 1
                && fake.ids(privat.id, ["INBOX"]).filter { $0 == "m1@x.example" }.count == 2
        }

        // MARK: A9 wiring

        await checkAsync("mail_folders and mail_move: classes, listing, native readiness and receipts know both tools") {
            let listed = Dictionary(uniqueKeysWithValues: PippaMCPTools.toolList().compactMap { tool in (tool["name"] as? String).map { ($0, tool) } })
            func hints(_ name: String) -> [String: Any] { listed[name]?["annotations"] as? [String: Any] ?? [:] }
            let native = Set(listed.keys.map { "mcp__pippa__" + $0 })
            func outcome(_ value: [String: Any], isError: Bool) -> PiActionRecord.Outcome {
                PiTurnReceipt.classify(tool: "mcp__pippa__mail_move", isError: isError,
                                       result: ["content": [["type": "text", "text": String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)]]])
            }
            return PippaActionClasses.of("mail_folders") == .read && PippaActionClasses.of("mail_move") == .undoable
                && hints("mail_folders")["readOnlyHint"] as? Bool == true && hints("mail_move")["readOnlyHint"] as? Bool == false
                && hints("mail_move")["destructiveHint"] as? Bool == false && Set(PiNativeReadiness.tools) == native
                && outcome(["done": true, "dispatched": true, "data": [:]], isError: false) == .done
                && outcome(["done": false, "status": "plan_required", "dispatched": false], isError: true) == .blocked
                && outcome(["done": false, "state": "unclear"], isError: false) == .unclear
        }
        await checkAsync("mail_folders and mail_move: an online AI without Mac access can neither list nor call them") {
            let fake = fakeMail()
            var host = try world(fake).host
            host.egress = PippaMCPEgress(rules: SourceSharing(), web: false)
            let tools = PippaMCPTools(host: host)
            let list = await rpc(tools, "tools/list")
            let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let folders = await call(tools, "mail_folders")
            let move = await call(tools, "mail_move", ["refs": ["m000000000000"], "to": "Rechnungen"])
            return !names.contains("mail_folders") && !names.contains("mail_move") && !names.isEmpty
                && folders.json["status"] as? String == "stays_on_mac" && move.json["status"] as? String == "stays_on_mac" && fake.moveCalls.isEmpty
        }

        // MARK: A11 scripts compile, never run

        await checkAsync("Mail folder, Message-ID lookup and move scripts compile without running") {
            let result = await MainActor.run { IntegrationScripts.compileAll() }
            return result["MailMove"] == true && result["MailAccounts"] == true && result["MailMoveDiagnose"] == true
        }

        // MARK: A12 the probe

        await checkAsync("Mail move probe: --help and wrong arguments print usage without touching Mail; no --account lists accounts and types") {
            let made = LockedBox(0)
            let fake = fakeMail()
            func run(_ arguments: [String]) async -> (exitCode: Int32, stdout: String, stderr: String) {
                await MailMoveProbe.execute(arguments, mail: { made.mutate { $0 += 1 }; return fake }, pause: {})
            }
            let help = await run(["--mail-move-probe", "--help"])
            let wrong = await run(["--mail-move-probe", "--acount", "Privat"])
            let twice = await run(["--mail-move-probe", "--account", "A", "--account", "B"])
            let empty = await run(["--mail-move-probe", "--account"])
            let lonely = await run(["--mail-move-probe", "--diagnose"])
            let untouched = made.value == 0
            let list = await run(["--mail-move-probe"])
            let listed = (try? JSONSerialization.jsonObject(with: Data(list.stdout.utf8))) as? [String: Any]
            let accounts = listed?["accounts"] as? [[String: Any]] ?? []
            return help.exitCode == 0 && help.stdout.contains("usage: Pippa --mail-move-probe") && wrong.exitCode == 2 && wrong.stderr.contains("usage:")
                && twice.exitCode == 2 && empty.exitCode == 2 && lonely.exitCode == 2 && lonely.stderr.contains("--diagnose needs --account")
                && help.stdout.contains("--diagnose") && untouched && list.exitCode == 0
                && accounts.map { $0["name"] as? String ?? "" } == ["Privat", "Arbeit"] && accounts.allSatisfy { $0["type"] as? String == "imap" }
        }
        await checkAsync("Mail move probe: copies the oldest inbox mails into A, moves them to B as mail_move does, undoes and checks they are back; JSON without personal data") {
            let fake = fakeMail()
            fake.newIDsOnMove = true
            let inboxBefore = fake.ids(privat.id, ["INBOX"])
            let result = await MailMoveProbe.execute(["--mail-move-probe", "--account", "privat"], mail: { fake }, journalDirectory: dir("probe-\(UUID().uuidString)"),
                                                     pause: {}, settle: FakeSettleClock().settle)
            let report = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any] ?? [:]
            let counts = report["counts"] as? [String: Any] ?? [:]
            let undo = counts["undo"] as? [String: Int] ?? [:]
            let a = fake.ids(privat.id, [MailMoveProbe.folderA]), b = fake.ids(privat.id, [MailMoveProbe.folderB])
            let personal = ["Rechnung", "Absender", "@x.example", "Privat", privat.id]
            return result.exitCode == 0 && report["verified"] as? String == "20 of 20" && counts["back_in_a"] as? Int == 20
                && undo == ["undone": 20, "left": 0, "failed": 0] && counts["second_undo_steps"] as? Int == 0
                && report["mail_ids_changed"] as? String == "yes" && report["account_type"] as? String == "imap"
                && a == (1...20).map { "m\($0)@x.example" }.sorted() && b.isEmpty && fake.ids(privat.id, ["INBOX"]) == inboxBefore
                && fake.moveCalls.map(\.count) == [10, 10, 10, 10] && report["reused_copies"] as? Int == 0
                && (report["settle"] as? [String: Any])?["undo"] as? [String: Int] != nil
                && personal.allSatisfy { !result.stdout.contains($0) } && report["timings_ms"] is [String: Int]
                && fake.folderCalls == 0
        }
        await checkAsync("Mail move probe: runs again on an earlier run's copies: B goes back to A through the move path, A is used again, with settling; never another folder") {
            let fake = fakeMail()
            fake.newIDsOnMove = true
            // An earlier run whose Undo was cut short: 4 copies in A, 2 in B.
            fake.add(privat.id, [MailMoveProbe.folderA], mails: (1...4).map { var m = mail($0); m.id += 70_000; return m })
            fake.add(privat.id, [MailMoveProbe.folderB], mails: (5...6).map { var m = mail($0); m.id += 70_000; return m })
            fake.lagLookups = 2
            let clock = FakeSettleClock()
            let inboxBefore = fake.ids(privat.id, ["INBOX"])
            let first = await MailMoveProbe.execute(["--mail-move-probe", "--account", "Privat"], mail: { fake }, pause: {}, settle: clock.settle)
            let report = (try? JSONSerialization.jsonObject(with: Data(first.stdout.utf8))) as? [String: Any] ?? [:]
            let counts = report["counts"] as? [String: Any] ?? [:]
            let settle = report["settle"] as? [String: [String: Int]] ?? [:]
            let reset = counts["reset_b_to_a"] as? [String: Any] ?? [:]
            let again = await MailMoveProbe.execute(["--mail-move-probe", "--account", "Privat"], mail: { fake }, pause: {}, settle: clock.settle)
            let second = (try? JSONSerialization.jsonObject(with: Data(again.stdout.utf8))) as? [String: Any] ?? [:]
            let personal = ["Rechnung", "Absender", "@x.example", "Privat", privat.id]
            return first.exitCode == 0 && report["verified"] as? String == "6 of 6" && report["reused_copies"] as? Int == 6
                && reset["verified"] as? Int == 2 && counts["back_in_a"] as? Int == 6 && counts["undo"] as? [String: Int] == ["undone": 6, "left": 0, "failed": 0]
                && settle["move"]?["lookups"] == 3 && settle["undo"]?["lookups"] == 4 && settle["reset_move"]?["waited_ms"] == 2000
                && again.exitCode == 0 && second["verified"] as? String == "6 of 6" && second["reused_copies"] as? Int == 6
                && fake.duplicateCalls == 0 && fake.ids(privat.id, ["INBOX"]) == inboxBefore
                && fake.ids(privat.id, [MailMoveProbe.folderA]) == (1...6).map { "m\($0)@x.example" }.sorted() && fake.ids(privat.id, [MailMoveProbe.folderB]).isEmpty
                && fake.listedPaths.allSatisfy { $0 == [MailMoveProbe.folderA] || $0 == [MailMoveProbe.folderB] }
                && personal.allSatisfy { !first.stdout.contains($0) && !again.stdout.contains($0) } && fake.folderCalls == 0
        }
        await checkAsync("Mail move probe: a test folder's count timing out names the step, the time and the Apple event; a timed-out move names it too") {
            let fake = fakeMail()
            fake.add(privat.id, [MailMoveProbe.folderA])
            fake.add(privat.id, [MailMoveProbe.folderB])
            fake.testFolderTimeout = "count"
            let result = await MailMoveProbe.execute(["--mail-move-probe", "--account", "Privat"], mail: { fake }, pause: {}, settle: FakeSettleClock().settle)
            let report = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any] ?? [:]
            let error = report["error"] as? [String: String] ?? [:]
            let slowMove = fakeMail()
            slowMove.moveTimesOut = true
            let moved = await MailMoveProbe.execute(["--mail-move-probe", "--account", "Privat"], mail: { slowMove }, journalDirectory: dir("probe-\(UUID().uuidString)"),
                                                    pause: {}, settle: FakeSettleClock().settle)
            let movedReport = (try? JSONSerialization.jsonObject(with: Data(moved.stdout.utf8))) as? [String: Any] ?? [:]
            let counts = movedReport["counts"] as? [String: Any] ?? [:]
            let move = counts["move"] as? [String: Any] ?? [:]
            return result.exitCode == 1 && error == ["step": "folders", "kind": "timeout", "event": "count"]
                && (report["timings_ms"] as? [String: Int])?["folders"] != nil && fake.moveCalls.isEmpty && fake.folderCalls == 0
                && movedReport["move_error"] as? String == "timeout" && movedReport["move_error_event"] as? String == "move"
                && move["unclear"] as? Int == 10 && move["not_moved"] as? Int == 0 && slowMove.folderCalls == 0
        }
        await checkAsync("Mail move probe --diagnose: times the test folders and the mail_folders listing in numbers only and changes nothing") {
            let fake = fakeMail()
            fake.add(privat.id, [MailMoveProbe.folderA], mails: (1...4).map { var m = mail($0); m.id += 70_000; return m })
            fake.slowFolders = [["Rechnungen"]]
            let inboxBefore = fake.ids(privat.id, ["INBOX"])
            let result = await MailMoveProbe.execute(["--mail-move-probe", "--account", "Privat", "--diagnose"], mail: { fake }, pause: {})
            let after = try await fake.testFolders(account: privat.id)
            let report = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any] ?? [:]
            let tests = report["test_folders"] as? [String: Any] ?? [:]
            let a = tests[MailMoveProbe.folderA] as? [String: Any] ?? [:], b = tests[MailMoveProbe.folderB] as? [String: Any] ?? [:]
            let listing = report["listing"] as? [String: Any] ?? [:]
            let personal = ["Rechnung", "Absender", "@x.example", "Privat", privat.id, "INBOX", "Archiv", "Junk"]
            return result.exitCode == 0 && report["mode"] as? String == "diagnose" && report["changed"] as? String == "nothing"
                && a["exists"] as? Bool == true && a["messages"] as? Int == 4 && a["message_ids"] as? Int == 4 && a["list_ids_ms"] is Int
                && b["exists"] as? Bool == false && b["message_ids"] == nil && tests["resolve_and_count_ms"] is Int
                && listing["folders_listed"] as? Int == 9 && listing["timed_out_mailboxes"] as? Int == 1
                && (listing["timeouts"] as? [String: Int])?["count"] == 1 && listing["slowest_mailbox_ms"] as? Int == 5000 && listing["total_ms"] is Int
                && fake.moveCalls.isEmpty && fake.duplicateCalls == 0 && after.map(\.exists) == [true, false] && after[0].count == 4
                && fake.ids(privat.id, ["INBOX"]) == inboxBefore && personal.allSatisfy { !result.stdout.contains($0) }
        }
        await checkAsync("Mail move probe: an empty A that gets mail the probe did not copy is refused, and nothing moves") {
            let foreign = fakeMail()
            foreign.foreignAfterDuplicate = [MailMoveProbe.folderA]
            let late = await MailMoveProbe.execute(["--mail-move-probe", "--account", "Privat"], mail: { foreign }, pause: {}, settle: FakeSettleClock().settle)
            let refused = ((try? JSONSerialization.jsonObject(with: Data(late.stdout.utf8))) as? [String: Any])?["refused"] as? String
            return late.exitCode == 1 && refused == "test_folder_has_other_mail" && foreign.moveCalls.isEmpty
                && foreign.ids(privat.id, ["INBOX"]).count == 30
        }
    }
}
