import Foundation
import PippaCore

/// `calendar_update` and `reminder_update` on synthetic Calendar and Reminders (`DemoIntegrations`, never real apps),
/// with a fresh run journal: change, read back, Undo of the run, and the guards that refuse before anything is saved.
private struct UpdateFixture {
    let demo = DemoIntegrations(granted: true)
    let journal: Executor
    var host: PippaMCPHost
    let scope = PippaMCPWriteScope(turnID: UUID(), origin: .init(conversationID: UUID(), requestID: UUID()))
    var run: UUID { scope.turnID! }
    var tools: PippaMCPWriteTools { .init(host: host, scope: scope) }
    let calendar: Calendar
    let tomorrow: Date

    init() throws {
        journal = try Executor(baseDirectory: root.appendingPathComponent("update-journal-" + UUID().uuidString))
        host = .demo()
        host.writer = demo; host.integrations = demo; host.reminderJournal = journal; host.requiresReminderJournal = true
        let recipes = PippaMCPWriteTools.updateUndoRecipe(writer: demo)
        for kind in ["event.update", "reminder.update"] { host.runRecipes[kind] = recipes(kind) }
        let cal = host.calendar
        let day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        calendar = cal; tomorrow = day
        let at = { (hour: Int, minute: Int) in cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)! }
        demo.calendarEvents = [
            CalendarEvent(id: "upd-plain", title: "Haircut", start: at(10, 0), end: at(10, 45), calendar: "Privat", location: "Salon", notes: "Bring card"),
            CalendarEvent(id: "upd-meeting", title: "Planning", start: at(13, 0), end: at(14, 0), calendar: "Arbeit",
                          attendees: [.init(name: "Someone Else"), .init(name: "Me", isCurrentUser: true)]),
            CalendarEvent(id: "upd-series", title: "Weekly sync", start: at(9, 0), end: at(9, 30), calendar: "Arbeit", recurring: true),
            CalendarEvent(id: "upd-birthday", title: "Birthday", start: tomorrow, end: calendar.date(byAdding: .day, value: 1, to: tomorrow)!,
                          allDay: true, calendar: "Geburtstage"),
        ]
        demo.calendarNames = ["Arbeit", "Privat", "Geburtstage"]
        demo.readOnlyCalendars = ["Geburtstage"]
        demo.seedReminder("upd-rent", ReminderSnapshot(title: "Pay rent", due: calendar.dateComponents([.year, .month, .day], from: tomorrow),
                                                       notes: "Landlord", list: "Erinnerungen"))
        demo.seedReminder("upd-shared", ReminderSnapshot(title: "Shared list item", list: "Family"))
        demo.seedReminder("upd-weekly", ReminderSnapshot(title: "Take out bins", list: "Erinnerungen"))
        demo.readOnlyReminderLists = ["Family"]
        demo.recurringReminders = ["upd-weekly"]
    }

    func at(_ hour: Int, _ minute: Int) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow)! }
    func rows() async throws -> [RunAction] { try await journal.runActions(run: run) }
}

private func updateJSON(_ result: PippaMCPToolResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
}

func runMCPUpdateChecks() async {
    await checkAsync("calendar_update: title, time and location change, are read back and journaled with the before snapshot; run Undo restores exactly") {
        let f = try UpdateFixture()
        let original = f.demo.storedEvent("upd-plain")!
        let result = await f.tools.callUpdate("calendar_update", ["id": "upd-plain", "title": "Haircut (moved)", "time": "14:30", "location": "New salon"])
        let json = updateJSON(result)
        let changed = f.demo.storedEvent("upd-plain")!
        let rows = try await f.rows()
        guard rows.count == 1, let row = rows.first else { return false }
        let before = row.before?["snapshot"].flatMap { try? JSONDecoder().decode(CalendarEventSnapshot.self, from: Data($0.utf8)) }
        let summary = await f.host.runSummaries([f.run])[f.run]
        let report = try await f.host.undoRun(f.run)
        let restored = f.demo.storedEvent("upd-plain")!
        let after = try await f.rows()
        return !result.isError && json["done"] as? Bool == true && json["verified"] as? String == "1 of 1"
            && result.receipt?.action == "calendarUpdate" && result.receipt?.outcome == "done" && result.receipt?.created == nil
            && changed.title == "Haircut (moved)" && changed.start == f.at(14, 30) && changed.end == f.at(15, 15) && changed.location == "New salon"
            && changed.notes == "Bring card"
            && row.tool == "calendar_update" && row.actionClass == .undoable && row.object.kind == "event.update" && row.state == .done
            && row.verified == true && row.object.fields["identifier"] == "upd-plain" && row.object.fields["fingerprint"] != nil
            && before?.title == "Haircut" && before?.start == original.start && before?.location == "Salon"
            && summary?.undoable == 1
            && report.undone.count == 1 && report.left.isEmpty && report.failed.isEmpty
            && restored == original && after.first?.state == .undone
    }

    await checkAsync("calendar_update: only a new date keeps the time and length; Undo after the person edited it leaves their edit (changed)") {
        let f = try UpdateFixture()
        let dayAfter = f.calendar.date(byAdding: .day, value: 1, to: f.tomorrow)!
        let iso = f.calendar.dateComponents([.year, .month, .day], from: dayAfter)
        let date = String(format: "%04d-%02d-%02d", iso.year!, iso.month!, iso.day!)
        let result = await f.tools.callUpdate("calendar_update", ["id": "upd-plain", "date": date])
        let moved = f.demo.storedEvent("upd-plain")!
        let start = f.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: dayAfter)!
        f.demo.editEvent("upd-plain") { $0.title = "Haircut, edited by the person" }
        let report = try await f.host.undoRun(f.run)
        let kept = f.demo.storedEvent("upd-plain")!
        return !result.isError && moved.start == start && moved.end == start.addingTimeInterval(45 * 60)
            && report.undone.isEmpty && report.left.count == 1 && report.left.first?.note == "changed"
            && kept.title == "Haircut, edited by the person" && kept.start == start
    }

    await checkAsync("calendar_update: fails closed on attendees, a recurring series and a read-only calendar; nothing changed, no journal row") {
        let f = try UpdateFixture()
        let before = ["upd-meeting", "upd-series", "upd-birthday"].map { f.demo.storedEvent($0) }
        let attendees = await f.tools.callUpdate("calendar_update", ["id": "upd-meeting", "title": "Planning (moved)", "time": "15:00"])
        let series = await f.tools.callUpdate("calendar_update", ["id": "upd-series", "location": "Room 2"])
        let readOnly = await f.tools.callUpdate("calendar_update", ["id": "upd-birthday", "title": "Party"])
        let missing = await f.tools.callUpdate("calendar_update", ["id": "upd-nope", "title": "Ghost"])
        // The writer itself refuses too, even when called without the tool's look first.
        var direct: CalendarUpdateError?
        do { _ = try await f.demo.updateEvent(identifier: "upd-meeting", patch: CalendarEventPatch(title: "Sneaky")) }
        catch let error as CalendarUpdateError { direct = error }
        let after = ["upd-meeting", "upd-series", "upd-birthday"].map { f.demo.storedEvent($0) }
        let rows = try await f.rows()
        return attendees.isError && updateJSON(attendees)["status"] as? String == "has_attendees"
            && series.isError && updateJSON(series)["status"] as? String == "recurring"
            && readOnly.isError && updateJSON(readOnly)["status"] as? String == "read_only"
            && missing.isError && updateJSON(missing)["status"] as? String == "not_found"
            && [attendees, series, readOnly, missing].allSatisfy { updateJSON($0)["changed"] as? Bool == false && $0.receipt?.outcome == "failed" }
            && direct == .hasAttendees && before == after && rows.isEmpty
    }

    await checkAsync("reminder_update: marks done and changes title and due; run Undo restores isCompleted false, title and due") {
        let f = try UpdateFixture()
        let original = f.demo.storedReminder("upd-rent")!
        let result = await f.tools.callUpdate("reminder_update", ["id": "upd-rent", "completed": true, "title": "Pay rent (done)",
                                                                  "date": "today", "time": "18:00"])
        let json = updateJSON(result)
        let changed = f.demo.storedReminder("upd-rent")!
        let today = f.calendar.dateComponents([.year, .month, .day], from: Date())
        let rows = try await f.rows()
        let report = try await f.host.undoRun(f.run)
        let restored = f.demo.storedReminder("upd-rent")!
        return !result.isError && json["verified"] as? String == "1 of 1" && result.receipt?.action == "reminderUpdate" && result.receipt?.created == nil
            && changed.isCompleted && changed.title == "Pay rent (done)"
            && changed.due == DateComponents(year: today.year, month: today.month, day: today.day, hour: 18, minute: 0)
            && changed.notes == "Landlord"
            && rows.count == 1 && rows[0].tool == "reminder_update" && rows[0].object.kind == "reminder.update" && rows[0].state == .done
            && rows[0].actionClass == .undoable && rows[0].verified == true && rows[0].before?["snapshot"] != nil
            && report.undone.count == 1 && restored == original && restored.isCompleted == false
    }

    await checkAsync("reminder_update: Undo leaves a reminder the person changed since (changed) and counts a deleted one as gone") {
        let f = try UpdateFixture()
        _ = await f.tools.callUpdate("reminder_update", ["id": "upd-rent", "completed": true])
        f.demo.editReminder("upd-rent") { $0.notes = "Paid by bank transfer" }
        let report = try await f.host.undoRun(f.run)
        let kept = f.demo.storedReminder("upd-rent")!
        let g = try UpdateFixture()
        _ = await g.tools.callUpdate("reminder_update", ["id": "upd-rent", "clear_due": true])
        let cleared = g.demo.storedReminder("upd-rent")!
        g.demo.deleteReminder("upd-rent")
        let gone = try await g.host.undoRun(g.run)
        let readOnly = await g.tools.callUpdate("reminder_update", ["id": "upd-shared", "completed": true])
        let recurring = await g.tools.callUpdate("reminder_update", ["id": "upd-weekly", "completed": true])
        var directRecurring: CalendarUpdateError?
        do { _ = try await g.demo.updateReminder(identifier: "upd-weekly", patch: ReminderPatch(completed: true)) }
        catch let error as CalendarUpdateError { directRecurring = error }
        return report.left.count == 1 && report.undone.isEmpty && kept.isCompleted && kept.notes == "Paid by bank transfer"
            && cleared.due == nil && gone.undone.count == 1 && g.demo.storedReminder("upd-rent") == nil
            && readOnly.isError && updateJSON(readOnly)["status"] as? String == "read_only" && g.demo.storedReminder("upd-shared")?.isCompleted == false
            && recurring.isError && updateJSON(recurring)["status"] as? String == "recurring"
            && (updateJSON(recurring)["error"] as? String)?.contains("reminder") == true
            && (updateJSON(recurring)["error"] as? String)?.contains("Reminders") == true
            && g.demo.storedReminder("upd-weekly")?.isCompleted == false && directRecurring == .isRecurring
    }

    await checkAsync("calendar_update and reminder_update: invalid arguments fail before anything is read or written") {
        let f = try UpdateFixture()
        let calls: [(String, [String: Any])] = [
            ("calendar_update", ["title": "No id"]),
            ("calendar_update", ["id": "upd-plain"]),
            ("calendar_update", ["id": "upd-plain", "date": "2001-01-01"]),
            ("calendar_update", ["id": "upd-plain", "time": "25:00"]),
            ("calendar_update", ["id": "upd-plain", "minutes": 30, "end": "12:00"]),
            ("calendar_update", ["id": "upd-plain", "calendar": "Arbeit"]),
            ("reminder_update", ["completed": true]),
            ("reminder_update", ["id": "upd-rent"]),
            ("reminder_update", ["id": "upd-rent", "time": "09:00"]),
            ("reminder_update", ["id": "upd-rent", "date": "tomorrow", "clear_due": true]),
            ("reminder_update", ["id": "upd-rent", "completed": "yes"]),
        ]
        var statuses: [String] = []
        for (name, args) in calls { statuses.append(updateJSON(await f.tools.callUpdate(name, args))["status"] as? String ?? "-") }
        let other = await f.tools.callUpdate("calendar_add", ["title": "Not an update", "date": "tomorrow"])
        let rows = try await f.rows()
        return statuses.allSatisfy { $0 == "invalid_arguments" } && other.isError && rows.isEmpty
            && f.demo.storedEvent("upd-plain")?.title == "Haircut" && f.demo.storedReminder("upd-rent")?.title == "Pay rent"
            && f.demo.createdCount == 0
            && PippaMCPWriteTools.updateToolList().compactMap { $0["name"] as? String } == PippaMCPWriteTools.updateNames
    }
}
