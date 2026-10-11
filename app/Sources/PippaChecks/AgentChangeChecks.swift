import Foundation
import PippaCore

/// Undo of what Pi changed in a conversation (AgentChange, Executor.recordAgentChanges): entries from pippa-assist.ts
/// `pippa-change`, one job per answer, undo like after tidying up.
func runAgentChangeChecks() async {
    check("Changes from Pi: entries are read, incomplete or relative ones dropped, per file only the state before the answer") {
        let parsed = AgentChange.parse(#"{"v":1,"changes":[{"kind":"restore","file":"/u/a.txt","copy":"/b/1 a.txt"},{"kind":"restore","file":"/u/a.txt","copy":"/b/2 a.txt"},{"kind":"create","file":"/u/neu.txt"},{"kind":"move","from":"/d/x.pdf","to":"/d/X/x.pdf"},{"kind":"trash","from":"/d/y.pdf","to":"/T/y.pdf"},{"kind":"move","from":"rel.pdf","to":"/d/z.pdf"},{"kind":"other","file":"/u/b"}]}"#)
        let merged = AgentChange.merged(parsed)
        return parsed.count == 5 && merged.count == 4 && merged[0] == AgentChange(kind: .restore, from: "/b/1 a.txt", to: "/u/a.txt")
            && AgentChange.parse("kein json").isEmpty
            && AgentChange.finalPath(of: 0, in: [AgentChange(kind: .create, from: nil, to: "/u/n.txt"),
                                                 AgentChange(kind: .move, from: "/u/n.txt", to: "/u/A/n.txt")]) == "/u/A/n.txt"
    }

    await checkAsync("Changes from Pi: undo brings back the old version, removes the new file and moves back, in reverse order") {
        let home = dir("agent-change-files")
        let backups = dir("agent-change-backups")
        let edited = home.appendingPathComponent("Brief.txt"), copy = backups.appendingPathComponent("2026 Brief.txt")
        write("alt", copy); write("neu", edited)
        let created = home.appendingPathComponent("Notiz.txt")
        write("frisch", created)
        let source = home.appendingPathComponent("Rechnung.pdf"), folder = home.appendingPathComponent("Rechnungen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = folder.appendingPathComponent("Rechnung.pdf")
        write("%PDF", moved)
        let ex = try Executor(baseDirectory: dir("agent-change-support"))
        let changes = [AgentChange(kind: .restore, from: copy.path, to: edited.path), AgentChange(kind: .create, from: nil, to: created.path),
                       AgentChange(kind: .move, from: source.path, to: moved.path)]
        guard let receipt = try await ex.recordAgentChanges(changes, summary: "3 files changed", detail: "") else { return false }
        let listed = await ex.recentJobs().contains { $0.id == receipt.id && $0.canUndo }
        let report = try await ex.undo(jobID: receipt.id)
        let text = try? String(contentsOf: edited, encoding: .utf8)
        let state = await ex.jobState(jobID: receipt.id)
        let nothing = try await ex.recordAgentChanges([], summary: "", detail: "")
        return listed && report.conflicts.isEmpty && report.restored == 3 && text == "alt" && state == "undone"
            && !FileManager.default.fileExists(atPath: created.path)
            && FileManager.default.fileExists(atPath: source.path) && !FileManager.default.fileExists(atPath: moved.path)
            && FileManager.default.fileExists(atPath: copy.path) && nothing == nil
    }

    await checkAsync("Changes from Pi: a file changed again after the answer stays, and says why") {
        let home = dir("agent-change-later")
        let edited = home.appendingPathComponent("Liste.txt"), copy = home.appendingPathComponent("Kopie Liste.txt")
        write("alt", copy); write("neu", edited)
        let ex = try Executor(baseDirectory: dir("agent-change-later-support"))
        guard let receipt = try await ex.recordAgentChanges([AgentChange(kind: .restore, from: copy.path, to: edited.path)],
                                                             summary: "Liste.txt", detail: "") else { return false }
        Thread.sleep(forTimeInterval: 0.05)
        write("von Hand weiter geschrieben", edited)
        let report = try await ex.undo(jobID: receipt.id)
        let text = try? String(contentsOf: edited, encoding: .utf8)
        return report.restored == 0 && report.conflicts.count == 1 && text == "von Hand weiter geschrieben"
    }
}
