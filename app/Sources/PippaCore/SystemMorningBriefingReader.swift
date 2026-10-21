@preconcurrency import EventKit
import Foundation

/// A separate adapter prevents the scheduled routine from acquiring the interactive agent's
/// broader capabilities. Every query names one selected calendar ID and rechecks current access.
public actor SystemMorningBriefingReader: MorningBriefingReading {
    private let store = EKEventStore()
    public init() {}

    private func requireAccess(_ kind: MorningBriefingSource.Kind) throws {
        switch EKEventStore.authorizationStatus(for: kind == .calendar ? .event : .reminder) {
        case .fullAccess: return
        case .notDetermined, .writeOnly: throw MorningBriefingReadFailure.needsAccess
        default: throw MorningBriefingReadFailure.denied
        }
    }

    public func sources(for kind: MorningBriefingSource.Kind) async throws -> [MorningBriefingSource] {
        try requireAccess(kind)
        try Task.checkCancellation()
        store.reset()
        return store.calendars(for: kind == .calendar ? .event : .reminder).map {
            MorningBriefingSource(kind: kind, identifier: $0.calendarIdentifier, title: String($0.title.prefix(160)))
        }.sorted { ($0.title, $0.identifier) < ($1.title, $1.identifier) }
    }

    public func read(_ source: MorningBriefingSource, day: DateInterval, limit: Int) async throws -> MorningBriefingRead {
        try requireAccess(source.kind)
        try Task.checkCancellation()
        guard day.duration > 0, day.duration <= 26 * 3600, limit > 0, limit <= 100 else {
            throw MorningBriefingReadFailure.unavailable
        }
        store.reset()
        let type: EKEntityType = source.kind == .calendar ? .event : .reminder
        guard let selected = store.calendars(for: type).first(where: { $0.calendarIdentifier == source.identifier }) else {
            throw MorningBriefingReadFailure.sourceMissing
        }
        var currentSource = source; currentSource.title = String(selected.title.prefix(160))
        if source.kind == .calendar {
            let predicate = store.predicateForEvents(withStart: day.start, end: day.end, calendars: [selected])
            let events = store.events(matching: predicate).filter { event in
                event.status != .canceled && !(event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false)
            }.sorted { $0.startDate < $1.startDate }
            try requireAccess(source.kind)
            try Task.checkCancellation()
            let entries = events.prefix(limit).map { event in
                MorningBriefingEntry(id: event.eventIdentifier ?? event.calendarItemIdentifier, source: currentSource,
                    title: event.title ?? "", start: event.startDate, end: event.endDate, allDay: event.isAllDay)
            }
            return MorningBriefingRead(entries: Array(entries), total: events.count)
        }
        // A bounded past window keeps old overdue tasks useful without scanning years of lists.
        let earliest = day.start.addingTimeInterval(-30 * 86400)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: earliest, ending: day.end, calendars: [selected])
        let sourceValue = currentSource
        let wait = MorningReminderWait(store: store)
        let result: MorningBriefingRead = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait.begin(continuation)
                if Task.isCancelled { wait.cancel(); return }
                let request = store.fetchReminders(matching: predicate) { reminders in
                    guard let reminders else { wait.finish(.failure(MorningBriefingReadFailure.unavailable)); return }
                    let entries = reminders.compactMap { reminder -> MorningBriefingEntry? in
                        guard !reminder.isCompleted, let components = reminder.dueDateComponents,
                              let due = (components.calendar ?? Calendar.current).date(from: components),
                              due >= earliest, due < day.end else { return nil }
                        return MorningBriefingEntry(id: reminder.calendarItemIdentifier, source: sourceValue,
                            title: reminder.title ?? "", start: due, allDay: components.hour == nil)
                    }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
                    wait.finish(.success(MorningBriefingRead(entries: Array(entries.prefix(limit)), total: entries.count)))
                }
                wait.install(request)
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    wait.cancel()
                }
            }
        } onCancel: { wait.cancel() }
        try requireAccess(source.kind)
        try Task.checkCancellation()
        return result
    }
}

/// EventKit callbacks can arrive after cancellation. Resume once and cancel a request that is
/// installed after a racing pause. The five-second deadline also covers a callback that never arrives.
private final class MorningReminderWait: @unchecked Sendable {
    private let store: EKEventStore
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MorningBriefingRead, Error>?
    private var request: Any?
    private var finished = false
    init(store: EKEventStore) { self.store = store }
    func begin(_ continuation: CheckedContinuation<MorningBriefingRead, Error>) {
        let cancelled = lock.withLock { if finished { return true }; self.continuation = continuation; return false }
        if cancelled { continuation.resume(throwing: MorningBriefingReadFailure.unavailable) }
    }
    func install(_ request: Any) {
        let cancelled = lock.withLock { if finished { return true }; self.request = request; return false }
        if cancelled { store.cancelFetchRequest(request) }
    }
    func finish(_ result: Result<MorningBriefingRead, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<MorningBriefingRead, Error>? in
            guard !finished else { return nil }
            finished = true; defer { continuation = nil; request = nil }; return continuation
        }
        pending?.resume(with: result)
    }
    func cancel() {
        let pending = lock.withLock { () -> (CheckedContinuation<MorningBriefingRead, Error>?, Any?)? in
            guard !finished else { return nil }
            finished = true; defer { continuation = nil; request = nil }; return (continuation, request)
        }
        if let request = pending?.1 { store.cancelFetchRequest(request) }
        pending?.0?.resume(throwing: MorningBriefingReadFailure.unavailable)
    }
}
