import Foundation
import PippaCore

// Pi's session files per conversation, key file for `pippa-local` and Pippa's settings.json.
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

/// Node from the payload, else Homebrew. `nil`: the check with the real Pi is skipped.
private func nodeBinary() -> String? {
    let env = ProcessInfo.processInfo.environment
    let candidates = [env["PIPPA_PI_PAYLOAD"].map { $0 + "/bin/node" }, "/opt/homebrew/bin/node", "/usr/local/bin/node"].compactMap { $0 }
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}

func runPiPivotChecks() async {
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
