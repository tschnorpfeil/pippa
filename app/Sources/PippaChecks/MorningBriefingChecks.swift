import Foundation
import PippaCore

private actor BriefingFixture: MorningBriefingReading {
    var values: [String: MorningBriefingRead]
    var failures: [String: MorningBriefingReadFailure]
    var reads: [String] = []
    var hold: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    init(values: [String: MorningBriefingRead] = [:], failures: [String: MorningBriefingReadFailure] = [:], hold: Bool = false) {
        self.values = values; self.failures = failures; self.hold = hold
    }
    func sources(for kind: MorningBriefingSource.Kind) async throws -> [MorningBriefingSource] { [] }
    func read(_ source: MorningBriefingSource, day: DateInterval, limit: Int) async throws -> MorningBriefingRead {
        reads.append(source.id); started?.resume(); started = nil
        if hold { await withCheckedContinuation { pending = $0 } }
        if let failure = failures[source.id] { throw failure }
        return values[source.id] ?? MorningBriefingRead(entries: [], total: 0)
    }
    func waitForRead() async { if reads.isEmpty { await withCheckedContinuation { started = $0 } } }
    func release() { hold = false; pending?.resume(); pending = nil }
    func readIDs() -> [String] { reads }
}

@MainActor private func checkBriefing(_ name: String, _ body: @MainActor () async throws -> Bool) async {
    do { let passed = try await body(); check(name) { passed } }
    catch { check(name) { throw error } }
}

/// Synthetic sources only. No EventKit store, real permissions, notification center or model is used.
@MainActor func runMorningBriefingChecks() async {
    func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!; return calendar
    }
    let berlin = calendar("Europe/Berlin")
    func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 21, _ hour: Int = 8, _ minute: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    let now = date()
    let work = MorningBriefingSource(kind: .calendar, identifier: "calendar-work", title: "Work")
    let tasks = MorningBriefingSource(kind: .reminders, identifier: "list-home", title: "Home")
    var enabled = MorningBriefingConfiguration(); enabled.enabled = true; enabled.sources = [work, tasks]; enabled.notify = true
    let occurrence = MorningBriefingSchedule.due(enabled, now: now, calendar: berlin)!
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-morning-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func empty(_ occurrence: MorningBriefingOccurrence) -> MorningBriefingResult {
        .init(occurrence: occurrence, readAt: now, entries: [], checkedSources: [work, tasks], issues: [])
    }

    check("Morning overview: default off, no implicit sources, invalid schedules never run") {
        let defaults = MorningBriefingConfiguration()
        var invalid = enabled; invalid.sources = []
        var invalidDay = enabled; invalidDay.weekdays = [0, 8]
        var duplicate = enabled; duplicate.sources = [work, work]
        return !defaults.enabled && !defaults.notify && defaults.sources.isEmpty
            && MorningBriefingSchedule.due(defaults, now: now, calendar: berlin) == nil
            && !invalid.isValid && !invalidDay.isValid && !duplicate.isValid
    }
    check("Morning overview: one current-day catch-up within four hours, no missed-day replay") {
        MorningBriefingSchedule.due(enabled, now: now.addingTimeInterval(-1), calendar: berlin) == nil
            && MorningBriefingSchedule.due(enabled, now: now.addingTimeInterval(4 * 3600), calendar: berlin) != nil
            && MorningBriefingSchedule.due(enabled, now: now.addingTimeInterval(4 * 3600 + 1), calendar: berlin) == nil
            && MorningBriefingSchedule.due(enabled, now: date(2026, 10, 24), calendar: berlin) == nil
            && MorningBriefingSchedule.due(enabled, now: date(2026, 10, 22, 7), calendar: berlin) == nil
    }
    check("Morning overview: skipped DST time advances to first valid time, repeated hour uses first occurrence") {
        var config = enabled; config.weekdays = [1]; config.hour = 2; config.minute = 30
        let spring = MorningBriefingSchedule.due(config, now: date(2026, 3, 29, 3), calendar: berlin)
        let fall = MorningBriefingSchedule.due(config, now: date(2026, 10, 25, 4), calendar: berlin)
        let iso = ISO8601DateFormatter()
        return spring?.scheduledAt == date(2026, 3, 29, 3) && spring?.day.duration == 23 * 3600
            && fall?.scheduledAt == iso.date(from: "2026-10-25T00:30:00Z") && fall?.day.duration == 25 * 3600
    }
    check("Morning overview: schedule follows the Mac timezone and civil date keys do not include the zone") {
        let tokyo = calendar("Asia/Tokyo")
        let tokyoMorning = tokyo.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 8))!
        let due = MorningBriefingSchedule.due(enabled, now: tokyoMorning, calendar: tokyo)
        return due?.key == occurrence.key && due?.timeZone == "Asia/Tokyo"
            && due?.scheduledAt == tokyoMorning && due?.scheduledAt != occurrence.scheduledAt
    }
    await checkBriefing("Morning overview: persistent claim deduplicates restarts, wake and travel, next day runs") {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MorningBriefingStore(baseDirectory: root)
        try store.configure(enabled)
        guard let claim = try store.claim(now: now, calendar: berlin), try store.finish(claim, result: empty(claim.occurrence)) else { return false }
        let reopened = try MorningBriefingStore(baseDirectory: root)
        let ny = calendar("America/New_York")
        let nyMorning = ny.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 8))!
        return try reopened.claim(now: now, calendar: berlin) == nil && reopened.claim(now: nyMorning, calendar: ny) == nil
            && reopened.latest?.isComplete == true && reopened.claim(now: date(2026, 10, 22), calendar: berlin) != nil
    }
    await checkBriefing("Morning overview: interrupted read becomes visible on restart and never automatically retries that day") {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MorningBriefingStore(baseDirectory: root, processSessionID: UUID()); try store.configure(enabled)
        guard try store.claim(now: now, calendar: berlin) != nil else { return false }
        let reopened = try MorningBriefingStore(baseDirectory: root, processSessionID: UUID())
        return try reopened.latest?.issues.first?.reason == .interrupted && reopened.latest?.checkedSources.isEmpty == true
            && reopened.claim(now: now, calendar: berlin) == nil
    }
    await checkBriefing("Morning overview: pause fences late completion and notifications") {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MorningBriefingStore(baseDirectory: root); try store.configure(enabled)
        guard let claim = try store.claim(now: now, calendar: berlin) else { return false }
        var paused = enabled; paused.enabled = false; try store.configure(paused)
        return try !store.isCurrent(claim) && !store.finish(claim, result: empty(claim.occurrence))
            && !store.allowsNotification(after: claim) && store.latest == nil
    }
    await checkBriefing("Morning overview: removing a source hides its saved facts; deleting keeps only daily dedup") {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MorningBriefingStore(baseDirectory: root); try store.configure(enabled)
        guard let claim = try store.claim(now: now, calendar: berlin), try store.finish(claim, result: empty(claim.occurrence)),
              store.allowsNotification(after: claim) else { return false }
        var narrower = enabled; narrower.sources = [tasks]; try store.configure(narrower)
        guard store.latest == nil, !store.allowsNotification(after: claim) else { return false }
        try store.delete(); try store.configure(enabled)
        return try store.latest == nil && store.claim(now: now, calendar: berlin) == nil
    }
    await checkBriefing("Morning overview: a corrupt store fails closed instead of forgetting consent or daily claims") {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try MorningBriefingStore(baseDirectory: root)
        try Data("not-a-database".utf8).write(to: root.appendingPathComponent("MorningBriefing/routine.sqlite"))
        do { _ = try MorningBriefingStore(baseDirectory: root); return false } catch { return true }
    }
    await checkBriefing("Morning overview: independent connections share one claim and opening another store preserves the live owner") {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try MorningBriefingStore(baseDirectory: root)
        let second = try MorningBriefingStore(baseDirectory: root)
        try first.configure(enabled)
        guard let claim = try first.claim(now: now, calendar: berlin),
              try second.claim(now: now, calendar: berlin) == nil else { return false }
        let third = try MorningBriefingStore(baseDirectory: root)
        let ownerPreserved = first.isCurrent(claim) && second.isCurrent(claim) && third.latest == nil
        let finished = try first.finish(claim, result: empty(claim.occurrence))
        return ownerPreserved && finished && second.latest?.isComplete == true
    }
    await checkBriefing("Morning overview: another connection's pause or delete fences stale completion and notification") {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try MorningBriefingStore(baseDirectory: root)
        let second = try MorningBriefingStore(baseDirectory: root)
        try first.configure(enabled)
        guard let claim = try first.claim(now: now, calendar: berlin) else { return false }
        var paused = enabled; paused.enabled = false; try second.configure(paused)
        guard !first.isCurrent(claim), try !first.finish(claim, result: empty(claim.occurrence)),
              !first.configuration.enabled else { return false }
        try second.configure(enabled)
        guard let next = try first.claim(now: date(2026, 10, 22), calendar: berlin),
              try first.finish(next, result: empty(next.occurrence)), first.allowsNotification(after: next) else { return false }
        try second.delete()
        return !first.allowsNotification(after: next) && first.latest == nil && !first.configuration.enabled
    }
    await checkBriefing("Morning overview: denied selected source stays partial, no unselected source is read") {
        let entry = MorningBriefingEntry(id: "e", source: work, title: "Appointment", start: now, end: now.addingTimeInterval(1800))
        let fixture = BriefingFixture(values: [work.id: .init(entries: [entry], total: 1)], failures: [tasks.id: .denied])
        let result = await MorningBriefingReader.run(configuration: enabled, occurrence: occurrence, reader: fixture, now: now, isCurrent: { true })
        let reads = await fixture.readIDs()
        return result?.entries == [entry] && result?.checkedSources == [work] && result?.issues == [.init(source: tasks, reason: .denied)]
            && result?.isComplete == false && reads == [work.id, tasks.id]
    }
    await checkBriefing("Morning overview: empty and unavailable are different checked outcomes") {
        let emptyReader = BriefingFixture()
        let unavailable = BriefingFixture(failures: [work.id: .needsAccess, tasks.id: .sourceMissing])
        let good = await MorningBriefingReader.run(configuration: enabled, occurrence: occurrence, reader: emptyReader, now: now, isCurrent: { true })
        let bad = await MorningBriefingReader.run(configuration: enabled, occurrence: occurrence, reader: unavailable, now: now, isCurrent: { true })
        return good?.entries.isEmpty == true && good?.isComplete == true && good?.checkedSources.count == 2
            && bad?.isComplete == false && bad?.checkedSources.isEmpty == true && bad?.issues.count == 2
    }
    await checkBriefing("Morning overview: source/range boundaries, duplicate filtering and actual interval overlaps are computed in code") {
        let one = MorningBriefingEntry(id: "a", source: work, title: "One", start: now, end: now.addingTimeInterval(3600))
        let two = MorningBriefingEntry(id: "b", source: work, title: "Two", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(5400))
        let adjoining = MorningBriefingEntry(id: "c", source: work, title: "Three", start: now.addingTimeInterval(5400), end: now.addingTimeInterval(7200))
        let foreign = MorningBriefingEntry(id: "private", source: .init(kind: .calendar, identifier: "unselected", title: "Private"), title: "Must not show", start: now)
        let tomorrow = MorningBriefingEntry(id: "tomorrow", source: work, title: "Tomorrow", start: occurrence.day.end)
        let tooOld = MorningBriefingEntry(id: "old", source: tasks, title: "Old", start: now.addingTimeInterval(-40 * 86400))
        let fixture = BriefingFixture(values: [work.id: .init(entries: [one, one, two, adjoining, foreign, tomorrow], total: 6),
                                               tasks.id: .init(entries: [tooOld], total: 1)])
        let result = await MorningBriefingReader.run(configuration: enabled, occurrence: occurrence, reader: fixture, now: now, isCurrent: { true })
        return result?.entries.map(\.id) == ["a", "b", "c"] && result?.entries.map(\.overlaps) == [true, true, false]
    }
    await checkBriefing("Morning overview: excessive results have explicit truncation and a hard display limit") {
        let events = (0..<120).map { MorningBriefingEntry(id: String($0), source: work, title: "Event", start: now) }
        let reminders = (0..<120).map { MorningBriefingEntry(id: String($0), source: tasks, title: "Task", start: now) }
        let fixture = BriefingFixture(values: [work.id: .init(entries: events, total: 120), tasks.id: .init(entries: reminders, total: 120)])
        let result = await MorningBriefingReader.run(configuration: enabled, occurrence: occurrence, reader: fixture, now: now, isCurrent: { true })
        return result?.truncated == true && result?.entries.count == 100
    }
    await checkBriefing("Morning overview: source edit during a slow read prevents all later reads and result publication") {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MorningBriefingStore(baseDirectory: root); try store.configure(enabled)
        guard let claim = try store.claim(now: now, calendar: berlin) else { return false }
        let fixture = BriefingFixture(hold: true)
        let config = enabled
        let task = Task { await MorningBriefingReader.run(configuration: config, occurrence: occurrence, reader: fixture, now: now,
            isCurrent: { await MainActor.run { store.isCurrent(claim) } }) }
        await fixture.waitForRead()
        var changed = enabled; changed.sources = [tasks]; try store.configure(changed)
        await fixture.release()
        let result = await task.value
        let reads = await fixture.readIDs()
        return result == nil && reads == [work.id] && store.latest == nil
    }
    await checkBriefing("Morning overview: cancellation discards a late native callback before the next source") {
        let fixture = BriefingFixture(hold: true)
        let config = enabled
        let task = Task { await MorningBriefingReader.run(configuration: config, occurrence: occurrence, reader: fixture, now: now, isCurrent: { true }) }
        await fixture.waitForRead(); task.cancel(); await fixture.release()
        let result = await task.value
        let reads = await fixture.readIDs()
        return result == nil && reads == [work.id]
    }
}
