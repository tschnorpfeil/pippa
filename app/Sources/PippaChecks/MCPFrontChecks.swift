import Foundation
import PippaCore

/// Accessibility stand-in: a fixed state, the system prompt's answer and counters, never the real TCC.
private final class StandInAccessibility: AccessibilityFrontReading, @unchecked Sendable {
    private let lock = NSLock()
    private var state: IntegrationAccess
    private let answer: IntegrationAccess
    private let content: FrontContent?
    private var asked = 0, read = 0
    init(_ state: IntegrationAccess, answer: IntegrationAccess = .granted, content: FrontContent? = nil) {
        self.state = state; self.answer = answer; self.content = content
    }
    func accessibilityAccess(ask: Bool) -> IntegrationAccess {
        lock.withLock {
            if ask { asked += 1; state = answer }
            return state
        }
    }
    func readAccessibility(_ app: FrontApp) async throws -> FrontContent? { lock.withLock { read += 1; return content } }
    var counts: (asked: Int, read: Int) { lock.withLock { (asked, read) } }
}

extension MCPCheckContext {
    func excelChecks() async {
        // MARK: Excel

        await checkAsync("MCP excel_selection: sheet with values and formulas (stand-in), plain text without permission") {
            let s = setup()
            let r = await call(s.tools, "excel_selection")
            let sheet = (r.json["data"] as? [String: Any])?["sheet"] as? String ?? ""
            let no = setup(granted: false)
            let notYet = await call(no.tools, "excel_selection")
            return !r.isError && sheet.contains("Kosten 2026") && sheet.contains("[=SUM(B2:B4)]") && r.json["untrusted"] as? Bool == true
                && notYet.isError && notYet.json["status"] as? String == "needs_access"
        }
    }

    func frontChecks() async {
        // MARK: App in front

        check("Front app label: app and title on one line, cut at 80 characters; title equal to the name is left out") {
            let safari = FrontApp(name: "Safari", bundleID: FrontApp.safari, pid: 1, title: "Mietrecht Kaution – Beispielseite")
            let plain = FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 2, title: "TextEdit")
            let long = FrontApp(name: "Safari", bundleID: FrontApp.safari, pid: 1, title: String(repeating: "Kaution ", count: 30) + "\nzweite Zeile")
            let cut = long.shortTitle ?? ""
            return safari.label(german: true) == "[Im Vordergrund: Safari – „Mietrecht Kaution – Beispielseite“]"
                && safari.label(german: false) == "[In front: Safari – “Mietrecht Kaution – Beispielseite”]"
                && plain.label(german: true) == "[Im Vordergrund: TextEdit]"
                && cut.count == FrontApp.titleLimit && cut.hasSuffix("…") && !cut.contains("\n")
        }
        await checkAsync("MCP front_read: only the chip's app; page text as untrusted data; without chip, permission or window plain text") {
            let safari = FrontApp(name: "Safari", bundleID: FrontApp.safari, pid: 1, title: "Mietkaution – Beispielseite")
            func host(_ shown: FrontApp?, _ front: DemoFrontApp, notes: Box<PippaMCPReadNote>? = nil, asked: Box<String>? = nil) -> PippaMCPTools {
                let demo = DemoIntegrations(granted: true)
                var h = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                                     askForAccess: asked != nil, now: { now }, calendar: berlin,
                                     explainAccess: { subject, sentence in asked?.append("\(subject.appName)|\(sentence)"); return true },
                                     onRead: { notes?.append($0) })
                h.shownFront = { shown }
                h.front = front
                return PippaMCPTools(host: h)
            }
            let notes = Box<PippaMCPReadNote>()
            let read = await call(host(safari, DemoFrontApp(), notes: notes), "front_read")
            let data = read.json["data"] as? [String: Any] ?? [:]
            let none = await call(host(nil, DemoFrontApp()), "front_read")
            let denied = await call(host(safari, DemoFrontApp(access: .denied)), "front_read")
            let empty = await call(host(safari, DemoFrontApp(content: nil)), "front_read")
            let asked = Box<String>()
            let first = await call(host(safari, DemoFrontApp(access: .notDetermined), asked: asked), "front_read")
            return !read.isError && read.json["untrusted"] as? Bool == true && data["app"] as? String == "Safari"
                && (data["text"] as? String)?.contains("drei Nettokaltmieten") == true && data["url"] as? String == "https://beispiel.example/kaution"
                && notes.all.first?.line == L("Read %@: “%@”", table: "MCP", "Safari", "Mietkaution – Beispielseite")
                && none.isError && none.json["status"] as? String == "nothing_shown"
                && denied.isError && (denied.json["tell"] as? String)?.contains("Automation") == true
                && empty.isError && empty.json["status"] as? String == "nothing_open"
                && !first.isError && asked.all == ["Safari|\(PippaMCPTools.accessExplanation(.front("Safari")))"]
        }
        await checkAsync("MCP front_read: Accessibility only when Apple Events bring nothing; bounded window text as untrusted data") {
            let slack = FrontApp(name: "Slack", bundleID: "com.example.chat", pid: 4, title: "Team")
            let window = FrontContent(kind: .page, title: "Team – Chat", text: "Kaution kommt Freitag\n\n\n" + String(repeating: "x", count: 7000))
            func tools(_ app: FrontApp, _ front: DemoFrontApp, ask: Bool = false, explain: Box<String>? = nil, go: Bool = true) -> PippaMCPTools {
                let demo = DemoIntegrations(granted: true)
                var h = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                                     askForAccess: ask, now: { now }, calendar: berlin,
                                     explainAccess: { subject, _ in explain?.append(subject.appName); return go })
                h.shownFront = { app }
                h.front = front
                return PippaMCPTools(host: h)
            }
            // Apple Events have the page: Accessibility is never asked.
            let primaryAX = StandInAccessibility(.granted, content: window)
            let primary = await call(tools(slack, DemoFrontApp(accessibility: primaryAX)), "front_read")
            // Nothing via Apple Events (not scriptable, or no front document): the window text instead.
            let fallbackAX = StandInAccessibility(.granted, content: window)
            let fallback = await call(tools(slack, DemoFrontApp(content: nil, accessibility: fallbackAX)), "front_read")
            let data = fallback.json["data"] as? [String: Any] ?? [:]
            let text = data["text"] as? String ?? ""
            let unavailableAX = StandInAccessibility(.granted, content: window)
            let unscriptable = await call(tools(slack, DemoFrontApp(access: .unavailable("not scriptable"), accessibility: unavailableAX)), "front_read")
            // Automation denied stays an Automation repair, Accessibility is not tried.
            let automationAX = StandInAccessibility(.granted, content: window)
            let automation = await call(tools(slack, DemoFrontApp(access: .denied, accessibility: automationAX)), "front_read")
            // Accessibility finds no text: the old answer.
            let blankAX = StandInAccessibility(.granted, content: FrontContent(kind: .page, title: "Leer", text: ""))
            let blank = await call(tools(slack, DemoFrontApp(content: nil, accessibility: blankAX)), "front_read")
            return !primary.isError && ((primary.json["data"] as? [String: Any])?["text"] as? String)?.contains("drei Nettokaltmieten") == true
                && (primary.json["data"] as? [String: Any])?["via"] == nil && primaryAX.counts == (0, 0)
                && !fallback.isError && fallback.json["untrusted"] as? Bool == true && data["via"] as? String == "accessibility"
                && data["app"] as? String == "Slack" && data["title"] as? String == "Team – Chat"
                && text.hasPrefix("Kaution kommt Freitag\n\nxxx") && text.count == 6000 && data["textTruncated"] as? Bool == true
                && fallbackAX.counts == (0, 1)
                && !unscriptable.isError && unavailableAX.counts.read == 1
                && automation.isError && automation.json["status"] as? String == "denied"
                && (automation.json["tell"] as? String)?.contains("Automation") == true && automationAX.counts == (0, 0)
                && blank.isError && blank.json["status"] as? String == "nothing_open" && blank.json["app"] as? String == "Slack"
        }
        await checkAsync("MCP front_read: Accessibility permission – headless needs_access, declined sentence never prompts, denied repairs Accessibility") {
            let notes = Box<PippaMCPReadNote>()
            let app = FrontApp(name: "Notes", bundleID: "com.example.notes", pid: 5)
            let window = FrontContent(kind: .page, title: "Einkauf", text: "Milch")
            func run(_ ax: StandInAccessibility, ask: Bool, go: Bool = true, explain: Box<String>? = nil) async -> (json: [String: Any], isError: Bool, bytes: Int) {
                let demo = DemoIntegrations(granted: true)
                var h = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                                     askForAccess: ask, now: { now }, calendar: berlin,
                                     explainAccess: { subject, sentence in explain?.append("\(subject.appName)|\(sentence)"); return go },
                                     onRead: { notes.append($0) })
                h.shownFront = { app }
                h.front = DemoFrontApp(content: nil, accessibility: ax)
                return await call(PippaMCPTools(host: h), "front_read")
            }
            let headlessAX = StandInAccessibility(.notDetermined, content: window)
            let headless = await run(headlessAX, ask: false)
            let declinedAX = StandInAccessibility(.notDetermined, content: window), declinedSentence = Box<String>()
            let declined = await run(declinedAX, ask: true, go: false, explain: declinedSentence)
            let allowedAX = StandInAccessibility(.notDetermined, content: window), allowedSentence = Box<String>()
            let allowed = await run(allowedAX, ask: true, explain: allowedSentence)
            let promptDeniedAX = StandInAccessibility(.notDetermined, answer: .denied, content: window)
            let promptDenied = await run(promptDeniedAX, ask: true)
            let deniedAX = StandInAccessibility(.denied, content: window)
            let denied = await run(deniedAX, ask: true)
            let sentence = "Notes|\(PippaMCPTools.accessExplanation(.front("Notes")))"
            return headless.isError && headless.json["status"] as? String == "needs_access" && headlessAX.counts == (0, 0)
                && (headless.json["tell"] as? String)?.contains("Accessibility") == true
                && declined.isError && declined.json["status"] as? String == "needs_access" && declinedAX.counts == (0, 0)
                && declinedSentence.all == [sentence]
                && !allowed.isError && allowedAX.counts == (1, 1) && allowedSentence.all == [sentence]
                && promptDenied.isError && promptDenied.json["status"] as? String == "denied" && promptDeniedAX.counts == (1, 0)
                && denied.isError && denied.json["status"] as? String == "denied" && deniedAX.counts == (0, 0)
                && (denied.json["tell"] as? String)?.contains("Accessibility") == true && denied.json["app"] as? String == "Notes"
                && notes.all.filter { $0.permissionRepair == .accessibility }.count == 2
        }
        check("Accessibility walk: depth ≤ 12, nodes ≤ 800, chrome skipped, repeated lines once, 6000 characters at most") {
            // A chain 30 levels deep: text below level 12 is never reached.
            var chain = AXNodeSample(role: "AXStaticText", texts: ["level 30"])
            for level in stride(from: 29, through: 0, by: -1) { chain = AXNodeSample(role: "AXGroup", texts: ["level \(level)"], children: [chain]) }
            let deep = AccessibilityText.collect(chain)
            // 2000 siblings, nearly all without text: the walk stops after 800 nodes (the window and 799 rows).
            let wide = AccessibilityText.collect(AXNodeSample(role: "AXWindow", children: (0..<2000).map {
                AXNodeSample(role: "AXStaticText", texts: $0 == 798 ? ["last read"] : $0 == 799 ? ["never read"] : [])
            }))
            let chrome = AccessibilityText.collect(AXNodeSample(role: "AXWindow", texts: ["Inbox"], children: [
                AXNodeSample(role: "AXToolbar", texts: ["Back"], children: [AXNodeSample(role: "AXTextField", texts: ["https://hidden.example"])]),
                AXNodeSample(role: "AXMenuBar", texts: ["File"]), AXNodeSample(role: "AXScrollBar", texts: ["0.5"]),
                AXNodeSample(role: "AXSplitter"), AXNodeSample(role: "AXSecureTextField", texts: ["hunter2"]),
                AXNodeSample(role: "AXStaticText", texts: ["Hello", "Hello", "  "]), AXNodeSample(role: "AXStaticText", texts: ["Hello"]),
                AXNodeSample(role: "AXTextArea", texts: ["", "line one\n\n  line   two  ", ""]), AXNodeSample(role: "AXStaticText", texts: ["Inbox"]),
            ]))
            let long = AccessibilityText.collect(AXNodeSample(role: "AXWindow", children: (0..<50).map { AXNodeSample(role: "AXStaticText", texts: ["\($0) " + String(repeating: "a", count: 300)]) }))
            return deep.deepest == AccessibilityText.maxDepth && deep.lines.count == 13 && deep.lines.last == "level 12" && !deep.text.contains("level 13")
                && wide.visited == AccessibilityText.maxNodes && wide.clipped && wide.lines == ["last read"]
                && chrome.lines == ["Inbox", "Hello", "line one", "line two", "Inbox"]
                && !chrome.text.contains("hidden.example") && !chrome.text.contains("hunter2") && !chrome.clipped
                && long.text.count == AccessibilityText.maxChars && long.clipped && long.visited < 50
        }
        await checkAsync("MCP front_read: with Mail in front it reads the selected mail (same receipt as mail_selected)") {
            let notes = Box<PippaMCPReadNote>()
            let demo = DemoIntegrations(granted: true)
            var h = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                                 askForAccess: false, now: { now }, calendar: berlin, onRead: { notes.append($0) })
            h.shownFront = { FrontApp(name: "Mail", bundleID: Integration.mail.bundleIdentifier, pid: 3) }
            h.front = DemoFrontApp(access: .denied)
            let r = await call(PippaMCPTools(host: h), "front_read")
            let direct = await call(setup().tools, "mail_selected")
            return !r.isError && (r.json["data"] as? [String: Any])?["subject"] as? String == (direct.json["data"] as? [String: Any])?["subject"] as? String
                && notes.all.first?.tool == "mail_selected"
        }
    }
}
