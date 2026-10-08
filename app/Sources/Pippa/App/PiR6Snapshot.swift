import AppKit
import PippaCore

#if DEBUG
/// One real pass through the default path in the real window, in a fake HOME
/// (scripts/pi-setup-ui.sh r6). Setup with an adopted model (no question) → question about a shown PDF →
/// capabilities button ("Einfach erklären") → look up online (card, "Nicht jetzt": no network) → add an appointment
/// (`calendar_add` via Pippa's MCP server with a substitute calendar, PIPPA_DEMO=1). Finally: how many llama-servers are running.
/// Report `r6.txt`, images `r6-*.png`.
@MainActor enum PiR6Snapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        var failures = 0
        let started = Date()
        func note(_ s: String) { lines.append(String(format: "[%6.1f s] ", Date().timeIntervalSince(started)) + s) }
        func verify(_ ok: Bool, _ what: String) { note("\(ok ? "PASS" : "FAIL"): \(what)"); if !ok { failures += 1 }; finish() }
        func finish() {
            let heading = failures == 0 ? "PASS: r6" : "FAIL: r6 (\(failures))"
            try? ([heading] + lines).joined(separator: "\n").appending("\n").write(to: directory.appendingPathComponent("r6.txt"), atomically: true, encoding: .utf8)
        }
        var shot = 0
        func snap(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(600))
            shot += 1
            let ok = capture(shell.panel, to: directory.appendingPathComponent(String(format: "r6-%02d-%@.png", shot, name)))
            note("Bild \(name): \(ok ? "ok" : "fehlt")")
        }
        guard let setup = PiSetupController.shared, PiRPCChat.isLive,
              let corpus = ProcessInfo.processInfo.environment["PIPPA_R2_CORPUS"] else {
            verify(false, "braucht den Pi-Weg, die Einrichtung und PIPPA_R2_CORPUS (scripts/pi-setup-ui.sh r6)"); finish(); return
        }
        NSApp.activate()
        // Substitute answers for Pippa's own dialogs (sentence before the system prompt), never the real person.
        PippaMCPService.explainForSnapshot = { _, _ in true }

        // 1. First launch: quiet setup, the existing model is adopted.
        model.show(.onboarding)
        let t0 = Date()
        var states: [String] = []
        while Date().timeIntervalSince(t0) < 600 {
            let label = String(describing: setup.state)
            if states.last != label { states.append(label); note("Einrichtung: \(label)") }
            if case .preparing = setup.state { try? await Task.sleep(for: .milliseconds(100)); continue }
            if case .downloading = setup.state { try? await Task.sleep(for: .milliseconds(100)); continue }
            break
        }
        verify(!states.contains { $0.hasPrefix("askDownload") }, "erster Start ohne Frage (Modell übernommen)")
        guard case .ready(let source) = setup.state else {
            await snap("setup-fehler"); verify(false, "Einrichtung nicht bereit: \(setup.state)"); finish(); return
        }
        verify(source != nil, "KI übernommen aus \(source ?? "–") nach \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        await snap("setup")

        func wait(onCard: ((WebAccessAsk) -> Void)? = nil) async -> (first: Double?, total: Double) {
            let a0 = Date()
            var first: Double?
            var card = false
            try? await Task.sleep(for: .milliseconds(200))
            while model.conversations.isRunning, Date().timeIntervalSince(a0) < 600 {
                if first == nil, !model.conversations.streamingText.isEmpty { first = Date().timeIntervalSince(a0) }
                if !card, let ask = model.conversations.webAsk {
                    card = true
                    note("Karte „Online nachsehen“: „\(ask.shown)“")
                    onCard?(ask)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let total = Date().timeIntervalSince(a0)
            note("erstes Wort nach \(first.map { String(format: "%.1f s", $0) } ?? "–"), fertig nach \(String(format: "%.1f", total)) s")
            return (first, total)
        }
        func last() -> ConversationMessage? { model.conversations.current?.messages.last }
        func report() {
            let message = last()
            note("Antwort (\(message?.role.rawValue ?? "?"), \(message?.modelLabel ?? "ohne Etikett")): \(message?.text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(600) ?? "")")
            if let work = message?.work { note("Lesequittung: \(work.summary)") }
            if let actions = message?.actions { note("Was passiert ist: \(actions.lines.map(\.text))") }
            if let error = model.conversations.error { note("Fehler: \(error)") }
        }
        model.conversationSize = DevSnapshot.workspaceSize
        let pdf = URL(fileURLWithPath: corpus, isDirectory: true).appendingPathComponent("brief-finanzamt.pdf")

        // 2. Question about a shown PDF.
        model.newConversation()
        try? await Task.sleep(for: .milliseconds(400))
        model.attach(.files([pdf]), items: [pdf], startsFresh: true, open: true)
        try? await Task.sleep(for: .milliseconds(400))
        note("Gezeigt: \(pdf.lastPathComponent) · Frage: Wie viel muss ich zahlen und bis wann?")
        model.route("Wie viel muss ich zahlen und bis wann?")
        _ = await wait()
        report()
        let answer = last()?.text ?? ""
        verify(last()?.role == .assistant && answer.contains("312"), "Antwort nennt den Betrag aus dem PDF (312)")
        verify(last()?.modelLabel != "Pi (RPC-Spike)", "kein Entwickleretikett an der Antwort")
        await snap("pdf-frage")

        // 3. Capabilities button on the letter (like the button in the conversation: runSkill).
        if let skill = PippaSkill.bundled.first(where: { $0.name == "brief-verstehen" }) {
            let before = model.conversations.current?.messages.count ?? 0
            note("Knopf: \(skill.title ?? skill.name)")
            model.runSkill(skill, offered: PippaSkill.suggestions(for: .brief), place: .brief)
            _ = await wait()
            report()
            let added = (model.conversations.current?.messages.count ?? 0) - before
            let user = model.conversations.current?.messages.dropLast().last { $0.role == .user }
            verify(added >= 2 && last()?.role == .assistant && !(last()?.text ?? "").isEmpty, "Knopf antwortet über Pi")
            verify(user?.text == skill.prompt, "im Verlauf steht nur die Knopf-Nachricht, nicht die Anleitung")
            await snap("knopf")
        } else {
            verify(false, "Fähigkeit brief-verstehen fehlt")
        }

        // 4. Look up online: card appears, "Nicht jetzt" (no real fetch).
        model.newConversation()
        try? await Task.sleep(for: .milliseconds(400))
        note("Frage: Wie wird das Wetter morgen in Köln? Schau bitte online nach.")
        var sawCard = false
        model.route("Wie wird das Wetter morgen in Köln? Schau bitte online nach.")
        _ = await wait(onCard: { ask in
            sawCard = true
            Task { @MainActor in
                await snap("karte")
                model.conversations.answerWebAsk(ask.id, approved: false)
            }
        })
        report()
        verify(sawCard, "Karte „Online nachsehen“ erschienen")
        let webLines = last()?.actions?.items.filter { $0.action == "webSearch" || $0.action == "webPage" } ?? []
        verify(sawCard ? webLines.contains { $0.outcome == "declined" } : false, "Quittung: nicht online nachgesehen (abgelehnt)")

        // 5. Add an appointment via Pippa's MCP server (substitute calendar).
        model.newConversation()
        try? await Task.sleep(for: .milliseconds(400))
        let ask = "Trag bitte morgen von 9 bis 10 Uhr den Termin „Zahnarzt“ in meinen Kalender ein."
        note("Frage: \(ask)")
        model.route(ask)
        _ = await wait()
        report()
        let calendar = last()?.actions?.items.filter { $0.action == "calendarAdd" } ?? []
        verify(calendar.contains { $0.outcome == "done" }, "Quittung „Termin eingetragen“ aus dem Ereignis (calendar_add)")
        await snap("termin")

        // 6. One llama-server.
        let list = run("/usr/bin/pgrep", ["-lx", "llama-server"])
        let home = ProcessInfo.processInfo.environment["PIPPA_PI_HOME"] ?? "-"
        let mine = run("/usr/bin/pgrep", ["-f", "llama-server.*" + home]).split(separator: "\n")
        note("llama-server laufend (alle): \(list.split(separator: "\n").count) · aus diesem HOME: \(mine.count)")
        let status = await PiRPCChat.shared.localServerStatus()
        note("llama-server der App: PID \(status.pid.map(String.init) ?? "–")")
        verify(list.split(separator: "\n").count == 1, "genau ein llama-server läuft")
        finish()
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = pipe
        do { try process.run() } catch { return "" }
        // Read first, then wait: otherwise both hang once the output fills the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func capture(_ window: NSWindow, to destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", destination.path]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return FileManager.default.fileExists(atPath: destination.path)
    }
}
#endif
