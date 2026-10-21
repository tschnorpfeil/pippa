import CryptoKit
import Foundation

/// Trusted origin supplied by the app. Document text and tool arguments cannot select another request's authority.
public struct PippaMCPOrigin: Sendable, Equatable, Codable {
    public let conversationID: UUID
    public let requestID: UUID
    public init(conversationID: UUID, requestID: UUID) { self.conversationID = conversationID; self.requestID = requestID }
}

/// Immutable native destination. A later default-list change must not redirect a recovered operation.
public struct NativeReminderTarget: Sendable, Equatable, Codable {
    public let identifier: String
    public let title: String
    public let matched: Bool
    public init(identifier: String, title: String, matched: Bool = true) {
        self.identifier = identifier; self.title = title; self.matched = matched
    }
}

public struct NativeReminderRecord: Sendable, Equatable, Codable {
    public enum Phase: String, Sendable, Codable { case planned, prepared, dispatched, uncertain, completed, notDispatched }
    public let id: UUID
    public let origin: PippaMCPOrigin?
    public let originatingTurnID: UUID?
    public var attemptTurnID: UUID?
    public let requestHash: String
    public let reminder: NewReminder
    public let label: String
    public var phase: Phase
    /// Monotonic durable state version, used to reject stale UI/recovery evidence across attempts.
    public var revision: Int
    public var target: NativeReminderTarget?
    public var result: HostWrite?
    /// Marker reconciliation proves identity, but does not establish that the entry is unchanged since creation.
    public var recovered: Bool
    public var processSession: UUID
    public let created: Date
    public var updated: Date
    public var finalReceipt: PippaMCPWriteReceipt?

    public var marker: URL { URL(string: "pippa://operation/" + id.uuidString.lowercased())! }
    public var undoSafe: Bool { phase == .completed && !recovered && result?.item.fingerprint != nil }
    public var isUnresolved: Bool { [.planned, .prepared, .dispatched, .uncertain].contains(phase) }
    public var receipt: PippaMCPWriteReceipt {
        var receipt = finalReceipt ?? .init(action: "reminderAdd", outcome: phase == .completed ? "done" : phase == .notDispatched ? "cancelled" : "unclear",
                                            name: label, reason: phase == .notDispatched ? "stopped" : phase == .completed ? nil : "unconfirmed")
        receipt.operationID = id; receipt.turnID = originatingTurnID; receipt.nativeRevision = revision
        return receipt
    }

    /// Includes the normalized arguments before resolving relative dates, so a retry tomorrow retains today's plan.
    public static func requestHash(_ arguments: [String: String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum NativeReminderAdmission: Sendable {
    case execute(NativeReminderRecord)
    case completed(NativeReminderRecord)
    case blocked(NativeReminderRecord)
}

public enum NativeReminderLookup: Sendable {
    case found(HostWrite)
    case notFound
    case ambiguous
    case unavailable
}

public enum NativeReminderJournalError: Error, Sendable { case invalidState, unreadable, targetChanged }

extension Executor {
    static let nativeReminderSchema = """
        CREATE TABLE IF NOT EXISTS native_reminder_ops(
            id TEXT PRIMARY KEY, conversation TEXT, request TEXT, request_hash TEXT NOT NULL,
            state TEXT NOT NULL, process_session TEXT NOT NULL, record TEXT NOT NULL);
        CREATE UNIQUE INDEX IF NOT EXISTS native_reminder_request ON native_reminder_ops(conversation, request, request_hash)
            WHERE conversation IS NOT NULL AND request IS NOT NULL;
        CREATE INDEX IF NOT EXISTS native_reminder_conversation ON native_reminder_ops(conversation, state);
        """

    /// Claims an operation before any permission wait. This transaction also serializes independent Executor
    /// instances. A new user request is new intent; an uncertain operation blocks further writes in its conversation.
    public func beginNativeReminder(id: UUID, origin: PippaMCPOrigin?, turnID: UUID?, requestHash: String,
                                    reminder: NewReminder, label: String) throws -> NativeReminderAdmission {
        try db.exec("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.exec("ROLLBACK") } }
        try closeUndispatchedNativeReminders()
        var existing: NativeReminderRecord?
        if let origin {
            existing = try nativeRows("WHERE conversation=? AND request=? AND request_hash=?",
                [.text(origin.conversationID.uuidString), .text(origin.requestID.uuidString), .text(requestHash)]).first
        }
        let admission: NativeReminderAdmission
        if let existing, existing.phase == .completed {
            admission = .completed(existing)
        } else if let blocker = try nativeRows("WHERE conversation=? AND state IN ('planned','prepared','dispatched','uncertain') ORDER BY rowid LIMIT 1",
                                              [origin.map { .text($0.conversationID.uuidString) } ?? .null]).first {
            admission = .blocked(blocker)
        } else if var existing {
            guard existing.phase == .notDispatched else { throw NativeReminderJournalError.invalidState }
            existing.phase = .planned; existing.processSession = nativeSessionID; existing.attemptTurnID = turnID
            existing.updated = Date(); existing.finalReceipt = nil
            try saveNativeReminder(&existing)
            admission = .execute(existing)
        } else {
            let record = NativeReminderRecord(id: id, origin: origin, originatingTurnID: turnID, attemptTurnID: turnID,
                requestHash: requestHash, reminder: reminder, label: label, phase: .planned, revision: 0, target: nil, result: nil,
                recovered: false, processSession: nativeSessionID, created: Date(), updated: Date(), finalReceipt: nil)
            try db.run("INSERT INTO native_reminder_ops(id,conversation,request,request_hash,state,process_session,record) VALUES(?,?,?,?,?,?,?)",
                       [.text(id.uuidString), origin.map { .text($0.conversationID.uuidString) } ?? .null,
                        origin.map { .text($0.requestID.uuidString) } ?? .null, .text(requestHash), .text(record.phase.rawValue),
                        .text(nativeSessionID.uuidString), .text(try encodeNativeReminder(record))])
            admission = .execute(record)
        }
        try db.exec("COMMIT"); committed = true
        return admission
    }

    public func prepareNativeReminder(id: UUID, target: NativeReminderTarget) throws -> NativeReminderRecord {
        try nativeReminderTransaction {
            var record = try nativeReminder(id: id)
            guard [.planned, .prepared].contains(record.phase), record.processSession == nativeSessionID else { throw NativeReminderJournalError.invalidState }
            guard !target.identifier.isEmpty, record.target == nil || record.target == target else { throw NativeReminderJournalError.targetChanged }
            record.target = target; record.phase = .prepared; record.updated = Date()
            try saveNativeReminder(&record)
            return record
        }
    }

    /// Must commit before the native save. A crash after this point is uncertain even if no entry can be found.
    @discardableResult public func dispatchNativeReminder(id: UUID) throws -> NativeReminderRecord {
        try nativeReminderTransaction {
            var record = try nativeReminder(id: id)
            guard record.phase == .prepared, record.target != nil, record.processSession == nativeSessionID else { throw NativeReminderJournalError.invalidState }
            record.phase = .dispatched; record.updated = Date()
            try saveNativeReminder(&record)
            return record
        }
    }

    /// Store native identity before responding to Pi. A failed journal write leaves the prior dispatched row blocking replay.
    @discardableResult public func completeNativeReminder(id: UUID, result: HostWrite, recovered: Bool = false) throws -> NativeReminderRecord {
        try nativeReminderTransaction {
            var record = try nativeReminder(id: id)
            guard [.dispatched, .uncertain, .completed].contains(record.phase), result.item.integration == .reminders,
                  !result.item.identifier.isEmpty else { throw NativeReminderJournalError.invalidState }
            if let old = record.result, old.item.identifier != result.item.identifier { throw NativeReminderJournalError.invalidState }
            guard result.containerIdentifier == record.target?.identifier else { throw NativeReminderJournalError.targetChanged }
            record.result = result; record.phase = .completed; record.recovered = record.recovered || recovered
            record.updated = Date(); record.finalReceipt = nil
            try saveNativeReminder(&record)
            return record
        }
    }

    /// Known pre-dispatch refusal is retryable. Once the actual save began, no error is proof of no effect.
    @discardableResult public func finishNativeReminder(id: UUID, dispatched: Bool,
                                                        receipt: PippaMCPWriteReceipt?) throws -> NativeReminderRecord {
        try nativeReminderTransaction {
            var record = try nativeReminder(id: id)
            if record.phase == .completed { return record }
            guard record.processSession == nativeSessionID else { throw NativeReminderJournalError.invalidState }
            record.phase = dispatched ? .uncertain : .notDispatched
            record.finalReceipt = receipt; record.updated = Date()
            if dispatched { record.finalReceipt = nil }
            try saveNativeReminder(&record)
            return record
        }
    }

    public func nativeReminderRecords(conversationID: UUID? = nil) throws -> [NativeReminderRecord] {
        try nativeReminderTransaction {
            try closeUndispatchedNativeReminders()
            return try nativeRows(conversationID == nil ? "ORDER BY rowid" : "WHERE conversation=? ORDER BY rowid",
                                  conversationID.map { [.text($0.uuidString)] } ?? [])
        }
    }

    /// Read-only recovery: no permission prompt and no writes to Reminders. Only a unique native identity resolves
    /// an uncertain dispatch. Absence, permission loss, a missing list and duplicate markers all remain unresolved.
    public func reconcileNativeReminders(using writer: any HostWriting, conversationID: UUID? = nil) async throws -> [NativeReminderRecord] {
        let candidates = try nativeReminderRecords(conversationID: conversationID)
        let deadline = ContinuousClock.now + .seconds(12)
        for record in candidates.filter({ [.dispatched, .uncertain].contains($0.phase) }).prefix(8) {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
            guard let target = record.target else { continue }
            if case .found(let result) = await writer.lookupReminder(marker: record.marker, target: target,
                                                                      identifier: record.result?.item.identifier) {
                _ = try completeNativeReminder(id: record.id, result: result, recovered: true)
            }
        }
        return try nativeReminderRecords(conversationID: conversationID)
    }

    public func nativeReminder(id: UUID) throws -> NativeReminderRecord {
        guard let record = try nativeRows("WHERE id=?", [.text(id.uuidString)]).first else { throw NativeReminderJournalError.unreadable }
        return record
    }

    private func closeUndispatchedNativeReminders() throws {
        for var record in try nativeRows("WHERE state IN ('planned','prepared') AND process_session!=?", [.text(nativeSessionID.uuidString)]) {
            record.phase = .notDispatched; record.updated = Date(); record.finalReceipt = nil
            try saveNativeReminder(&record)
        }
    }

    private func nativeRows(_ condition: String, _ arguments: [SQLiteDB.Value] = []) throws -> [NativeReminderRecord] {
        try db.query("SELECT record FROM native_reminder_ops " + condition, arguments).map { row in
            guard let text = row.first?.string, let record = try? JSONDecoder().decode(NativeReminderRecord.self, from: Data(text.utf8)) else {
                throw NativeReminderJournalError.unreadable
            }
            return record
        }
    }

    private func encodeNativeReminder(_ record: NativeReminderRecord) throws -> String {
        String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    }

    /// Every caller holds BEGIN IMMEDIATE, so independent Executor connections cannot reuse a revision.
    private func saveNativeReminder(_ record: inout NativeReminderRecord) throws {
        guard record.revision < Int.max else { throw NativeReminderJournalError.invalidState }
        record.revision += 1
        try db.run("UPDATE native_reminder_ops SET state=?,process_session=?,record=? WHERE id=?",
                   [.text(record.phase.rawValue), .text(record.processSession.uuidString), .text(try encodeNativeReminder(record)), .text(record.id.uuidString)])
    }

    private func nativeReminderTransaction<T>(_ body: () throws -> T) throws -> T {
        try db.exec("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.exec("ROLLBACK") } }
        let result = try body()
        try db.exec("COMMIT"); committed = true
        return result
    }
}
