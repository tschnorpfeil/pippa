import Foundation
import PippaCore
import SQLite3

private func routineFixtureDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-routine-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

private func berlin(_ localeID: String = "de_DE") -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
    cal.locale = Locale(identifier: localeID)
    return cal
}

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func userVersion(_ url: URL) -> Int32? {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return sqlite3_column_int(stmt, 0)
}

private func setUserVersion(_ url: URL, _ version: Int) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { return false }
    defer { sqlite3_close(db) }
    return sqlite3_exec(db, "PRAGMA user_version=\(version)", nil, nil, nil) == SQLITE_OK
}

private func event(_ id: String, _ title: String, _ start: Date, minutes: Int = 60, allDay: Bool = false,
                   status: CalendarEvent.Status = .confirmed, declined: Bool = false, location: String? = nil) -> CalendarEvent {
    CalendarEvent(id: id, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), allDay: allDay,
                  calendar: "Privat", status: status, declined: declined, location: location)
}

private func mcpCall(_ tools: PippaMCPTools, _ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
    let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
    guard let data = try? JSONSerialization.data(withJSONObject: body), let reply = await tools.handle(data) else { return nil }
    return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
}

private func toolPayload(_ reply: [String: Any]?) -> (isError: Bool, payload: [String: Any]) {
    let result = reply?["result"] as? [String: Any] ?? [:]
    let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    return (result["isError"] as? Bool ?? false, payload)
}

/// Offline checks for routines (package 1): schedule math, store, parser, builders, gate, settings and read-only isolation.
public func runRoutineChecks() async {
    let cal = berlin()

    // MARK: Settings and gate

    check("Routines: unknown muted kinds never break settings.json and new kinds round-trip") {
        let json = #"{"enabled": true, "dailyCap": 2, "mutedKinds": ["watched_file", "from_the_future", "calendar_change", 7]}"#
        let decoded = try JSONDecoder().decode(ProactivitySettings.self, from: Data(json.utf8))
        let strings = #"{"enabled": true, "mutedKinds": ["watched_file", "from_the_future", "routine", "reminder_due"]}"#
        let decodedStrings = try JSONDecoder().decode(ProactivitySettings.self, from: Data(strings.utf8))
        let roundTrip = try JSONDecoder().decode(ProactivitySettings.self,
                                                 from: JSONEncoder().encode(ProactivitySettings(enabled: true, mutedKinds: [.routine, .calendarChange])))
        // A malformed list (mixed types) is ignored, never fatal; a list of strings keeps every known kind.
        return decoded.enabled && decoded.dailyCap == 2
            && decodedStrings.mutedKinds == [.watchedFile, .routine, .reminderDue]
            && roundTrip.mutedKinds == [.routine, .calendarChange]
            && ProactiveMatterKind(rawValue: "calendar_change") == .calendarChange
            && ProactivitySettings(dailyCap: 9).dailyCap == 2 && ProactivitySettings(quietStartHour: 40).quietStartHour == 23
    }

    check("Routines: gate drops disabled routines and Desk-only matters before any budget or hold") {
        let settings = ProactivitySettings(enabled: true, quietHoursEnabled: false, dailyCap: 1)
        let matter = ProactiveMatter(kind: .routine, matterKey: "routine:x", sourceRef: "r", sourceVersion: "v", title: "T",
                                     summary: "", preparedPrompt: "p")
        let noon = at(2026, 11, 26, 12, 0, cal)
        let free = FocusStatus()
        let legacy = ProactivityGate.evaluate(matter: matter, settings: settings, deliveredToday: 0, focusStatus: free, now: noon, calendar: cal)
        let off = ProactivityGate.evaluate(matter: matter, settings: settings, deliveredToday: 0, focusStatus: free, now: noon, calendar: cal,
                                           routineEnabled: false)
        let desk = ProactivityGate.evaluate(matter: matter, settings: settings, deliveredToday: 0, focusStatus: free, now: noon, calendar: cal,
                                            deliveryMode: .deskOnly)
        // Even with the budget used up and Focus on, Desk-only is a drop, not a hold that would wait for budget.
        let deskCapped = ProactivityGate.evaluate(matter: matter, settings: settings, deliveredToday: 1,
                                                  focusStatus: FocusStatus(isFocusActive: true), now: noon, calendar: cal, deliveryMode: .deskOnly)
        let capped = ProactivityGate.evaluate(matter: matter, settings: settings, deliveredToday: 1, focusStatus: free, now: noon, calendar: cal)
        let viaReader = ProactivityGate.evaluate(matter: matter, settings: settings, deliveredToday: 0, focusReader: StubFocusStatusReader(),
                                                 now: noon, calendar: cal, deliveryMode: .deskOnly)
        return legacy == .deliver && off == .drop(reason: .disabled) && desk == .drop(reason: .deskOnly)
            && deskCapped == .drop(reason: .deskOnly) && capped == .hold(reason: .dailyCapReached) && viaReader == .drop(reason: .deskOnly)
    }

    await checkAsync("Routines: Desk-only matters spend none of the daily budget in the store") {
        let base = try routineFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try ProactiveMatterStore(baseDirectory: base)
        let settings = ProactivitySettings(enabled: true, quietHoursEnabled: false, dailyCap: 1)
        let noon = at(2026, 11, 26, 12, 0, cal)
        let dayKey = ProactiveMatterStore.dayKey(for: noon, calendar: cal)
        let draft = ProactiveMatterDraft(kind: .reminderDue, matterKey: "reminder-due:\(dayKey)", sourceRef: "r", sourceVersion: "v1",
                                         title: "1 reminder is due", summary: "• Pay rent", preparedPrompt: "p")
        guard let matter = try await store.upsertPrepared(draft, now: noon).matter else { return false }
        let used = try await store.deliveredCount(forDayKey: dayKey)
        let decision = ProactivityGate.evaluate(matter: matter, settings: settings, deliveredToday: used, focusStatus: FocusStatus(),
                                                now: noon, calendar: cal, deliveryMode: .deskOnly)
        if case .deliver = decision {
            _ = try await store.recordDelivery(matterID: matter.id, kind: matter.kind, dayKey: dayKey, cap: settings.dailyCap, shownAt: noon)
        }
        let after = try await store.deliveredCount(forDayKey: dayKey)
        return decision == .drop(reason: .deskOnly) && used == 0 && after == 0
    }

    check("Routines: durable job kind for routine runs is encoded and older kinds keep their raw values") {
        DurableJobKind(rawValue: "routineRun") == .routineRun && DurableJobKind.morningBriefing.rawValue == "morningBriefing"
            && DurableJobKind.filePreparation.rawValue == "filePreparation"
    }

    // MARK: Model

    check("Routines: schedules and triggers normalize into their ranges") {
        var mutated = ProactiveRoutine(title: "x", instruction: "", template: .customCheck, trigger: .schedule(.interval(minutes: 2)))
        mutated.trigger = .upcomingMeeting(leadMinutes: 2)
        return ProactiveSchedule.weekly(weekdays: [6, 2, 2, 9, 0], hour: 30, minute: -5).normalized == .weekly(weekdays: [2, 6], hour: 23, minute: 0)
            && ProactiveSchedule.weekly(weekdays: [], hour: 9, minute: 0).normalized == .weekly(weekdays: [2], hour: 9, minute: 0)
            && ProactiveSchedule.monthly(day: 40, hour: 9, minute: 0).normalized == .monthly(day: 31, hour: 9, minute: 0)
            && ProactiveSchedule.monthly(day: 0, hour: 9, minute: 0).normalized == .monthly(day: 1, hour: 9, minute: 0)
            && ProactiveSchedule.interval(minutes: 1).normalized == .interval(minutes: 15)
            && ProactiveSchedule.interval(minutes: 99_999).normalized == .interval(minutes: 1440)
            && ProactiveTrigger.calendarChange(lookaheadHours: 0).normalized == .calendarChange(lookaheadHours: 1)
            && ProactiveTrigger.calendarChange(lookaheadHours: 999).normalized == .calendarChange(lookaheadHours: 168)
            && ProactiveTrigger.upcomingMeeting(leadMinutes: 1).normalized == .upcomingMeeting(leadMinutes: 5)
            && ProactiveTrigger.upcomingMeeting(leadMinutes: 999).normalized == .upcomingMeeting(leadMinutes: 120)
            && ProactiveRoutine(title: "x", instruction: "", template: .customCheck, trigger: .schedule(.interval(minutes: 2))).trigger
                == .schedule(.interval(minutes: 15))
            && mutated.trigger == .upcomingMeeting(leadMinutes: 5)
    }

    check("Routines: trigger summaries read as everyday English and German") {
        func s(_ t: ProactiveTrigger, _ l: String) -> String { t.humanSummary(language: l, calendar: cal) }
        let pairs: [(ProactiveTrigger, String, String)] = [
            (.schedule(.daily(hour: 8, minute: 0)), "Every day at 08:00", "Täglich um 08:00"),
            (.schedule(.weekdays(hour: 8, minute: 0)), "Weekdays at 08:00", "Werktags um 08:00"),
            (.schedule(.weekly(weekdays: [6, 2], hour: 9, minute: 0)), "Mon, Fri at 09:00", "Mo, Fr um 09:00"),
            (.schedule(.weekly(weekdays: [1, 2], hour: 9, minute: 30)), "Mon, Sun at 09:30", "Mo, So um 09:30"),
            (.schedule(.monthly(day: 1, hour: 9, minute: 0)), "Monthly on day 1 at 09:00", "Am 1. jeden Monats um 09:00"),
            (.schedule(.interval(minutes: 120)), "Every 2 hours", "Alle 2 Stunden"),
            (.schedule(.interval(minutes: 60)), "Every hour", "Stündlich"),
            (.schedule(.interval(minutes: 30)), "Every 30 minutes", "Alle 30 Minuten"),
            (.schedule(.once(at: at(2026, 11, 27, 14, 0, cal))), "Once on 27 Nov 2026 at 14:00", "Einmalig am 27.11.2026 um 14:00"),
            (.folder(path: "/Users/me/Downloads", bookmark: nil), "New files in Downloads", "Neue Dateien in Downloads"),
            (.folder(path: "", bookmark: nil), "New files in a folder", "Neue Dateien in einem Ordner"),
            (.calendarChange(lookaheadHours: 48), "When appointments change", "Wenn sich Termine ändern"),
            (.upcomingMeeting(leadMinutes: 30), "30 min before appointments", "30 Min vor Terminen"),
            (.reminderDue, "When reminders come due", "Wenn Erinnerungen fällig werden"),
        ]
        let wrong = pairs.filter { s($0.0, "en") != $0.1 || s($0.0, "de-DE") != $0.2 }
        for w in wrong { print("  summary: \(s(w.0, "en")) | \(s(w.0, "de"))") }
        return wrong.isEmpty
    }

    check("Routines: starter packs have stable built-in keys and IDs, the right kinds and only the brief on") {
        let en = ProactiveRoutine.starterPacks(language: "en")
        let de = ProactiveRoutine.starterPacks(language: "de")
        let keys = en.compactMap(\.builtInKey)
        let folder = ProactiveRoutine.watchedFolder(path: "", language: "de")
        return keys == ["builtin.morning_brief", "builtin.evening_preview", "builtin.weekly_review",
                        "builtin.calendar_radar", "builtin.meeting_prep", "builtin.reminder_radar"]
            && en.map(\.id) == de.map(\.id) && Set(en.map(\.id)).count == 6
            && en.map(\.matterKind) == [.morningBrief, .routine, .routine, .calendarChange, .routine, .reminderDue]
            && en.filter(\.enabled).map(\.builtInKey) == ["builtin.morning_brief"]
            && en.allSatisfy { $0.executionMode == .deterministic } && de[0].title == "Morgenbrief" && en[0].title == "Morning Brief"
            && folder.builtInKey == "builtin.watched_folder" && folder.matterKind == .watchedFile && folder.title == "Ordner beobachten"
            && ProactiveRoutine(title: "f", instruction: "", template: .followUp, trigger: .reminderDue).matterKind == .followUp
    }

    // MARK: Schedule math

    check("Routines: slot keys are local YYYY-MM-DD-HHmm") {
        ProactiveScheduleCalculator.slotKey(for: at(2026, 3, 9, 8, 5, cal), calendar: cal) == "2026-03-09-0805"
    }

    check("Routines: daily, weekdays, weekly and once fire at the next local time") {
        let friday = at(2026, 11, 27, 9, 0, cal)   // Friday
        let daily = ProactiveScheduleCalculator.nextFireDate(for: .daily(hour: 8, minute: 0), after: friday, calendar: cal)
        let weekdays = ProactiveScheduleCalculator.nextFireDate(for: .weekdays(hour: 8, minute: 0), after: friday, calendar: cal)
        let weekly = ProactiveScheduleCalculator.nextFireDate(for: .weekly(weekdays: [4, 1], hour: 10, minute: 0), after: friday, calendar: cal)
        let onceFuture = ProactiveScheduleCalculator.nextFireDate(for: .once(at: friday.addingTimeInterval(60)), after: friday, calendar: cal)
        let oncePast = ProactiveScheduleCalculator.nextFireDate(for: .once(at: friday), after: friday, calendar: cal)
        let interval = ProactiveScheduleCalculator.nextFireDate(for: .interval(minutes: 5), after: friday, calendar: cal)
        return daily == at(2026, 11, 28, 8, 0, cal) && weekdays == at(2026, 11, 30, 8, 0, cal)
            && weekly == at(2026, 11, 29, 10, 0, cal) && onceFuture == friday.addingTimeInterval(60) && oncePast == nil
            && interval == friday.addingTimeInterval(15 * 60)
    }

    check("Routines: DST spring forward 2026-03-29 02:30 Berlin fires once at the next existing time that day") {
        let before = at(2026, 3, 28, 12, 0, cal)
        guard let fire = ProactiveScheduleCalculator.nextFireDate(for: .daily(hour: 2, minute: 30), after: before, calendar: cal) else { return false }
        let c = cal.dateComponents([.year, .month, .day, .hour], from: fire)
        let next = ProactiveScheduleCalculator.nextFireDate(for: .daily(hour: 2, minute: 30), after: fire, calendar: cal)
        return c.year == 2026 && c.month == 3 && c.day == 29 && c.hour == 3 && next == at(2026, 3, 30, 2, 30, cal)
    }

    check("Routines: DST fall back 2026-10-25 02:30 Berlin fires only the first 02:30, never the repeated hour") {
        let before = at(2026, 10, 24, 12, 0, cal)
        guard let fire = ProactiveScheduleCalculator.nextFireDate(for: .daily(hour: 2, minute: 30), after: before, calendar: cal) else { return false }
        // The first 02:30 is still summer time: 00:30 UTC.
        let firstUTC = Date(timeIntervalSince1970: 1_792_888_200)   // 2026-10-25T00:30:00Z
        let oneMinLater = firstUTC.addingTimeInterval(60)         // 02:31 CEST (before the repeated 02:30 CET!)
        let nextAfterFire = ProactiveScheduleCalculator.nextFireDate(for: .daily(hour: 2, minute: 30), after: fire, calendar: cal)
        let nextAfterMinute = ProactiveScheduleCalculator.nextFireDate(for: .daily(hour: 2, minute: 30), after: oneMinLater, calendar: cal)
        let dueAfterRepeat = ProactiveScheduleCalculator.evaluateDue(
            schedule: .daily(hour: 2, minute: 30), lastSlotKey: ProactiveScheduleCalculator.slotKey(for: fire, calendar: cal), lastRunAt: fire,
            createdAt: before, now: fire.addingTimeInterval(3600 + 60), calendar: cal)
        // Intervals during the fall-back hour use UTC slot keys so the second 02:30 (01:30 UTC) still fires.
        let intervalFirst = ProactiveScheduleCalculator.evaluateDue(
            schedule: .interval(minutes: 60), lastSlotKey: nil, lastRunAt: firstUTC.addingTimeInterval(-3600),
            createdAt: before, now: firstUTC, calendar: cal)
        let intervalSecond = ProactiveScheduleCalculator.evaluateDue(
            schedule: .interval(minutes: 60), lastSlotKey: intervalFirst?.slotKey, lastRunAt: firstUTC,
            createdAt: before, now: firstUTC.addingTimeInterval(3600), calendar: cal)
        return fire == firstUTC && nextAfterFire == at(2026, 10, 26, 2, 30, cal) && nextAfterMinute == at(2026, 10, 26, 2, 30, cal)
            && dueAfterRepeat == nil && intervalFirst?.slotKey == "u-2026-10-25-0030"
            && intervalSecond?.slotKey == "u-2026-10-25-0130" && intervalSecond?.slotKey != intervalFirst?.slotKey
    }

    check("Routines: monthly day 31 clamps to 28 Feb 2026, 29 Feb 2028 and 30 April") {
        let feb2026 = ProactiveScheduleCalculator.nextFireDate(for: .monthly(day: 31, hour: 9, minute: 0), after: at(2026, 2, 1, 0, 0, cal), calendar: cal)
        let feb2028 = ProactiveScheduleCalculator.nextFireDate(for: .monthly(day: 31, hour: 9, minute: 0), after: at(2028, 2, 1, 0, 0, cal), calendar: cal)
        let april = ProactiveScheduleCalculator.nextFireDate(for: .monthly(day: 31, hour: 9, minute: 0), after: at(2026, 4, 1, 0, 0, cal), calendar: cal)
        let afterJan = ProactiveScheduleCalculator.nextFireDate(for: .monthly(day: 31, hour: 9, minute: 0), after: at(2026, 1, 31, 9, 0, cal), calendar: cal)
        let first = ProactiveScheduleCalculator.nextFireDate(for: .monthly(day: 1, hour: 9, minute: 0), after: at(2026, 11, 26, 12, 0, cal), calendar: cal)
        return feb2026 == at(2026, 2, 28, 9, 0, cal) && feb2028 == at(2028, 2, 29, 9, 0, cal) && april == at(2026, 4, 30, 9, 0, cal)
            && afterJan == at(2026, 2, 28, 9, 0, cal) && first == at(2026, 12, 1, 9, 0, cal)
    }

    check("Routines: after three days asleep only the newest slot within 12 h catches up, older ones are skipped") {
        let daily = ProactiveSchedule.daily(hour: 8, minute: 0)
        let created = at(2026, 11, 1, 7, 0, cal)
        let lastRun = at(2026, 11, 22, 8, 0, cal)
        let lastKey = ProactiveScheduleCalculator.slotKey(for: lastRun, calendar: cal)
        let wake = at(2026, 11, 25, 10, 0, cal)
        let due = ProactiveScheduleCalculator.evaluateDue(schedule: daily, lastSlotKey: lastKey, lastRunAt: lastRun, createdAt: created, now: wake, calendar: cal)
        let again = ProactiveScheduleCalculator.evaluateDue(schedule: daily, lastSlotKey: due?.slotKey, lastRunAt: wake, createdAt: created,
                                                            now: wake.addingTimeInterval(60), calendar: cal)
        let late = ProactiveScheduleCalculator.evaluateDue(schedule: daily, lastSlotKey: lastKey, lastRunAt: lastRun, createdAt: created,
                                                           now: at(2026, 11, 25, 21, 0, cal), calendar: cal)
        let beforeCreation = ProactiveScheduleCalculator.evaluateDue(schedule: daily, lastSlotKey: nil, lastRunAt: nil,
                                                                     createdAt: at(2026, 11, 25, 9, 0, cal), now: wake, calendar: cal)
        // Created half a second after 08:00:00 must not fire the 08:00:00 slot.
        let subSecondAfterSlot = ProactiveScheduleCalculator.evaluateDue(schedule: daily, lastSlotKey: nil, lastRunAt: nil,
                                                                         createdAt: at(2026, 11, 25, 8, 0, cal).addingTimeInterval(0.5),
                                                                         now: wake, calendar: cal)
        // Hourly-ish weekly slots within the window still yield a single, newest slot.
        let weekdays = ProactiveScheduleCalculator.evaluateDue(schedule: .weekdays(hour: 8, minute: 0), lastSlotKey: nil, lastRunAt: nil,
                                                               createdAt: created, now: at(2026, 11, 30, 9, 0, cal), calendar: cal)
        return due?.slotKey == "2026-11-25-0800" && due?.slotDate == at(2026, 11, 25, 8, 0, cal)
            && due?.nextFireDate == at(2026, 11, 26, 8, 0, cal) && due?.disableAfterFire == false
            && again == nil && late == nil && beforeCreation == nil && subSecondAfterSlot == nil && weekdays?.slotKey == "2026-11-30-0800"
    }

    check("Routines: once fires a single time and asks to be switched off; intervals wait for their time") {
        let target = at(2026, 11, 26, 14, 0, cal)
        let created = at(2026, 11, 26, 9, 0, cal)
        let early = ProactiveScheduleCalculator.evaluateDue(schedule: .once(at: target), lastSlotKey: nil, lastRunAt: nil, createdAt: created,
                                                            now: target.addingTimeInterval(-60), calendar: cal)
        let due = ProactiveScheduleCalculator.evaluateDue(schedule: .once(at: target), lastSlotKey: nil, lastRunAt: nil, createdAt: created,
                                                          now: target.addingTimeInterval(120), calendar: cal)
        let ranAlready = ProactiveScheduleCalculator.evaluateDue(schedule: .once(at: target), lastSlotKey: due?.slotKey, lastRunAt: target,
                                                                 createdAt: created, now: target.addingTimeInterval(600), calendar: cal)
        let tooOld = ProactiveScheduleCalculator.evaluateDue(schedule: .once(at: target), lastSlotKey: nil, lastRunAt: nil, createdAt: created,
                                                             now: target.addingTimeInterval(25 * 3600), calendar: cal)
        let intervalWait = ProactiveScheduleCalculator.evaluateDue(schedule: .interval(minutes: 30), lastSlotKey: nil, lastRunAt: nil,
                                                                   createdAt: created, now: created.addingTimeInterval(29 * 60), calendar: cal)
        let intervalDue = ProactiveScheduleCalculator.evaluateDue(schedule: .interval(minutes: 30), lastSlotKey: nil, lastRunAt: nil,
                                                                  createdAt: created, now: created.addingTimeInterval(30 * 60), calendar: cal)
        let intervalAfterSleep = ProactiveScheduleCalculator.evaluateDue(schedule: .interval(minutes: 30), lastSlotKey: "x",
                                                                         lastRunAt: created, createdAt: created,
                                                                         now: created.addingTimeInterval(3 * 86_400), calendar: cal)
        return early == nil && due?.disableAfterFire == true && due?.slotKey == "2026-11-26-1400" && due?.nextFireDate == nil
            && ranAlready == nil && tooOld == nil && intervalWait == nil
            && intervalDue?.nextFireDate == created.addingTimeInterval(60 * 60)
            && intervalAfterSleep?.slotDate == created.addingTimeInterval(3 * 86_400)
    }

    // MARK: Store

    await checkAsync("Routines: store CRUD, built-in key uniqueness, enable, delete with snapshot") {
        let base = try routineFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try ProactiveRoutineStore(baseDirectory: base)
        let packs = ProactiveRoutine.starterPacks(language: "en", now: at(2026, 11, 26, 9, 0, cal))
        for routine in packs { try await store.upsert(routine) }
        for routine in packs { try await store.upsert(routine) }   // idempotent
        var custom = ProactiveRoutine(title: "Check invoices", instruction: "Look for new invoices", template: .customCheck,
                                      trigger: .schedule(.weekdays(hour: 9, minute: 0)), executionMode: .localAIReadOnly,
                                      createdAt: at(2026, 11, 26, 10, 0, cal))
        try await store.upsert(custom)
        custom.title = "Check invoices daily"
        custom.lastOutcome = .silent
        try await store.upsert(custom)
        let all = try await store.allRoutines()
        let byKey = try await store.routine(builtInKey: "builtin.weekly_review")
        var duplicateKey = ProactiveRoutine(title: "Clone", instruction: "", template: .weeklyReview,
                                            trigger: .schedule(.daily(hour: 9, minute: 0)), builtInKey: "builtin.weekly_review")
        duplicateKey.enabled = true
        var conflict = false
        do { try await store.upsert(duplicateKey) } catch ProactiveRoutineStoreError.builtInKeyConflict { conflict = true }
        var invalid = false
        do { try await store.upsert(ProactiveRoutine(title: "  ", instruction: "", template: .customCheck, trigger: .reminderDue)) }
        catch ProactiveRoutineStoreError.invalidRequest { invalid = true }
        let toggled = try await store.setEnabled(id: packs[1].id, enabled: true, now: at(2026, 11, 26, 11, 0, cal))
        var unknown = false
        do { try await store.setEnabled(id: UUID(), enabled: true) } catch ProactiveRoutineStoreError.unknownRoutine { unknown = true }
        try await store.saveSnapshot(#"{"a":1}"#, for: custom.id)
        try await store.delete(id: custom.id)
        let gone = try await store.routine(id: custom.id)
        let snapshotGone = try await store.snapshot(for: custom.id)
        let reopened = try ProactiveRoutineStore(baseDirectory: base)
        let persisted = try await reopened.routine(id: packs[1].id)
        let remaining = try await reopened.allRoutines().count
        let perms = (try? FileManager.default.attributesOfItem(atPath: base.appendingPathComponent("Proactivity").path)[.posixPermissions] as? Int) ?? 0
        return all.count == 7 && all.last?.title == "Check invoices daily" && all.last?.lastOutcome == .silent
            && byKey?.id == packs[2].id && conflict && invalid && unknown
            && toggled.enabled && persisted?.enabled == true && persisted?.updatedAt == at(2026, 11, 26, 11, 0, cal)
            && gone == nil && snapshotGone == nil && remaining == 6 && perms & 0o077 == 0
    }

    await checkAsync("Routines: one run per routine and slot, history newest first, snapshots persist") {
        let base = try routineFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try ProactiveRoutineStore(baseDirectory: base)
        let routine = ProactiveRoutine.starterPacks(language: "de")[3]
        try await store.upsert(routine)
        let t0 = at(2026, 11, 26, 8, 0, cal)
        let first = RoutineRunRecord(routineID: routine.id, routineTitle: routine.title, slotKey: "2026-11-26-0800", outcome: .silent,
                                     inputHash: "h1", startedAt: t0, finishedAt: t0.addingTimeInterval(1))
        let dup = RoutineRunRecord(routineID: routine.id, routineTitle: routine.title, slotKey: "2026-11-26-0800", outcome: .prepared,
                                   matterID: UUID(), startedAt: t0.addingTimeInterval(5), finishedAt: t0.addingTimeInterval(6))
        let second = RoutineRunRecord(routineID: routine.id, routineTitle: routine.title, slotKey: "2026-11-26-0900", outcome: .prepared,
                                      matterID: UUID(), inputHash: "h2", detail: "2 changes",
                                      startedAt: t0.addingTimeInterval(3600), finishedAt: t0.addingTimeInterval(3601))
        let other = RoutineRunRecord(routineID: UUID(), routineTitle: "Other", slotKey: "2026-11-26-0800", outcome: .failed,
                                     startedAt: t0.addingTimeInterval(10), finishedAt: t0.addingTimeInterval(11))
        let r1 = try await store.recordRun(first)
        let r2 = try await store.recordRun(dup)
        let r3 = try await store.recordRun(second)
        let r4 = try await store.recordRun(other)
        var badSlot = false
        do { _ = try await store.recordRun(RoutineRunRecord(routineID: routine.id, routineTitle: "x", slotKey: "", outcome: .skipped,
                                                            startedAt: t0, finishedAt: t0)) }
        catch ProactiveRoutineStoreError.invalidRequest { badSlot = true }
        let mine = try await store.runs(for: routine.id)
        let recent = try await store.recentRuns(limit: 2)
        try await store.saveSnapshot("{\"v\":1}", for: routine.id, now: t0)
        try await store.saveSnapshot("{\"v\":2}", for: routine.id, now: t0)
        let reopened = try ProactiveRoutineStore(baseDirectory: base)
        let snapshot = try await reopened.snapshot(for: routine.id)
        let has = try await reopened.hasRun(routineID: routine.id, slotKey: "2026-11-26-0800")
        let hasNot = try await reopened.hasRun(routineID: routine.id, slotKey: "2026-11-27-0800")
        return r1 == .recorded(first) && r2 == .duplicateSlot && r3 == .recorded(second) && r4 == .recorded(other) && badSlot
            && mine.map(\.id) == [second.id, first.id] && mine.first == second && recent.map(\.id) == [second.id, other.id]
            && snapshot == "{\"v\":2}" && has && !hasNot
    }

    await checkAsync("Routines: routines.sqlite refuses a newer schema; proactivity.sqlite stays at user_version 1") {
        let base = try routineFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try ProactiveMatterStore(baseDirectory: base)
        let routines = try ProactiveRoutineStore(baseDirectory: base)
        try await routines.upsert(ProactiveRoutine.starterPacks(language: "en")[0])
        let matterDB = base.appendingPathComponent("Proactivity/proactivity.sqlite")
        let routineDB = base.appendingPathComponent("Proactivity/routines.sqlite")
        _ = try ProactiveMatterStore(baseDirectory: base)
        let versions = (userVersion(matterDB), userVersion(routineDB))
        guard setUserVersion(routineDB, 2) else { return false }
        var refused = false
        do { _ = try ProactiveRoutineStore(baseDirectory: base) } catch ProactiveRoutineStoreError.unsupportedVersion { refused = true }
        return versions.0 == 1 && versions.1 == 1 && refused && userVersion(matterDB) == 1
            && ProactiveRoutineStore.schemaVersion == 1
    }

    // MARK: Natural language

    let now = at(2026, 11, 26, 10, 0, cal)   // Thursday
    func parsed(_ text: String, _ language: String = "en") -> ParsedRoutineDraft? {
        RoutineNaturalLanguageParser.parse(text, now: now, language: language, calendar: cal)
    }
    func expect(_ text: String, _ trigger: ProactiveTrigger, template: ProactiveRoutineTemplate? = nil, instruction: String? = nil,
                _ language: String = "en") -> Bool {
        let d = parsed(text, language)
        let ok = d?.trigger == trigger && (template == nil || d?.template == template) && (instruction == nil || d?.instruction == instruction)
        if !ok { print("  parse \"\(text)\" → \(String(describing: d))") }
        return ok
    }

    check("Routines: English requests parse into schedules, templates and clean tasks") {
        [
            expect("Every morning at 8:30 summarize my unread mail", .schedule(.daily(hour: 8, minute: 30)), template: .customCheck,
                   instruction: "Summarize my unread mail"),
            expect("every morning give me my morning brief", .schedule(.daily(hour: 8, minute: 0)), template: .morningBrief),
            expect("Every evening at 6pm show me a preview of tomorrow", .schedule(.daily(hour: 18, minute: 0)), template: .eveningPreview),
            expect("every evening check what's on tomorrow", .schedule(.daily(hour: 18, minute: 0)), template: .eveningPreview),
            expect("Daily at 7am check the shared folder for new invoices", .schedule(.daily(hour: 7, minute: 0)),
                   instruction: "Check the shared folder for new invoices"),
            expect("every weekday at 9 list my overdue tasks", .schedule(.weekdays(hour: 9, minute: 0))),
            expect("Every Monday and Thursday at 10:15 review open offers", .schedule(.weekly(weekdays: [2, 5], hour: 10, minute: 15)),
                   instruction: "Review open offers"),
            expect("On Fridays at 4 pm do my weekly review", .schedule(.weekly(weekdays: [6], hour: 16, minute: 0)), template: .weeklyReview),
            expect("Monthly on the 1st at 9 remind me to pay rent", .schedule(.monthly(day: 1, hour: 9, minute: 0)), instruction: "Pay rent"),
            expect("every 2 hours check the status page", .schedule(.interval(minutes: 120)), instruction: "Check the status page"),
            expect("hourly look for urgent mails", .schedule(.interval(minutes: 60))),
            expect("every 30 minutes check the build", .schedule(.interval(minutes: 30))),
            expect("tomorrow at 14:00 remind me to call the bank", .schedule(.once(at: at(2026, 11, 27, 14, 0, cal))),
                   instruction: "Call the bank"),
            expect("today at 17:00 check the parcel tracking", .schedule(.once(at: at(2026, 11, 26, 17, 0, cal)))),
            expect("in 2 hours check whether Anna replied", .schedule(.once(at: now.addingTimeInterval(7200)))),
            expect("Whenever a new file arrives in Downloads, sort it", .folder(path: "", bookmark: nil), template: .folderWatch),
            expect("when my calendar changes let me know", .calendarChange(lookaheadHours: 48), template: .calendarRadar),
            expect("when reminders are due tell me", .reminderDue, template: .reminderRadar),
            expect("Every Friday at 9 check my overdue reminders", .schedule(.weekly(weekdays: [6], hour: 9, minute: 0)),
                   template: .customCheck, instruction: "Check my overdue reminders"),
            expect("Mondays and Thursdays at 9 review invoices", .schedule(.weekly(weekdays: [2, 5], hour: 9, minute: 0)),
                   instruction: "Review invoices"),
            expect("Every day look at 120 invoices", .schedule(.daily(hour: 9, minute: 0)), instruction: "Look at 120 invoices"),
            expect("15 minutes before every meeting prepare notes", .upcomingMeeting(leadMinutes: 15), template: .meetingPrep),
            expect("0 8 * * 1-5 summarize the news", .schedule(.weekdays(hour: 8, minute: 0)), instruction: "Summarize the news"),
        ].allSatisfy { $0 }
    }

    check("Routines: German requests parse into schedules, templates and clean tasks") {
        [
            expect("Jeden Morgen um 8 Uhr fasse meine neuen Mails zusammen", .schedule(.daily(hour: 8, minute: 0)),
                   instruction: "Fasse meine neuen Mails zusammen", "de"),
            expect("jeden Morgen um 8:30 meinen Morgenbrief", .schedule(.daily(hour: 8, minute: 30)), template: .morningBrief, "de"),
            expect("Jeden Abend um 18 Uhr zeig mir die Vorschau auf morgen", .schedule(.daily(hour: 18, minute: 0)), template: .eveningPreview, "de"),
            expect("Jeden Abend um 6 Uhr Nachrichten prüfen", .schedule(.daily(hour: 18, minute: 0)), instruction: "Nachrichten prüfen", "de"),
            expect("Heute Abend um 7 Uhr Paket prüfen", .schedule(.once(at: at(2026, 11, 26, 19, 0, cal))), instruction: "Paket prüfen", "de"),
            expect("täglich um 7 prüfe den Ordner Rechnungen", .schedule(.daily(hour: 7, minute: 0)), instruction: "Prüfe den Ordner Rechnungen", "de"),
            expect("werktags um 9 Uhr offene Angebote prüfen", .schedule(.weekdays(hour: 9, minute: 0)), instruction: "Offene Angebote prüfen", "de"),
            expect("unter der Woche um 8 meine Termine zusammenfassen", .schedule(.weekdays(hour: 8, minute: 0)), "de"),
            expect("Jeden Montag und Donnerstag um 9 Uhr Wochenüberblick", .schedule(.weekly(weekdays: [2, 5], hour: 9, minute: 0)),
                   template: .weeklyReview, "de"),
            expect("montags und donnerstags um 10 die Steuerunterlagen prüfen", .schedule(.weekly(weekdays: [2, 5], hour: 10, minute: 0)), "de"),
            expect("Am 1. jeden Monats um 9 erinnere mich an die Miete", .schedule(.monthly(day: 1, hour: 9, minute: 0)),
                   instruction: "Die Miete", "de"),
            expect("jeden Monat am 15. Kontoauszüge ablegen", .schedule(.monthly(day: 15, hour: 9, minute: 0)), "de"),
            expect("alle 2 Stunden den Status prüfen", .schedule(.interval(minutes: 120)), instruction: "Den Status prüfen", "de"),
            expect("stündlich neue Mails prüfen", .schedule(.interval(minutes: 60)), "de"),
            expect("alle 30 Minuten den Build prüfen", .schedule(.interval(minutes: 30)), "de"),
            expect("morgen um 14 Uhr die Bank anrufen", .schedule(.once(at: at(2026, 11, 27, 14, 0, cal))), instruction: "Die Bank anrufen", "de"),
            expect("heute um 17 Uhr das Paket verfolgen", .schedule(.once(at: at(2026, 11, 26, 17, 0, cal))), "de"),
            expect("in 30 Minuten nachsehen, ob Anna geantwortet hat", .schedule(.once(at: now.addingTimeInterval(1800))), "de"),
            expect("Wenn eine neue Datei in Downloads landet, sortiere sie", .folder(path: "", bookmark: nil), template: .folderWatch, "de"),
            expect("Wenn sich ein Termin ändert, sag mir Bescheid", .calendarChange(lookaheadHours: 48), template: .calendarRadar, "de"),
            expect("Vor jedem Termin vorbereiten", .upcomingMeeting(leadMinutes: 30), template: .meetingPrep, "de"),
            expect("fällige Erinnerungen melden", .reminderDue, template: .reminderRadar, "de"),
        ].allSatisfy { $0 }
    }

    check("Routines: parsed drafts carry titles, summaries and confidence in the app language") {
        let brief = parsed("jeden Morgen meinen Morgenbrief", "de")
        let custom = parsed("Every weekday at 9 check the shared inbox", "en")
        let folder = parsed("wenn eine neue Datei kommt, zusammenfassen", "de")
        return brief?.title == "Morgenbrief" && brief?.confidence == .medium && brief?.humanSummary == "Täglich um 08:00"
            && custom?.title == "Check the shared inbox" && custom?.confidence == .high && custom?.humanSummary == "Weekdays at 09:00"
            && folder?.title == "Ordner beobachten" && folder?.humanSummary == "Neue Dateien in einem Ordner"
            && parsed("every day at 9") == nil   // no task, no template
            && parsed("today at 9:00 check mail") == nil   // already past
            && parsed("") == nil
    }

    check("Routines: cron covers the common five-field patterns and refuses the rest") {
        let p = RoutineNaturalLanguageParser.parseCron
        let ok = p("0 8 * * *") == .daily(hour: 8, minute: 0)
            && p("30 8 * * 1-5") == .weekdays(hour: 8, minute: 30)
            && p("0 9 * * 1,3,5") == .weekly(weekdays: [2, 4, 6], hour: 9, minute: 0)
            && p("0 9 * * 0") == .weekly(weekdays: [1], hour: 9, minute: 0)
            && p("0 9 * * 0-6") == .daily(hour: 9, minute: 0)
            && p("0 9 1 * *") == .monthly(day: 1, hour: 9, minute: 0)
            && p("*/30 * * * *") == .interval(minutes: 30)
            && p("0 */2 * * *") == .interval(minutes: 120)
            && p("15 * * * *") == .interval(minutes: 60)
        let refused = [p("0 9 1 1 *"), p("0 9 1 * 1"), p("61 8 * * *"), p("0 24 * * *"), p("0 8 * *"), p("a b c d e"), p("0 9 * * 8"),
                       p("0 9 * * -1"), p("0 9 * * 1-"), p("0 9 * * ,1")]
        return ok && refused.allSatisfy { $0 == nil }
    }

    check("Routines: only real routine wording looks like a routine request; questions never do") {
        let yes = ["Every morning at 8 summarize my mail", "daily check the news", "weekdays at 9 list my tasks", "remind me every Monday to water the plants",
                   "jeden Morgen um 8 meine Mails", "werktags um 9 die Termine", "täglich den Ordner prüfen", "alle 2 Stunden den Status prüfen",
                   "Whenever a new file lands in Downloads, sort it", "wenn eine neue Datei kommt, sortieren", "Am 1. jeden Monats die Miete",
                   "0 8 * * 1-5 news", "every 30 minutes check the build", "jeden Montag Wochenüberblick", "Before every meeting prep notes"]
        let no = ["What's on my calendar tomorrow?", "Was steht morgen im Kalender?", "What did I do every day last week?",
                  "Wann ist mein nächster Termin?", "Remind me tomorrow at 9 to call mom", "Erinnere mich morgen um 9 an Mama",
                  "Read every file in Downloads", "Summarize this document", "Wie wird das Wetter heute?", "tomorrow at 14:00 call the bank",
                  "Gibt es jeden Tag ein Meeting?", "Hab ich jeden Montag Training?", "On Monday I have a dentist appointment",
                  "Show me my overdue reminders", "Zeig mir meine fälligen Erinnerungen", "Can you check my mail every morning?",
                  "Kannst du jeden Tag meine Mails lesen?", "Every day at 9", ""]
        let wrongYes = yes.filter { !RoutineNaturalLanguageParser.looksLikeRoutineRequest($0) }
        let wrongNo = no.filter { RoutineNaturalLanguageParser.looksLikeRoutineRequest($0) }
        for w in wrongYes { print("  expected routine: \(w)") }
        for w in wrongNo { print("  expected no routine: \(w)") }
        return wrongYes.isEmpty && wrongNo.isEmpty
    }

    // MARK: Builders

    let thursday = at(2026, 11, 26, 18, 0, cal)
    let friday9 = at(2026, 11, 27, 9, 0, cal)

    check("Routines: Evening Preview lists tomorrow and what is open, quiet when nothing is there") {
        let input = RoutineDigestInput(
            now: thursday,
            events: [event("a", "Zahnarzt", friday9, location: "Praxis"), event("b", "Abgesagt", friday9, status: .cancelled),
                     event("c", "Heute", at(2026, 11, 26, 19, 0, cal)), event("d", "Abgelehnt", friday9, declined: true)],
            reminders: [ReminderItem(title: "Miete überweisen", list: "Privat", due: at(2026, 11, 25, 9, 0, cal)),
                        ReminderItem(title: "Nächste Woche", list: "Privat", due: at(2026, 12, 3, 9, 0, cal))],
            calendar: cal, language: "de")
        guard let draft = EveningPreviewBuilder.draft(input) else { return false }
        let again = EveningPreviewBuilder.draft(input)
        let empty = EveningPreviewBuilder.draft(RoutineDigestInput(now: thursday, events: [event("c", "Heute", at(2026, 11, 26, 19, 0, cal))],
                                                                   calendar: cal, language: "en"))
        let english = EveningPreviewBuilder.draft(RoutineDigestInput(now: thursday, events: [event("a", "Dentist", friday9)], calendar: cal, language: "en"))
        return draft.kind == .routine && draft.matterKey == "evening-preview:2026-11-27" && draft.title.hasPrefix("Morgen · ")
            && draft.summary.contains("1 Termin morgen") && draft.summary.contains("09:00 Zahnarzt")
            && !draft.summary.contains("Abgesagt") && !draft.summary.contains("Abgelehnt") && !draft.summary.contains("Heute")
            && draft.summary.contains("Miete überweisen (überfällig)") && !draft.summary.contains("Nächste Woche")
            && !draft.preparedPrompt.contains("Zahnarzt") && draft.sourceVersion.count == 64 && again?.sourceVersion == draft.sourceVersion
            && empty == nil && english?.summary.contains("1 appointment tomorrow") == true && english?.title.hasPrefix("Tomorrow · ") == true
    }

    check("Routines: Weekly Review counts days, finds the busiest day and confirmed overlaps, quiet for an empty week") {
        let monday = at(2026, 11, 30, 8, 0, cal)
        let events = [
            event("1", "Team", at(2026, 11, 30, 10, 0, cal), minutes: 60),
            event("2", "Kunde", at(2026, 11, 30, 10, 30, cal), minutes: 60),                       // overlaps Team
            event("3", "Vielleicht", at(2026, 11, 30, 10, 15, cal), minutes: 30, status: .tentative), // not confirmed
            event("4", "Feiertag", at(2026, 11, 30, 0, 0, cal), minutes: 1440, allDay: true),
            event("5", "Mittag", at(2026, 11, 30, 12, 0, cal), minutes: 30),
            event("6", "Review", at(2026, 12, 2, 9, 0, cal)),
            event("7", "Abgelehnt", at(2026, 12, 2, 9, 30, cal), declined: true),
            event("8", "Später", at(2026, 12, 9, 9, 0, cal)),                                       // outside the week
        ]
        let reminders = [ReminderItem(title: "Steuer", list: "Privat", due: at(2026, 11, 20, 9, 0, cal)),
                         ReminderItem(title: "Geschenk", list: "Privat", due: at(2026, 12, 4, 9, 0, cal))]
        guard let draft = WeeklyReviewBuilder.draft(RoutineDigestInput(now: monday, events: events, reminders: reminders, calendar: cal, language: "de"))
        else { return false }
        let overlaps = WeeklyReviewBuilder.overlaps(events)
        let empty = WeeklyReviewBuilder.draft(RoutineDigestInput(now: monday, events: [events[7]], calendar: cal, language: "en"))
        let english = WeeklyReviewBuilder.draft(RoutineDigestInput(now: monday, events: Array(events.prefix(2)), calendar: cal, language: "en"))
        return overlaps.count == 1 && overlaps.first?.first.title == "Team" && overlaps.first?.second.title == "Kunde"
            && draft.matterKey == "weekly-review:2026-11-30" && draft.summary.contains("6 Termine in 7 Tagen")
            && draft.summary.contains("Vollster Tag: ") && draft.summary.contains("(5)") && draft.summary.contains("1 Überschneidung")
            && draft.summary.contains("Team ↔ Kunde") && draft.summary.contains("2 fällige Erinnerungen")
            && draft.summary.contains("davon 1 überfällig") && draft.summary.contains("Steuer (überfällig)") && !draft.summary.contains("Später")
            && !draft.preparedPrompt.contains("Team") && empty == nil
            && english?.summary.contains("1 overlap") == true && english?.summary.contains("Busiest day: ") == true
    }

    check("Routines: Calendar Radar records a baseline, stays quiet when unchanged, reports moves, new places and new appointments") {
        let now = at(2026, 11, 26, 9, 0, cal)
        let base = [event("a", "Team", at(2026, 11, 26, 14, 0, cal), location: "Raum 1"),
                    event("b", "Arzt", at(2026, 11, 27, 9, 0, cal)),
                    event("x", "Abgesagt", at(2026, 11, 26, 16, 0, cal), status: .cancelled)]
        let first = CalendarRadarBuilder.evaluate(events: base, previousSnapshotJSON: nil, now: now, lookaheadHours: 48, calendar: cal, language: "de")
        let same = CalendarRadarBuilder.evaluate(events: base, previousSnapshotJSON: first.nextSnapshotJSON, now: now.addingTimeInterval(600),
                                                 lookaheadHours: 48, calendar: cal, language: "de")
        let moved = [event("a", "Team", at(2026, 11, 26, 15, 0, cal), location: "Raum 1"),
                     event("b", "Arzt", at(2026, 11, 27, 9, 0, cal), location: "Praxis Süd"),
                     event("c", "Neu dazu", at(2026, 11, 27, 11, 0, cal)),
                     event("x", "Abgesagt", at(2026, 11, 26, 17, 0, cal), status: .cancelled)]
        let changed = CalendarRadarBuilder.evaluate(events: moved, previousSnapshotJSON: same.nextSnapshotJSON, now: now.addingTimeInterval(1200),
                                                    lookaheadHours: 48, calendar: cal, language: "de")
        // An appointment that only moved into the window as time passed is not "new".
        let later = now.addingTimeInterval(86_400)
        let entering = CalendarRadarBuilder.evaluate(events: moved + [event("d", "Übermorgen", at(2026, 11, 28, 20, 0, cal))],
                                                     previousSnapshotJSON: changed.nextSnapshotJSON, now: later, lookaheadHours: 48, calendar: cal)
        let unreadable = CalendarRadarBuilder.evaluate(events: base, previousSnapshotJSON: "not json", now: now, calendar: cal)
        guard let draft = changed.draft else { return false }
        return first.draft == nil && same.draft == nil && same.inputHash == first.inputHash && changed.inputHash != first.inputHash
            && draft.kind == .calendarChange && draft.title == "3 Termine haben sich geändert" && draft.sourceVersion == changed.inputHash
            && draft.summary.contains("Verschoben: Team") && draft.summary.contains("Neuer Ort: Arzt") && draft.summary.contains("Praxis Süd")
            && draft.summary.contains("Neu: ") && draft.summary.contains("Neu dazu") && !draft.summary.contains("Abgesagt")
            && !draft.preparedPrompt.contains("Team") && draft.matterKey == "calendar-radar:2026-11-26"
            && entering.draft == nil && unreadable.draft == nil
    }

    check("Routines: Calendar Radar lists at most five changes") {
        let now = at(2026, 11, 26, 9, 0, cal)
        let first = CalendarRadarBuilder.evaluate(events: [], previousSnapshotJSON: nil, now: now, calendar: cal, language: "en")
        let many = (0..<8).map { event("n\($0)", "Meeting \($0)", at(2026, 11, 26, 10 + $0, 0, cal)) }
        let result = CalendarRadarBuilder.evaluate(events: many, previousSnapshotJSON: first.nextSnapshotJSON, now: now, calendar: cal, language: "en")
        let bullets = result.draft?.summary.split(separator: "\n").filter { $0.hasPrefix("•") }.count
        return bullets == 5 && result.draft?.summary.contains("… and 3 more") == true && result.draft?.title == "8 appointments changed"
    }

    check("Routines: Reminder Radar fires on new or escalated reminders, stays quiet when one is completed") {
        let now = at(2026, 11, 26, 9, 0, cal)
        let reminders = [ReminderItem(id: "1", title: "Steuer", list: "Privat", due: at(2026, 11, 24, 9, 0, cal)),
                         ReminderItem(id: "2", title: "Blumen gießen", list: "Privat", due: at(2026, 11, 26, 18, 0, cal), dueHasTime: true),
                         ReminderItem(id: "3", title: "Später", list: "Privat", due: at(2026, 11, 28, 9, 0, cal)),
                         ReminderItem(id: "4", title: "Ohne Datum", list: "Privat")]
        let first = ReminderRadarBuilder.evaluate(reminders: reminders, previousSnapshotJSON: nil, now: now, calendar: cal, language: "de")
        let same = ReminderRadarBuilder.evaluate(reminders: reminders, previousSnapshotJSON: first.nextSnapshotJSON, now: now.addingTimeInterval(600), calendar: cal, language: "de")
        // Completing "Steuer" leaves a subset of already-seen reminders: must stay quiet!
        let completedOne = ReminderRadarBuilder.evaluate(reminders: Array(reminders.dropFirst()), previousSnapshotJSON: first.nextSnapshotJSON,
                                                         now: now.addingTimeInterval(1200), calendar: cal, language: "de")
        // Next day, "Blumen gießen" transitions from due-today to overdue: must speak up!
        let escalated = ReminderRadarBuilder.evaluate(reminders: [reminders[1]], previousSnapshotJSON: completedOne.nextSnapshotJSON,
                                                      now: at(2026, 11, 27, 9, 0, cal), calendar: cal, language: "de")
        let more = ReminderRadarBuilder.evaluate(reminders: reminders + [ReminderItem(id: "5", title: "Anruf", list: "Arbeit", due: at(2026, 11, 26, 11, 0, cal))],
                                                 previousSnapshotJSON: first.nextSnapshotJSON, now: now, calendar: cal, language: "en")
        let corrupt = ReminderRadarBuilder.evaluate(reminders: reminders, previousSnapshotJSON: "not-json", now: now, calendar: cal, language: "en")
        let none = ReminderRadarBuilder.evaluate(reminders: [reminders[2], reminders[3]], previousSnapshotJSON: nil, now: now, calendar: cal)
        guard let draft = first.draft else { return false }
        return draft.kind == .reminderDue && draft.title == "2 Erinnerungen sind fällig" && draft.summary.contains("1 überfällig\n• Steuer")
            && draft.summary.contains("1 heute fällig\n• Blumen gießen") && !draft.summary.contains("Später") && !draft.summary.contains("Ohne Datum")
            && !draft.preparedPrompt.contains("Steuer") && draft.sourceVersion == first.inputHash
            && same.draft == nil && completedOne.draft == nil && escalated.draft?.title == "1 Erinnerung ist fällig"
            && more.draft?.title == "3 reminders are due" && more.draft?.summary.contains("2 due today") == true
            && corrupt.draft == nil && none.draft == nil
    }

    check("Routines: Upcoming Meeting Prep prepares once before a confirmed appointment and cross-references reminders") {
        let now = at(2026, 11, 26, 13, 40, cal)
        let events = [
            event("m1", "Steuerberater Termin", at(2026, 11, 26, 14, 0, cal), minutes: 45, location: "Kanzlei Mitte"),
            event("m2", "Ganztägig", at(2026, 11, 26, 13, 50, cal), minutes: 1440, allDay: true),
            event("m3", "Abgelehnt", at(2026, 11, 26, 13, 55, cal), declined: true),
            event("m4", "Später", at(2026, 11, 26, 16, 0, cal)),
        ]
        let reminders = [ReminderItem(id: "r1", title: "Belege für Steuerberater einpacken", list: "Privat", due: now)]
        let first = UpcomingMeetingPrepBuilder.evaluate(events: events, reminders: reminders, previousSnapshotJSON: nil,
                                                        now: now, leadMinutes: 30, calendar: cal, language: "de")
        let repeatSame = UpcomingMeetingPrepBuilder.evaluate(events: events, reminders: reminders, previousSnapshotJSON: first.nextSnapshotJSON,
                                                             now: now.addingTimeInterval(300), leadMinutes: 30, calendar: cal, language: "de")
        let nextLead = UpcomingMeetingPrepBuilder.nextLeadDate(events: [events[3]], now: now, leadMinutes: 30)
        guard let draft = first.draft else { return false }
        return draft.kind == .routine && draft.title == "In 20 Min: Steuerberater Termin"
            && draft.summary.contains("14:00–14:45 · Kanzlei Mitte")
            && draft.summary.contains("Offene Erinnerung: Belege für Steuerberater einpacken")
            && !draft.preparedPrompt.contains("Steuerberater")
            && repeatSame.draft == nil && nextLead == at(2026, 11, 26, 15, 30, cal)
    }

    check("Routines: AI output parser accepts only the strict schema and stays quiet otherwise") {
        let p = RoutineAIOutputParser.parse
        let ready = p("STATUS: READY\nTITLE: 2 new invoices\nSUMMARY: Stadtwerke, 84 €\nTelekom, 39 €")
        let crlf = p("STATUS: READY\r\nTITLE: Bill due\rSUMMARY: Pay soon")
        let think = p("<think>Let me look…\nSTATUS: READY</think>\nSTATUS: NOTHING_NEW")
        let unclosedThink = p("<THINK>STATUS: READY\nTITLE: Leak\nSUMMARY: Should stay quiet")
        let bidi = p("status: ready\ntitle: Invoice \u{202E}fdp.exe\u{202C} due\u{0007}\nsummary: Pay \u{2066}today\u{2069}")
        return p("STATUS: NOTHING_NEW") == .nothingNew
            && ready == .prepared(title: "2 new invoices", summary: "Stadtwerke, 84 €\nTelekom, 39 €")
            && crlf == .prepared(title: "Bill due", summary: "Pay soon")
            && think == .nothingNew && unclosedThink == .nothingNew
            && bidi == .prepared(title: "Invoice fdp.exe due", summary: "Pay today")
            && p("") == .nothingNew && p("   \n") == .nothingNew
            && p("STATUS: READY\nTITLE: I'm sorry, I can't help with that\nSUMMARY: No.") == .nothingNew
            && p("STATUS: READY\nTITLE: Hinweis\nSUMMARY: Es tut mir leid, das kann ich nicht.") == .nothingNew
            && p("STATUS: READY\nTITLE: Only a title") == .nothingNew
            && p("Here are your invoices: …") == .nothingNew
            && p("STATUS: MAYBE\nTITLE: x\nSUMMARY: y") == .nothingNew
    }

    // MARK: Read-only isolation

    await checkAsync("Routines: a read-only MCP host lists and runs only readers; writers and online tools are refused before dispatch") {
        var host = PippaMCPHost.demo()
        host.readOnly = true
        let confirmations = LockedBox(0)
        host.confirmAction = { _ in confirmations.mutate { $0 += 1 }; return true }
        host.confirmBrowser = { _, _, _ in confirmations.mutate { $0 += 1 }; return true }
        let tools = PippaMCPTools(host: host)
        let initReply = ((await mcpCall(tools, "initialize", ["protocolVersion": "2025-11-25"]))?["result"] as? [String: Any])?["instructions"] as? String ?? ""
        let listed = ((await mcpCall(tools, "tools/list"))?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let names = listed.compactMap { $0["name"] as? String }
        let allRead = !names.isEmpty && names.allSatisfy { PippaActionClasses.of($0) == .read }
        let expectedReaders = PippaMCPTools.toolList().compactMap { $0["name"] as? String }.filter { PippaActionClasses.of($0) == .read }
        var refusedAll = true
        for name in ["calendar_add", "reminder_add", "calendar_update", "mail_draft", "mail_send", "mail_move", "browse", "prepare_files"] {
            let (isError, payload) = toolPayload(await mcpCall(tools, "tools/call", ["name": name, "arguments": ["title": "x", "url": "https://example.com"]]))
            let ok = isError && payload["status"] as? String == "read_only" && payload["dispatched"] as? Bool == false
            if !ok { print("  read-only \(name): \(payload)") }
            refusedAll = refusedAll && ok
        }
        let read = toolPayload(await mcpCall(tools, "tools/call", ["name": "calendar_read", "arguments": ["period": "today"]]))
        let budget = (try? JSONSerialization.data(withJSONObject: PippaMCPTools.toolList(), options: [.sortedKeys]))?.count ?? .max
        // The full host keeps every tool listed.
        let full = ((await mcpCall(PippaMCPTools(host: PippaMCPHost.demo()), "tools/list"))?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        if !(allRead && names == expectedReaders) || read.isError || confirmations.value != 0 {
            print("  read-only list: \(names) expected \(expectedReaders); read: \(read); confirmations: \(confirmations.value)")
        }
        return allRead && names == expectedReaders && !names.contains("browse") && !names.contains("mail_send")
            && initReply.contains("read-only") && !initReply.contains("Mail drafts")
            && refusedAll && !read.isError && confirmations.value == 0 && budget < 9_800 && full.count == PippaMCPTools.toolNames.count
    }

    await checkAsync("Routines: read-only also filters host extra tools by their class") {
        var host = PippaMCPHost.demo()
        host.readOnly = true
        let ran = LockedBox(0)
        let result = PippaMCPToolResult(text: "{}", isError: false)
        host.extraTools = [
            PippaMCPHostTool(name: "check_reader", actionClass: .read, describe: { _ in nil }, run: { _ in ran.mutate { $0 += 1 }; return result }),
            PippaMCPHostTool(name: "check_writer", actionClass: .undoable, describe: { _ in nil }, run: { _ in ran.mutate { $0 += 1 }; return result }),
            PippaMCPHostTool(name: "check_unclassed", actionClass: nil, describe: { _ in nil }, run: { _ in ran.mutate { $0 += 1 }; return result }),
        ]
        let tools = PippaMCPTools(host: host)
        let names = (((await mcpCall(tools, "tools/list"))?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let reader = toolPayload(await mcpCall(tools, "tools/call", ["name": "check_reader"]))
        let writer = toolPayload(await mcpCall(tools, "tools/call", ["name": "check_writer"]))
        let unclassed = toolPayload(await mcpCall(tools, "tools/call", ["name": "check_unclassed"]))
        return names.contains("check_reader") && !names.contains("check_writer") && !names.contains("check_unclassed")
            && !reader.isError && writer.payload["status"] as? String == "read_only" && unclassed.payload["status"] as? String == "read_only"
            && ran.value == 1
    }
}
