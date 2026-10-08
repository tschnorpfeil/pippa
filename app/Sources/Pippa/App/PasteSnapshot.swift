import AppKit
import PippaCore

#if DEBUG
/// `PIPPA_DEMO=1 PIPPA_SNAPSHOT=<fresh dir> PIPPA_SNAPSHOT_ONLY=paste`: ⌘V with files, a picture and text on a
/// private pasteboard (never the real clipboard). Writes `paste.txt` and a screenshot.
@MainActor enum PasteSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        var failed = false
        func verify(_ ok: Bool, _ text: String) { lines.append((ok ? "PASS: " : "FAIL: ") + text); if !ok { failed = true } }
        guard model.engine is StubEngine, DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            try? "FAIL: needs demo engine and isolated PIPPA_SNAPSHOT\n".write(to: directory.appendingPathComponent("paste.txt"), atomically: true, encoding: .utf8)
            return
        }
        NSApp.activate()
        model.conversationSize = CGSize(width: 400, height: 600)
        model.newConversation()
        model.openInput()
        try? await Task.sleep(for: .milliseconds(800))
        let board = NSPasteboard(name: .init("pippa-test"))
        func pending() -> [URL] { model.conversations.current?.context?.files ?? [] }
        func shot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(900))
            let url = directory.appendingPathComponent(name + ".png")
            if let view = shell.panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            verify(FileManager.default.fileExists(atPath: url.path), "Screenshot \(name)")
        }

        // 1. Plain text: normal paste.
        board.clearContents(); board.setString("Hallo Pippa", forType: .string)
        verify(!shell.pasteAsAttachment(board, requireFocus: false), "text is not taken as attachment")

        // 2. Finder-style: file URL plus the name as text.
        let file = directory.appendingPathComponent("Rechnung Mai.txt")
        try? "Testinhalt\n".write(to: file, atomically: true, encoding: .utf8)
        board.clearContents(); board.writeObjects([file as NSURL]); board.addTypes([.string], owner: nil); board.setString("Rechnung Mai.txt", forType: .string)
        verify(shell.pasteAsAttachment(board, requireFocus: false), "Finder file is taken")
        try? await Task.sleep(for: .milliseconds(400))
        verify(pending().contains { $0.lastPathComponent == "Rechnung Mai.txt" }, "file chip present")

        // 3. Screenshot-style picture only.
        let image = NSImage(size: NSSize(width: 240, height: 140), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 50, dy: 30)).fill(); return true
        }
        board.clearContents()
        if let tiff = image.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        verify(shell.pasteAsAttachment(board, requireFocus: false), "picture is taken")
        try? await Task.sleep(for: .milliseconds(400))
        verify(pending().contains { $0.lastPathComponent.hasPrefix("Bild aus der Zwischenablage") || $0.lastPathComponent.hasPrefix("Clipboard image") },
               "image chip with friendly name: \(pending().map(\.lastPathComponent))")

        // 4. Rich text with a picture: stays text.
        board.clearContents()
        if let tiff = image.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        board.setString("Tabelle", forType: .string)
        verify(!shell.pasteAsAttachment(board, requireFocus: false), "rich text with picture stays text")
        await shot("paste-01-chips")
        board.releaseGlobally()
        try? ((failed ? "FAIL" : "PASS") + ": paste fixture\n" + lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("paste.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
