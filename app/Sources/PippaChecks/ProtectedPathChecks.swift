import Foundation
import PippaCore

/// Pippa's own folder and Pi's sign-in folders stay closed to the app's MCP tools that take a path (ProtectedPaths, the
/// same rules as runtime/pippa-tools/protected.ts). Synthetic folders only; nothing in them is ever read.
func runProtectedPathChecks() async {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-protected-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    // The real path (/private/var/…), so the firmlink form below names the same folder.
    let home = URL(fileURLWithPath: realpath(fixture.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? fixture.path, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let support = home.appendingPathComponent("Library/Application Support/Pippa", isDirectory: true)
    let work = support.appendingPathComponent("pi-work", isDirectory: true)
    let agent = home.appendingPathComponent(".pi/agent", isDirectory: true)
    let documents = home.appendingPathComponent("Documents", isDirectory: true)
    for folder in [work, agent, documents, support.appendingPathComponent("pi-sessions")] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try? Data("{}".utf8).write(to: agent.appendingPathComponent("auth.json"))
    try? Data("ok".utf8).write(to: documents.appendingPathComponent("letter.txt"))
    await checkAsync("Protected paths: a hard link in the working folder cannot alias a credential") {
        let alias = work.appendingPathComponent("hardlink.txt")
        do {
            try FileManager.default.linkItem(at: agent.appendingPathComponent("auth.json"), to: alias)
            return ProtectedPaths(roots: [support, agent], open: [work]).contains(alias)
        } catch { return false }
    }
    try? FileManager.default.createSymbolicLink(at: work.appendingPathComponent("alias.json"), withDestinationURL: agent.appendingPathComponent("auth.json"))
    try? FileManager.default.createSymbolicLink(at: documents.appendingPathComponent("sessions"), withDestinationURL: support.appendingPathComponent("pi-sessions"))
    let paths = ProtectedPaths.app(support: support, home: home, environment: [:])

    check("Protected paths: Pippa's folder and ~/.pi by real location (symlink, case, .., firmlink); working folder and own files open") {
        let closed = [support.appendingPathComponent("inference-settings.json").path, support.appendingPathComponent("memory.md").path,
                      agent.appendingPathComponent("auth.json").path, work.appendingPathComponent("alias.json").path,
                      documents.appendingPathComponent("sessions/x.jsonl").path, work.path + "/../memory.md",
                      home.path + "/.PI/AGENT/auth.json", "/System/Volumes/Data" + agent.appendingPathComponent("auth.json").path]
        let open = [work.appendingPathComponent("note.txt").path, documents.appendingPathComponent("letter.txt").path, work.path]
        return closed.allSatisfy { paths.contains(URL(fileURLWithPath: $0)) } && !open.contains { paths.contains(URL(fileURLWithPath: $0)) }
    }
    check("Protected paths: the extensions get the same places; a working folder that holds a protected one is not open") {
        let env = ProtectedPaths.app(support: support, home: home, extra: [URL(fileURLWithPath: "/tmp/pinned")], environment: [:]).environment
        let listed = (try? JSONSerialization.jsonObject(with: Data((env["PIPPA_PROTECTED_PATHS"] ?? "").utf8))) as? [String] ?? []
        return listed == [support.path, home.appendingPathComponent(".pi").path, "/tmp/pinned"] && env["PIPPA_WORK_DIR"] == work.path
            && ProtectedPaths(roots: [support], open: [home]).open.isEmpty
            && ProtectedPaths.app(support: support, home: home, environment: ["PI_CODING_AGENT_DIR": "/tmp/agent-dir"]).roots.map(\.path).contains("/tmp/agent-dir")
    }
    check("Protected paths: the work exception requires the original directory entry") {
        let fm = FileManager.default
        let sessions = support.appendingPathComponent("pi-sessions", isDirectory: true)
        try fm.moveItem(at: work, to: support.appendingPathComponent("old-work"))
        try fm.createSymbolicLink(at: work, withDestinationURL: sessions)
        let target = sessions.appendingPathComponent("private.txt")
        let symlinkClosed = paths.contains(target) && ProtectedPaths(roots: [support], open: [work]).contains(target)
        try fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        return symlinkClosed && paths.contains(work.appendingPathComponent("note.txt"))
            && paths.environment["PIPPA_WORK_ID"] == ""
    }
    await checkAsync("MCP read_document refuses a synthetic protected root, including its file URL spelling") {
        let previous = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
        setenv("PI_CODING_AGENT_DIR", agent.path, 1)
        defer {
            if let previous { setenv("PI_CODING_AGENT_DIR", previous, 1) }
            else { unsetenv("PI_CODING_AGENT_DIR") }
        }
        let reader = PippaMCPTurnTools(turns: PippaMCPTurns())
        func status(_ path: String) async -> String? {
            let result = await reader.call("read_document", ["path": path])
            return (try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])?["status"] as? String
        }
        let file = agent.appendingPathComponent("auth.json")
        for path in [file.path, file.absoluteString] where await status(path) != "protected" { return false }
        return await status(documents.appendingPathComponent("letter.txt").path) != "protected"
    }

}
