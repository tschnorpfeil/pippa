import EventKit
import Foundation

extension EventKitBridge {
    /// Only the original list and our UUID marker establish recovery identity. Titles/due dates are never dedupe keys
    /// in the native store. No permission request, no mutation, and an incomplete fetch is not evidence of absence.
    func lookupReminder(marker: URL, target: NativeReminderTarget, identifier: String?) async -> NativeReminderLookup {
        guard access(.reminders) == .granted else { return .unavailable }
        let s = store
        guard let list = s.calendar(withIdentifier: target.identifier), list.allowedEntityTypes.contains(.reminder) else { return .unavailable }
        let wait = ReminderLookupWait(store: s)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                wait.begin(continuation)
                if Task.isCancelled { wait.cancel(); return }
                let predicate = s.predicateForReminders(in: [list])
                let request = s.fetchReminders(matching: predicate) { [self] reminders in
                    guard let reminders, reminders.count <= 10_000 else { wait.finish(.unavailable); return }
                    let matches = reminders.filter { $0.url == marker && $0.calendar.calendarIdentifier == target.identifier }
                    guard matches.count == 1, let reminder = matches.first else {
                        wait.finish(matches.isEmpty ? .notFound : .ambiguous); return
                    }
                    // A known native ID changing is not silently accepted as a new identity.
                    if let identifier, identifier != reminder.calendarItemIdentifier { wait.finish(.unavailable); return }
                    let item = CreatedItem(integration: .reminders, identifier: reminder.calendarItemIdentifier,
                                           modified: reminder.lastModifiedDate, fingerprint: fingerprint(reminder))
                    wait.finish(.found(HostWrite(item: item, container: reminder.calendar.title, containerMatched: target.matched,
                                                containerIdentifier: target.identifier)))
                }
                wait.install(request)
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    wait.cancel()
                }
            }
        } onCancel: { wait.cancel() }
    }
}

/// EventKit can return after cancellation. Complete once, and cancel a request installed after a racing Stop.
private final class ReminderLookupWait: @unchecked Sendable {
    let store: EKEventStore
    let lock = NSLock()
    var continuation: CheckedContinuation<NativeReminderLookup, Never>?
    var request: Any?
    var finished = false
    init(store: EKEventStore) { self.store = store }
    func begin(_ continuation: CheckedContinuation<NativeReminderLookup, Never>) {
        let cancelled = lock.withLock { if finished { return true }; self.continuation = continuation; return false }
        if cancelled { continuation.resume(returning: .unavailable) }
    }
    func install(_ request: Any) {
        let cancelled = lock.withLock { if finished { return true }; self.request = request; return false }
        if cancelled { store.cancelFetchRequest(request) }
    }
    func finish(_ result: NativeReminderLookup) {
        let pending = lock.withLock { () -> CheckedContinuation<NativeReminderLookup, Never>? in
            guard !finished else { return nil }
            finished = true; defer { continuation = nil; request = nil }; return continuation
        }
        pending?.resume(returning: result)
    }
    func cancel() {
        let pending = lock.withLock { () -> (CheckedContinuation<NativeReminderLookup, Never>?, Any?)? in
            guard !finished else { return nil }
            finished = true; defer { continuation = nil; request = nil }; return (continuation, request)
        }
        if let request = pending?.1 { store.cancelFetchRequest(request) }
        pending?.0?.resume(returning: .unavailable)
    }
}
