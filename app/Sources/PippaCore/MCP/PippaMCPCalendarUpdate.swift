import Foundation

// `calendar_update` and `reminder_update`: change one existing event or reminder by its id, journaled with what it was
// before (run journal kind `event.update` / `reminder.update`), read back, and undone only while it is still exactly
// as Pippa left it. Events with attendees, recurring series and read-only calendars are refused before anything is
// saved: an update there could reach other people or other occurrences.
//
// Not yet in `names`/`toolList()` or the action class table: `updateNames`, `updateToolList()` and
// `updateUndoRecipe(writer:)` are wired into the shared lists in one step.

extension PippaMCPWriteTools {
    public static let updateNames = ["calendar_update", "reminder_update"]

    /// Short like `toolList()`: names and types only, ranges are checked in the tool.
    public static func updateToolList() -> [[String: Any]] {
        func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
            ["name": name, "title": title, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required],
             "annotations": PippaActionClass.undoable.annotations.merging(["title": title]) { a, _ in a }]
        }
        let text: [String: Any] = ["type": "string"], flag: [String: Any] = ["type": "boolean"]
        return [
            tool("calendar_update", "Termin ändern",
                 "id from calendar_read; change only what is given. date=YYYY-MM-DD/today/tomorrow/weekday; time/end=HH:MM; minutes. Not for events with attendees or repeats.",
                 ["id": text, "title": text, "date": text, "end_date": text, "time": text, "minutes": ["type": "integer"], "end": text,
                  "location": text, "notes": text],
                 required: ["id"]),
            tool("reminder_update", "Erinnerung ändern",
                 "id from reminders_read; change only what is given. completed=true marks done. date=YYYY-MM-DD/today/tomorrow/weekday; time=HH:MM needs date; clear_due removes the date.",
                 ["id": text, "title": text, "date": text, "time": text, "clear_due": flag, "notes": text, "completed": flag],
                 required: ["id"]),
        ]
    }

    /// Only the update tools, until they join `names`.
    public func callUpdate(_ name: String, _ raw: [String: Any]) async -> PippaMCPToolResult {
        guard Self.updateNames.contains(name) else { return Self.invalid("Unknown tool \(name).") }
        return await call(name, raw)
    }

    /// Undo for `event.update` and `reminder.update` rows: put the journaled `before` back, only while the object still
    /// has the fingerprint Pippa read back after her change.
    public static func updateUndoRecipe(writer: any HostWriting) -> (String) -> RunUndoRecipe? {
        { kind in
            switch kind {
            case "event.update":
                return { row in
                    guard let id = row.object.fields["identifier"], let snapshot = row.before?["snapshot"].flatMap(decodeSnapshot(CalendarEventSnapshot.self))
                    else { return .failed }
                    return await writer.restoreEvent(identifier: id, expectedFingerprint: row.object.fields["fingerprint"], snapshot: snapshot)
                }
            case "reminder.update":
                return { row in
                    guard let id = row.object.fields["identifier"], let snapshot = row.before?["snapshot"].flatMap(decodeSnapshot(ReminderSnapshot.self))
                    else { return .failed }
                    return await writer.restoreReminder(identifier: id, expectedFingerprint: row.object.fields["fingerprint"], snapshot: snapshot)
                }
            default: return nil
            }
        }
    }

    static func encodeSnapshot<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func decodeSnapshot<T: Decodable>(_ type: T.Type) -> (String) -> T? {
        { text in try? JSONDecoder().decode(type, from: Data(text.utf8)) }
    }

    /// Not done because of what the object is (attendees, a series, read-only, gone, changed meanwhile): nothing was
    /// changed, and the model must not work around it with another tool.
    func updateRefused(_ error: CalendarUpdateError, _ integration: Integration, receipt: PippaMCPWriteReceipt) -> PippaMCPToolResult {
        let what = integration == .calendar ? "event" : "reminder"
        let why: String = switch error {
        case .notFound: "There is no \(what) with this id. Read it again (\(integration == .calendar ? "calendar_read" : "reminders_read")) and use its id; never guess one."
        case .hasAttendees: "This event has attendees: changing it could send an update to other people, so Pippa does not change it. The person can change it in Calendar."
        case .isRecurring: "This event belongs to a repeating series, so Pippa does not change it. The person can change it in Calendar."
        case .readOnly(let name): "The \(integration == .calendar ? "calendar" : "list") \(Self.singleLine(name, max: 80)) is read-only."
        case .changed: "The \(what) changed while Pippa was about to update it. Read it again before trying once more."
        }
        var receipt = receipt
        receipt.reason = error.receiptReason
        return PippaMCPToolResult(text: PippaMCPTools.json([
            "done": false, "status": error.status, "changed": false, "error": why,
            "next": "Nothing was changed. Say so in one sentence with the reason. Do not delete and recreate it or use another tool to work around this.",
        ]), isError: true, receipt: receipt)
    }

    // MARK: calendar_update

    func calendarUpdate(_ input: Input) async -> PippaMCPToolResult {
        guard let id = input.text("id") else { return Self.invalid("id is required: the event's id from calendar_read.") }
        let fields = ["title", "date", "end_date", "time", "end", "location", "notes"]
        guard fields.contains(where: { input.text($0) != nil }) || input.minutes != nil else {
            return Self.invalid("Give at least one change: title, date, end_date, time, minutes, end, location or notes.")
        }
        let cal = host.calendar, now = host.now()
        // Dates and times are checked before anything is read, so a bad argument never reaches the calendar.
        var day: Date?, endDay: Date?
        if let raw = input.text("date") {
            guard let d = Self.day(raw, now: now, calendar: cal) else { return Self.invalid("date must be YYYY-MM-DD, today, tomorrow or a weekday, not in the past.") }
            day = d
        }
        if let raw = input.text("end_date") {
            guard let d = Self.day(raw, now: now, calendar: cal) else { return Self.invalid("end_date must be YYYY-MM-DD (or a relative day), not in the past.") }
            endDay = d
        }
        var time: (hour: Int, minute: Int)?, endTime: (hour: Int, minute: Int)?
        if let raw = input.text("time") {
            guard let t = Self.time(raw) else { return Self.invalid("time must be a valid local HH:MM.") }
            time = t
        }
        if let raw = input.text("end") {
            guard let t = Self.time(raw) else { return Self.invalid("end must be a valid local HH:MM.") }
            endTime = t
        }
        if input.minutes != nil && endTime != nil { return Self.invalid("Use minutes or end, not both.") }
        if let minutes = input.minutes, !(5...1440).contains(minutes) { return Self.invalid("minutes must be 5 to 1440.") }

        func notDone(_ name: String, _ reason: String) -> PippaMCPWriteReceipt {
            PippaMCPWriteReceipt(action: "calendarUpdate", outcome: "failed", name: name, reason: reason)
        }
        guard let writer = host.writer else {
            return Self.blocked("unavailable", L("Pippa can’t add to %@ right now.", table: "MCP", Integration.calendar.appName), receipt: notDone("", "unavailable"))
        }
        if case .blocked(let status, let tell) = await ensure(.calendar) { return Self.blocked(status, tell, receipt: notDone("", status)) }

        let current: EventLookup
        do {
            try PippaMCPWriteLease.current?.check()
            current = try await writer.eventSnapshot(identifier: id)
        } catch let error as CalendarUpdateError {
            return updateRefused(error, .calendar, receipt: notDone("", "refused"))
        } catch {
            return failure(error, .calendar, receipt: notDone("", "failed"))
        }
        let before = current.snapshot
        let label = Self.singleLine(before.title, max: 80)

        // The new times, from what was given and what the event has (Pippa computes; the model never does).
        var start: Date?, end: Date?, allDay: Bool?
        if day != nil || endDay != nil || time != nil || endTime != nil || input.minutes != nil {
            let startDay = day ?? cal.startOfDay(for: before.start)
            let startTime = time ?? (before.allDay ? nil : (cal.component(.hour, from: before.start), cal.component(.minute, from: before.start)))
            if let startTime {
                guard let begin = Self.exactTime(startTime, on: startDay, calendar: cal) else { return Self.invalid("time must be a valid local HH:MM.") }
                let finish: Date
                if let endTime {
                    let last = endDay ?? startDay
                    guard let f = Self.exactTime(endTime, on: last, calendar: cal), f > begin else { return Self.invalid("end must be a valid local HH:MM after time.") }
                    guard f.timeIntervalSince(begin) <= 31 * 86_400 else { return Self.invalid("An event can span at most 31 days.") }
                    finish = f
                } else if let minutes = input.minutes {
                    finish = begin.addingTimeInterval(TimeInterval(minutes * 60))
                } else if endDay != nil {
                    return Self.invalid("With end_date and a time, give end (HH:MM), not minutes.")
                } else {
                    // Same length as before; an all-day event that gets a time becomes one hour.
                    finish = begin.addingTimeInterval(before.allDay ? 3600 : max(300, before.end.timeIntervalSince(before.start)))
                }
                start = begin; end = finish; allDay = false
            } else {
                guard input.minutes == nil, endTime == nil else { return Self.invalid("minutes and end need a time.") }
                // All-day stays all-day: same number of days unless end_date says otherwise (end_date is inclusive).
                let oldSpan = Self.dayOffset(from: before.start, to: max(before.start, before.end.addingTimeInterval(-1)), calendar: cal) ?? 0
                let last = endDay ?? cal.date(byAdding: .day, value: oldSpan, to: startDay) ?? startDay
                guard let span = Self.dayOffset(from: startDay, to: last, calendar: cal), span >= 0 else {
                    return Self.invalid("end_date must be on or after the event's first day.")
                }
                guard span + 1 <= 31 else { return Self.invalid("An event can span at most 31 days.") }
                start = startDay; end = Self.dayAfter(last, calendar: cal); allDay = true
            }
        }
        let patch = CalendarEventPatch(title: input.text("title").map { Self.singleLine($0, max: 200) }, start: start, end: end, allDay: allDay,
                                       location: input.text("location").map { Self.singleLine($0, max: 200) },
                                       notes: input.text("notes").map { String($0.prefix(2000)) }, expectedFingerprint: current.fingerprint)
        let (wanted, changes) = patch.applied(to: before)
        let short = "\(when(wanted.start, wanted.end, allDay: wanted.allDay, short: true)) – \(Self.singleLine(wanted.title, max: 80))"
        guard !changes.isEmpty else {
            return PippaMCPToolResult(text: PippaMCPTools.json([
                "done": true, "changed": [String](), "updated": ["title": before.title, "when": when(before.start, before.end, allDay: before.allDay, short: false)],
                "next": "The event already is like that; nothing was changed. Say so in one sentence.",
            ]), isError: false)
        }
        guard let snapshotJSON = Self.encodeSnapshot(before) else { return failure(PippaError.notAvailable, .calendar, receipt: notDone(label, "failed")) }

        let lease = PippaMCPWriteLease.current
        let row: PippaMCPRunRow?
        do {
            try lease?.check()
            row = try await PippaMCPRunRow.dispatch(host, run: lease?.turnID, tool: "calendar_update", actionClass: .undoable,
                                                    object: RunObject(kind: "event.update", fields: ["identifier": current.identifier]),
                                                    label: short, before: ["snapshot": snapshotJSON], after: ["changed": changes.joined(separator: ",")])
        } catch {
            if error is CancellationError { return Self.stopped(receipt: notDone(label, "stopped")) }
            return Self.blocked("unavailable", L("Pippa can’t add to %@ right now.", table: "MCP", Integration.calendar.appName), receipt: notDone(label, "journalUnavailable"))
        }
        let updated: EventUpdateResult
        do {
            try lease?.check()
            updated = try await writer.updateEvent(identifier: current.identifier, patch: patch)
        } catch let error as CalendarUpdateError {
            await row?.abandon(dispatched: lease?.hasDispatched == true)
            return updateRefused(error, .calendar, receipt: notDone(label, "refused"))
        } catch {
            await row?.abandon(dispatched: lease?.hasDispatched == true)
            return failure(error, .calendar, receipt: notDone(label, "failed"))
        }
        // Read back by identifier: exactly what was asked, with the fingerprint Undo will compare against.
        var matched = true
        if let row {
            let back = try? await writer.eventSnapshot(identifier: updated.identifier)
            matched = back?.snapshot == wanted && back?.fingerprint == updated.fingerprint
            var fields = ["identifier": updated.identifier]
            fields["fingerprint"] = updated.fingerprint
            fields["modified"] = updated.modified.map { String($0.timeIntervalSinceReferenceDate) }
            await row.complete(verified: matched, object: RunObject(kind: "event.update", fields: fields),
                               after: ["changed": updated.changed.joined(separator: ","), "calendar": updated.container])
        }
        var data: [String: Any] = ["title": updated.after.title, "when": when(updated.after.start, updated.after.end, allDay: updated.after.allDay, short: false),
                                   "calendar": updated.container, "changed": updated.changed]
        if let location = updated.after.location { data["location"] = location }
        if updated.changed.contains("time") { data["was"] = when(before.start, before.end, allDay: before.allDay, short: false) }
        // No `created`: the receipt row must never offer to delete an event Pippa only changed. Undo goes through the run.
        let result = PippaMCPToolResult(text: PippaMCPTools.json([
            "done": true, "updated": data,
            "next": "Say in one sentence what changed, with day and time as in when.",
        ]), isError: false, receipt: PippaMCPWriteReceipt(action: "calendarUpdate", outcome: "done", name: short))
        return row == nil ? result : Self.verified(result, matched: matched, integration: .calendar)
    }
}
