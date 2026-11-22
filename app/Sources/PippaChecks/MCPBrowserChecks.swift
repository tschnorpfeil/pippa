import Foundation
import PippaCore

/// `browse` at protocol level with `DemoBrowserOperator` (invented pages, no network): schema, address guard,
/// the person's OK, stale refs, password and login handoff, and bounded output.
func runMCPBrowserChecks() async {
    struct World {
        let tools: PippaMCPTools
        let browser: DemoBrowserOperator
        let asked: LockedBox<[String]>
        var prompts = LockedBox<[(title: String, message: String)]>([])
        let handoffs: LockedBox<[String]>
        let notes: LockedBox<[PippaMCPReadNote]>
        let turns: PippaMCPTurns
        let turn: PippaMCPTurn
    }
    /// `confirm`: the person's answer per action; `nil` leaves `confirmBrowser` unset (nothing can ask).
    func world(confirm: (@Sendable (String) -> Bool)? = { _ in true }, ask: Bool = true, page: DemoBrowserOperator.Page? = nil,
               privateHost: @escaping @Sendable (String) async -> Bool = { _ in false }, journal: Executor? = nil,
               operating: (any BrowserOperating)? = nil) -> World {
        let demo = DemoIntegrations(granted: true)
        var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: Date()),
                                askForAccess: ask)
        let turns = PippaMCPTurns()
        let turn = PippaMCPTurn()
        turns.begin(turn)
        host.turns = turns
        let browser = DemoBrowserOperator(page: page)
        let asked = LockedBox<[String]>([]), prompts = LockedBox<[(title: String, message: String)]>([]), handoffs = LockedBox<[String]>([]), notes = LockedBox<[PippaMCPReadNote]>([])
        host.browser = operating ?? browser
        host.reminderJournal = journal
        host.resolveHostIsPrivate = privateHost
        if let confirm { host.confirmBrowser = { action, title, message in
            asked.mutate { $0.append(action) }; prompts.mutate { $0.append((title, message)) }; return confirm(action)
        } }
        host.onBrowserHandoff = { reason, _ in handoffs.mutate { $0.append(reason) } }
        host.onRead = { note in notes.mutate { $0.append(note) } }
        return World(tools: PippaMCPTools(host: host), browser: browser, asked: asked, prompts: prompts, handoffs: handoffs, notes: notes, turns: turns, turn: turn)
    }
    func browse(_ w: World, _ arguments: [String: Any]) async -> (json: [String: Any], isError: Bool, text: String) {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                "params": ["name": "browse", "arguments": arguments]])
        let reply = await w.tools.handle(body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = reply?["result"] as? [String: Any] ?? [:]
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:], result["isError"] as? Bool ?? true, text)
    }
    func data(_ json: [String: Any]) -> [String: Any] { json["data"] as? [String: Any] ?? [:] }
    let page = "https://example.org/kontakt"

    check("MCP browse: compact strict schema with the seven actions, ref pattern and open-world hints") {
        let tool = PippaMCPBrowserTool.toolList().first ?? [:]
        let schema = tool["inputSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let a = tool["annotations"] as? [String: Any] ?? [:]
        let bytes = (try? JSONSerialization.data(withJSONObject: [tool]))?.count ?? .max
        return tool["name"] as? String == "browse" && schema["additionalProperties"] as? Bool == false
            && schema["required"] as? [String] == ["action"]
            && properties.keys.sorted() == ["action", "ref", "snapshot_id", "text", "url", "value"]
            && (properties["action"] as? [String: Any])?["enum"] as? [String] == ["open", "snapshot", "click", "fill", "select", "back", "close"]
            && (properties["ref"] as? [String: Any])?["pattern"] as? String == "^@e[1-9][0-9]*$"
            && a["openWorldHint"] as? Bool == true && a["destructiveHint"] as? Bool == false && a["readOnlyHint"] as? Bool == false
            && bytes < 800 && PippaMCPTools.toolNames.filter { $0 == "browse" }.count == 1
    }

    await checkAsync("MCP browse: invalid arguments fail before asking or touching the browser") {
        let w = world()
        let bad: [[String: Any]] = [[:], ["action": "download"], ["action": 1], ["action": "open"], ["action": "open", "url": 5],
            ["action": "open", "url": page, "ref": "@e1"], ["action": "click"], ["action": "click", "ref": "e1"], ["action": "click", "ref": "@e0"],
            ["action": "fill", "ref": "@e2"], ["action": "fill", "ref": "@e2", "text": NSNull()], ["action": "select", "ref": "@e4"],
            ["action": "snapshot", "url": page], ["action": "click", "ref": "@e1", "snapshot_id": ""], ["action": "back", "extra": "x"]]
        for arguments in bad {
            let r = await browse(w, arguments)
            guard r.isError, r.json["status"] as? String == "invalid_arguments", r.json["done"] as? Bool == false,
                  r.json["dispatched"] as? Bool == false else { return false }
        }
        return w.asked.value.isEmpty && w.browser.actions.isEmpty
    }

    await checkAsync("MCP browse: only http(s) pages on the internet; this Mac, local networks and other schemes are refused") {
        let w = world()
        let blocked = ["http://localhost/", "http://dev.localhost/", "http://drucker.local/", "http://127.0.0.1/", "http://127.1/",
            "http://2130706433/", "http://0x7f000001/", "http://0177.0.0.1/", "http://0.0.0.0/", "http://10.0.0.1/", "http://172.16.0.1/",
            "http://172.31.255.1/", "http://192.168.1.1/", "http://100.64.0.1/", "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/", "http://[::]/", "http://[fe80::1]/", "http://[fd00::1]/", "http://[::ffff:127.0.0.1]/", "http://[::ffff:8.8.8.8]/",
            "http://[64:ff9b::a00:1]/", "http://fritz.box/", "http://intranet/", "https://user:pw@example.org/",
            "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "about:blank", "ftp://example.org/", "http:///nohost"]
        for url in blocked {
            let allowed = URL(string: url).map(PippaMCPBrowserTool.isAllowedURL) ?? false
            let r = await browse(w, ["action": "open", "url": url])
            guard !allowed, r.isError, ["blocked", "invalid_arguments"].contains(r.json["status"] as? String ?? "") else {
                print("  allowed: \(url)"); return false
            }
        }
        let fine = ["https://example.org/", "http://example.com:8080/a?b=c", "https://8.8.8.8/", "https://[2606:4700::1111]/",
                    "https://172.32.0.1/", "https://cafe.de/", "https://0xproject.org/"]
        return w.asked.value.isEmpty && w.browser.actions.isEmpty
            && fine.allSatisfy { PippaMCPBrowserTool.isAllowedURL(URL(string: $0)!) }
    }

    await checkAsync("MCP browse: opening asks once per host and answer; declining or no one to ask opens nothing") {
        let none = world(confirm: nil)
        let unasked = await browse(none, ["action": "open", "url": page])
        let headless = world(confirm: { _ in false }, ask: false)
        let declined = await browse(headless, ["action": "open", "url": page])
        let yes = world()
        let first = await browse(yes, ["action": "open", "url": page])
        let again = await browse(yes, ["action": "open", "url": "https://example.org/impressum"])
        let other = await browse(yes, ["action": "open", "url": "https://example.net/"])
        return unasked.isError && unasked.json["status"] as? String == "cancelled" && unasked.json["done"] as? Bool == false
            && none.browser.actions.isEmpty
            && !declined.isError && declined.json["status"] as? String == "cancelled" && declined.json["dispatched"] as? Bool == false
            && headless.asked.value == ["open"] && headless.browser.actions.isEmpty
            && !first.isError && first.json["done"] as? Bool == true && !again.isError && !other.isError
            && yes.asked.value == ["open", "open"] && yes.browser.actions.count == 3
    }

    await checkAsync("MCP browse: a page comes back as untrusted bounded data with refs and a snapshot id") {
        let w = world()
        let r = await browse(w, ["action": "open", "url": page])
        let d = data(r.json), refs = d["refs"] as? [[String: Any]] ?? []
        let snap = await browse(w, ["action": "snapshot"])
        return r.json["untrusted"] as? Bool == true && r.json["source"] as? String == "Browser (example.org)"
            && d["url"] as? String == page && d["snapshot_id"] as? String == "s1" && refs.first?["ref"] as? String == "@e1"
            && d["truncated"] as? Bool == false && (d["text"] as? String)?.isEmpty == false
            && data(snap.json)["snapshot_id"] as? String == "s2" && w.asked.value == ["open"]
            && w.notes.value.map(\.tool) == ["browse", "browse"] && w.notes.value.allSatisfy(\.read)
    }

    await checkAsync("MCP browse: every click, fill and select asks; a no changes nothing") {
        let w = world()
        _ = await browse(w, ["action": "open", "url": page])
        let click = await browse(w, ["action": "click", "ref": "@e1", "snapshot_id": "s1"])
        let fill = await browse(w, ["action": "fill", "ref": "@e2", "text": "Öffnungszeiten"])
        let id = data(fill.json)["snapshot_id"] as? String ?? ""
        let select = await browse(w, ["action": "select", "ref": "@e4", "value": "English", "snapshot_id": id])
        let filled = (data(fill.json)["refs"] as? [[String: Any]] ?? []).first { $0["ref"] as? String == "@e2" }
        let no = world(confirm: { $0 == "open" })
        _ = await browse(no, ["action": "open", "url": page])
        let declined = await browse(no, ["action": "click", "ref": "@e1"])
        return click.json["done"] as? Bool == true && fill.json["done"] as? Bool == true && select.json["done"] as? Bool == true
            && filled?["value"] as? String == "Öffnungszeiten" && w.asked.value == ["open", "click", "fill", "select"]
            && declined.json["status"] as? String == "cancelled" && declined.json["dispatched"] as? Bool == false
            && no.asked.value == ["open", "click"] && no.browser.actions.count == 1
    }

    await checkAsync("MCP browse: a click, fill or select after the yes gets an external run journal row; open, snapshot and a no get none") {
        let journal = try Executor(baseDirectory: root.appendingPathComponent("browse-journal-" + UUID().uuidString))
        let w = world(confirm: { $0 != "select" }, journal: journal)
        _ = await browse(w, ["action": "open", "url": page])
        _ = await browse(w, ["action": "click", "ref": "@e1", "snapshot_id": "s1"])
        _ = await browse(w, ["action": "snapshot"])
        _ = await browse(w, ["action": "fill", "ref": "@e2", "text": "Öffnungszeiten"])
        _ = await browse(w, ["action": "select", "ref": "@e4", "value": "English"])
        let rows = try await journal.runActions(run: w.turn.id)
        return rows.map(\.object.kind) == ["browser.click", "browser.fill"] && rows.allSatisfy { $0.actionClass == .external && $0.state == .done }
            && rows.allSatisfy { $0.tool == "browse" && !$0.label.isEmpty }
    }

    await checkAsync("MCP browse: a click that reached the page, then a blocked redirect or a closed browser, leaves an unclear row") {
        /// The page as the demo shows it; every click then ends with `error`, as after the step acted.
        struct AfterClick: BrowserOperating {
            let error: BrowserError
            func currentSnapshot() async -> BrowserSnapshot? { DemoBrowserOperator.example(URL(string: "https://example.org/kontakt")!, "s1") }
            func perform(_ action: BrowserAction) async throws -> BrowserSnapshot? { throw error }
        }
        var states: [RunAction.State] = []
        for error in [BrowserError.blockedAddress, .nothingOpen] {
            let journal = try Executor(baseDirectory: root.appendingPathComponent("browse-after-" + UUID().uuidString))
            let w = world(journal: journal, operating: AfterClick(error: error))
            let r = await browse(w, ["action": "click", "ref": "@e3", "snapshot_id": "s1"])
            guard r.isError, r.json["dispatched"] as? Bool == true else { return false }
            states += try await journal.runActions(run: w.turn.id).map(\.state)
        }
        return states == [.unclear, .unclear]
    }

    await checkAsync("MCP browse: stale or unknown refs fail before asking or acting") {
        let w = world()
        let early = await browse(w, ["action": "click", "ref": "@e1"])
        _ = await browse(w, ["action": "open", "url": page])
        let mismatch = await browse(w, ["action": "click", "ref": "@e1", "snapshot_id": "s0"])
        let unknown = await browse(w, ["action": "click", "ref": "@e99"])
        let unknownFill = await browse(w, ["action": "fill", "ref": "@e99", "text": "x", "snapshot_id": "s1"])
        return [early, mismatch, unknown, unknownFill].allSatisfy {
            $0.isError && $0.json["status"] as? String == "stale_ref" && $0.json["dispatched"] as? Bool == false
        } && w.asked.value == ["open"] && w.browser.actions.count == 1
    }

    let login: DemoBrowserOperator.Page = { url, id in
        BrowserSnapshot(snapshotId: id, url: url.absoluteString, title: "Anmelden", text: "Bitte anmelden.",
                        refs: [BrowserElementRef(ref: "@e1", role: "textbox", name: "E-Mail", type: "email"),
                               BrowserElementRef(ref: "@e2", role: "textbox", name: "Passwort", type: "password", value: "geheim-123")],
                        loginDetected: true)
    }
    await checkAsync("MCP browse: login pages hand over to the person; password values never reach Pi and are never filled") {
        let w = world(page: login)
        let open = await browse(w, ["action": "open", "url": page])
        let fill = await browse(w, ["action": "fill", "ref": "@e2", "text": "hunter2", "snapshot_id": "s1"])
        return !open.isError && open.json["status"] as? String == "handoff_required" && open.json["done"] as? Bool == false
            && open.json["dispatched"] as? Bool == false && (open.json["tell"] as? String)?.isEmpty == false
            && (open.json["next"] as? String)?.contains("Never ask the person for passwords") == true
            && !open.text.contains("geheim-123") && !fill.text.contains("hunter2")
            && fill.json["status"] as? String == "handoff_required" && fill.json["dispatched"] as? Bool == false
            && w.handoffs.value == ["login", "password"] && w.asked.value == ["open"]
            && !w.browser.actions.contains { if case .fill = $0 { true } else { false } }
    }

    await checkAsync("MCP browse: a CAPTCHA after a click hands over and says the click happened") {
        let clicked = LockedBox(false)
        let w = world(page: { url, id in
            var p = DemoBrowserOperator.example(url, id)
            p.captchaDetected = clicked.value
            return p
        })
        _ = await browse(w, ["action": "open", "url": page])
        clicked.mutate { $0 = true }
        let r = await browse(w, ["action": "click", "ref": "@e3", "snapshot_id": "s1"])
        return r.json["status"] as? String == "handoff_required" && r.json["reason"] as? String == "captcha"
            && r.json["dispatched"] as? Bool == true && w.handoffs.value == ["captcha"]
    }

    await checkAsync("MCP browse: a huge page stays within the result limit and says it was cut") {
        let w = world(page: { url, id in
            BrowserSnapshot(snapshotId: id, url: url.absoluteString, title: String(repeating: "T", count: 500),
                            text: String(repeating: "Ein langer Absatz mit vielen Wörtern. ", count: 400),
                            refs: (1...300).map { BrowserElementRef(ref: "@e\($0)", role: "link", name: String(repeating: "Link \($0) ", count: 20)) })
        })
        let r = await browse(w, ["action": "open", "url": page])
        let d = data(r.json)
        return r.text.utf8.count <= PippaMCPBrowserTool.maxResultBytes && r.text.utf8.count <= PippaMCPTools.maxResultBytes
            && d["truncated"] as? Bool == true && !(d["refs"] as? [Any] ?? []).isEmpty && r.json["done"] as? Bool == true
    }

    /// Opens `page`, clicks the one element and returns the approval card it produced.
    func clickPrompt(_ element: BrowserElementRef) async -> (title: String, message: String, json: [String: Any], text: String)? {
        let w = world(page: { url, id in
            BrowserSnapshot(snapshotId: id, url: url.absoluteString, title: "Test", text: "Test", refs: [element])
        })
        let open = await browse(w, ["action": "open", "url": page])
        _ = await browse(w, ["action": "click", "ref": "@e1", "snapshot_id": "s1"])
        guard let card = w.prompts.value.last, w.asked.value.last == "click" else { return nil }
        return (card.title, card.message, open.json, open.text)
    }
    let book = "https://example.org/book?secret=123#frag"

    await checkAsync("MCP browse: a form submit names its destination path, never the query") {
        guard let card = await clickPrompt(BrowserElementRef(ref: "@e1", role: "button", name: "Weiter", type: "submit",
                                                             submitsForm: true, formAction: book)) else { return false }
        return card.title == L("May Pippa submit this?", table: "Tools") && card.message.contains("/book")
            && !card.message.contains("secret") && !card.message.contains("123") && !card.message.contains("frag")
    }

    await checkAsync("MCP browse: a cross-host form submit names host and path, never the query") {
        guard let card = await clickPrompt(BrowserElementRef(ref: "@e1", role: "button", name: "Bezahlen", type: "submit",
                                                             submitsForm: true, formAction: "https://pay.other.org/checkout?id=9")) else { return false }
        return card.title == L("May Pippa submit this?", table: "Tools") && card.message.contains("pay.other.org/checkout")
            && !card.message.contains("id=9")
    }

    await checkAsync("MCP browse: a link to another host names that host; same-host links and plain buttons keep the click wording") {
        guard let link = await clickPrompt(BrowserElementRef(ref: "@e1", role: "link", name: "Shop", href: "https://shop.other.org/a?token=abc")),
              let same = await clickPrompt(BrowserElementRef(ref: "@e1", role: "link", name: "Impressum", href: "https://www.example.org/impressum")),
              let plain = await clickPrompt(BrowserElementRef(ref: "@e1", role: "button", name: "Mehr"))
        else { return false }
        let click = L("May Pippa click this?", table: "Tools")
        return link.title == L("May Pippa open this link?", table: "Tools") && link.message.contains("shop.other.org") && !link.message.contains("token")
            && same.title == click && same.message == L("On %@, Pippa wants to click “%@”.", table: "Tools", "example.org", "Impressum")
            && plain.title == click && plain.message == L("On %@, Pippa wants to click “%@”.", table: "Tools", "example.org", "Mehr")
    }

    await checkAsync("MCP browse: malformed form actions and links fall back safely without leaking") {
        for action in ["javascript:void(0)", "#section", "", "/relative?x=SECRET", "https://", "https://example.org/?q=SECRET", "mailto:a@b.c?subject=SECRET"] {
            guard let card = await clickPrompt(BrowserElementRef(ref: "@e1", role: "button", name: "Go", type: "submit",
                                                                 submitsForm: true, formAction: action)),
                  card.title == L("May Pippa submit this?", table: "Tools"), !card.message.contains("SECRET") else { return false }
        }
        for href in ["javascript:void(0)", "#section", "", "https://", "mailto:a@b.c"] {
            guard let card = await clickPrompt(BrowserElementRef(ref: "@e1", role: "link", name: "Go", href: href)),
                  card.title == L("May Pippa click this?", table: "Tools") else { return false }
        }
        return true
    }

    await checkAsync("MCP browse: snapshot JSON for Pi carries no form action, submit flag or link target") {
        guard let card = await clickPrompt(BrowserElementRef(ref: "@e1", role: "button", name: "Weiter", type: "submit", submitsForm: true,
                                                             formAction: book, href: "https://shop.other.org/a?token=abc")) else { return false }
        return card.text.utf8.count <= PippaMCPBrowserTool.maxResultBytes
            && !card.text.contains("formAction") && !card.text.contains("submitsForm") && !card.text.contains("href")
            && !card.text.contains("secret=123") && !card.text.contains("token=abc")
    }

    await checkAsync("MCP browse: back and close need no extra OK; nothing open says so; no browser is unavailable") {
        let w = world()
        let nothing = await browse(w, ["action": "snapshot"])
        _ = await browse(w, ["action": "open", "url": page])
        let back = await browse(w, ["action": "back"])
        let close = await browse(w, ["action": "close"])
        let after = await browse(w, ["action": "snapshot"])
        let demo = DemoIntegrations(granted: true)
        let bare = PippaMCPTools(host: PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true),
                                                    hostData: DemoHostData(integrations: demo, now: Date())))
        let missing = await browse(World(tools: bare, browser: DemoBrowserOperator(), asked: .init([]), handoffs: .init([]),
                                         notes: .init([]), turns: w.turns, turn: w.turn),
                                   ["action": "snapshot"])
        return nothing.isError && nothing.json["status"] as? String == "unavailable"
            && back.json["done"] as? Bool == true && close.json["done"] as? Bool == true && data(close.json)["closed"] as? Bool == true
            && after.json["status"] as? String == "unavailable" && w.asked.value == ["open"]
            && missing.isError && missing.json["status"] as? String == "unavailable"
            && PippaMCPHost.demo().browser != nil
    }

    await checkAsync("MCP browse: a stopped answer opens and changes nothing") {
        let w = world()
        let turns = PippaMCPTurns()
        var host = PippaMCPHost(integrations: DemoIntegrations(granted: true), sheets: DemoSheetReader(granted: true),
                                hostData: DemoHostData(integrations: DemoIntegrations(granted: true), now: Date()))
        host.turns = turns; host.requireActiveWriteTurn = true; host.browser = w.browser
        host.confirmBrowser = { _, _, _ in true }
        let tools = PippaMCPTools(host: host)
        let r = await browse(World(tools: tools, browser: w.browser, asked: w.asked, handoffs: w.handoffs,
                                   notes: w.notes, turns: turns, turn: w.turn),
                             ["action": "open", "url": page])
        return r.isError && r.json["status"] as? String == "cancelled" && w.browser.actions.isEmpty
    }

    await checkAsync("MCP browse: trailing-dot local names and private DNS mappings are blocked before asking") {
        let w = world(privateHost: { $0 == "rebind.example.org" })
        let trailingDot = await browse(w, ["action": "open", "url": "http://localhost.:8080/bypass"])
        let lan = await browse(w, ["action": "open", "url": "http://router.lan/"])
        let internalHost = await browse(w, ["action": "open", "url": "http://api.internal/"])
        let rebind = await browse(w, ["action": "open", "url": "https://rebind.example.org/"])
        return [trailingDot, lan, internalHost, rebind].allSatisfy {
            $0.isError && $0.json["status"] as? String == "blocked"
        } && w.asked.value.isEmpty && w.browser.actions.isEmpty
    }

    await checkAsync("MCP browse: nil-turn approvals never persist and different turns stay isolated") {
        let approvals = PippaMCPBrowserApprovals()
        approvals.approve("example.org", turn: nil)
        let t1 = UUID(), t2 = UUID()
        approvals.approve("example.org", turn: t1)
        return !approvals.approved("example.org", turn: nil)
            && approvals.approved("example.org", turn: t1)
            && !approvals.approved("example.org", turn: t2)
    }

    await checkAsync("MCP browse: cancelling a turn inside open confirmation blocks dispatch and caching") {
        let turns = PippaMCPTurns()
        let turn = PippaMCPTurn()
        turns.begin(turn)
        let demo = DemoIntegrations(granted: true)
        var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: Date()))
        host.turns = turns
        host.browser = DemoBrowserOperator()
        host.resolveHostIsPrivate = { _ in false }
        host.confirmBrowser = { _, _, _ in
            turn.cancelWrites()
            return true
        }
        let tools = PippaMCPTools(host: host)
        let w = World(tools: tools, browser: host.browser as! DemoBrowserOperator, asked: .init([]), handoffs: .init([]),
                      notes: .init([]), turns: turns, turn: turn)
        let r = await browse(w, ["action": "open", "url": page])
        return r.isError && r.json["status"] as? String == "cancelled"
            && r.json["dispatched"] as? Bool == false
            && w.browser.actions.isEmpty
            && !host.browserApprovals.approved("example.org", turn: turn.id)
    }

    await checkAsync("MCP browse: sensitive verification-code refs are redacted and refused for fill") {
        let otpPage: DemoBrowserOperator.Page = { url, id in
            BrowserSnapshot(snapshotId: id, url: url.absoluteString, title: "Bestätigung", text: "Code eingeben",
                            refs: [BrowserElementRef(ref: "@e1", role: "textbox", name: "Einmalcode", type: "text",
                                                     value: "123456", sensitive: true)],
                            loginDetected: true)
        }
        let w = world(page: otpPage)
        let open = await browse(w, ["action": "open", "url": page])
        let fill = await browse(w, ["action": "fill", "ref": "@e1", "text": "654321", "snapshot_id": "s1"])
        return open.json["status"] as? String == "handoff_required"
            && !open.text.contains("123456")
            && fill.json["status"] as? String == "handoff_required"
            && fill.json["dispatched"] as? Bool == false
            && !fill.text.contains("654321")
            && !w.browser.actions.contains { if case .fill = $0 { true } else { false } }
    }
}
