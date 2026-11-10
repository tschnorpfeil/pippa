import Foundation
import PippaCore

/// Mail search picks the newest matches, `mail_read` opens exactly the mail it is given, and attachments are saved or
/// reported as unreadable. Synthetic mails only: no Mail, no real inbox, no model.
private final class FakeMailSearch: MailSearchNative, @unchecked Sendable {
    private let lock = NSLock()
    private let all: [MailSearchCandidate]
    private let headers: [Int: MailHeader]
    private var calls = 0
    private var requested: [[Int]] = []
    /// Rows missing for the first this-many `rows` calls (a message that left between the two steps).
    private var goneCalls: Int
    init(_ all: [MailSearchCandidate], goneCalls: Int = 0) {
        self.all = all; self.goneCalls = goneCalls
        headers = Dictionary(all.map { c in
            (c.id, MailHeader(subject: "Mail \(c.id)", sender: "Absender <a@b.example>", date: c.date, mailbox: "Eingang", preview: "Text \(c.id)",
                              messageID: "m\(c.id)@x.example"))
        }, uniquingKeysWith: { first, _ in first })
    }
    var candidateCalls: Int { lock.withLock { calls } }
    var rowRequests: [[Int]] { lock.withLock { requested } }
    func candidates(query: String, unread: Bool) throws -> [MailSearchCandidate] { lock.withLock { calls += 1; return all } }
    func rows(ids: [Int]) throws -> [MailSearchRow] {
        lock.withLock {
            requested.append(ids)
            if goneCalls > 0 { goneCalls -= 1; return Array(ids.dropFirst()).compactMap(row) }
            return ids.compactMap(row)
        }
    }
    private func row(_ id: Int) -> MailSearchRow? { headers[id].map { MailSearchRow(id: id, date: $0.date, header: $0) } }
}

extension MCPCheckContext {
    func mailSelectionChecks() async {
        // MARK: A1 newest before limit

        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func at(_ minutes: Int) -> Date { base.addingTimeInterval(Double(minutes) * 60) }
        // 25 matches, listed in a scrambled order that is neither oldest- nor newest-first. Mail id n was received n minutes in.
        let scrambled = (1...25).map { ($0 * 7) % 26 }.map { MailSearchCandidate(id: $0, date: at($0)) }
        check("Mail search: the newest N of more matching mails, whatever order Mail lists them in; total is every match") {
            let native = FakeMailSearch(scrambled)
            let fetch = try MailSearchFlow.search(native, query: "", unread: false, limit: 5)
            return fetch.items.map(\.subject) == ["Mail 25", "Mail 24", "Mail 23", "Mail 22", "Mail 21"] && fetch.total == 25
                && Set(scrambled.map(\.id)).count == 25
        }
        check("Mail search: text is read for the chosen messages only, in one request") {
            let native = FakeMailSearch(scrambled)
            _ = try MailSearchFlow.search(native, query: "", unread: false, limit: 3)
            return native.rowRequests == [[25, 24, 23]] && native.candidateCalls == 1
        }
        check("Mail search: fewer matches than the limit all come back newest first; no match is an empty answer without reading text") {
            let few = FakeMailSearch([MailSearchCandidate(id: 4, date: at(1)), MailSearchCandidate(id: 9, date: at(8))])
            let fetch = try MailSearchFlow.search(few, query: "", unread: false, limit: 10)
            let none = FakeMailSearch([])
            let empty = try MailSearchFlow.search(none, query: "", unread: false, limit: 10)
            return fetch.items.map(\.subject) == ["Mail 9", "Mail 4"] && fetch.total == 2
                && empty.items.isEmpty && empty.total == 0 && none.rowRequests.isEmpty
        }
        check("Mail search: missing dates come last and equal dates go by the larger Mail id, the same for every input order") {
            let same = at(50)
            let mails = [MailSearchCandidate(id: 3, date: nil), MailSearchCandidate(id: 8, date: same), MailSearchCandidate(id: 5, date: nil),
                         MailSearchCandidate(id: 6, date: same), MailSearchCandidate(id: 7, date: at(10)), MailSearchCandidate(id: 9, date: same)]
            let expected = ["Mail 9", "Mail 8", "Mail 6", "Mail 7", "Mail 5", "Mail 3"]
            var orders: [[MailSearchCandidate]] = [mails, mails.reversed()]
            orders.append(mails.sorted { $0.id < $1.id })
            for order in orders {
                guard try MailSearchFlow.search(FakeMailSearch(order), query: "", unread: false, limit: 20).items.map(\.subject) == expected else { return false }
            }
            // Cut inside the tie and inside the undated mails: the same ones survive.
            let tie = try MailSearchFlow.search(FakeMailSearch(mails.reversed()), query: "", unread: false, limit: 2).items.map(\.subject)
            let undated = try MailSearchFlow.search(FakeMailSearch([MailSearchCandidate(id: 3, date: nil), MailSearchCandidate(id: 5, date: nil)].reversed()),
                                                    query: "", unread: false, limit: 1).items.map(\.subject)
            return tie == ["Mail 9", "Mail 8"] && undated == ["Mail 5"]
        }
        check("Mail search: a message that left between the two steps is read again once; if it keeps changing the search fails, never a partial answer") {
            let once = FakeMailSearch(scrambled, goneCalls: 1)
            let fetch = try MailSearchFlow.search(once, query: "", unread: false, limit: 3)
            let always = FakeMailSearch(scrambled, goneCalls: 9)
            let failed: Bool
            do { _ = try MailSearchFlow.search(always, query: "", unread: false, limit: 3); failed = false } catch { failed = true }
            let duplicate = FakeMailSearch([MailSearchCandidate(id: 1, date: at(1)), MailSearchCandidate(id: 1, date: at(2))])
            let duplicated: Bool
            do { _ = try MailSearchFlow.search(duplicate, query: "", unread: false, limit: 3); duplicated = false } catch { duplicated = true }
            return fetch.items.map(\.subject) == ["Mail 25", "Mail 24", "Mail 23"] && once.candidateCalls == 2 && failed && always.candidateCalls == 2
                && duplicated
        }

        func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let l = NSAppleEventDescriptor.list()
            for (i, item) in items.enumerated() { l.insert(item, at: i + 1) }
            return l
        }
        func int(_ n: Int32) -> NSAppleEventDescriptor { NSAppleEventDescriptor(int32: n) }
        let missing = NSAppleEventDescriptor(typeCode: 0x6d73_6e67)
        func throwsMalformed(_ body: () throws -> Any) -> Bool { (try? body()) == nil }
        check("Mail search: the native candidate answer is read strictly (ids and dates in step, missing date allowed, anything else fails)") {
            let good = try MailSearchFlow.parseCandidates(list([list([int(11), int(12), int(13)]), list([NSAppleEventDescriptor(date: at(1)), missing, .null()])]))
            let empty = try MailSearchFlow.parseCandidates(list([list([]), list([])]))
            return good == [MailSearchCandidate(id: 11, date: at(1)), MailSearchCandidate(id: 12, date: nil), MailSearchCandidate(id: 13, date: nil)]
                && empty.isEmpty
                && throwsMalformed { try MailSearchFlow.parseCandidates(list([list([int(1), int(2)]), list([NSAppleEventDescriptor(date: at(1))])])) }
                && throwsMalformed { try MailSearchFlow.parseCandidates(list([list([NSAppleEventDescriptor(string: "7")]), list([NSAppleEventDescriptor(date: at(1))])])) }
                && throwsMalformed { try MailSearchFlow.parseCandidates(list([list([int(1)]), list([NSAppleEventDescriptor(string: "gestern")])])) }
                && throwsMalformed { try MailSearchFlow.parseCandidates(list([list([int(-4)]), list([NSAppleEventDescriptor(date: at(1))])])) }
                && throwsMalformed { try MailSearchFlow.parseCandidates(list([list([int(1)])])) }
                && throwsMalformed { try MailSearchFlow.parseCandidates(NSAppleEventDescriptor(string: "oops")) }
                && throwsMalformed { try MailSearchFlow.parseCandidates(list([int(1), int(2)])) }
        }
        check("Mail search: the native row answer is read strictly; a message that is gone is left out, a malformed row fails the search") {
            func row(_ id: Int32, subject: String = "Betreff", unread: NSAppleEventDescriptor = NSAppleEventDescriptor(boolean: true)) -> NSAppleEventDescriptor {
                list([int(id), NSAppleEventDescriptor(string: subject), NSAppleEventDescriptor(string: "Frau A <a@b.example>"), NSAppleEventDescriptor(date: at(5)),
                      NSAppleEventDescriptor(string: "Eingang"), NSAppleEventDescriptor(string: "Anfang des Textes"),
                      NSAppleEventDescriptor(string: " id-1@x.example "), unread])
            }
            let rows = try MailSearchFlow.parseRows(list([row(5), list([]), row(7, subject: "Zweiter")]), expecting: 3)
            return rows.map(\.id) == [5, 7] && rows[0].header.subject == "Betreff" && rows[0].header.messageID == "id-1@x.example"
                && rows[0].header.unread && rows[0].date == at(5) && rows[0].header.preview == "Anfang des Textes" && rows[1].header.subject == "Zweiter"
                && throwsMalformed { try MailSearchFlow.parseRows(list([row(5)]), expecting: 2) }
                && throwsMalformed { try MailSearchFlow.parseRows(list([list([int(5), NSAppleEventDescriptor(string: "nur zwei")])]), expecting: 1) }
                && throwsMalformed { try MailSearchFlow.parseRows(list([row(5, unread: NSAppleEventDescriptor(string: "ja"))]), expecting: 1) }
                && throwsMalformed { try MailSearchFlow.parseRows(NSAppleEventDescriptor(string: "oops"), expecting: 1) }
        }
        await checkAsync("MCP mail_search: Demo mails beyond the limit return the newest, with total preserved, unread and query unchanged") {
            let demo = DemoIntegrations(granted: true)
            let mails = (1...12).map { n in
                MailHeader(subject: n.isMultiple(of: 2) ? "Rechnung \(n)" : "Info \(n)", sender: "Firma <f@x.example>",
                           date: n == 4 ? nil : at(n), mailbox: "Eingang", preview: "Text \(n)", messageID: "n\(n)@x.example", unread: n > 8)
            }
            var generator = SeededGenerator(seed: 7)
            let data = DemoHostData(integrations: demo, mails: mails.shuffled(using: &generator), now: now)
            let host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: data, askForAccess: false, now: { now }, calendar: berlin)
            let tools = PippaMCPTools(host: host)
            func subjects(_ r: (json: [String: Any], isError: Bool, bytes: Int)) -> [String] {
                ((r.json["data"] as? [String: Any])?["mails"] as? [[String: Any]] ?? []).compactMap { $0["subject"] as? String }
            }
            func total(_ r: (json: [String: Any], isError: Bool, bytes: Int)) -> Int? { (r.json["data"] as? [String: Any])?["total"] as? Int }
            let newest = await call(tools, "mail_search", ["limit": 3])
            let query = await call(tools, "mail_search", ["query": "Rechnung", "limit": 2])
            let unread = await call(tools, "mail_search", ["unread": true, "limit": 2])
            return subjects(newest) == ["Rechnung 12", "Info 11", "Rechnung 10"] && total(newest) == 12
                && subjects(query) == ["Rechnung 12", "Rechnung 10"] && total(query) == 6
                && subjects(unread) == ["Rechnung 12", "Info 11"] && total(unread) == 4
        }

        // MARK: A2 exact mail_read by message_id

        let sender = "Hausverwaltung Berger <info@berger-hv.example>"
        func repeated(_ id: String, _ body: String, _ date: Date?) -> MailMessage {
            MailMessage(subject: "Nachricht zur Abrechnung", sender: sender, date: date, body: body, attachmentNames: [], messageID: id)
        }
        let inbox = [repeated("mitte@berger-hv.example", "Mitte: bitte melden.", at(20)), repeated("neu@berger-hv.example", "Neu: Frist verlängert.", at(30)),
                     repeated("alt@berger-hv.example", "Alt: erste Fassung.", at(10))]
        func repeatedWorld() -> (tools: PippaMCPTools, demo: DemoIntegrations) {
            let demo = DemoIntegrations(granted: true)
            demo.sampleMail = nil
            demo.inboxMails = inbox
            let headers = inbox.map { MailHeader(subject: $0.subject, sender: $0.sender, date: $0.date, mailbox: "Eingang", preview: $0.body, messageID: $0.messageID) }
            var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, mails: headers, now: now),
                                    askForAccess: false, now: { now }, calendar: berlin)
            host.mailFiles = dir("mail-repeated-\(UUID().uuidString)")
            return (PippaMCPTools(host: host), demo)
        }
        func body(_ r: (json: [String: Any], isError: Bool, bytes: Int)) -> String? { (r.json["data"] as? [String: Any])?["body"] as? String }
        await checkAsync("MCP mail_search and mail_read: repeated subject and sender, each result has its own message_id and reads back its own body") {
            let w = repeatedWorld()
            let search = await call(w.tools, "mail_search", ["query": "Abrechnung"])
            let found = (search.json["data"] as? [String: Any])?["mails"] as? [[String: Any]] ?? []
            let ids = found.compactMap { $0["message_id"] as? String }
            guard !search.isError, ids == ["neu@berger-hv.example", "mitte@berger-hv.example", "alt@berger-hv.example"] else { return false }
            let bodies = await ids.asyncMap { body(await call(w.tools, "mail_read", ["message_id": $0])) }
            let onlyID = await call(w.tools, "mail_read", ["message_id": "<alt@berger-hv.example>"])
            return bodies == ["Neu: Frist verlängert.", "Mitte: bitte melden.", "Alt: erste Fassung."] && body(onlyID) == "Alt: erste Fassung."
        }
        await checkAsync("MCP mail_read: a message_id wins over a look-alike subject; an unknown id is not_found and never the similar mail") {
            let w = repeatedWorld()
            let mixed = await call(w.tools, "mail_read", ["message_id": "alt@berger-hv.example", "subject": "Nachricht zur Abrechnung", "from": sender])
            let unknown = await call(w.tools, "mail_read", ["message_id": "gibt-es-nicht@berger-hv.example", "subject": "Nachricht zur Abrechnung", "from": sender])
            let otherCase = await call(w.tools, "mail_read", ["message_id": "ALT@berger-hv.example"])
            return body(mixed) == "Alt: erste Fassung."
                && unknown.isError && unknown.json["status"] as? String == "not_found" && body(unknown) == nil
                && otherCase.isError && otherCase.json["status"] as? String == "not_found"
        }
        await checkAsync("MCP mail_read: a wrong type, blank or malformed message_id is rejected before any lookup") {
            let w = repeatedWorld()
            var rejected = true
            for value: Any in [123, true, NSNull(), ["alt@berger-hv.example"], "", "   ", "kein id", "a b@c.example", "<>"] {
                let r = await call(w.tools, "mail_read", ["message_id": value, "subject": "Nachricht zur Abrechnung"])
                rejected = rejected && r.isError && r.json["status"] as? String == "invalid_arguments" && body(r) == nil
            }
            let none = await call(w.tools, "mail_read", [:])
            return rejected && none.isError && none.json["status"] as? String == "invalid_arguments"
                && w.demo.mailLookups == 0 && w.demo.mailPreparations == 0
        }
        await checkAsync("MCP mail_read: without a message_id the subject and sender still select the newest matching mail") {
            let w = repeatedWorld()
            let legacy = await call(w.tools, "mail_read", ["subject": "Nachricht zur Abrechnung", "from": sender])
            let bare = await call(w.tools, "mail_read", ["subject": "Nachricht zur Abrechnung"])
            let wrongSender = await call(w.tools, "mail_read", ["subject": "Nachricht zur Abrechnung", "from": "fremd@example.com"])
            return body(legacy) == "Neu: Frist verlängert." && body(bare) == "Neu: Frist verlängert."
                && wrongSender.isError && wrongSender.json["status"] as? String == "not_found"
        }
        check("MCP tool list: mail_read takes an optional message_id and no longer requires a subject; mail_search hits carry no other new field") {
            let tools = PippaMCPTools.toolList()
            guard let read = tools.first(where: { $0["name"] as? String == "mail_read" }),
                  let schema = read["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: Any] else { return false }
            return Set(properties.keys) == ["message_id", "subject", "from"] && (schema["required"] as? [String] ?? []).isEmpty
                && schema["additionalProperties"] as? Bool == false
                && (properties["message_id"] as? [String: Any])?["type"] as? String == "string"
        }

        // MARK: A3 document attachments

        let pdf = Data("%PDF-1.4 Vertrag inline mit Content-ID".utf8)
        func mime(_ parts: String...) -> String {
            """
            From: Maximilian Lahm <maximilian.lahm@firma.example>
            Subject: Vertrag
            Message-ID: <vertrag-1@firma.example>
            Content-Type: multipart/mixed; boundary="b1"

            --b1
            Content-Type: text/plain; charset=utf-8

            Anbei der Vertrag.
            \(parts.map { "--b1\n" + $0 }.joined(separator: "\n"))
            --b1--

            """
        }
        let inlinePDF = """
        Content-Type: application/pdf; name="Vertrag.pdf"
        Content-Disposition: inline; filename="Vertrag.pdf"
        Content-ID: <vertrag-pdf@firma.example>
        Content-Transfer-Encoding: base64

        \(pdf.base64EncodedString())
        """
        let logo = """
        Content-Type: image/png; name="logo.png"
        Content-Disposition: inline; filename="logo.png"
        Content-ID: <logo@firma.example>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        """
        let emptyPart = """
        Content-Type: application/pdf; name="Leer.pdf"
        Content-Disposition: attachment; filename="Leer.pdf"
        Content-Transfer-Encoding: base64

        """
        check("Mail attachments: an inline PDF with a Content-ID is a document and saved byte-exact; the inline logo is still left out") {
            let source = mime(inlinePDF, logo)
            let parsed = MailParser.parse(Data(source.utf8))
            let folder = dir("mail-inline-pdf")
            let eml = folder.appendingPathComponent("Vertrag.eml")
            try source.write(to: eml, atomically: true, encoding: .utf8)
            let result = MailFiling.save(of: eml, into: folder)
            return parsed.files.map(\.inline) == [false, true]
                && result.saved.map(\.name) == ["Vertrag.pdf"] && (try? Data(contentsOf: result.saved[0].url)) == pdf
                && result.skippedInline == ["logo.png"] && result.unsaved.isEmpty && !result.unreadable
                && MailFiling.saveAttachments(of: eml, into: folder) == result.files
        }
        func host(_ name: String, root: URL? = nil) -> PippaMCPHost {
            let demo = DemoIntegrations(granted: true)
            var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                                    askForAccess: false, now: { now }, calendar: berlin)
            host.mailFiles = root ?? dir(name)
            return host
        }
        func read(_ mail: MailMessage, in host: PippaMCPHost) async -> [String: Any] {
            (host.integrations as? DemoIntegrations)?.sampleMail = mail
            let r = await call(PippaMCPTools(host: host), "mail_read", ["subject": mail.subject])
            return r.json
        }
        func mail(names: [String], source: String?) -> MailMessage {
            MailMessage(subject: "Vertrag", sender: "Maximilian Lahm <maximilian.lahm@firma.example>", date: nil, body: "Anbei der Vertrag.",
                        attachmentNames: names, messageID: "vertrag-1@firma.example", source: source)
        }
        check("Mail attachments: an older cache cannot substitute equal-sized bytes when an inline document shifts duplicate names") {
            let later = Data(repeating: UInt8(ascii: "x"), count: pdf.count)
            let second = inlinePDF.replacingOccurrences(of: "inline;", with: "attachment;")
                .replacingOccurrences(of: pdf.base64EncodedString(), with: later.base64EncodedString())
            let folder = dir("mail-cache-upgrade"), eml = folder.appendingPathComponent("Vertrag.eml")
            // The earlier parser skipped the inline PDF and saved the later attachment under this name.
            try later.write(to: folder.appendingPathComponent("Vertrag.pdf"))
            try mime(inlinePDF, second).write(to: eml, atomically: true, encoding: .utf8)
            let saved = MailFiling.saveAttachments(of: eml, into: folder)
            guard saved.count == 2 else { return false }
            let contents = try saved.map { try Data(contentsOf: $0) }
            return contents == [pdf, later]
        }
        check("Mail attachments: each duplicate filename needs its own saved, failed or deliberately skipped occurrence") {
            let cases: [([String], String, [String])] = [
                (["Vertrag.pdf", "Vertrag.pdf"], mime(inlinePDF), ["Vertrag.pdf"]),
                (["Leer.pdf", "Leer.pdf"], mime(emptyPart), ["Leer.pdf", "Leer.pdf"]),
                (["logo.png", "logo.png"], mime(logo), ["logo.png"]),
                (["Vertrag.pdf", "Vertrag.pdf"], mime(inlinePDF, inlinePDF), [])
            ]
            for (i, item) in cases.enumerated() {
                let filed = try MailFiling.file(mail(names: item.0, source: item.1), root: dir("mail-name-occurrences-\(i)"))
                if filed.notSaved != item.2 { return false }
            }
            return true
        }
        check("Mail attachments: a named inline CSV is saved byte-exact and named inline body text remains readable") {
            let csv = Data("Position,Betrag\n1,42.50\n".utf8)
            let part = """
            Content-Type: text/csv; name="rows.csv"
            Content-Disposition: inline; filename="rows.csv"
            Content-ID: <rows@firma.example>
            Content-Transfer-Encoding: base64

            \(csv.base64EncodedString())
            """
            let filed = try MailFiling.file(mail(names: ["rows.csv"], source: mime(part)), root: dir("mail-inline-csv"))
            let namedBody = "Content-Type: text/plain; name=body.txt\nContent-Disposition: inline; filename=body.txt\n\nMessage body."
            let body = MailParser.parse(Data(namedBody.utf8)).body
            return filed.attachments.count == 1 && (try? Data(contentsOf: filed.attachments[0])) == csv
                && filed.notSaved.isEmpty && body == "Message body."
        }
        await checkAsync("MCP mail_read: an inline PDF reaches read_document as a file with its bytes, the logo does not") {
            let h = host("mail-read-inline")
            let json = await read(mail(names: ["Vertrag.pdf", "logo.png"], source: mime(inlinePDF, logo)), in: h)
            let data = json["data"] as? [String: Any] ?? [:]
            let files = data["attachments"] as? [[String: Any]] ?? []
            let path = files.first?["path"] as? String ?? ""
            return files.count == 1 && files.first?["name"] as? String == "Vertrag.pdf" && (try? Data(contentsOf: URL(fileURLWithPath: path))) == pdf
                && data["attachmentsNotSaved"] == nil
        }
        await checkAsync("MCP mail_read: an empty or whitespace source gives names without paths and says they are not readable content") {
            let names = ["Vertrag.pdf", "Anlage.xlsx"]
            var ok = true
            for source: String? in [nil, "", "  \n\t "] {
                let h = host("mail-blank-source-\(UUID().uuidString)")
                let json = await read(mail(names: names, source: source), in: h)
                let data = json["data"] as? [String: Any] ?? [:]
                let shown = data["attachments"] as? [Any] ?? []
                ok = ok && !shown.contains { $0 is [String: Any] } && data["attachmentsNotSaved"] as? [String] == names
                    && (json["next"] as? String)?.contains("attachmentsNotSaved") == true
                    && !((json["next"] as? String)?.contains("read_document") ?? true)
                    && (try? FileManager.default.contentsOfDirectory(atPath: h.mailFiles.path))?.isEmpty == true
            }
            return ok
        }
        await checkAsync("MCP mail_read: an attachment that cannot be saved is reported as unreadable beside the ones that were saved") {
            let source = mime(inlinePDF, emptyPart)
            let h = host("mail-partial")
            let json = await read(mail(names: ["Vertrag.pdf", "Leer.pdf"], source: source), in: h)
            let data = json["data"] as? [String: Any] ?? [:]
            let files = data["attachments"] as? [[String: Any]] ?? []
            // Mail lists an attachment its source does not contain (not downloaded yet).
            let h2 = host("mail-missing-part")
            let missing = await read(mail(names: ["Vertrag.pdf", "Fehlt.pdf"], source: mime(inlinePDF)), in: h2)
            let missingData = missing["data"] as? [String: Any] ?? [:]
            // The cache folder cannot be created at all.
            let blocker = dir("mail-blocked").appendingPathComponent("datei")
            try? Data("x".utf8).write(to: blocker)
            let h3 = host("unused", root: blocker)
            let blocked = await read(mail(names: ["Vertrag.pdf"], source: mime(inlinePDF)), in: h3)
            let blockedData = blocked["data"] as? [String: Any] ?? [:]
            return files.count == 1 && files.first?["name"] as? String == "Vertrag.pdf" && data["attachmentsNotSaved"] as? [String] == ["Leer.pdf"]
                && (missingData["attachments"] as? [[String: Any]])?.count == 1 && missingData["attachmentsNotSaved"] as? [String] == ["Fehlt.pdf"]
                && !((blockedData["attachments"] as? [Any]) ?? []).contains { $0 is [String: Any] } && blockedData["attachmentsNotSaved"] as? [String] == ["Vertrag.pdf"]
        }
        check("Mail attachments: a file that cannot be written is listed as unsaved, saved ones stay") {
            let source = mime(inlinePDF, """
            Content-Type: application/pdf; name="Zweite.pdf"
            Content-Disposition: attachment; filename="Zweite.pdf"
            Content-Transfer-Encoding: base64

            \(Data("%PDF zweite".utf8).base64EncodedString())
            """)
            let folder = dir("mail-write-fails")
            let eml = folder.appendingPathComponent("Vertrag.eml")
            try source.write(to: eml, atomically: true, encoding: .utf8)
            // A folder where the first attachment's file belongs: writing there fails.
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Vertrag.pdf"), withIntermediateDirectories: true)
            let result = MailFiling.save(of: eml, into: folder)
            return result.unsaved == ["Vertrag.pdf"] && result.saved.map(\.name) == ["Zweite.pdf"]
        }
        check("Mail attachments: two mails with the same subject, sender and no Message-ID keep separate folders") {
            let root = dir("mail-same-subject")
            func plain(_ text: String) -> MailMessage {
                MailMessage(subject: "Gleich", sender: "Gleich <g@x.example>", date: nil, body: text, attachmentNames: [])
            }
            let a = try MailFiling.file(plain("Erste"), root: root), b = try MailFiling.file(plain("Zweite"), root: root)
            let first = try String(contentsOf: a.eml, encoding: .utf8)
            return a.eml.deletingLastPathComponent() != b.eml.deletingLastPathComponent() && first.contains("Erste")
        }
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}

/// A fixed shuffle: checks must not depend on the order of a run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9e37_79b9_7f4a_7c15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
