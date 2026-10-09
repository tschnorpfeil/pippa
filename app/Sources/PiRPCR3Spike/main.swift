import Foundation
import PiRPC
import PippaCore

// R3 end-to-end probe: appointment, reminder, mail draft via Pippa's MCP server with real Pi and
// a real local model. Launched as in the app (PippaPiLaunch.configuration + Pippa's extensions + Pippa's
// MCP server in this process). **Stand-in integrations only** (`DemoIntegrations`): invented appointments, drafts and
// entries live only in this process's memory; real Mail, real Calendar and real Reminders are never touched.
//
//   scripts/pi-rpc-spike.sh setup && scripts/pi-rpc-spike.sh llama-start [k2|qwen]
//   scripts/pi-rpc-spike.sh r3 [hfbar|all]
//   scripts/pi-rpc-spike.sh llama-stop
//
// h: warm-up ("Sag nur: Hallo.")
// f: mail proposes Thursday 9 am, calendar free → "Antworte auf die Mail und trag den Termin ein, wenn Donnerstag
//    9 Uhr frei ist". Expected: read calendar, draft, create appointment.
// b: same request, but Thursday 9 am is busy → no appointment, the reply draft says so.
// a: "after OK": "Passt mir Donnerstag 9 Uhr? Schreib eine Antwort." → draft, but **no** appointment; question in the text.
// r: "Erinnere mich morgen um 18 Uhr an den Müll." → reminder_add.

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let which = CommandLine.arguments.dropFirst().first ?? "all"
let clock = ContinuousClock()
func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
func oneLine(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ ") }

guard let home = env["PIPPA_PI_HOME"], let payload = PiPayload.locate(environment: env), let extensions = env["PIPPA_PI_EXTENSIONS"],
      let work = env["PIPPA_SPIKE_WORK"], let agent = env["PI_CODING_AGENT_DIR"] else {
    print("First run: scripts/pi-rpc-spike.sh setup (PIPPA_PI_HOME, PIPPA_PI_PAYLOAD, PIPPA_PI_EXTENSIONS, PIPPA_SPIKE_WORK, PI_CODING_AGENT_DIR)"); exit(2)
}
let calendar = Calendar.autoupdatingCurrent
let now = Date()
let today = calendar.startOfDay(for: now)
// The next Thursday after today (like PippaMCPWriteTools.day "thursday").
let thursday = calendar.nextDate(after: today, matching: DateComponents(weekday: 5), matchingPolicy: .nextTime)!
func on(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)! }
let dayLabel: String = {
    let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM"; return f.string(from: thursday)
}()

let corpus = URL(fileURLWithPath: work, isDirectory: true).deletingLastPathComponent().appendingPathComponent("r3-corpus", isDirectory: true)
try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
let mail = corpus.appendingPathComponent("terminvorschlag.eml")
try """
From: Praxis Dr. Beispiel <termine@praxis-beispiel.example>
Subject: Ihr Kontrolltermin
Message-ID: <r3-kontrolltermin-0001@praxis-beispiel.example>
Date: \({ let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return f.string(from: now) }())
Content-Type: text/plain; charset=utf-8

Guten Tag,

für Ihren Kontrolltermin schlagen wir \(dayLabel), um 9:00 Uhr vor (Dauer etwa 30 Minuten).
Bitte geben Sie uns kurz Bescheid, ob Ihnen der Termin passt.

Mit freundlichen Grüßen
Praxis Dr. Beispiel
""".write(to: mail, atomically: true, encoding: .utf8)

struct Case {
    let id: String, title: String, files: [URL], question: String
    var events: [CalendarEvent] = []
}
let other = CalendarEvent(id: "o", title: "Einkauf (Beispiel)", start: on(thursday, 17), end: on(thursday, 18), calendar: "Privat")
let busy = CalendarEvent(id: "b", title: "Team-Besprechung (Beispiel)", start: on(thursday, 8, 30), end: on(thursday, 10), calendar: "Arbeit")
let cases: [Case] = [
    Case(id: "h", title: "Warm-up", files: [], question: "Sag nur: Hallo."),
    Case(id: "f", title: "Mail with appointment proposal, free, create if free", files: [mail],
         question: "Antworte auf die Mail und trag den Termin ein, wenn Donnerstag 9 Uhr frei ist.", events: [other]),
    Case(id: "b", title: "Mail with appointment proposal, busy", files: [mail],
         question: "Antworte auf die Mail und trag den Termin ein, wenn Donnerstag 9 Uhr frei ist.", events: [busy, other]),
    Case(id: "a", title: "\"After OK\": only ask and answer", files: [mail],
         question: "Passt mir der Termin? Schreib eine Antwort.", events: [other]),
    Case(id: "r", title: "Reminder", files: [], question: "Erinnere mich morgen um 18 Uhr daran, den Müll rauszubringen."),
]

let homeURL = URL(fileURLWithPath: home, isDirectory: true)
let roots = PiInstallRoots(home: homeURL, payload: payload, searchPath: [homeURL.appendingPathComponent(".local/bin")])
let model = env["PIPPA_PI_MODEL"] ?? "k2-horizon-7b"
guard let spec = PiInstaller(roots: roots).launchSpec(modelID: model) else { print("Pi missing in the fake HOME (setup)"); exit(2) }
let launcher = PippaPiLaunch.Launcher(executable: spec.executable, launcherArguments: spec.launcherArguments, piArguments: spec.piArguments, environment: spec.environment)
let toolsDir = URL(fileURLWithPath: extensions, isDirectory: true)
let workDir = URL(fileURLWithPath: work, isDirectory: true)
let paths = PippaPiLaunch.Paths(extensionsDirectory: toolsDir, webExtension: nil,
                                sessionDirectory: URL(fileURLWithPath: env["PIPPA_SPIKE_SESSIONS"] ?? work + "-sessions", isDirectory: true))
let piEnv = ["PI_CODING_AGENT_DIR": agent, "PIPPA_TRASH_DIR": env["PIPPA_TRASH_DIR"] ?? work + "-trash"]
print("Pi \(model) · Thursday = \(dayLabel)")

final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [PippaMCPWriteReceipt] = []
    func append(_ note: PippaMCPWriteReceipt) { lock.withLock { notes.append(note) } }
    var all: [PippaMCPWriteReceipt] { lock.withLock { notes } }
}

var summary: [String] = []
for c in cases where which == "all" || which.contains(c.id) {
    print("\n## (\(c.id)) \(c.title)")
    // A fresh stand-in per case: only these invented appointments, drafts in memory only.
    let demo = DemoIntegrations(granted: true)
    demo.calendarEvents = c.events
    var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                            askForAccess: false)
    host.writer = demo
    let writes = Notes()
    host.onWrite = { writes.append($0) }
    let server = try PippaMCPServer(host: host)
    try await server.start()
    let prompt = PiShownContext.prompt(.init(question: c.question, files: c.files, newFiles: c.files, language: "de"))
    let configuration = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: workDir, paths: paths, sessionID: nil, language: "de",
                                                    environment: piEnv, mcp: (.init(url: server.url, token: server.token), toolsDir.appendingPathComponent("pippa-mcp.ts")))
    let client = PiRPCClient(configuration: configuration)
    nonisolated(unsafe) var asked: [String] = []
    await client.setUIHandler { request in
        asked.append(oneLine(request.title + " | " + request.message))
        return request.method == "select" ? .value(request.options.first ?? "") : .confirmed(true)
    }
    try await client.start()
    let t0 = clock.now
    var first: Int?, text = "", tools: [String] = []
    var receipt = PiTurnReceipt()
    for try await event in try await client.prompt(prompt) {
        receipt.observe(event)
        let t = ms(clock.now - t0)
        switch event {
        case .textDelta(let d): if first == nil { first = t }; text += d
        case .toolStarted(_, let name, let arguments): tools.append(name.replacingOccurrences(of: "mcp__pippa__", with: "")); print("    [\(t) ms] TOOL \(name) \(oneLine(String(arguments.prefix(400))))")
        case .toolEnded(_, let name, let isError, let result): print("    [\(t) ms] DONE \(name)\(isError ? " ERROR" : "") \(oneLine(String(result.prefix(300))))")
        case .assistantEnded(_, let reason, let error): if reason != "toolUse" { print("    [\(t) ms] End (\(reason))\(error.map { " \($0)" } ?? "")") }
        default: break
        }
    }
    let total = ms(clock.now - t0)
    let stats = (try? await client.command(["type": "get_session_stats"])).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    await client.shutdown()
    let tokens = stats?["tokens"] as? [String: Any]
    // Like PiRPCChat.actions: lines from events, write lines from the server's own receipts; read lines left out here.
    var pending = writes.all
    let items = receipt.records.filter { $0.action != "read" }.map { r -> ActionReceipt.Item in
        if r.action == "write", !pending.isEmpty { return pending.removeFirst().item }
        return ActionReceipt.Item(action: r.action, outcome: r.outcome.rawValue, name: r.name, toName: r.toName)
    }
    print("  < \(oneLine(text))")
    print("  = Tools \(tools), questions \(asked.count)\(asked.isEmpty ? "" : " \(asked)")")
    for item in items { print("  = Receipt: \(item.line(language: "de"))\(item.canOpenMailDraft ? " [Open draft]" : "")") }
    // Follow-up "Save as draft in Mail" (like PiRPCChat.takeShownActions): line and offer from code; click like the button.
    let rule = MailDraftOfferRule.evaluate(answer: text, mailSource: MailDraftOfferRule.shownMail(files: c.files, focused: []), items: items)
    if let line = rule.line { print("  = Receipt: \(line.line(language: "de"))\(rule.offer == nil ? "" : " [As draft in Mail]")") }
    if let offer = rule.offer {
        print("  = Offer (reply text from the answer):\n      | \(offer.body.replacingOccurrences(of: "\n", with: "\n      | "))")
        let clicked = await MailDraftOfferRule.save(offer, with: PippaMCPWriteTools(host: host)).item
        print("  = Click \"As draft in Mail\": \(clicked.line(language: "de"))")
    }
    let drafts = demo.insertedDrafts
    for d in drafts { print("  = Draft (stand-in mail, never sent): to \(d.to ?? "-") · \(d.replySubject) · reply in thread: \(d.isReply) · Message-ID \(d.messageID ?? "-")\n      | \(d.body.replacingOccurrences(of: "\n", with: "\n      | "))") }
    let entries = try await demo.events(in: DateInterval(start: today, end: calendar.date(byAdding: .day, value: 8, to: today)!), limit: 50)
        .events.filter { e in !c.events.contains { $0.id == e.id } }
    for e in entries { print("  = New appointment in the stand-in calendar: \(e.title) \(e.start) – \(e.end)") }
    print("  = Entries created: \(demo.createdCount)")
    print("  = first word \(first ?? -1) ms, total \(total) ms, tokens in \(tokens?["input"] ?? "?") + cache \(tokens?["cacheRead"] ?? "?"), out \(tokens?["output"] ?? "?")")
    summary.append("(\(c.id)) \(tools) · receipt \(items.map { $0.line(language: "de") }) · drafts \(drafts.count)")
    server.stop()
}
print("\n## Summary")
for line in summary { print(line) }
