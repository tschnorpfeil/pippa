import Foundation
import PippaCore
import SQLite3

/// Synthetic Reminders store. No EventKit instance, system permission request, or personal reminder is involved.
private actor ReminderJournalWriter: HostWriting {
    var writes = 0
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
        if lookupUnavailable { return .unavailable }
        let matches = (stored[marker] ?? []).filter { $0.containerIdentifier == target.identifier }
        if matches.count > 1 { return .ambiguous }
        guard let result = matches.first else { return .notFound }
        if let identifier, result.item.identifier != identifier { return .unavailable }
        return .found(result)
    }
}

private actor ReminderPendingProbe {
    var ids: [UUID] = []
    var revisions: [Int?] = []
    func capture(_ scope: PippaMCPWriteScope) {
        let pending = scope.snapshot.pending
        ids = pending.map(\.id); revisions = pending.map(\.nativeRevision)
    }
}

private struct ReminderFixture {
    let directory: URL
    let journal: Executor
    let writer: ReminderJournalWriter
    let origin: PippaMCPOrigin
    let scope: PippaMCPWriteScope
    var host: PippaMCPHost
    var tools: PippaMCPWriteTools { .init(host: host, scope: scope) }
    init() throws {
        directory = root.appendingPathComponent("native-reminder-" + UUID().uuidString)
        journal = try Executor(baseDirectory: directory)
        writer = ReminderJournalWriter()
        origin = .init(conversationID: UUID(), requestID: UUID())
        scope = .init(turnID: UUID(), origin: origin)
        host = .demo()
        host.writer = writer; host.reminderJournal = journal; host.requiresReminderJournal = true
    }
    func reopened() throws -> Executor { try Executor(baseDirectory: directory, nativeRecoverySessionID: UUID()) }
}

private func reminderFixtureSQL(_ directory: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(directory.appendingPathComponent("journal.sqlite").path, &database) == SQLITE_OK else { throw PippaError.notAvailable }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw PippaError.notAvailable }
}

func runNativeReminderChecks() async {
    await checkAsync("Reminder journal keeps native identity, target, original request and stable receipt across restart") {
        let f = try ReminderFixture()
        let result = await f.tools.call("reminder_add", ["title": "Synthetic reminder", "notes": "Made-up fixture only"])
        let records = try await f.reopened().nativeReminderRecords(conversationID: f.origin.conversationID)
        guard let record = records.first, let native = record.result else { return false }
        return records.count == 1 && record.phase == .completed && record.origin == f.origin
            && record.originatingTurnID == f.scope.turnID && record.target?.identifier == "fixture-list-a"
            && native.item.identifier == "fixture-native-1" && native.containerIdentifier == record.target?.identifier
            && record.undoSafe && result.receipt?.operationID == record.id && record.receipt == result.receipt
    }

    await checkAsync("Same reminder request replays its completion; identical text in a distinct request remains new intent") {
        let f = try ReminderFixture()
        let first = await f.tools.call("reminder_add", ["title": "Fixture"])
        let replay = PippaMCPWriteTools(host: f.host, scope: .init(turnID: UUID(), origin: f.origin))
        let second = await replay.call("reminder_add", ["title": "Fixture"])
        let afterReplay = await f.writer.writes
        let anotherOrigin = PippaMCPOrigin(conversationID: f.origin.conversationID, requestID: UUID())
        let another = PippaMCPWriteTools(host: f.host, scope: .init(turnID: UUID(), origin: anotherOrigin))
        let third = await another.call("reminder_add", ["title": "Fixture"])
        let afterNewRequest = await f.writer.writes
        return afterReplay == 1 && afterNewRequest == 2 && first.receipt?.operationID == second.receipt?.operationID
            && third.receipt?.operationID != first.receipt?.operationID && second.text.contains("already_completed")
    }

    await checkAsync("Empty optional reminder fields replay the same completed intent without a second native save") {
        let f = try ReminderFixture()
        let first = await f.tools.call("reminder_add", ["title": "Fixture"])
        let replay = PippaMCPWriteTools(host: f.host, scope: .init(turnID: UUID(), origin: f.origin))
        let second = await replay.call("reminder_add", ["title": " Fixture ", "time": " \n", "date": "", "list": " ", "notes": ""])
        let writes = await f.writer.writes
        let records = try await f.journal.nativeReminderRecords()
        return writes == 1 && records.count == 1 && first.receipt?.operationID == second.receipt?.operationID
            && second.receipt?.outcome == "done" && second.text.contains("already_completed")
    }

    await checkAsync("Native reminder revisions survive restart and serialize independent journal connections") {
        let f = try ReminderFixture()
        let reminder = NewReminder(title: "Fixture")
        guard case .execute(let planned) = try await f.journal.beginNativeReminder(id: UUID(), origin: f.origin, turnID: UUID(),
            requestHash: "revision", reminder: reminder, label: "Fixture") else { return false }
        let target = try await f.writer.reminderTarget(for: reminder)
        let prepared = try await f.journal.prepareNativeReminder(id: planned.id, target: target)
        let dispatched = try await f.journal.dispatchNativeReminder(id: planned.id)
        let native = try await f.writer.addReminder(reminder, target: target, marker: planned.marker)
        let uncertain = try await f.journal.finishNativeReminder(id: planned.id, dispatched: true, receipt: nil)
        let second = try Executor(baseDirectory: f.directory)
        async let left = f.journal.completeNativeReminder(id: planned.id, result: native)
        async let right = second.completeNativeReminder(id: planned.id, result: native, recovered: true)
        let completed = try await [left, right]
        let saved = try await f.reopened().nativeReminder(id: planned.id)
        let revisions: [Int] = [planned.revision, prepared.revision, dispatched.revision, uncertain.revision]
        let completedRevisions: [Int] = completed.map(\.revision).sorted()
        return revisions == [0, 1, 2, 3]
            && completedRevisions == [4, 5] && saved.revision == 5 && saved.phase == .completed
            && saved.receipt.nativeRevision == 5 && saved.receipt.item.nativeRevision == 5
    }

    await checkAsync("Lost native reply is reconciled by one UUID marker without creating another reminder") {
        let f = try ReminderFixture()
        let reminder = NewReminder(title: "Fixture")
        let admission = try await f.journal.beginNativeReminder(id: UUID(), origin: f.origin, turnID: f.scope.turnID,
                                                              requestHash: "fixture", reminder: reminder, label: "Fixture")
        guard case .execute(var record) = admission else { return false }
        let target = try await f.writer.reminderTarget(for: reminder)
        record = try await f.journal.prepareNativeReminder(id: record.id, target: target)
        try await f.journal.dispatchNativeReminder(id: record.id)
        _ = try await f.writer.addReminder(reminder, target: target, marker: record.marker)
        // Simulate crash after native save but before completion is persisted.
        let reopened = try f.reopened()
        let before = try await reopened.nativeReminderRecords()
        let after = try await reopened.reconcileNativeReminders(using: f.writer, conversationID: f.origin.conversationID)
        let count = await f.writer.writes
        guard let recovered = after.first else { return false }
        let repeated = try await reopened.beginNativeReminder(id: UUID(), origin: f.origin, turnID: UUID(), requestHash: "fixture",
                                                              reminder: reminder, label: "Fixture")
        guard case .completed(let same) = repeated else { return false }
        return before.first?.receipt.outcome == "unclear" && count == 1 && recovered.id == record.id
            && recovered.phase == .completed && recovered.recovered && !recovered.undoSafe
            && recovered.result?.item.identifier == "fixture-native-1" && same.id == recovered.id
    }

    await checkAsync("Missing, ambiguous and permission-blocked native evidence never permits uncertain replay") {
        for evidence in ["missing", "ambiguous", "denied"] {
            let f = try ReminderFixture()
            let reminder = NewReminder(title: "Fixture")
            let admission = try await f.journal.beginNativeReminder(id: UUID(), origin: f.origin, turnID: UUID(), requestHash: "first",
                                                                  reminder: reminder, label: "Fixture")
            guard case .execute(let record) = admission else { return false }
            let target = try await f.writer.reminderTarget(for: reminder)
            _ = try await f.journal.prepareNativeReminder(id: record.id, target: target)
            try await f.journal.dispatchNativeReminder(id: record.id)
            if evidence != "missing" {
                _ = try await f.writer.addReminder(reminder, target: target, marker: record.marker)
                if evidence == "ambiguous" { await f.writer.duplicate(record.marker) }
                else { await f.writer.setUnavailable(true) }
            }
            let reopened = try f.reopened()
            let recovered = try await reopened.reconcileNativeReminders(using: f.writer)
            guard recovered.first?.receipt.outcome == "unclear" else { return false }
            let otherRequest = PippaMCPOrigin(conversationID: f.origin.conversationID, requestID: UUID())
            let retry = try await reopened.beginNativeReminder(id: UUID(), origin: otherRequest, turnID: UUID(), requestHash: "paraphrased",
                                                               reminder: NewReminder(title: "Different wording"), label: "Different wording")
            guard case .blocked(let prior) = retry, prior.id == record.id else { return false }
            let otherConversation = PippaMCPOrigin(conversationID: UUID(), requestID: UUID())
            let independent = try await reopened.beginNativeReminder(id: UUID(), origin: otherConversation, turnID: UUID(), requestHash: "independent",
                                                                     reminder: reminder, label: "Fixture")
            guard case .execute = independent else { return false }
        }
        return true
    }

    await checkAsync("Restart before dispatch permits an explicit retry but retains its original list and operation identity") {
        let f = try ReminderFixture()
        let reminder = NewReminder(title: "Fixture")
        guard case .execute(let record) = try await f.journal.beginNativeReminder(id: UUID(), origin: f.origin, turnID: UUID(),
            requestHash: "same", reminder: reminder, label: "Fixture") else { return false }
        let originalTarget = try await f.writer.reminderTarget(for: reminder)
        _ = try await f.journal.prepareNativeReminder(id: record.id, target: originalTarget)
        await f.writer.changeDefault()
        let reopened = try f.reopened()
        let stopped = try await reopened.nativeReminderRecords()
        guard case .execute(let retry) = try await reopened.beginNativeReminder(id: UUID(), origin: f.origin, turnID: UUID(),
            requestHash: "same", reminder: reminder, label: "Fixture") else { return false }
        let writes = await f.writer.writes
        return stopped.first?.phase == .notDispatched && retry.id == record.id && retry.target == originalTarget
            && retry.target?.identifier == "fixture-list-a" && writes == 0
    }

    await checkAsync("A second Executor instance in the same process cannot treat a live permission wait as a crash") {
        let f = try ReminderFixture()
        guard case .execute(let pending) = try await f.journal.beginNativeReminder(id: UUID(), origin: f.origin, turnID: UUID(),
            requestHash: "same", reminder: NewReminder(title: "Fixture"), label: "Fixture") else { return false }
        let second = try Executor(baseDirectory: f.directory)
        let attempt = try await second.beginNativeReminder(id: UUID(), origin: f.origin, turnID: UUID(), requestHash: "same",
                                                          reminder: NewReminder(title: "Fixture"), label: "Fixture")
        guard case .blocked(let blocked) = attempt else { return false }
        return blocked.id == pending.id && blocked.phase == .planned
    }

    await checkAsync("Stop during the permission explanation persists a pre-dispatch result and creates no reminder") {
        var f = try ReminderFixture()
        let integrations = DemoIntegrations(granted: false)
        f.host.integrations = integrations
        let scope = f.scope
        f.host.explainAccess = { _, _ in scope.cancel(); return true }
        let result = await f.tools.call("reminder_add", ["title": "Fixture"])
        let records = try await f.journal.nativeReminderRecords()
        let writes = await f.writer.writes
        return writes == 0 && result.receipt?.outcome == "cancelled" && records.first?.phase == .notDispatched
            && result.receipt?.operationID == records.first?.id && scope.snapshot.receipts.count == 1
    }

    await checkAsync("Stop after native dispatch retains the completed write and its persisted identity") {
        let f = try ReminderFixture()
        let scope = f.scope
        await f.writer.setAfterDispatch { scope.cancel() }
        let result = await f.tools.call("reminder_add", ["title": "Fixture"])
        let records = try await f.reopened().nativeReminderRecords()
        let writes = await f.writer.writes
        return result.receipt?.outcome == "done" && records.first?.phase == .completed && scope.snapshot.cancelled
            && records.first?.id == result.receipt?.operationID && writes == 1
    }

    await checkAsync("Lost completion commit stays uncertain and can later reconcile the existing native item") {
        let f = try ReminderFixture()
        try reminderFixtureSQL(f.directory, """
            CREATE TRIGGER fixture_block_completion BEFORE UPDATE OF state ON native_reminder_ops
            WHEN NEW.state='completed' BEGIN SELECT RAISE(ABORT,'fixture failed commit'); END;
            """)
        let result = await f.tools.call("reminder_add", ["title": "Fixture"])
        let before = try await f.journal.nativeReminderRecords()
        guard before.first?.phase == .uncertain, result.receipt?.outcome == "unclear", result.receipt?.operationID == before.first?.id else { return false }
        try reminderFixtureSQL(f.directory, "DROP TRIGGER fixture_block_completion")
        let recovered = try await f.reopened().reconcileNativeReminders(using: f.writer)
        let writes = await f.writer.writes
        return recovered.first?.phase == .completed && recovered.first?.id == before.first?.id && writes == 1
    }

    await checkAsync("Failure to persist dispatch prevents the actual native save") {
        let f = try ReminderFixture()
        try reminderFixtureSQL(f.directory, """
            CREATE TRIGGER fixture_block_dispatch BEFORE UPDATE OF state ON native_reminder_ops
            WHEN NEW.state='dispatched' BEGIN SELECT RAISE(ABORT,'fixture failed commit'); END;
            """)
        let result = await f.tools.call("reminder_add", ["title": "Fixture"])
        let records = try await f.journal.nativeReminderRecords()
        let writes = await f.writer.writes
        return result.isError && records.first?.phase == .notDispatched && writes == 0
    }

    await checkAsync("Draft-only native scope rejects every writer before permission or dispatch with scoped receipts") {
        let f = try ReminderFixture()
        let scope = PippaMCPWriteScope(turnID: UUID(), origin: f.origin, allowsNativeWrites: false)
        let tools = PippaMCPWriteTools(host: f.host, scope: scope)
        for name in PippaMCPWriteTools.names {
            let result = await tools.call(name, ["title": "Fixture", "body": "Fixture"])
            guard result.isError, result.text.contains("not_dispatched"), result.receipt?.reason == "draftOnly",
                  result.receipt?.turnID == scope.turnID, result.receipt?.operationID != nil else { return false }
        }
        let records = try await f.journal.nativeReminderRecords()
        let writes = await f.writer.writes
        return records.isEmpty && scope.snapshot.receipts.count == 3 && writes == 0
    }

    await checkAsync("A retried pre-dispatch operation keeps one identity in pending and final receipts") {
        var f = try ReminderFixture()
        let integrations = DemoIntegrations(granted: false)
        f.host.integrations = integrations
        let firstScope = f.scope
        f.host.explainAccess = { _, _ in firstScope.cancel(); return true }
        let first = await f.tools.call("reminder_add", ["title": "Fixture"])
        let retryScope = PippaMCPWriteScope(turnID: UUID(), origin: f.origin)
        let probe = ReminderPendingProbe()
        f.host.explainAccess = { _, _ in
            await probe.capture(retryScope)
            retryScope.cancel()
            return true
        }
        let retry = await PippaMCPWriteTools(host: f.host, scope: retryScope).call("reminder_add", ["title": "Fixture"])
        let pending = await probe.ids
        let revisions = await probe.revisions
        let writes = await f.writer.writes
        return writes == 0 && pending == [first.receipt?.operationID].compactMap { $0 }
            && first.receipt?.operationID == retry.receipt?.operationID && retry.receipt?.outcome == "cancelled"
            && first.receipt?.nativeRevision == 1 && revisions == [2] && retry.receipt?.nativeRevision == 3
    }

    await checkAsync("A replay with an explicit date now in the past creates nothing and retains the prior confirmed receipt") {
        var f = try ReminderFixture()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10))!
        let secondDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 10))!
        f.host.calendar = calendar; f.host.now = { firstDay }
        let first = await f.tools.call("reminder_add", ["title": "Fixture", "date": "2026-10-21"])
        f.host.now = { secondDay }
        let replay = await PippaMCPWriteTools(host: f.host, scope: .init(turnID: UUID(), origin: f.origin))
            .call("reminder_add", ["title": "Fixture", "date": "2026-10-21"])
        let records = try await f.journal.nativeReminderRecords()
        let writes = await f.writer.writes
        return replay.isError && replay.text.contains("invalid_arguments") && writes == 1 && records.count == 1
            && records.first?.phase == .completed && records.first?.id == first.receipt?.operationID
    }

    check("Reminder intent fingerprint ignores argument order and retains relative date spelling") {
        NativeReminderRecord.requestHash(["title": "Fixture", "date": "tomorrow"])
            == NativeReminderRecord.requestHash(["date": "tomorrow", "title": "Fixture"])
    }
}
