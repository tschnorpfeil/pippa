import Foundation
import PippaCore
import SQLite3

/// Synthetic Reminders store. No EventKit instance, system permission request, or personal reminder is involved.
actor ReminderJournalWriter: HostWriting {
    var writes = 0
    var lookups: [URL] = []
    var target = NativeReminderTarget(identifier: "fixture-list-a", title: "Fixture list")
    var stored: [URL: [HostWrite]] = [:]
    var lookupUnavailable = false
    var afterDispatch: (@Sendable () -> Void)?
    func setAfterDispatch(_ action: @escaping @Sendable () -> Void) { afterDispatch = action }
    func setUnavailable(_ value: Bool) { lookupUnavailable = value }
    func duplicate(_ marker: URL) { if let item = stored[marker]?.first { stored[marker, default: []].append(item) } }
    func forget(_ marker: URL) { stored[marker] = nil }
    func changeDefault() { target = .init(identifier: "fixture-list-b", title: "Other list") }
    func reminderTarget(for reminder: NewReminder) async throws -> NativeReminderTarget { target }
    func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite { throw PippaError.notAvailable }
    func addReminder(_ reminder: NewReminder) async throws -> HostWrite { throw PippaError.notAvailable }
    func addReminder(_ reminder: NewReminder, target: NativeReminderTarget, marker: URL) async throws -> HostWrite {
        try PippaMCPWriteLease.current?.beginDispatch()
        writes += 1
        let item = CreatedItem(integration: .reminders, identifier: "fixture-native-\(writes)", modified: Date(), fingerprint: "fixture-fingerprint-\(writes)")
        let result = HostWrite(item: item, container: target.title, containerMatched: target.matched, containerIdentifier: target.identifier)
        stored[marker, default: []].append(result)
        afterDispatch?()
        return result
    }
    func lookupReminder(marker: URL, target: NativeReminderTarget, identifier: String?) async -> NativeReminderLookup {
        lookups.append(marker)
        if lookupUnavailable { return .unavailable }
        let matches = (stored[marker] ?? []).filter { $0.containerIdentifier == target.identifier }
        if matches.count > 1 { return .ambiguous }
        guard let result = matches.first else { return .notFound }
        if let identifier, result.item.identifier != identifier { return .unavailable }
        return .found(result)
    }
}

actor ReminderPendingProbe {
    var ids: [UUID] = []
    var revisions: [Int?] = []
    func capture(_ scope: PippaMCPWriteScope) {
        let pending = scope.snapshot.pending
        ids = pending.map(\.id); revisions = pending.map(\.nativeRevision)
    }
}

/// Models the system permission boundary; no EventKit, TCC reset or system prompt is involved.
actor ReminderPermissionIntegrations: AppIntegrations {
    var state: IntegrationAccess
    let answer: IntegrationAccess
    var trace: [String] = []
    var explanations: [String] = []
    let stopAtRequest: PippaMCPWriteScope?
    init(state: IntegrationAccess = .notDetermined, answer: IntegrationAccess = .granted, stopAtRequest: PippaMCPWriteScope? = nil) {
        self.state = state; self.answer = answer; self.stopAtRequest = stopAtRequest
    }
    func explain(_ subject: PippaMCPAccessSubject, _ sentence: String) {
        trace.append("explain"); explanations.append(subject.appName + "|" + sentence)
    }
    func access(_ integration: Integration) async -> IntegrationAccess { trace.append("access"); return state }
    func requestAccess(_ integration: Integration) async -> IntegrationAccess {
        trace.append("request"); state = answer; stopAtRequest?.cancel(); return state
    }
    func remove(_ item: CreatedItem) async throws -> RemoveResult { throw PippaError.notAvailable }
    func selectedMail() async throws -> MailMessage? { throw PippaError.notAvailable }
    func insertReply(_ draft: MailDraft) async throws -> MailInsertResult { throw PippaError.notAvailable }
    func events(in interval: DateInterval, limit: Int) async throws -> CalendarFetch { throw PippaError.notAvailable }
}

struct ReminderFixture {
    let directory: URL
    let journal: Executor
    let writer: ReminderJournalWriter
    let origin: PippaMCPOrigin
    let scope: PippaMCPWriteScope
    var host: PippaMCPHost
    var tools: PippaMCPWriteTools { .init(host: host, scope: scope) }
    init(origin: PippaMCPOrigin? = nil) throws {
        directory = root.appendingPathComponent("native-reminder-" + UUID().uuidString)
        journal = try Executor(baseDirectory: directory)
        writer = ReminderJournalWriter()
        self.origin = origin ?? .init(conversationID: UUID(), requestID: UUID())
        scope = .init(turnID: UUID(), origin: self.origin)
        host = .demo()
        host.writer = writer; host.reminderJournal = journal; host.requiresReminderJournal = true
    }
    func reopened() throws -> Executor { try Executor(baseDirectory: directory, nativeRecoverySessionID: UUID()) }
}

func reminderFixtureSQL(_ directory: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(directory.appendingPathComponent("journal.sqlite").path, &database) == SQLITE_OK else { throw PippaError.notAvailable }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw PippaError.notAvailable }
}

extension NativeReminderRecord {
    /// Completed in this run with a fingerprint: Undo may remove exactly this reminder.
    var undoSafe: Bool { phase == .completed && !recovered && result?.item.fingerprint != nil }
}
