import Foundation
import PippaCore

/// Writes chosen actions and their outcome to the task log, in order and silently.
/// A write error changes nothing about the task itself. The log is read by `Habits`.
@MainActor
final class TaskLogRecorder {
    private let log: TaskLog?
    /// All writes one after another, so that an outcome never arrives before its line.
    private var tail: Task<Void, Never>?
    /// Last chosen action that can still become a receipt (undo).
    private var awaitingReceipt: Task<Int64?, Never>?
    /// Receipt → log line, for "Undo" in this session.
    private var rows: [UUID: Task<Int64?, Never>] = [:]
    /// Mark from `choseTracked` → log line, until the outcome is known.
    private var tracked: [UUID: Task<Int64?, Never>] = [:]

    init(log: TaskLog?) { self.log = log }

    /// An action was chosen. `bindsReceipt`: the flow ends with a receipt (tidy, table, entry).
    /// `sourceLabel`: short derived name of the source (sender), never a path or address.
    func chose(_ chosen: String, offered: [String], kind: TaskKind, sourceLabel: String? = nil, bindsReceipt: Bool = false) {
        guard let log else { return }
        let record = TaskRecord(kind: kind, sourceLabel: sourceLabel, offered: offered, chosen: chosen)
        let previous = tail
        let row = Task<Int64?, Never> {
            _ = await previous?.value
            return try? await log.record(record)
        }
        tail = Task { _ = await row.value }
        awaitingReceipt = bindsReceipt ? row : nil
    }

    /// New items given: an open choice no longer belongs to a later receipt.
    func dropPending() { awaitingReceipt = nil }

    /// The job is done and stays that way for now.
    func finished(_ receipt: UUID) {
        guard let row = awaitingReceipt else { return }
        awaitingReceipt = nil
        rows[receipt] = row
        update(row, .kept)
    }

    func undone(_ receipt: UUID) {
        guard let row = rows.removeValue(forKey: receipt) else { return }
        update(row, .undone)
    }

    /// Offered but nothing chosen (the line closed without a choice). Counts for fading (`Habits.faded`).
    func ignored(offered: [String], kind: TaskKind, sourceLabel: String? = nil) {
        guard let log, !offered.isEmpty else { return }
        let record = TaskRecord(kind: kind, sourceLabel: sourceLabel, offered: offered, chosen: nil)
        let previous = tail
        tail = Task {
            _ = await previous?.value
            _ = try? await log.record(record)
        }
    }

    /// The result went somewhere (dragged, saved): add the destination and count `result_left`.
    func took(_ receipt: UUID, target: TaskTarget) {
        guard let log else { return }
        let row = rows[receipt]
        let previous = tail
        tail = Task {
            _ = await previous?.value
            if let row, let id = await row.value { try? await log.setTarget(target, for: id) }
            try? await log.log(.resultLeft)
        }
    }

    // MARK: Letter

    /// Chosen action whose outcome comes later (draft → insert). The mark belongs to `inserted`.
    @discardableResult
    func choseTracked(_ chosen: String, offered: [String], kind: TaskKind, sourceLabel: String?) -> UUID {
        let token = UUID()
        guard let log else { return token }
        let record = TaskRecord(kind: kind, sourceLabel: sourceLabel, offered: offered, chosen: chosen)
        let previous = tail
        let row = Task<Int64?, Never> {
            _ = await previous?.value
            return try? await log.record(record)
        }
        tail = Task { _ = await row.value }
        tracked[token] = row
        return token
    }

    /// The draft went into Mail (unsent): destination "inserted", outcome kept or changed, count `result_left`.
    func inserted(_ token: UUID, edited: Bool) {
        guard let log, let row = tracked.removeValue(forKey: token) else { return }
        let previous = tail
        tail = Task {
            _ = await previous?.value
            if let id = await row.value {
                try? await log.setTarget(TaskTarget(kind: .inserted, label: "Mail"), for: id)
                try? await log.setOutcome(edited ? .edited : .kept, for: id)
            }
            try? await log.log(.resultLeft)
        }
    }

    /// Event without content (permission asked, granted, denied).
    func event(_ event: TaskEvent) {
        guard let log else { return }
        let previous = tail
        tail = Task {
            _ = await previous?.value
            try? await log.log(event)
        }
    }

    /// Lines for the offer (`Habits`), newest first; waits for everything already being written.
    func records(limit: Int = 500) async -> [TaskRecord] {
        guard let log else { return [] }
        _ = await tail?.value
        return (try? await log.records(limit: limit)) ?? []
    }

    /// Settings must report a failed read instead of presenting an empty memory as success.
    func recordsForSettings() async throws -> [TaskRecord] {
        guard let log else { throw LearningStorageError.unavailable }
        _ = await tail?.value
        return try await log.records(limit: Int.max)
    }

    /// Explicitly requested in Settings; serialize the deletion with all other log writes.
    func forgetLearnedActions() async throws {
        guard let log else { throw LearningStorageError.unavailable }
        let previous = tail
        let clearing = Task {
            _ = await previous?.value
            try await log.forgetEverything()
        }
        // Future log writes wait for this operation even when the UI reports a deletion error.
        tail = Task { _ = await clearing.result }
        try await clearing.value
        awaitingReceipt = nil
        rows.removeAll()
        tracked.removeAll()
    }

    private enum LearningStorageError: LocalizedError {
        case unavailable
        var errorDescription: String? { T("I can’t access the learned actions right now.", table: "Settings") }
    }

    private func update(_ row: Task<Int64?, Never>, _ outcome: TaskOutcome) {
        guard let log else { return }
        let previous = tail
        tail = Task {
            _ = await previous?.value
            guard let id = await row.value else { return }
            try? await log.setOutcome(outcome, for: id)
        }
    }
}
