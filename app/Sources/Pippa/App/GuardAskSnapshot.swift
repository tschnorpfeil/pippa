import AppKit
import PiRPC
import PippaCore

#if DEBUG
/// The guard's question as a card in the running conversation (GuardAskCard), without Pi and without a model:
/// `PIPPA_DEMO=1 PIPPA_SNAPSHOT=<fresh folder> PIPPA_SNAPSHOT_ONLY=guardask` (optional `PIPPA_APPEARANCE=dark`).
/// Images `guardask.png` (details closed); report `guardask.txt`.
@MainActor enum GuardAskSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        var failures = 0
        func verify(_ ok: Bool, _ what: String) { lines.append("\(ok ? "PASS" : "FAIL"): \(what)"); if !ok { failures += 1 } }
        NSApp.activate()
        model.conversationSize = DevSnapshot.workspaceSize
        model.newConversation()
        try? await Task.sleep(for: .milliseconds(400))
        let chat = model.conversations
        chat.append(.user, "Benenne die Scans in Downloads nach ihrem Inhalt um.")
        // The guard's real wording for a rename (pippa-guard.ts describeCommand + commandDetail).
        let request = PiUIRequest(id: "snap", method: "select",
                                  title: "Darf Pippa das?\n\nPippa möchte im Ordner ‚Downloads‘ eine Datei umbenennen: „Scan 3.pdf“ wird zu „Mietvertrag.pdf“. OK?\n\nBefehl (für Fachleute): mv \"Scan 3.pdf\" Mietvertrag.pdf\nOrdner: ~/Downloads. Rückgängig geht mit einem Klick.",
                                  message: "", options: ["Erlauben", "Für diese Aufgabe erlauben", "Nicht erlauben"])
        let ask = GuardAsk(request)
        verify(ask?.sentence.hasPrefix("Pippa möchte im Ordner") == true, "Satz ohne Befehl: \(ask?.sentence ?? "-")")
        verify(ask?.detail.contains("mv ") == true, "Befehl nur in den Details")
        if let ask { chat.showGuardAskForSnapshot(ask) }
        try? await Task.sleep(for: .milliseconds(900))
        verify(capture(shell.panel, to: directory.appendingPathComponent("guardask.png")), "Bild guardask.png")
        let heading = failures == 0 ? "PASS: guardask" : "FAIL: guardask (\(failures))"
        try? ([heading] + lines).joined(separator: "\n").appending("\n").write(to: directory.appendingPathComponent("guardask.txt"), atomically: true, encoding: .utf8)
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
