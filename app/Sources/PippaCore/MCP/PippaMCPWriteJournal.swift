import Foundation

/// The run journal row of one native write (RunJournal.swift): `dispatched` on disk before the native call, then
/// done or unclear from Pippa's own read-back. Used by the writer tools and `prepare_files`.
struct PippaMCPRunRow: Sendable {
    let journal: Executor
    let id: UUID
    let run: UUID

    /// `nil`: no run (no answer owns the lease) or a host without a journal that does not require one (checks).
    /// Throws when the host requires the journal and the row cannot be written; then nothing may run.
    static func dispatch(_ host: PippaMCPHost, lease: PippaMCPWriteLease?, tool: String, object: RunObject, label: String,
                         before: [String: String]? = nil, after: [String: String]? = nil) async throws -> PippaMCPRunRow? {
        try await dispatch(host, run: lease?.turnID, tool: tool, object: object, label: label, before: before, after: after)
    }

    static func dispatch(_ host: PippaMCPHost, run: UUID?, tool: String, actionClass: PippaActionClass? = nil, object: RunObject,
                         label: String, before: [String: String]? = nil, after: [String: String]? = nil) async throws -> PippaMCPRunRow? {
        guard let run else { return nil }
        guard let journal = host.reminderJournal else {
            if host.requiresReminderJournal { throw NativeReminderJournalError.unreadable }
            return nil
        }
        let draft = RunActionDraft(tool: tool, actionClass: actionClass, object: object, before: before, after: after, label: label)
        let rows = try await journal.planRunActions(run: run, [draft], dispatched: true)
        return PippaMCPRunRow(journal: journal, id: rows[0].id, run: run)
    }

    /// A failed commit leaves the row dispatched, which reads as unclear: never as done.
    func complete(verified: Bool?, object: RunObject? = nil, after: [String: String]? = nil) async {
        _ = try? await journal.completeRunActions([.init(id: id, verified: verified, object: object, after: after)])
    }

    /// The call ended without a result: unclear once the native call started, otherwise nothing happened and the row goes.
    func abandon(dispatched: Bool) async {
        if dispatched { try? await journal.unclearRunActions([id]) } else { try? await journal.dropRunActions([id]) }
    }
}

extension PippaMCPWriteTools {
    /// The event or reminder as the store has it now matches what was asked and what Pippa saved.
    static func readBackMatches(_ readBack: CreatedItemReadBack, _ item: CreatedItem, title: String, container: String? = nil,
                                start: Date? = nil, end: Date? = nil, allDay: Bool = false, calendar: Calendar = .current) -> Bool {
        guard case .found(let foundTitle, let foundStart, let foundEnd, let foundContainer, let fingerprint) = readBack else { return false }
        guard foundTitle == title, item.fingerprint == nil || fingerprint == item.fingerprint else { return false }
        if let container, foundContainer != container { return false }
        if let start {
            guard let foundStart else { return false }
            if allDay { return calendar.isDate(foundStart, inSameDayAs: start) }
            guard foundStart == start, end == nil || foundEnd == end else { return false }
        }
        return true
    }

    /// What the model gets after the read-back: the count it may repeat, or "not confirmed" when it did not match.
    static func verified(_ result: PippaMCPToolResult, matched: Bool, integration: Integration) -> PippaMCPToolResult {
        guard matched else {
            var receipt = result.receipt
            receipt?.outcome = "unclear"; receipt?.reason = "notVerified"
            return PippaMCPToolResult(text: PippaMCPTools.json([
                "done": false, "state": "unclear", "verified": "0 of 1",
                "tell": L("Pippa couldn’t confirm the change in %@ when she checked it. Please look there. She won’t repeat it.", table: "MCP", integration.appName),
                "next": "Not confirmed: Pippa read it back and it did not match. Do not retry or recreate it in any way. Repeat tell.",
            ]), isError: false, receipt: receipt)
        }
        guard var object = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] else { return result }
        object["verified"] = "1 of 1"
        var checked = result
        checked.text = PippaMCPTools.json(object)
        return checked
    }
}

extension PippaMCPHost {
    /// How to undo one row, by its kind: a recipe a tool or check added (`runRecipes`) first, then Pippa's own.
    public func runUndoRecipe(_ kind: String) -> RunUndoRecipe? {
        if let recipe = runRecipes[kind] { return recipe }
        switch kind {
        case "event", "reminder":
            let integrations = self.integrations
            return { row in
                guard let item = row.object.createdItem else { return .failed }
                do {
                    return switch try await integrations.remove(item) {
                    case .removed: .undone
                    case .gone: .gone
                    case .changed: .changed
                    }
                } catch { return .failed }
            }
        case MailMover.kind:
            guard let reader = mailAccounts else { return nil }
            return { row in await MailMover.undo(row, reader: reader) }
        case "file.prepared":
            guard let journal = reminderJournal else { return nil }
            return { row in
                guard let job = row.object.fields["job"].flatMap(UUID.init), let path = row.object.fields["path"] else { return .failed }
                // Gone or moved away by the person: it stays as it is, never recreated or counted as undone.
                guard (try? DurableFileIdentity.capture(URL(fileURLWithPath: path))) == row.object.fileIdentity else { return .changed }
                do { return try await journal.undo(jobID: job).conflicts.isEmpty ? .undone : .changed } catch { return .failed }
            }
        default:
            return RunFileRecipes.recipe(kind)
        }
    }

    /// Undo from one receipt row of `run`, under the same lock as Undo of the whole answer; its run row then takes the
    /// same outcome, so each Undo sees what the other did. Busy: the receipt comes back as it was.
    public func undo(_ receipt: PippaMCPWriteReceipt, run: UUID?) async -> PippaMCPWriteReceipt {
        guard let run, let journal = reminderJournal, let key = receipt.created?.identifier, receipt.canUndo else { return await undo(receipt) }
        do { try await journal.beginRunUndo(run) } catch { return receipt }
        let result = await undo(receipt)
        let outcome: RunUndoOutcome? = switch result.undo {
        case "removed": .undone
        case "gone": .gone
        case "changed": .changed
        case "failed": .failed
        default: nil
        }
        if let outcome { try? await journal.markRunObject(run: run, key: key, outcome) }
        await journal.endRunUndo(run)
        return result
    }

    /// Undo for a whole run (one answer), backwards, each step only on an unchanged object.
    public func undoRun(_ run: UUID) async throws -> RunUndoReport {
        guard let journal = reminderJournal else { throw NativeReminderJournalError.unreadable }
        let host = self
        return try await journal.undoRun(run) { host.runUndoRecipe($0) }
    }

    /// The receipts for these runs, from the journal. A run without rows (or pruned) is missing.
    public func runSummaries(_ runs: [UUID]) async -> [UUID: RunSummary] {
        guard let journal = reminderJournal, let rows = try? await journal.runActions(runs: runs) else { return [:] }
        var result: [UUID: RunSummary] = [:]
        for (run, actions) in rows where !actions.isEmpty {
            result[run] = RunSummary(run: run, rows: actions) { runUndoRecipe($0) != nil }
        }
        return result
    }
}
