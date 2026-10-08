import AppKit
import PippaCore

#if DEBUG
/// "Räum meine Downloads auf" in the real window on the default path (Pi on), in a
/// fake HOME with an invented Downloads folder (scripts/pi-setup-ui.sh r7b). Expected: no Pi, the native preview as a
/// card, one run, **one** undo, then the folder as before. Control: "Was liegt in Downloads?" goes to
/// the Pi path (here the unfinished setup stops it), not to sorting. Report `r7b.txt`, images `r7b-*.png`.
@MainActor enum PiR7bSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        var failures = 0
        let started = Date()
        func note(_ s: String) { lines.append(String(format: "[%6.1f s] ", Date().timeIntervalSince(started)) + s); finish() }
        func verify(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; note("\(ok ? "PASS" : "FAIL"): \(what)") }
        func finish() {
            let heading = failures == 0 ? "PASS: r7b" : "FAIL: r7b (\(failures))"
            try? ([heading] + lines).joined(separator: "\n").appending("\n").write(to: directory.appendingPathComponent("r7b.txt"), atomically: true, encoding: .utf8)
        }
        var shot = 0
        func snap(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(700))
            shot += 1
            let ok = capture(shell.panel, to: directory.appendingPathComponent(String(format: "r7b-%02d-%@.png", shot, name)))
            note("Bild \(name): \(ok ? "ok" : "fehlt (keine Bildschirmaufnahme-Erlaubnis?)")")
        }
        func waitIdle(_ limit: Double = 120) async {
            let t0 = Date()
            try? await Task.sleep(for: .milliseconds(300))
            while (model.busy || model.sortFilling || model.conversations.isRunning), Date().timeIntervalSince(t0) < limit {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let downloads = model.tidyHome.appendingPathComponent("Downloads", isDirectory: true)
        guard PiRPCChat.isLive, DevEnvironment.value("PIPPA_PI_HOME") != nil,
              downloads.path.hasPrefix(FileManager.default.currentDirectoryPath + "/.build/"),
              FileManager.default.fileExists(atPath: downloads.path) else {
            verify(false, "braucht den Pi-Weg (PIPPA_PI_RPC=1) und einen erfundenen Downloads-Ordner unter .build (scripts/pi-setup-ui.sh r7b)")
            return
        }
        NSApp.activate()
        model.conversationSize = DevSnapshot.workspaceSize
        let before = tree(downloads)
        note("Ordner \(downloads.path): \(before.count) Einträge vorher")

        // 1. "Räum meine Downloads auf": native, without Pi.
        model.newConversation()
        try? await Task.sleep(for: .milliseconds(400))
        var piStarted = false
        let watch = Task { @MainActor in
            while !Task.isCancelled { if model.conversations.isRunning { piStarted = true }; try? await Task.sleep(for: .milliseconds(50)) }
        }
        let ask = "Räum meine Downloads auf"
        note("Nachricht: \(ask)")
        let t0 = Date()
        model.route(ask)
        await waitIdle()
        let previewAfter = Date().timeIntervalSince(t0)
        let mode = model.mode.key
        let ops = model.plan?.ops ?? []
        let moves = ops.filter { $0.kind != .mkdir }
        note("Modus \(mode), Vorschau nach \(String(format: "%.1f", previewAfter)) s: \(moves.count) Dateien, \(ops.count - moves.count) neue Ordner, "
             + "liegen bleibt \(model.plan?.skipped.count ?? 0), später \(model.plan?.later.count ?? 0)")
        for op in moves.prefix(20) { note("  \(op.source?.lastPathComponent ?? "?") → \(op.target.deletingLastPathComponent().lastPathComponent)/\(op.target.lastPathComponent) (\(op.certainty))") }
        verify(mode == "sort", "Vorschau als Karte (Modus sortSheet)")
        verify(!moves.isEmpty, "Vorschau enthält Dateien")
        let messages = model.conversations.current?.messages ?? []
        verify(messages.contains { $0.role == .user && $0.text == ask }, "Nachricht steht im Verlauf")
        verify(messages.contains { $0.role == .system && ($0.text.contains("Sorting preview") || $0.text.contains("Sortiervorschau")) },
               "Zeile „Sortiervorschau … noch nichts geändert“ im Verlauf")
        verify(tree(downloads) == before, "vor dem Ausführen nichts geändert")
        await snap("vorschau")

        // 2. Run (the one button).
        model.confirmPreview()
        await waitIdle()
        let receipt = model.lastReceipt
        let after = tree(downloads)
        note("Quittung: \(receipt?.summary ?? "–") · rückgängig machbar: \(receipt?.canUndo == true)")
        verify(receipt?.canUndo == true, "eine Quittung mit Rückgängig für den ganzen Auftrag")
        verify(after != before, "Dateien eingeordnet (\(after.count) Einträge nachher)")
        await snap("quittung")

        // 3. One undo.
        if let receipt { model.undo(receipt) }
        await waitIdle()
        let undone = tree(downloads)
        verify(undone == before, "nach einem Rückgängig ist der Ordner wie vorher")
        if undone != before { note("Unterschied: \(Set(undone).symmetricDifference(before).sorted().prefix(20))") }
        watch.cancel()
        verify(!piStarted, "Pi wurde für das Aufräumen nicht gefragt")
        await snap("rueckgaengig")

        // 4. Control: question about the contents goes to the Pi path, not to sorting.
        model.newConversation()
        try? await Task.sleep(for: .milliseconds(400))
        model.plan = nil
        let question = "Was liegt in Downloads?"
        note("Nachricht: \(question)")
        model.route(question)
        await waitIdle(20)
        let last = model.conversations.current?.messages.last
        note("Modus \(model.mode.key) · letzte Zeile (\(last?.role.rawValue ?? "?")): \(last?.text.prefix(200) ?? "")")
        verify(model.mode.key != "sort" && model.plan == nil, "keine Sortier-Vorschau für eine Frage")
        verify(last?.text == model.piSetupBlockedReason || last?.role == .assistant || model.conversations.isRunning,
               "Frage auf dem Pi-Weg (Antwort oder Satz der Einrichtung)")
        await snap("frage")
        finish()
    }

    /// All paths under `root` (relative), without .DS_Store.
    static func tree(_ root: URL) -> [String] {
        let prefix = root.standardizedFileURL.path + "/"
        let all = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        return all.map { $0.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "") }.filter { !$0.hasSuffix(".DS_Store") }.sorted()
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
