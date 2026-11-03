import Foundation

/// Returns the first answer without awaiting an operation that ignores cancellation.
public func firstAnswer<T: Sendable>(within seconds: TimeInterval, fallback: T,
                                     _ operation: @escaping @Sendable () async -> T) async -> T {
    let race = AnswerRace<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            race.install(continuation, fallback: fallback)
            let work = Task.detached { race.finish(await operation()) }
            let timer = Task.detached {
                do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
                race.finish(fallback)
            }
            race.tasks(work, timer)
        }
    } onCancel: { race.finish(fallback) }
}

private final class AnswerRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var finished = false
    private var workers: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T, Never>, fallback: T) {
        let cancelled = lock.withLock {
            if finished { return true }
            self.continuation = continuation
            return false
        }
        if cancelled { continuation.resume(returning: fallback) }
    }

    func tasks(_ work: Task<Void, Never>, _ timer: Task<Void, Never>) {
        let cancel = lock.withLock {
            if finished { return true }
            workers = [work, timer]
            return false
        }
        if cancel { work.cancel(); timer.cancel() }
    }

    func finish(_ value: T) {
        let result = lock.withLock { () -> (CheckedContinuation<T, Never>?, [Task<Void, Never>]) in
            guard !finished else { return (nil, []) }
            finished = true
            defer { continuation = nil; workers = [] }
            return (continuation, workers)
        }
        result.1.forEach { $0.cancel() }
        result.0?.resume(returning: value)
    }
}

/// Shared by callback APIs which may deliver more than one result.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
    func resume(_ value: T) {
        let c = lock.withLock { defer { cont = nil }; return cont }
        c?.resume(returning: value)
    }
}
