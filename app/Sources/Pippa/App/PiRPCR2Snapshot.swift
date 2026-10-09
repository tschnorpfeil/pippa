import AppKit
import PippaCore

#if DEBUG
/// The real Pippa window against the real Pi and a real local model, with what
/// the person shows. `PIPPA_SNAPSHOT_ONLY=pirpc-r2` plus the environment from `scripts/pi-rpc-spike.sh app` and
/// `PIPPA_R2_CORPUS` (synthetic corpus, scripts/quality/make-ctxsug-corpus.swift). Letter shown → question about
/// amount and deadline; folder shown → "Was ist da drin?"; weather question → pi-web-access looks it up (network, no card). Report `pirpc-r2.txt`.
@MainActor enum PiRPCR2Snapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        let started = Date()
        func note(_ s: String) { lines.append(String(format: "[%6.1f s] ", Date().timeIntervalSince(started)) + s) }
        func finish() { try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("pirpc-r2.txt"), atomically: true, encoding: .utf8) }
        guard PiRPCChat.isLive, let corpus = ProcessInfo.processInfo.environment["PIPPA_R2_CORPUS"] else {
            note("FAIL: braucht PIPPA_PI_RPC=1 und PIPPA_R2_CORPUS"); finish(); return
        }
        NSApp.activate()
        model.conversationSize = DevSnapshot.workspaceSize
        var shot = 0
        func snap(_ name: String) {
            shot += 1
            let ok = capture(shell.panel, to: directory.appendingPathComponent(String(format: "pirpc-r2-%02d-%@.png", shot, name)))
            note("Bild \(name): \(ok ? "ok" : "fehlt")")
        }
        func report() {
            let last = model.conversations.current?.messages.last
            note("Antwort (\(last?.role.rawValue ?? "?")): \(last?.text.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "")")
            if let work = last?.work { note("Lesequittung: \(work.summary) · Quellen \(work.sources.map { "\($0.name) \($0.status.rawValue)" })") }
            if let actions = last?.actions { note("Was passiert ist: \(actions.lines.map(\.text))") }
            if let error = model.conversations.error { note("Fehler: \(error)") }
        }
        /// Waits for the end; reports the first word.
        func wait() async {
            let t0 = Date()
            var first: Double?
            while model.conversations.isRunning, Date().timeIntervalSince(t0) < 400 {
                if first == nil, !model.conversations.streamingText.isEmpty { first = Date().timeIntervalSince(t0) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            note("erstes Wort nach \(first.map { String(format: "%.1f s", $0) } ?? "–"), fertig nach \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        }
        func show(_ url: URL, _ question: String, _ name: String) async {
            model.newConversation()
            try? await Task.sleep(for: .milliseconds(400))
            model.attach(.files([url]), items: [url], startsFresh: true, open: true)
            try? await Task.sleep(for: .milliseconds(400))
            note("Gezeigt: \(url.lastPathComponent) · Frage: \(question)")
            model.route(question)
            await wait()
            try? await Task.sleep(for: .milliseconds(500)); snap(name)
            report()
        }

        let base = URL(fileURLWithPath: corpus, isDirectory: true)
        await show(base.appendingPathComponent("brief-finanzamt.pdf"), "Wie viel muss ich zahlen und bis wann?", "brief")
        await show(base.appendingPathComponent("Unterlagen-2026", isDirectory: true), "Was ist da drin?", "ordner")

        model.newConversation()
        try? await Task.sleep(for: .milliseconds(400))
        note("Frage: Wetter morgen in Köln (pi-web-access)")
        model.route("Wie wird das Wetter morgen in Köln?")
        await wait()
        try? await Task.sleep(for: .milliseconds(500)); snap("web")
        report()
        finish()
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
