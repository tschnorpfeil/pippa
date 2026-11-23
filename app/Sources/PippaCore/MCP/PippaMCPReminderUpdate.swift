import Foundation

extension PippaMCPWriteTools {
    // MARK: reminder_update

    func reminderUpdate(_ input: Input) async -> PippaMCPToolResult {
        guard let id = input.text("id") else { return Self.invalid("id is required: the reminder's id from reminders_read.") }
        guard ["title", "date", "time", "notes"].contains(where: { input.text($0) != nil }) || input.completed != nil || input.clearDue == true else {
            return Self.invalid("Give at least one change: title, date, time, clear_due, notes or completed.")
        }
        let cal = host.calendar, now = host.now()
        var due: DateComponents?
        if let rawDate = input.text("date") {
            guard input.clearDue != true else { return Self.invalid("Use date or clear_due, not both.") }
            guard let day = Self.day(rawDate, now: now, calendar: cal) else {
                return Self.invalid("date must be YYYY-MM-DD, today, tomorrow or a weekday, not in the past.")
            }
            var parts = cal.dateComponents([.year, .month, .day], from: day)
            if let rawTime = input.text("time") {
                guard let t = Self.time(rawTime) else { return Self.invalid("time must be HH:MM.") }
                parts.hour = t.hour; parts.minute = t.minute
            }
            due = parts
        } else if input.text("time") != nil {
            return Self.invalid("time needs a date: also send date (today, tomorrow, a weekday or YYYY-MM-DD), the day the person said.")
        }

        func notDone(_ name: String, _ reason: String) -> PippaMCPWriteReceipt {
            PippaMCPWriteReceipt(action: "reminderUpdate", outcome: "failed", name: name, reason: reason)
        }
        guard let writer = host.writer else {
            return Self.blocked("unavailable", L("Pippa can’t add to %@ right now.", table: "MCP", Integration.reminders.appName), receipt: notDone("", "unavailable"))
        }
        if case .blocked(let status, let tell) = await ensure(.reminders) { return Self.blocked(status, tell, receipt: notDone("", status)) }

        let current: ReminderLookup
        do {
            try PippaMCPWriteLease.current?.check()
            current = try await writer.reminderSnapshot(identifier: id)
        } catch let error as CalendarUpdateError {
            return updateRefused(error, .reminders, receipt: notDone("", "refused"))
        } catch {
            return failure(error, .reminders, receipt: notDone("", "failed"))
        }
        let before = current.snapshot
        let patch = ReminderPatch(title: input.text("title").map { Self.singleLine($0, max: 200) }, due: due, clearDue: input.clearDue == true,
                                  notes: input.text("notes").map { String($0.prefix(2000)) }, completed: input.completed,
                                  expectedFingerprint: current.fingerprint)
        let (wanted, changes) = patch.applied(to: before)
        let label = Self.singleLine(wanted.title, max: 80)
        let dueText: (DateComponents?) -> String? = { [self] parts in
            guard let parts, let date = cal.date(from: parts) else { return nil }
            return format(date, parts.hour == nil ? "EEE d MMM y" : "EEE d MMM y HH:mm")
        }
        let short = wanted.due.flatMap { parts in cal.date(from: parts).map { date in
            L("%@ (due %@)", table: "MCP", label, format(date, parts.hour == nil ? "EEE d MMM" : "EEE d MMM HH:mm"))
        } } ?? label
        guard !changes.isEmpty else {
            return PippaMCPToolResult(text: PippaMCPTools.json([
                "done": true, "changed": [String](), "updated": ["title": before.title, "completed": before.isCompleted],
                "next": "The reminder already is like that; nothing was changed. Say so in one sentence.",
            ]), isError: false)
        }
        guard let snapshotJSON = Self.encodeSnapshot(before) else { return failure(PippaError.notAvailable, .reminders, receipt: notDone(label, "failed")) }

        let lease = PippaMCPWriteLease.current
        let row: PippaMCPRunRow?
        do {
            try lease?.check()
            row = try await PippaMCPRunRow.dispatch(host, run: lease?.turnID, tool: "reminder_update", actionClass: .undoable,
                                                    object: RunObject(kind: "reminder.update", fields: ["identifier": current.identifier]),
                                                    label: short, before: ["snapshot": snapshotJSON], after: ["changed": changes.joined(separator: ",")])
        } catch {
            if error is CancellationError { return Self.stopped(receipt: notDone(label, "stopped")) }
            return Self.blocked("unavailable", L("Pippa can’t add to %@ right now.", table: "MCP", Integration.reminders.appName), receipt: notDone(label, "journalUnavailable"))
        }
        let updated: ReminderUpdateResult
        do {
            try lease?.check()
            updated = try await writer.updateReminder(identifier: current.identifier, patch: patch)
        } catch let error as CalendarUpdateError {
            await row?.abandon(dispatched: lease?.hasDispatched == true)
            return updateRefused(error, .reminders, receipt: notDone(label, "refused"))
        } catch {
            await row?.abandon(dispatched: lease?.hasDispatched == true)
            return failure(error, .reminders, receipt: notDone(label, "failed"))
        }
        var matched = true
        if let row {
            // Alarms are the writer's business (a due change moves Pippa's alert); everything else must be as asked.
            let back = try? await writer.reminderSnapshot(identifier: updated.identifier)
            var expected = wanted
            expected.alarms = back?.snapshot.alarms ?? []
            matched = back?.snapshot == expected && back?.fingerprint == updated.fingerprint
            var fields = ["identifier": updated.identifier]
            fields["fingerprint"] = updated.fingerprint
            fields["modified"] = updated.modified.map { String($0.timeIntervalSinceReferenceDate) }
            await row.complete(verified: matched, object: RunObject(kind: "reminder.update", fields: fields),
                               after: ["changed": updated.changed.joined(separator: ","), "list": updated.container])
        }
        var data: [String: Any] = ["title": updated.after.title, "list": updated.container, "completed": updated.after.isCompleted,
                                   "changed": updated.changed]
        if let text = dueText(updated.after.due) { data["due"] = text }
        let result = PippaMCPToolResult(text: PippaMCPTools.json([
            "done": true, "updated": data,
            "next": updated.changed == ["completed"]
                ? (updated.after.isCompleted ? "Say in one sentence that the reminder is marked done." : "Say in one sentence that the reminder is open again.")
                : "Say in one sentence what changed, with due as given.",
        ]), isError: false, receipt: PippaMCPWriteReceipt(action: "reminderUpdate", outcome: "done", name: short))
        return row == nil ? result : Self.verified(result, matched: matched, integration: .reminders)
    }
}
