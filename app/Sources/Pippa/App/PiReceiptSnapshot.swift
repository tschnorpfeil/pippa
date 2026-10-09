import AppKit
import PippaCore

#if DEBUG
/// Receipt "Was passiert ist" (ActionReceipt) in the real conversation window, without Pi and without a model:
/// `PIPPA_DEMO=1 PIPPA_SNAPSHOT=<fresh folder> PIPPA_SNAPSHOT_ONLY=pireceipt` (optional `PIPPA_APPEARANCE=dark`).
/// The first answer text claims success after a failed call (as a local model did in a trial run); the receipt
/// below says "Nicht angelegt … (hat nicht geklappt)". Report `pireceipt.txt`, image `pireceipt.png`.
@MainActor enum PiReceiptSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        var failures = 0
        func verify(_ ok: Bool, _ what: String) { lines.append("\(ok ? "PASS" : "FAIL"): \(what)"); if !ok { failures += 1 } }
        NSApp.activate()
        model.conversationSize = DevSnapshot.workspaceSize
        model.newConversation()
        try? await Task.sleep(for: .milliseconds(400))
        let chat = model.conversations
        let declined = ActionReceipt(items: [.init(action: "create", outcome: "failed", name: "Einkauf.txt")])
        let done = ActionReceipt(items: [.init(action: "create", outcome: "done", name: "Einkauf.txt")])
        let tidy = ActionReceipt(items: [
            .init(action: "rename", outcome: "done", name: "Scan 3.pdf", toName: "Mietvertrag.pdf"),
            .init(action: "move", outcome: "failed", name: "Notiz.txt", toName: "Archiv"),
            .init(action: "trash", outcome: "done", name: "Kopie von Liste.txt"),
            .init(action: "command", outcome: "done"),
        ])
        chat.append(.user, "leg eine Datei Einkauf.txt mit Milch und Brot an")
        chat.append(.assistant, "Die Datei Einkauf.txt wurde mit „Milch“ und „Brot“ erstellt.", modelLabel: "Pi", actions: declined)
        chat.append(.user, "Bitte leg sie jetzt doch an.")
        chat.append(.assistant, "Ich habe die Datei Einkauf.txt mit Milch und Brot angelegt.", modelLabel: "Pi", actions: done)
        chat.append(.user, "Räum den Ordner ein bisschen auf.")
        chat.append(.assistant, "Ich habe den Scan umbenannt, die doppelte Liste weggeworfen und nachgesehen, wie viele Dateien übrig sind.",
                    modelLabel: "Pi", actions: tidy)
        let stored = chat.current?.messages.compactMap(\.actions) ?? []
        verify(stored == [declined, done, tidy], "Quittungen landen unverändert im Verlauf (\(stored.count) von 3)")
        // The bare debug file shows English (docs/development.md); the German lines here on purpose.
        for receipt in stored { for line in receipt.lines { lines.append("     \(line.text)") } }
        for receipt in stored { for line in receipt.lines(language: "de") { lines.append("  de \(line.text)") } }
        let first = declined.lines.first?.text ?? ""
        verify(first.contains("Einkauf.txt") && first != done.lines.first?.text, "Fehlgeschlagen und erledigt sehen verschieden aus: \(first)")
        try? await Task.sleep(for: .milliseconds(900))
        verify(capture(shell.panel, to: directory.appendingPathComponent("pireceipt.png")), "Bild pireceipt.png")
        let heading = failures == 0 ? "PASS: pireceipt" : "FAIL: pireceipt (\(failures))"
        try? ([heading] + lines).joined(separator: "\n").appending("\n").write(to: directory.appendingPathComponent("pireceipt.txt"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private static func capture(_ window: NSWindow, to destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", destination.path]
        do { try process.run(); process.waitUntilExit() } catch {}
        if FileManager.default.fileExists(atPath: destination.path) { return true }
        // Without screen-recording permission (or with the screen asleep) the view draws itself.
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: destination)) != nil
    }
}
#endif
