import AppKit
import Combine
import PippaCore

/// The person's own online service behind Pippa's approval. One broker (`PippaOnlineProxy`) per app run and connection,
/// access token per app run, only in the environment of Pippa's Pi. Before a request that leaves the Mac, the conversation
/// shows a card (`OnlineAskCard`) with exactly what would go along. Rules (one card per message, newly shown items,
/// Pi's retry, "Auf diesem Mac") in
/// `PippaOnlineDesk`.
@MainActor
final class PippaOnlineService: ObservableObject {
    static let shared = PippaOnlineService()

    typealias Decision = PippaOnlineDesk.Decision

    /// The open card (at most one).
    @Published private(set) var ask: PippaOnlineAsk?
    let desk = PippaOnlineDesk()
    private var proxy: PippaOnlineProxy?
    /// What went out in the running answer (or was declined); the broker writes into it off the main thread.
    nonisolated let records = Records()

    final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [PippaOnlineRecord] = []
        func append(_ record: PippaOnlineRecord) { lock.withLock { items.append(record) } }
        func take() -> [PippaOnlineRecord] { lock.withLock { defer { items = [] }; return items } }
        /// Service of a declined request in this answer, without collecting anything.
        func peekDeclined() -> String? { lock.withLock { items.first { $0.outcome == .declined }?.service } }
    }

    init() {
        desk.onOpen = { [weak self] ask in
            self?.ask = ask
            if let ask {
                NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: Self.title(ask), .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
        desk.switchToLocal = { onWork in await PiRPCChat.shared.switchTurnToLocal(onWork: onWork) }
    }

    /// Broker for this connection (starts it if needed; another connection ends the old one).
    /// Delivers port and access token for models.json and Pi's environment. Port taken → one new try.
    func endpoint(for connection: ModelConnection, support: URL) async throws -> (port: Int, token: String) {
        if let proxy, proxy.connection == connection, proxy.port != 0 { return (Int(proxy.port), proxy.token) }
        proxy?.stop()
        proxy = nil
        var port = PiOnlineProvider.stablePort(support: support)
        for attempt in 0..<2 {
            let fresh = try makeProxy(connection, port: port)
            do {
                try await fresh.start()
                proxy = fresh
                return (Int(fresh.port), fresh.token)
            } catch {
                fresh.stop()
                DiagnosticsLog.shared.event("online-vermittler-fehler", ["versuch": String(attempt)])
                guard attempt == 0 else { throw error }
                port = PiOnlineProvider.stablePort(support: support, avoid: port)
            }
        }
        throw PippaOnlineProxyError.badPort
    }

    private func makeProxy(_ connection: ModelConnection, port: Int) throws -> PippaOnlineProxy {
        let id = connection.id
        let records = self.records
        // A service on this Mac: nothing leaves the Mac, no card and no "Online gefragt" line.
        let local = connection.isLocal
        return try PippaOnlineProxy(
            connection: connection, port: port, needsApproval: !connection.isLocal,
            credential: { try ModelCredentialStore.read(id) },
            decide: { outgoing in await PippaOnlineService.shared.desk.decide(outgoing) },
            onRecord: { if !local { records.append($0) } })
    }

    /// Connection changed or removed: approvals expire, the broker ends (the next Pi start sets it up anew).
    func reset() {
        desk.reset()
        proxy?.stop()
        proxy = nil
    }

    func stop() { proxy?.stop(); proxy = nil }

    /// An answer begins: conversation and shown items for the card and the approvals.
    func beginTurn(conversation: String, shown: [URL], onWork: WorkEventHandler?) {
        _ = records.take()
        desk.begin(.init(conversation: conversation, shown: shown, onWork: onWork))
    }

    /// Answer over: an open card counts as "No". Delivers this answer's receipt lines.
    func endTurn() -> [ActionReceipt.Item] {
        desk.end()
        return PippaOnlineRecord.receiptItems(records.take())
    }

    /// Card buttons.
    func answer(_ decision: Decision) { desk.answer(decision) }

    nonisolated static func title(_ ask: PippaOnlineAsk) -> String {
        T("May I ask %@ for this?", table: "App", ask.service)
    }
}
