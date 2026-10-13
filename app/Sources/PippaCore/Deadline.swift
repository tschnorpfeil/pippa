import Foundation

/// The operation's answer, or `fallback` once `seconds` have passed. A hanging operation is left behind, never awaited:
/// unlike a task group, nothing here waits for a child that does not come back.
public func firstAnswer<T: Sendable>(within seconds: TimeInterval, fallback: T,
                                     _ operation: @escaping @Sendable () async -> T) async -> T {
    await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        let once = ResumeOnce(cont)
        Task.detached { once.resume(await operation()) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.resume(fallback) }
    }
}

/// Resumes a continuation with the first value only.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
    func resume(_ value: T) {
        let c: CheckedContinuation<T, Never>? = lock.withLock { defer { cont = nil }; return cont }
        c?.resume(returning: value)
    }
}
