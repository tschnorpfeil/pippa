import Foundation

/// One result handed from work that must run to its end (an online turn's credential renewal, which has to be stored)
/// to a waiter that may stop waiting first (Stop). The waiter returns at once when cancelled; a result that arrives
/// after that goes to `orphan` (removing a private folder nobody will use), never to a later waiter.
public final class Handoff<Value: Sendable>: @unchecked Sendable {
    private enum State { case waiting(CheckedContinuation<Value?, Never>?), delivered(Value), closed }
    private let lock = NSLock()
    private var state = State.waiting(nil)
    private let orphan: @Sendable (Value) -> Void

    public init(orphan: @escaping @Sendable (Value) -> Void) { self.orphan = orphan }

    /// From the work, exactly once.
    public func deliver(_ value: Value) {
        let waiter: CheckedContinuation<Value?, Never>?? = lock.withLock {
            switch state {
            case .waiting(let continuation):
                state = continuation == nil ? .delivered(value) : .closed
                return .some(continuation)
            case .delivered, .closed:
                return .none
            }
        }
        switch waiter {
        case .some(.some(let continuation)): continuation.resume(returning: value)
        case .some(.none): break
        case .none: orphan(value)
        }
    }

    /// The result, or `CancellationError` as soon as the waiting task is cancelled. Call once.
    public func value() async throws -> Value {
        let value: Value? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: Value?? = lock.withLock {
                    switch state {
                    case .waiting: state = .waiting(continuation); return .none
                    case .delivered(let value): state = .closed; return .some(value)
                    case .closed: return .some(nil)
                    }
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let (waiter, dropped): (CheckedContinuation<Value?, Never>?, Value?) = lock.withLock {
                defer { state = .closed }
                switch state {
                case .waiting(let continuation): return (continuation, nil)
                case .delivered(let value): return (nil, value)
                case .closed: return (nil, nil)
                }
            }
            waiter?.resume(returning: nil)
            if let dropped { orphan(dropped) }
        }
        guard let value else { throw CancellationError() }
        return value
    }
}
