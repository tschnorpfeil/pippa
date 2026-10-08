import Foundation
import PippaCore

// Native undo for guard entries, Pi's session files per conversation, key file for `pippa-local` and Pippa's settings.json.
// Runs with PIPPA_SETUP_CHECKS=1 and in the full run.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private func run(_ executable: String, _ arguments: [String], environment: [String: String] = ["PATH": "/usr/bin:/bin"]) -> (status: Int32, output: String) {
    let process = Process(), out = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = out; process.standardError = out
    guard (try? process.run()) != nil else { return (-1, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Node for the comparison with restore.mjs: from the payload, else Homebrew. `nil`: comparison is skipped.
private func nodeBinary() -> String? {
    let env = ProcessInfo.processInfo.environment
    let candidates = [env["PIPPA_PI_PAYLOAD"].map { $0 + "/bin/node" }, "/opt/homebrew/bin/node", "/usr/local/bin/node"].compactMap { $0 }
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}

/// An undo folder as written by the guard: edit (with backup), newly created file, rename, bash log.
private func undoFixture(_ base: URL) throws -> (root: URL, work: URL, edit: URL, create: URL, rename: URL, bash: URL) {
    let work = base.appendingPathComponent("work", isDirectory: true)
    let root = base.appendingPathComponent("undo", isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    func entry(_ name: String, _ manifest: [String: Any], files: [String: String] = [:]) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("files"), withIntermediateDirectories: true)
        for (file, text) in files { write(text, dir.appendingPathComponent("files/\(file)")) }
        try JSONSerialization.data(withJSONObject: manifest.merging(["version": 1]) { $1 }).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }
    write("neu\n", work.appendingPathComponent("Brief.md"))           // Pi changed "alt" to "neu"
    write("frisch\n", work.appendingPathComponent("Frisch.md"))       // Pi created it
    write("liste\n", work.appendingPathComponent("Liste.txt"))        // Pi renamed Einkauf.txt to Liste.txt
    let edit = try entry("1-edit", ["tool": "edit", "entries": [["path": work.appendingPathComponent("Brief.md").path, "existed": true,
                                                                 "snapshot": root.appendingPathComponent("1-edit/files/0-Brief.md").path]]],
                         files: ["0-Brief.md": "alt\n"])
    let create = try entry("2-write", ["tool": "write", "entries": [["path": work.appendingPathComponent("Frisch.md").path, "existed": false]]])
    let rename = try entry("3-rename", ["tool": "rename_or_move", "restorable": true,
                                        "moves": [["from": work.appendingPathComponent("Einkauf.txt").path, "to": work.appendingPathComponent("Liste.txt").path]]])
    let bash = try entry("4-bash", ["tool": "bash", "command": "echo x > y", "restorable": false, "entries": []])
    return (root, work, edit, create, rename, bash)
}

/// All files under `base` with content, relative, without restored.json (its timestamp differs).
private func fileTree(_ base: URL) -> [String: String] {
    var result: [String: String] = [:]
    let prefix = base.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    for url in (fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL]) ?? [] {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, url.lastPathComponent != "restored.json" else { continue }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "")
        result[path] = path.hasSuffix("manifest.json") ? "manifest" : (try? String(contentsOf: url, encoding: .utf8)) ?? "?"
    }
    return result
}

func runPiPivotChecks() async {
    check("Undo (native): edit reverted (current state to the trash), created file to the trash, rename reverted, bash not; second click changes nothing") {
        let base = dir("pi-undo-swift")
        let f = try undoFixture(base)
        let trashDir = base.appendingPathComponent("trash", isDirectory: true)
        let trash = { (url: URL) throws -> URL? in
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let target = trashDir.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: url, to: target)
            return target
        }
        let edit = PiUndo.restore(f.edit, root: f.root, trash: trash)
        let create = PiUndo.restore(f.create, root: f.root, trash: trash)
        let rename = PiUndo.restore(f.rename, root: f.root, trash: trash)
        let bash = PiUndo.restore(f.bash, root: f.root, trash: trash)
        let again = PiUndo.restore(f.edit, root: f.root, trash: trash)
        let outside = PiUndo.restore(f.edit, root: base.appendingPathComponent("anders"), trash: trash)
        let pruned = ActionReceipt.Item(action: "change", outcome: "done", name: "Alt.md", undoEntry: f.root.appendingPathComponent("weg").path, restorable: true)
        let text = { (name: String) in try? String(contentsOf: f.work.appendingPathComponent(name), encoding: .utf8) }
        let createdItem = ActionReceipt.Item(action: "create", outcome: "done", name: "Frisch.md", undoEntry: f.create.path, restorable: true)
        let renamedItem = ActionReceipt.Item(action: "rename", outcome: "done", name: "Einkauf.txt", toName: "Liste.txt", undoEntry: f.rename.path, restorable: true)
        return edit.status == .restored && text("Brief.md") == "alt\n"
            && (try? String(contentsOf: trashDir.appendingPathComponent("Brief.md"), encoding: .utf8)) == "neu\n"
            && create.status == .restored && text("Frisch.md") == nil
            && (try? String(contentsOf: trashDir.appendingPathComponent("Frisch.md"), encoding: .utf8)) == "frisch\n"
            && !pruned.canUndo && pruned.line(language: "de") == "Geändert: Alt.md · nicht mehr rückgängig machbar (Sicherung nach einiger Zeit aufgeräumt)"
            && rename.status == .restored && text("Einkauf.txt") == "liste\n" && text("Liste.txt") == nil
            && bash.status == .notRestorable && !PiUndo.isRestored(f.bash)
            && again.status == .alreadyRestored && outside.status == .outsideRoot
            && !createdItem.canUndo && !renamedItem.canUndo   // restored.json is there now
            && PiUndo.receipt(for: createdItem, create).line(language: "de") == "Rückgängig: Frisch.md in den Papierkorb gelegt"
            && PiUndo.receipt(for: renamedItem, rename).line(language: "de") == "Wiederhergestellt: Einkauf.txt"
            && PiUndo.receipt(for: renamedItem, again).line(language: "de") == "Nicht rückgängig gemacht: Einkauf.txt (schon rückgängig gemacht)"
    }

    check("Undo (native): spot occupied or target gone → nothing overwritten, partial result, button stays") {
        let base = dir("pi-undo-conflict")
        let f = try undoFixture(base)
        write("schon da\n", f.work.appendingPathComponent("Einkauf.txt"))
        let occupied = PiUndo.restore(f.rename, root: f.root)
        try fm.removeItem(at: f.work.appendingPathComponent("Einkauf.txt"))
        try fm.removeItem(at: f.work.appendingPathComponent("Liste.txt"))
        let gone = PiUndo.restore(f.rename, root: f.root)
        let item = ActionReceipt.Item(action: "rename", outcome: "done", name: "Einkauf.txt", undoEntry: f.rename.path, restorable: true)
        return occupied.status == .partial && occupied.failures.map(\.reason) == ["occupied"]
            && gone.status == .partial && gone.failures.map(\.reason) == ["gone"]
            && item.canUndo
            && PiUndo.receipt(for: item, occupied).line(language: "de") == "Nicht rückgängig gemacht: Einkauf.txt (dort liegt inzwischen etwas anderes)"
    }

    if let node = nodeBinary() {
        check("Undo: Swift and restore.mjs leave the same files") {
            let a = try undoFixture(dir("pi-undo-parity-swift")), b = try undoFixture(dir("pi-undo-parity-node"))
            let trashA = a.root.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
            let trashB = b.root.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
            for entry in [a.edit, a.create, a.rename, a.bash] {
                _ = PiUndo.restore(entry, root: a.root) { url in
                    try fm.createDirectory(at: trashA, withIntermediateDirectories: true)
                    try fm.moveItem(at: url, to: trashA.appendingPathComponent(url.lastPathComponent)); return nil
                }
            }
            let script = repoRoot.appendingPathComponent("runtime/pippa-guard/restore.mjs").path
            let codes = [b.edit, b.create, b.rename, b.bash].map {
                run(node, [script, $0.path], environment: ["PATH": "/usr/bin:/bin", "PIPPA_TRASH_DIR": trashB.path]).status
            }
            let marks = [a.edit, a.create, a.rename, a.bash].map(PiUndo.isRestored) == [b.edit, b.create, b.rename, b.bash].map(PiUndo.isRestored)
            let same = fileTree(a.root.deletingLastPathComponent()) == fileTree(b.root.deletingLastPathComponent())
            if !same { print("   ", fileTree(a.root.deletingLastPathComponent()), "\n   ", fileTree(b.root.deletingLastPathComponent())) }
            return codes == [0, 0, 0, 1] && marks && same
        }
    } else {
        print("– Comparison with restore.mjs skipped (no node)")
    }

    /// A `move_files` batch as the guard writes it: ONE manifest with all moves plus the new target folders.
    func batchFixture(_ base: URL) throws -> (root: URL, work: URL, entry: URL) {
        let work = base.appendingPathComponent("work", isDirectory: true), root = base.appendingPathComponent("undo", isDirectory: true)
        let entry = root.appendingPathComponent("1-move-files", isDirectory: true)
        for sub in ["PDFs", "Bilder", "Texte/2026"] { try fm.createDirectory(at: work.appendingPathComponent(sub), withIntermediateDirectories: true) }
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        let files = ["a.pdf": "PDFs", "b.pdf": "PDFs", "c.jpg": "Bilder", "d.txt": "Texte/2026"]
        for (name, into) in files { write(name, work.appendingPathComponent("\(into)/\(name)")) }
        let moves = files.map { ["from": work.appendingPathComponent($0.key).path, "to": work.appendingPathComponent("\($0.value)/\($0.key)").path] }
        let created = ["Bilder", "Texte", "Texte/2026"].map { work.appendingPathComponent($0).path }
        let manifest: [String: Any] = ["version": 1, "tool": "move_files", "restorable": true, "moves": moves,
                                       "folders": [created[0], created[1]], "created": created]
        try JSONSerialization.data(withJSONObject: manifest).write(to: entry.appendingPathComponent("manifest.json"))
        return (root, work, entry)
    }
    check("Undo (native): one move_files batch entry brings every file back and trashes only the new, empty folders") {
        let f = try batchFixture(dir("pi-undo-batch"))
        let trashDir = f.root.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
        let result = PiUndo.restore(f.entry, root: f.root) { url in
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent)); return nil
        }
        let left = (try? fm.contentsOfDirectory(atPath: f.work.path).sorted()) ?? []
        let item = ActionReceipt.Item(action: "move", outcome: "done", name: "4 Dateien", toName: "PDFs, Bilder, Texte/2026", undoEntry: f.entry.path, restorable: true)
        return result.status == .restored && left == ["PDFs", "a.pdf", "b.pdf", "c.jpg", "d.txt"]
            && (try? fm.contentsOfDirectory(atPath: f.work.appendingPathComponent("PDFs").path)) == []
            && PiUndo.isRestored(f.entry) && !item.canUndo
    }
    if let node = nodeBinary() {
        check("Undo: Swift and restore.mjs leave the same files for a move_files batch") {
            let a = try batchFixture(dir("pi-undo-batch-swift")), b = try batchFixture(dir("pi-undo-batch-node"))
            let trashA = a.root.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
            let trashB = b.root.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
            _ = PiUndo.restore(a.entry, root: a.root) { url in
                try fm.createDirectory(at: trashA, withIntermediateDirectories: true)
                try fm.moveItem(at: url, to: trashA.appendingPathComponent(url.lastPathComponent)); return nil
            }
            let script = repoRoot.appendingPathComponent("runtime/pippa-guard/restore.mjs").path
            let code = run(node, [script, b.entry.path], environment: ["PATH": "/usr/bin:/bin", "PIPPA_TRASH_DIR": trashB.path]).status
            let same = fileTree(a.root.deletingLastPathComponent()) == fileTree(b.root.deletingLastPathComponent())
            if !same { print("   ", fileTree(a.root.deletingLastPathComponent()), "\n   ", fileTree(b.root.deletingLastPathComponent())) }
            return code == 0 && PiUndo.isRestored(a.entry) && PiUndo.isRestored(b.entry) && same
        }
    }

    check("Pi sessions: working folder from the existing session, deleting sets aside all files with that ID") {
        let base = dir("pi-sessions")
        let sessions = base.appendingPathComponent("pi-sessions", isDirectory: true)
        let folder = base.appendingPathComponent("Ordner A", isDirectory: true)
        let trash = base.appendingPathComponent("trash", isDirectory: true)
        for url in [sessions, folder, trash] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        func session(_ file: String, id: String, cwd: String) {
            write(#"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-10-07T10:00:00.000Z","cwd":"\#(cwd)"}"# + "\n{\"type\":\"message\"}\n",
                  sessions.appendingPathComponent(file))
        }
        session("2026-10-07T10-00-00-000Z_abc.jsonl", id: "abc", cwd: folder.path)
        session("2026-10-07T11-00-00-000Z_abc.jsonl", id: "abc", cwd: base.appendingPathComponent("weg").path) // folder no longer exists
        session("2026-10-07T10-00-00-000Z_abc_rev.jsonl", id: "abc_rev", cwd: folder.path)
        session("2026-10-07T10-00-00-000Z_other.jsonl", id: "other", cwd: folder.path)
        write("kein json\n", sessions.appendingPathComponent("2026-10-07T12-00-00-000Z_abc.jsonl"))
        let pinned = PiSessionFiles.pinnedWorkingDirectory(id: "abc", in: sessions)
        let none = PiSessionFiles.pinnedWorkingDirectory(id: "neu", in: sessions)
        let moved = PiSessionFiles.trash(ids: ["abc", "abc_rev"], in: sessions) { url in
            try fm.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let left = try fm.contentsOfDirectory(atPath: sessions.path).sorted()
        let trashed = try fm.contentsOfDirectory(atPath: trash.path).count
        return pinned?.standardizedFileURL.path == folder.standardizedFileURL.path && none == nil && moved.count == 3
            && left == ["2026-10-07T10-00-00-000Z_other.jsonl", "2026-10-07T12-00-00-000Z_abc.jsonl"]
            && trashed == 3
    }

    check("Key file for pippa-local: 0600, stable, too-wide permissions repaired; !command returns it even with ' and spaces") {
        let base = dir("llama-key")
        let support = base.appendingPathComponent("it's Application Support/Pippa", isDirectory: true)
        let key = try PiInstaller.stableKey(support: support)
        let file = PiInstaller.keyFile(support: support)
        let mode = { ((try? fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 }
        let first = mode()
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let again = try PiInstaller.stableKey(support: support)
        let entry = PiInstaller.providerEntry(models: [], port: 1, keyFile: file)
        guard let command = (entry["apiKey"] as? String), command.hasPrefix("!") else { return false }
        let viaShell = run("/bin/sh", ["-c", String(command.dropFirst())])
        return key.count == 64 && again == key && first == 0o600 && mode() == 0o600
            && viaShell.status == 0 && viaShell.output == key
    }

    // With a real payload: Pi's own resolution of models.json values (dist/core/resolve-config-value.js).
    if let payload = ProcessInfo.processInfo.environment["PIPPA_PI_PAYLOAD"], let node = nodeBinary() {
        check("Key file (real, pinned Pi): resolveConfigValueOrThrow reads the key, without cache") {
            let support = dir("llama-key-pi").appendingPathComponent("Application Support/Pippa", isDirectory: true)
            let key = try PiInstaller.stableKey(support: support)
            let command = PiInstaller.providerEntry(models: [], port: 1, keyFile: PiInstaller.keyFile(support: support))["apiKey"] as? String ?? ""
            let module = payload + "/release/node_modules/@earendil-works/pi-coding-agent/dist/core/resolve-config-value.js"
            // Resolve twice, changing the file in between: without a cache the new value comes back (models.md "not cached").
            let script = """
            const m = await import(process.argv[1]); const fs = await import("node:fs");
            const a = m.resolveConfigValueOrThrow(process.argv[2], "k");
            fs.writeFileSync(process.argv[3], "zweiter\\n");
            const b = m.resolveConfigValueOrThrow(process.argv[2], "k");
            console.log(JSON.stringify([a, b]));
            """
            let result = run(node, ["--input-type=module", "-e", script, module, command, PiInstaller.keyFile(support: support).path])
            return result.status == 0 && result.output == "[\"\(key)\",\"zweiter\"]"
        }
    }

    // Server for pippa-local, idle, mkdir, read receipts, sentence before the system prompt.
    await runWave2dChecks()
}
