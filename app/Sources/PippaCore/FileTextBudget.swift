import Foundation

/// Optional searchable text must not hold a usable file hostage. One monotonic budget is shared by all
/// images in a conversion; expiry also prevents later pages from starting more optional work.
public final class FileTextBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let seconds: TimeInterval
    private var end: TimeInterval?
    private var skipped = false

    public init(seconds: TimeInterval = 5) { self.seconds = max(0, seconds) }

    public var didSkip: Bool { lock.withLock { skipped } }

    public func markSkipped() { lock.withLock { skipped = true } }

    private func remaining() -> TimeInterval {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            if end == nil { end = now + seconds }
            return max(0, (end ?? now) - now)
        }
    }

    /// Executes recognition on GCD. The synchronous caller still waits in short intervals, up to the shared
    /// deadline, so cancellation is observed promptly; this is not a nonblocking async API. Expired results are
    /// discarded forever. `cancel` must be safe to call concurrently with `work`.
    public func run<Value: Sendable>(cancel: @escaping @Sendable () -> Void,
                                    work: @escaping @Sendable () -> Value) throws -> Value? {
        try Task.checkCancellation()
        guard remaining() > 0 else { markSkipped(); cancel(); return nil }
        let result = FileTextResult<Value>(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(work())
            done.signal()
        }
        while true {
            if Task.isCancelled { cancel(); throw CancellationError() }
            let left = remaining()
            guard left > 0 else { markSkipped(); cancel(); return nil }
            if done.wait(timeout: .now() + min(0.05, left)) == .success {
                try Task.checkCancellation()
                return result.get()
            }
        }
    }
}

private final class FileTextResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func get() -> Value? { lock.withLock { value } }
}
