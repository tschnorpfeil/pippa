import Foundation

extension PippaMCPWriteTools {
    // MARK: reminder_add

    func reminderAdd(_ input: Input) async -> PippaMCPToolResult {
        guard let rawTitle = input.text("title") else { return Self.invalid("title is required.") }
        let title = Self.singleLine(rawTitle, max: 200)
        let cal = host.calendar, now = host.now()
        var due: DateComponents?
        var dueDate: Date?
        var dueHasTime = false
        if let rawDate = input.text("date") {
            guard let day = Self.day(rawDate, now: now, calendar: cal) else {
                return Self.invalid("date must be YYYY-MM-DD, today, tomorrow or a weekday, not in the past.")
            }
            var parts = cal.dateComponents([.year, .month, .day], from: day)
            dueDate = day
            if let rawTime = input.text("time") {
                guard let t = Self.time(rawTime) else { return Self.invalid("time must be HH:MM.") }
                parts.hour = t.hour; parts.minute = t.minute
                dueDate = cal.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day)
                dueHasTime = true
            }
            due = parts
        } else if input.text("time") != nil {
            return Self.invalid("time needs a date: also send date (today, tomorrow, a weekday or YYYY-MM-DD), the day the person said.")
        }
        let label = Self.singleLine(title, max: 80)
        let short = dueDate.map { L("%@ (due %@)", table: "MCP", label, format($0, dueHasTime ? "EEE d MMM HH:mm" : "EEE d MMM")) } ?? label
        func notDone(_ reason: String) -> PippaMCPWriteReceipt { PippaMCPWriteReceipt(action: "reminderAdd", outcome: "failed", name: short, reason: reason) }
        guard let writer = host.writer else {
            return Self.blocked("unavailable", L("Pippa can’t add to %@ right now.", table: "MCP", Integration.reminders.appName), receipt: notDone("unavailable"))
        }
        let reminder = NewReminder(title: title, due: due, list: input.text("list").map { Self.singleLine($0, max: 200) },
                                   notes: input.text("notes").map { String($0.prefix(2000)) })
        if let journal = host.reminderJournal {
            var key = input.strings.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            key["title"] = title; key["list"] = reminder.list?.lowercased(); key["notes"] = reminder.notes
            key["date"] = input.text("date")?.lowercased()
            key["time"] = input.text("time").flatMap(Self.time).map { String(format: "%02d:%02d", $0.hour, $0.minute) }
            return await durableReminder(reminder, label: short, hash: NativeReminderRecord.requestHash(key), writer: writer, journal: journal)
        }
        if host.requiresReminderJournal {
            return Self.blocked("unavailable", L("Pippa can’t add to %@ right now.", table: "MCP", Integration.reminders.appName), receipt: notDone("journalUnavailable"))
        }
        if case .blocked(let status, let tell) = await ensure(.reminders) { return Self.blocked(status, tell, receipt: notDone(status)) }
        let added: HostWrite
        do {
            try PippaMCPWriteLease.current?.check()
            added = try await writer.addReminder(NewReminder(title: title, due: due, list: input.text("list").map { Self.singleLine($0, max: 200) },
                                                             notes: input.text("notes").map { String($0.prefix(2000)) }))
        } catch {
            return failure(error, .reminders, receipt: notDone("failed"))
        }
        var data: [String: Any] = ["title": title, "list": added.container]
        if let dueDate { data["due"] = format(dueDate, dueHasTime ? "EEE d MMM y HH:mm" : "EEE d MMM y") }
        if !added.containerMatched, let wanted = input.text("list") { data["listNote"] = "There is no list named \(Self.singleLine(wanted, max: 80)); it is in \(added.container)." }
        return PippaMCPToolResult(text: PippaMCPTools.json([
            "done": true, "added": data,
            "next": "Say in one sentence that the reminder is there, with due as given.",
        ]), isError: false, receipt: PippaMCPWriteReceipt(action: "reminderAdd", outcome: "done", name: short, created: added.item))
    }

    /// Durable admission is separate from the in-memory cancellation lease. Neither can replace the other:
    /// the journal survives process loss, while the lease prevents queued work from escaping Stop.
    private func durableReminder(_ reminder: NewReminder, label: String, hash: String, writer: any HostWriting,
                                 journal: Executor) async -> PippaMCPToolResult {
        guard let lease = PippaMCPWriteLease.current else { return Self.invalid("A native action scope is required.") }
        var record: NativeReminderRecord
        do {
            try lease.check()
            var admission = try await journal.beginNativeReminder(id: lease.id, origin: lease.origin, turnID: lease.turnID,
                                                                  requestHash: hash, reminder: reminder, label: label)
            if case .blocked = admission {
                _ = try await journal.reconcileNativeReminders(using: writer, conversationID: lease.origin?.conversationID)
                try lease.check()
                admission = try await journal.beginNativeReminder(id: lease.id, origin: lease.origin, turnID: lease.turnID,
                                                                  requestHash: hash, reminder: reminder, label: label)
            }
            switch admission {
            case .completed(let prior): return reminderCompleted(prior, repeated: true)
            case .blocked(let prior): return reminderUnconfirmed(prior)
            case .execute(let active): record = active; lease.bindOperationID(active.id, nativeRevision: active.revision)
            }
        } catch {
            return failure(error, .reminders, receipt: .init(action: "reminderAdd", outcome: "failed", name: label, reason: "journalUnavailable"))
        }
        if case .blocked(let status, let tell) = await ensure(.reminders) {
            let result = Self.blocked(status, tell, receipt: .init(action: "reminderAdd", outcome: "failed", name: record.label, reason: status))
            return await finishReminderFailure(result, record: record, journal: journal, lease: lease)
        }
        do {
            try lease.check()
            let target: NativeReminderTarget
            if let pinned = record.target { target = pinned } else { target = try await writer.reminderTarget(for: record.reminder) }
            try lease.check()
            record = try await journal.prepareNativeReminder(id: record.id, target: target)
            lease.bindOperationID(record.id, nativeRevision: record.revision)
            try lease.check()
            record = try await journal.dispatchNativeReminder(id: record.id)
            lease.bindOperationID(record.id, nativeRevision: record.revision)
            // A Stop during the journal commit still prevents the actual native dispatch.
            try lease.check()
            let result = try await writer.addReminder(record.reminder, target: target, marker: record.marker)
            // Do not check cancellation here: the OS result is evidence, including after Stop or a lost Pi reply.
            record = try await journal.completeNativeReminder(id: record.id, result: result)
            return reminderCompleted(record, repeated: false)
        } catch {
            let result = failure(error, .reminders, receipt: .init(action: "reminderAdd", outcome: "failed", name: record.label, reason: "failed"))
            return await finishReminderFailure(result, record: record, journal: journal, lease: lease)
        }
    }

    private func finishReminderFailure(_ result: PippaMCPToolResult, record: NativeReminderRecord, journal: Executor,
                                       lease: PippaMCPWriteLease) async -> PippaMCPToolResult {
        var result = result
        if let final = try? await journal.finishNativeReminder(id: record.id, dispatched: lease.hasDispatched, receipt: result.receipt) {
            result.receipt = final.receipt
        } else {
            // A failed completion commit keeps the write-ahead row unresolved. Retain the stable operation identity.
            result.receipt?.operationID = record.id; result.receipt?.turnID = record.originatingTurnID
            result.receipt?.nativeRevision = record.revision
        }
        return result
    }

    private func reminderUnconfirmed(_ record: NativeReminderRecord) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json([
            "done": false, "state": "unclear", "operationID": record.id.uuidString,
            "tell": L("Pippa couldn’t confirm whether the change in %@ finished. Please check the app before trying again.", table: "MCP", Integration.reminders.appName),
            "next": "An earlier reminder operation is unresolved. This attempt made no new reminder. Do not retry or use another tool to recreate it.",
        ]), isError: false, receipt: record.receipt)
    }

    private func reminderCompleted(_ record: NativeReminderRecord, repeated: Bool) -> PippaMCPToolResult {
        guard let result = record.result else { return reminderUnconfirmed(record) }
        var added: [String: Any] = ["title": record.reminder.title, "list": result.container]
        if let due = record.reminder.due, let date = host.calendar.date(from: due) {
            added["due"] = format(date, due.hour == nil ? "EEE d MMM y" : "EEE d MMM y HH:mm")
        }
        if !result.containerMatched, let wanted = record.reminder.list {
            added["listNote"] = "There is no list named \(Self.singleLine(wanted, max: 80)); it is in \(result.container)."
        }
        return PippaMCPToolResult(text: PippaMCPTools.json([
            "done": true, "operationID": record.id.uuidString, "already_completed": repeated,
            "recovered": record.recovered, "added": added,
            "next": repeated
                ? "This same request was already recorded as created. Report that prior completion, not a new change. Do not create another reminder."
                : "Say in one sentence that the reminder was created, with due as given.",
        ]), isError: false, receipt: record.receipt)
    }
}
