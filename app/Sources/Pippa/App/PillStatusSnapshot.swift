import AppKit
import PippaCore

#if DEBUG
/// The living pill through the real conversation controller and the real pill click, without Pi or a model:
/// `PIPPA_DEMO=1 PIPPA_SNAPSHOT=<fresh folder> PIPPA_SNAPSHOT_ONLY=pillstatus` (optional `PIPPA_APPEARANCE=dark`,
/// `PIPPA_REDUCE_MOTION=1`). Empty conversation, pill while working, "answer is ready" until clicked, a failed answer.
/// Images `pillstatus-*.png`, report `pillstatus.txt`. German strings need the bundle (docs/development.md).
@MainActor enum PillStatusSnapshot {
    /// Holds the scripted answer at named points so the pill can be photographed in each phase.
    private actor Gate {
        private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<String> = []
        private(set) var current: String?
        func hold(_ name: String) async {
            if released.contains(name) { return }
            current = name
            await withCheckedContinuation { waiting[name] = $0 }
        }
        func release(_ name: String) {
            released.insert(name)
            if current == name { current = nil }
            waiting.removeValue(forKey: name)?.resume()
        }
    }

    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        var failures = 0
        func verify(_ ok: Bool, _ what: String) { lines.append("\(ok ? "PASS" : "FAIL"): \(what)"); if !ok { failures += 1 } }
        func snap(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(900))
            verify(capture(shell.panel, to: directory.appendingPathComponent("pillstatus-\(name).png")), "Bild \(name)")
        }
        func until(_ seconds: Double = 6, _ condition: () async -> Bool) async -> Bool {
            for _ in 0..<Int(seconds * 50) {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        guard model.engine is StubEngine, DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            verify(false, "Requires PIPPA_DEMO=1 and an isolated PIPPA_SNAPSHOT directory")
            return write(lines, failures, to: directory)
        }
        NSApp.activate()
        model.conversationSize = DevSnapshot.workspaceSize
        let chat = model.conversations

        // 1 Empty conversation: four example cards.
        model.newConversation()
        model.openInput()
        verify(ConversationWorkspace.examples.count == 4, "Vier Beispiele")
        await snap("01-empty")

        // 2 A question runs while only the pill shows.
        let gate = Gate()
        let answering = SnapshotChat(script: { _, _, context, onDelta in
            let work = context.onWork
            // Real order: reading the files is preparation, then the model thinks.
            work?(.phase(.reading(name: "Mietvertrag_2019_final.pdf", index: 1, count: 2)))
            await gate.hold("reading")
            work?(.phase(.waitingForAnswer(continuing: false)))
            await gate.hold("thinking")
            let text = "Die Kaution beträgt 2.340 Euro (synthetisch)."
            onDelta(text)
            return text
        })
        chat.send("Wie hoch ist die Kaution?", chat: answering)
        model.collapse()
        verify(await until { await gate.current == "reading" }, "Antwort läuft")
        try? await Task.sleep(for: .milliseconds(150))
        verify(!model.isExpanded && model.pillStatus.tone == .working, "Pille arbeitet")
        verify(model.pillStatus.label.contains("1/2") && !model.pillStatus.label.contains(".pdf") && model.pillStatus.progress != nil,
               "Pille: \(model.pillStatus.label)")
        await snap("02-reading")
        await gate.release("reading")
        verify(await until { await gate.current == "thinking" }, "Denkt nach")
        try? await Task.sleep(for: .milliseconds(150))
        verify(model.pillStatus.tone == .working && model.pillStatus.progress == nil, "Pille: \(model.pillStatus.label)")
        await snap("03-thinking")
        await gate.release("thinking")

        // 3 Done while collapsed: stays until clicked.
        verify(await until { !chat.isRunning }, "Antwort fertig")
        verify(model.pillStatus.tone == .done, "Pille: \(model.pillStatus.label)")
        await snap("04-answered")
        try? await Task.sleep(for: .seconds(3))
        verify(model.pillStatus.tone == .done, "Bleibt nach 3 s stehen")
        shell.pillClicked()
        verify(await until { model.mode.isConversation }, "Klick öffnet das Gespräch (\(model.mode.key))")
        verify(model.pillStatus.tone == .rest, "Klick löscht den Hinweis")
        await snap("05-opened")

        // 4 A failed answer while collapsed.
        let failing = SnapshotChat(script: { _, _, context, _ in
            context.onWork?(.phase(.waitingForAnswer(continuing: false)))
            try? await Task.sleep(for: .milliseconds(300))
            throw PiRPCChat.Failure.model("snapshot")
        })
        chat.send("Und wann endet der Vertrag?", chat: failing)
        model.collapse()
        verify(await until { !chat.isRunning }, "Fehler kam an")
        verify(model.pillStatus.tone == .failed, "Pille: \(model.pillStatus.label)")
        await snap("06-failed")
        shell.pillClicked()
        verify(await until { model.mode.isConversation }, "Klick öffnet das Gespräch")
        await snap("07-failed-opened")

        // 5 The file task's error card (ErrorContent) with a reason.
        model.show(.message(title: T("That didn’t work", table: "App"),
                            body: T("The answer didn’t come through just now. Please try again in a moment.", table: "App"), isError: true))
        await snap("08-errorcard")
        write(lines, failures, to: directory)
    }

    private static func write(_ lines: [String], _ failures: Int, to directory: URL) {
        let heading = failures == 0 ? "PASS: pillstatus" : "FAIL: pillstatus (\(failures))"
        try? ([heading] + lines).joined(separator: "\n").appending("\n")
            .write(to: directory.appendingPathComponent("pillstatus.txt"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private static func capture(_ window: NSWindow, to destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", destination.path]
        do { try process.run(); process.waitUntilExit() } catch {}
        if FileManager.default.fileExists(atPath: destination.path) { return true }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: destination)) != nil
    }
}
#endif
