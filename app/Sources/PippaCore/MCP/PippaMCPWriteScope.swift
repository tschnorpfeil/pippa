import Foundation

/// Native writes belong to the answer that requested them, even if another answer starts while macOS is waiting.
/// Cancellation and dispatch share this lock. Once dispatch began, cancellation cannot promise an OS rollback.
public final class PippaMCPWriteScope: @unchecked Sendable {
    public struct Pending: Sendable, Equatable {
        public let id: UUID
        public let action: String
        public let dispatched: Bool
        public let nativeRevision: Int?
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
                                          reason: pending.dispatched ? "pending" : "stopped", operationID: pending.id, nativeRevision: pending.nativeRevision)
            }
        }
    }
    private struct State {
        var action: String
        var operationID: UUID?
        var nativeRevision: Int?
        var dispatched = false
        var cancelled = false
    }
    public let turnID: UUID?
    public let origin: PippaMCPOrigin?
    public let allowsNativeWrites: Bool
    private let lock = NSLock()
    private var cancelled = false
    private var operations: [UUID: State] = [:]
    private var receipts: [PippaMCPWriteReceipt] = []
    private var observer: (@Sendable (PippaMCPWriteReceipt) -> Void)?

    /// No turn ID: an independent native action, such as the person's Save Draft button.
    public init(turnID: UUID? = nil, origin: PippaMCPOrigin? = nil, allowsNativeWrites: Bool = true) {
        self.turnID = turnID; self.origin = origin; self.allowsNativeWrites = allowsNativeWrites
    }

    public func cancel() { lock.withLock { cancelled = true } }
    /// Future final outcomes, delivered after journaling and outside the lock, including after the answer ends.
    public func observeReceipts(_ observer: @escaping @Sendable (PippaMCPWriteReceipt) -> Void) {
        lock.withLock { self.observer = observer }
    }

    public var snapshot: Snapshot {
        lock.withLock {
            Snapshot(receipts: receipts, pending: operations.map { Pending(id: $0.value.operationID ?? $0.key, action: $0.value.action, dispatched: $0.value.dispatched, nativeRevision: $0.value.nativeRevision) }
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
            guard allowsNativeWrites else { throw PippaMCPWritePolicyDenied() }
            guard !cancelled, var state = operations[id], !state.cancelled else { throw CancellationError() }
            if dispatch { state.dispatched = true; operations[id] = state }
        }
    }
    fileprivate func bind(_ id: UUID, operationID: UUID, nativeRevision: Int?) {
        lock.withLock {
            if operations[id]?.dispatched == false {
                operations[id]?.operationID = operationID
                operations[id]?.nativeRevision = nativeRevision
            }
        }
    }
    fileprivate func cancel(_ id: UUID) { lock.withLock { operations[id]?.cancelled = true } }
    fileprivate func dispatched(_ id: UUID) -> Bool { lock.withLock { operations[id]?.dispatched == true } }
    fileprivate func noMutation(_ id: UUID) { lock.withLock { operations[id]?.dispatched = false } }
    fileprivate func finish(_ id: UUID, receipt: PippaMCPWriteReceipt?) -> PippaMCPWriteReceipt? {
        let recorded: (PippaMCPWriteReceipt, (@Sendable (PippaMCPWriteReceipt) -> Void)?)? = lock.withLock {
            guard let state = operations.removeValue(forKey: id), var receipt else { return nil }
            receipt.turnID = receipt.turnID ?? turnID; receipt.operationID = receipt.operationID ?? state.operationID ?? id
            receipt.nativeRevision = receipt.nativeRevision ?? state.nativeRevision
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
    public var origin: PippaMCPOrigin? { scope.origin }
    public var turnID: UUID? { scope.turnID }
    public var hasDispatched: Bool { scope.dispatched(id) }
    /// Bind a durable admitted operation before permission waits; retries retain one provisional/final receipt ID.
    func bindOperationID(_ operationID: UUID, nativeRevision: Int?) { scope.bind(id, operationID: operationID, nativeRevision: nativeRevision) }
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

/// The trusted app scope permits producing a draft, but no native mutation.
public struct PippaMCPWritePolicyDenied: Error, Sendable {}
