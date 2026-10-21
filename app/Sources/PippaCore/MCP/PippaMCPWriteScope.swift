import Foundation

/// Native writes belong to the answer that requested them, even if another answer starts while macOS is waiting.
/// Cancellation and dispatch share this lock. Once dispatch began, cancellation cannot promise an OS rollback.
public final class PippaMCPWriteScope: @unchecked Sendable {
    public struct Pending: Sendable, Equatable {
        public let id: UUID
        public let action: String
        public let dispatched: Bool
    }
    public struct Snapshot: Sendable, Equatable {
        public let receipts: [PippaMCPWriteReceipt]
        public let pending: [Pending]
        public let cancelled: Bool
        /// Provisional rows use the same operation ID as the eventual final receipt, so the UI replaces them.
        public var items: [ActionReceipt.Item] {
            receipts.map(\.item) + pending.compactMap { pending in
                guard pending.dispatched || cancelled else { return nil }
                return ActionReceipt.Item(action: pending.action, outcome: pending.dispatched ? "unclear" : "cancelled",
                                          reason: pending.dispatched ? "pending" : "stopped", operationID: pending.id)
            }
        }
    }
    private struct State {
        var action: String
        var dispatched = false
        var cancelled = false
    }
    public let turnID: UUID?
    private let lock = NSLock()
    private var cancelled = false
    private var operations: [UUID: State] = [:]
    private var receipts: [PippaMCPWriteReceipt] = []
    private var observer: (@Sendable (PippaMCPWriteReceipt) -> Void)?

    /// No turn ID: an independent native action, such as the person's Save Draft button.
    public init(turnID: UUID? = nil) { self.turnID = turnID }

    public func cancel() { lock.withLock { cancelled = true } }
    /// Future final outcomes, delivered after journaling and outside the lock, including after the answer ends.
    public func observeReceipts(_ observer: @escaping @Sendable (PippaMCPWriteReceipt) -> Void) {
        lock.withLock { self.observer = observer }
    }

    public var snapshot: Snapshot {
        lock.withLock {
            Snapshot(receipts: receipts, pending: operations.map { Pending(id: $0.key, action: $0.value.action, dispatched: $0.value.dispatched) }
                .sorted { $0.id.uuidString < $1.id.uuidString }, cancelled: cancelled)
        }
    }

    /// Wait briefly for dispatched calls to report their actual outcome. A hung native call cannot hold up Stop.
    public func settle(within seconds: TimeInterval) async -> Snapshot {
        let deadline = ContinuousClock.now + .seconds(max(0, seconds))
        while !snapshot.pending.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return snapshot
    }

    public func lease(action: String) -> PippaMCPWriteLease {
        let id = UUID()
        lock.withLock { operations[id] = State(action: action) }
        return PippaMCPWriteLease(id: id, scope: self)
    }

    fileprivate func check(_ id: UUID, dispatch: Bool = false) throws {
        try lock.withLock {
            guard !cancelled, var state = operations[id], !state.cancelled else { throw CancellationError() }
            if dispatch { state.dispatched = true; operations[id] = state }
        }
    }
    fileprivate func cancel(_ id: UUID) { lock.withLock { operations[id]?.cancelled = true } }
    fileprivate func dispatched(_ id: UUID) -> Bool { lock.withLock { operations[id]?.dispatched == true } }
    fileprivate func noMutation(_ id: UUID) { lock.withLock { operations[id]?.dispatched = false } }
    fileprivate func finish(_ id: UUID, receipt: PippaMCPWriteReceipt?) -> PippaMCPWriteReceipt? {
        let recorded: (PippaMCPWriteReceipt, (@Sendable (PippaMCPWriteReceipt) -> Void)?)? = lock.withLock {
            guard operations.removeValue(forKey: id) != nil, var receipt else { return nil }
            receipt.turnID = turnID; receipt.operationID = id
            receipts.append(receipt)
            return (receipt, observer)
        }
        guard let recorded else { return nil }
        recorded.1?(recorded.0)
        return recorded.0
    }
}

/// One tool call. TaskLocal carries it through native integration APIs; the Apple Events queue captures it explicitly.
public final class PippaMCPWriteLease: @unchecked Sendable {
    @TaskLocal public static var current: PippaMCPWriteLease?
    public let id: UUID
    private let scope: PippaMCPWriteScope
    fileprivate init(id: UUID, scope: PippaMCPWriteScope) { self.id = id; self.scope = scope }
    public var hasDispatched: Bool { scope.dispatched(id) }
    public func cancel() { scope.cancel(id) }
    public func check() throws {
        if Task.isCancelled { cancel() }
        try scope.check(id)
    }
    /// Immediately before the synchronous native save or mutating Apple Event. Never mark queued work as dispatched.
    public func beginDispatch() throws {
        if Task.isCancelled { cancel() }
        try scope.check(id, dispatch: true)
    }
    /// The native app explicitly confirmed this attempt created nothing (for example a stale Mail locator).
    func confirmNoMutation() { scope.noMutation(id) }
    func finish(_ receipt: PippaMCPWriteReceipt?) -> PippaMCPWriteReceipt? { scope.finish(id, receipt: receipt) }
}

/// Captured before an HTTP request is scheduled. It never rebinds to a later active answer.
public struct PippaMCPRequestContext: Sendable {
    let turn: PippaMCPTurn?
    let writes: PippaMCPWriteScope
    let front: FrontApp?
}
