import Foundation

/// The card in front of the person's own online service, without UI (the app shows `open`, checks answer themselves).
/// Rules:
///
/// 1. "Only this time" applies to the person's whole message, i.e. all model rounds of this answer (a "request"
///    = the person's request). A new card in the same answer only if shown things went along that were not on
///    the approved card.
/// 2. "For this conversation" applies to the conversation, connection and exactly what was shown (`PippaOnlineGrants`).
/// 3. If Pi asks again while the card is open (Pi's time limit of about 300 s on response headers, then a new
///    attempt), the new request attaches to the same card: no second card, same answer.
/// 4. "On this Mac": `switchToLocal` switches Pi to `pippa-local` for this answer; all further requests of this
///    answer to the proxy get `.local`, nothing goes out.
///
/// Without a running answer (no card possible) the result is "No".
@MainActor
public final class PippaOnlineDesk {
    public enum Decision: Sendable, Equatable { case once, conversation, local, deny }

    public struct Turn {
        public let id = UUID()
        public var conversation: String
        public var shown: [URL]
        public var onWork: WorkEventHandler?
        public init(conversation: String, shown: [URL], onWork: WorkEventHandler? = nil) {
            self.conversation = conversation; self.shown = shown; self.onWork = onWork
        }
    }

    /// The open card (at most one); `onOpen` reports every change.
    public private(set) var open: PippaOnlineAsk?
    public var onOpen: (PippaOnlineAsk?) -> Void = { _ in }
    /// Switches Pi to the on-device AI for the running answer; `false` → like "No".
    public var switchToLocal: (WorkEventHandler?) async -> Bool = { _ in false }
    /// Recordings and checks only: answers immediately instead of the person.
    public var answerAutomatically: ((PippaOnlineAsk) -> Decision)?
    /// How many cards were shown (for checks).
    public private(set) var cardsShown = 0

    private var turn: Turn?
    private var grants = PippaOnlineGrants()
    private var waiters: [CheckedContinuation<Decision, Never>] = []
    private var openTurn: UUID?
    private var localTurn: UUID?

    public init() {}

    public func begin(_ turn: Turn) {
        if let old = self.turn { end(old.id) }
        self.turn = turn
    }

    /// Answer over: an open card counts as "No", "Only this time" expires.
    public func end(_ id: UUID? = nil) {
        guard let turn, id == nil || id == turn.id else { return }
        grants.endTurn(turn.id.uuidString)
        self.turn = nil
        localTurn = nil
        answer(.deny)
    }

    /// Connection changed or removed: all grants expire.
    public func reset() {
        grants.removeAll()
        answer(.deny)
    }

    /// From the proxy, per request.
    public func decide(_ outgoing: PippaOnlineOutgoing) async -> PippaOnlineVerdict {
        guard let turn else { return .deny }
        if localTurn == turn.id { return .local }
        if grants.allows(conversation: turn.conversation, connection: outgoing.connection, shown: turn.shown) { return .allow }
        let ask = PippaOnlineAsk.make(outgoing, shown: turn.shown)
        if grants.turnAllows(turn.id.uuidString, shown: ask.shownIncluded) { return .allow }
        let decision: Decision
        if let open, openTurn == turn.id, Set(ask.shownIncluded).isSubset(of: Set(open.shownIncluded)) {
            decision = await withCheckedContinuation { waiters.append($0) }
        } else {
            answer(.deny)
            turn.onWork?(.phase(.waitingForPerson))
            open = ask
            openTurn = turn.id
            cardsShown += 1
            onOpen(ask)
            decision = await withCheckedContinuation { continuation in
                if let answerAutomatically {
                    open = nil; openTurn = nil; onOpen(nil)
                    continuation.resume(returning: answerAutomatically(ask))
                } else {
                    waiters.append(continuation)
                }
            }
        }
        guard self.turn?.id == turn.id else { return .deny }
        switch decision {
        case .deny: return .deny
        case .local:
            if localTurn == turn.id { return .local }
            guard await switchToLocal(turn.onWork), self.turn?.id == turn.id else { return .deny }
            localTurn = turn.id
            return .local
        case .once, .conversation:
            if decision == .conversation { grants.grant(conversation: turn.conversation, connection: outgoing.connection, shown: turn.shown) }
            grants.approveTurn(turn.id.uuidString, shown: ask.shownIncluded)
            turn.onWork?(.phase(.writing))
            return .allow
        }
    }

    /// The card's buttons. Applies to the open card and every request attached to it.
    public func answer(_ decision: Decision) {
        if open != nil { open = nil; onOpen(nil) }
        openTurn = nil
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume(returning: decision) }
    }
}
