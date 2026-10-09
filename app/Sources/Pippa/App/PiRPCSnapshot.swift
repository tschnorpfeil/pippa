import AppKit
import PippaCore

#if DEBUG
/// The real Pippa window against the real Pi (`pi --mode rpc`) and a real local
/// model. `PIPPA_DEMO=1 PIPPA_PI_RPC=1 PIPPA_SNAPSHOT=<fresh folder> PIPPA_SNAPSHOT_ONLY=pirpc` plus the environment from
/// `scripts/pi-rpc-spike.sh` (PIPPA_PI_EXTENSIONS, PIPPA_PI_WORKDIR, PI_CODING_AGENT_DIR).
/// Question with streaming, stop, create a file (no question: Pi runs its tools). Report `pirpc.txt`.
@MainActor enum PiRPCSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        let started = Date()
        func note(_ s: String) { lines.append(String(format: "[%6.1f s] ", Date().timeIntervalSince(started)) + s) }
        func finish() { try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("pirpc.txt"), atomically: true, encoding: .utf8) }
        guard PiRPCChat.isLive, let work = ProcessInfo.processInfo.environment["PIPPA_PI_WORKDIR"] else {
            note("FAIL: braucht PIPPA_PI_RPC=1 und PIPPA_PI_WORKDIR"); finish(); return
        }
        NSApp.activate()
        model.conversationSize = DevSnapshot.workspaceSize
        var shot = 0
        func snap(_ name: String) {
            shot += 1
            let ok = capture(shell.panel, to: directory.appendingPathComponent(String(format: "pirpc-%02d-%@.png", shot, name)))
            note("Bild \(name): \(ok ? "ok" : "fehlt")")
        }
        /// Waits until the answer is done; photographs once as soon as text streams.
        func waitForAnswer(streamingShot: String?, stopAfter: Double? = nil) async {
            let t0 = Date()
            var shotTaken = streamingShot == nil
            var first: Double?
            while model.conversations.isRunning, Date().timeIntervalSince(t0) < 240 {
                if first == nil, !model.conversations.streamingText.isEmpty { first = Date().timeIntervalSince(t0) }
                if !shotTaken, model.conversations.streamingText.count > 40 { snap(streamingShot!); shotTaken = true }
                if let stopAfter, let first, Date().timeIntervalSince(t0) > first + stopAfter {
                    note("Stoppen gedrückt nach \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                    model.stopChat()
                    let s0 = Date()
                    while model.conversations.isRunning, Date().timeIntervalSince(s0) < 10 { try? await Task.sleep(for: .milliseconds(20)) }
                    note("Antwort angehalten nach \(String(format: "%.2f", Date().timeIntervalSince(s0))) s")
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            note("erster Text nach \(first.map { String(format: "%.2f s", $0) } ?? "–"), fertig nach \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            let last = model.conversations.current?.messages.last
            note("letzte Nachricht (\(last?.role.rawValue ?? "?"), angehalten: \(last?.stopped ?? false)): \(last?.text.prefix(200) ?? "")")
            if let error = model.conversations.error { note("Fehler: \(error)") }
        }

        // The app starts the llama-server itself, idle, mkdir, read receipt.
        if ProcessInfo.processInfo.environment["PIPPA_PIRPC_SCENARIO"] == "wave2d" {
            await wave2d(model: model, work: URL(fileURLWithPath: work), note: note, snap: snap)
            finish(); return
        }

        // Cold start timeline: every visible phase change from the question until the first words.
        if ProcessInfo.processInfo.environment["PIPPA_PIRPC_SCENARIO"] == "coldstart" {
            model.newConversation()
            try? await Task.sleep(for: .milliseconds(300))
            let t0 = Date()
            note("Frage (kalt): Hauptstadt")
            model.route("Was ist die Hauptstadt von Frankreich? Antworte in einem Satz.")
            var last = ""
            var shotAt = 0
            while Date().timeIntervalSince(t0) < 240 {
                let line = model.conversations.thought
                let phase = line.phase.map { "\($0)" } ?? "-"
                let state = "\(phase) | \(line.isVisible ? (line.phase?.title ?? "") : "(unsichtbar)") \(line.currentStep ?? "")"
                if state != last { note(String(format: "+%5.2f s  ", Date().timeIntervalSince(t0)) + state); last = state }
                let secs = Int(Date().timeIntervalSince(t0))
                if secs >= shotAt, line.isVisible { snap(String(format: "kalt-%03ds", secs)); shotAt = secs + 4 }
                if !model.conversations.streamingText.isEmpty || !model.conversations.isRunning { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            note(String(format: "erster Text nach %.2f s", Date().timeIntervalSince(t0)))
            while model.conversations.isRunning, Date().timeIntervalSince(t0) < 240 { try? await Task.sleep(for: .milliseconds(100)) }
            finish(); return
        }

        model.newConversation()
        try? await Task.sleep(for: .milliseconds(500))
        note("Frage 1: Hauptstadt")
        model.route("Was ist die Hauptstadt von Frankreich? Antworte in zwei Sätzen.")
        await waitForAnswer(streamingShot: "streaming")
        try? await Task.sleep(for: .milliseconds(400)); snap("antwort")

        note("Frage 2: lange Antwort, dann Stoppen")
        model.route("Erzähl mir ausführlich in etwa 300 Wörtern die Geschichte des Fahrrads.")
        await waitForAnswer(streamingShot: nil, stopAfter: 1.5)
        try? await Task.sleep(for: .milliseconds(400)); snap("gestoppt")

        let target = URL(fileURLWithPath: work).appendingPathComponent("Einkauf.txt")
        note("Schreibwunsch; Datei vorher da: \(FileManager.default.fileExists(atPath: target.path))")
        var asked = false
        PiRPCChat.answerForSnapshot = { window, request in
            asked = true
            _ = capture(window, to: directory.appendingPathComponent("pirpc-abfrage.png"))
            note("FAIL: unerwartete Abfrage: \(request.title) | \(request.message.replacingOccurrences(of: "\n", with: " ⏎ "))")
            return .alertFirstButtonReturn
        }
        model.route("leg eine Datei Einkauf.txt mit Milch und Brot an")
        await waitForAnswer(streamingShot: nil)
        try? await Task.sleep(for: .milliseconds(400)); snap("schreiben")
        let content = (try? String(contentsOf: target, encoding: .utf8))?.replacingOccurrences(of: "\n", with: " ⏎ ")
        note("Datei danach: \(content ?? "nicht vorhanden") · gefragt: \(asked)")
        PiRPCChat.answerForSnapshot = nil
        finish()
    }

    /// Resident set size of a process in MB (`ps`), 0 if it is not running.
    static func rssMB(_ pid: Int32?) -> Double {
        guard let pid else { return 0 }
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(pid)]
        process.standardOutput = out; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
    }

    /// First question loads the model (thought line "bereit machen", Pi only after /health), create a folder
    /// (mkdir without question, receipt), read mail (read receipt, substitute mail from PIPPA_DEMO), idle until
    /// unload (memory before/after), next question reloads (cold start measured).
    private static func wave2d(model: AppModel, work: URL, note: @escaping (String) -> Void, snap: (String) -> Void) async {
        guard PiRPCChat.isLive else { return }
        let rpc = PiRPCChat.shared
        let app = ProcessInfo.processInfo.processIdentifier
        func status(_ label: String) async {
            let s = await rpc.localServerStatus()
            note(String(format: "%@: llama-server PID %@, RSS %.0f MB; letzter Start bis /health %@; Pippa RSS %.0f MB",
                        label, s.pid.map { String($0) } ?? "–", rssMB(s.pid), s.lastStart.map { String(format: "%.1f s", $0) } ?? "–", rssMB(app)))
        }
        /// Asks, waits for the answer, notes the thought line's phases and the receipt.
        func ask(_ text: String) async -> [ActionReceipt.Item] {
            let before = model.conversations.current?.messages.count ?? 0
            note("Frage: \(text)")
            let t0 = Date()
            model.route(text)
            var phases: [String] = [], first: Double?
            try? await Task.sleep(for: .milliseconds(100))
            while model.conversations.isRunning, Date().timeIntervalSince(t0) < 600 {
                if let title = model.conversations.thought.phase?.title, phases.last != title { phases.append(title) }
                if first == nil, !model.conversations.streamingText.isEmpty { first = Date().timeIntervalSince(t0) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            note("Gedankenzeile: \(phases.joined(separator: " → "))")
            note("erster Text nach \(first.map { String(format: "%.2f s", $0) } ?? "–"), fertig nach \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            let new = (model.conversations.current?.messages ?? []).dropFirst(before)
            if let last = new.last { note("Antwort: \(last.text.prefix(200).replacingOccurrences(of: "\n", with: " ⏎ "))") }
            if let error = model.conversations.error { note("Fehler: \(error)") }
            let items = new.compactMap(\.actions).flatMap(\.items)
            for line in new.compactMap(\.actions).flatMap({ $0.lines }) { note("Quittung: \(line.text)") }
            return items
        }
        PiRPCChat.answerForSnapshot = { _, request in
            note("Abfrage gezeigt (erlaubt): \(request.title.replacingOccurrences(of: "\n", with: " ⏎ "))")
            return .alertFirstButtonReturn
        }
        defer { PiRPCChat.answerForSnapshot = nil }

        model.newConversation()
        try? await Task.sleep(for: .milliseconds(500))
        await status("Vorher")
        _ = await ask("Was ist die Hauptstadt von Frankreich? Antworte in einem Satz.")
        await status("Nach Frage 1")
        snap("w2d-geladen")

        let folder = work.appendingPathComponent("Belege-2d")
        try? FileManager.default.removeItem(at: folder)   // own test folder under .build/spike-work
        let created = await ask("Leg im Arbeitsordner einen neuen, leeren Ordner Belege-2d an.")
        note("Ordner danach da: \(FileManager.default.fileExists(atPath: folder.path))")
        note("Aktionen: \(created.map { "\($0.action)/\($0.outcome)" }.joined(separator: ", "))")
        try? FileManager.default.removeItem(at: folder)
        snap("w2d-ordner")

        _ = await ask("Welche Mail habe ich gerade in Mail ausgewählt? Nenn mir nur kurz den Betreff.")
        snap("w2d-mail")

        let idle = await rpc.localServerStatus().idle ?? 600
        note(String(format: "Warte auf Entladen (Leerlauf %.0f s) …", idle))
        let w0 = Date()
        await status("Leerlauf, noch geladen")
        while await rpc.localServerStatus().pid != nil, Date().timeIntervalSince(w0) < idle + 120 { try? await Task.sleep(for: .milliseconds(250)) }
        note(String(format: "entladen nach %.1f s ohne Anfrage", Date().timeIntervalSince(w0)))
        try? await Task.sleep(for: .seconds(2))
        await status("Nach dem Entladen")
        _ = await ask("Und was ist die Hauptstadt von Italien? Ein Satz.")
        await status("Nach Neustart")
        snap("w2d-neustart")
    }

    /// Only Pippa's window (or the prompt) via screencapture, uncropped.
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
