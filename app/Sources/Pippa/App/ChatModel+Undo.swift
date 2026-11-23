import Foundation
import PippaCore

/// Undo for individual receipts and whole answer runs in `ChatModel`.
extension ChatModel {
    static func undoKey(_ messageID: UUID, _ index: Int) -> String { "\(messageID.uuidString)#\(index)" }

    /// Removes the event or reminder a receipt names, only if it is unchanged since Pippa added it, and keeps the
    /// outcome on the receipt (shown in the row, saved with the conversation).
    func undo(receiptAt index: Int, in messageID: UUID) {
        guard let id = currentID,
              let receipts = conversations.first(where: { $0.id == id })?.messages.first(where: { $0.id == messageID })?.receipts,
              receipts.indices.contains(index), receipts[index].canUndo else { return }
        let receipt = receipts[index]
        let key = Self.undoKey(messageID, index)
        guard !undoing.contains(key) else { return }
        undoing.insert(key)
        let run = conversations.first(where: { $0.id == id })?.messages.first(where: { $0.id == messageID })?.run?.run
        Task {
            let result = await PippaMCPService.undo(receipt, run: run)
            undoing.remove(key)
            update(messageID, in: id) { message in
                guard message.receipts.indices.contains(index) else { return }
                message.receipts[index] = result
            }
            if result.undo == "removed" { undoneNotes[id, default: []].append(result.name) }
            if let run, let summary = await PippaMCPService.runSummary(run) {
                update(messageID, in: id) { $0.run = summary }
            }
            save(id)
        }
    }

    /// Undo for everything the answer changed: backwards through its journal rows, each only if unchanged since Pippa
    /// touched it; the receipt then counts what was undone, left because it changed, and failed.
    func undoRun(in messageID: UUID) {
        guard let id = currentID, let run = conversations.first(where: { $0.id == id })?.messages.first(where: { $0.id == messageID })?.run,
              run.undoable > 0 else { return }
        let key = Self.undoKey(messageID, -1)
        guard !undoing.contains(key) else { return }
        undoing.insert(key)
        Task {
            let (summary, report) = await PippaMCPService.undoRun(run.run)
            undoing.remove(key)
            // Each object's outcome as its own receipt row says it.
            var outcomes: [String: String] = [:]
            for row in report?.undone ?? [] { if let key = row.object.key { outcomes[key] = row.note == "gone" ? "gone" : "removed" } }
            for row in report?.left ?? [] { if let key = row.object.key { outcomes[key] = "changed" } }
            for row in report?.failed ?? [] { if let key = row.object.key { outcomes[key] = "failed" } }
            update(messageID, in: id) { message in
                // No rows any more (pruned after 30 days): nothing left to undo.
                message.run = summary ?? RunSummary(run: run.run, changes: run.changes, checked: run.checked, unclear: run.unclear,
                                                    undone: run.undone, left: run.left, failed: run.failed)
                // The answer's own receipt rows say the same as the run receipt.
                for index in message.receipts.indices where message.receipts[index].undo == nil {
                    guard let key = message.receipts[index].created?.identifier, let outcome = outcomes[key] else { continue }
                    message.receipts[index].undo = outcome
                }
            }
            if let report { undoneNotes[id, default: []].append(contentsOf: report.undone.filter { $0.note != "gone" }.map(\.label)) }
            save(id)
        }
    }

    /// The run receipts as the journal has them now. A change cut off by a crash or quit shows as unclear.
    func refreshRuns() {
        let runs = conversations.flatMap(\.messages).compactMap(\.run?.run)
        guard !runs.isEmpty else { return }
        Task {
            let summaries = await PippaMCPService.runSummaries(runs)
            var changed: Set<String> = []
            for c in conversations.indices {
                for m in conversations[c].messages.indices {
                    guard let run = conversations[c].messages[m].run, let fresh = summaries[run.run], fresh != run else { continue }
                    conversations[c].messages[m].run = fresh
                    changed.insert(conversations[c].id)
                }
            }
            changed.forEach(save)
        }
    }
}
