import AppKit
import PiRPC
import PippaCore

/// Pippa's MCP server for the app's own Pi processes. Starts at the first Pi start,
/// one endpoint and key per Pi process, revoked on Stop or incomplete completion. Reading happens here in the Pippa process, so every
/// system prompt (calendar, reminders, automation for Mail/Excel) names Pippa.
///
/// With `PIPPA_DEMO=1` only invented data (never real apps). `PIPPA_PI_MCP`: path to the extension, otherwise `pippa-mcp.ts`
/// in Pippa's extensions folder. Pi conversations require this endpoint; direct native utilities do not.
@MainActor
enum PippaMCPService {
    private static var server: PippaMCPServer?
    private static var startingServer: PippaMCPServer?
    private static var generation: UInt64 = 0

    /// What Pippa's readers read in this app run, in order; PiRPCChat collects it per answer.
    nonisolated static let readNotes = Notes<PippaMCPReadNote>()
    /// What Pippa's writers did (calendar, reminders, mail drafts, prepared files), for the receipt under the answer.
    nonisolated static let writeNotes = Notes<PippaMCPWriteReceipt>()

    /// Binds the MCP tools to one answer: writes outside an answer are refused (`requireActiveWriteTurn`).
    static func begin(_ turn: PippaMCPTurn) { currentHost.turns.begin(turn) }
    static func end(_ turn: PippaMCPTurn) { currentHost.turns.end(turn); turn.cancelWrites() }

    /// Photos and PDFs into one PDF without the model: the same tool Pi calls, started by a button.
    static func makePDF(_ files: [URL]) async -> (card: ResultCard?, text: String, failed: Bool) {
        let turn = PippaMCPTurn()
        begin(turn)
        defer { end(turn) }
        let result = await PippaMCPFilePreparation(host: currentHost, turn: turn, scope: turn.writes).call(["paths": files.map(\.path)])
        let note = PippaMCPFilePreparation.readNote(for: result, turnID: turn.id)
        return (note.card, note.line, result.isError)
    }

    final class Notes<Note: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var notes: [Note] = []
        func append(_ note: Note) { lock.withLock { notes.append(note) } }
        func take() -> [Note] { lock.withLock { defer { notes = [] }; return notes } }
    }

    enum EndpointFailure: Error, Equatable { case extensionMissing, serverUnavailable }

    /// Only entry point from `PiRPCChat`: starts the server if needed; address, key and extension for
    /// `PippaPiLaunch.configuration(…, mcp:)`, which turns them into `addMCP`. Failure stops Pi admission before any user prompt.
    static func endpoint(extensions: URL) async throws -> (endpoint: PippaPiLaunch.MCPEndpoint, extension: URL) {
        let file = ProcessInfo.processInfo.environment["PIPPA_PI_MCP"] ?? extensions.appendingPathComponent("pippa-mcp.ts").path
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: file) else { throw EndpointFailure.extensionMissing }
        let running = try await started()
        return (.init(url: running.url, token: running.token), URL(fileURLWithPath: file))
    }

    /// An abandoned Pi process must never borrow a later answer's authority.
    static func invalidateEndpoint() {
        generation &+= 1
        server?.revoke()
        startingServer?.revoke()
        server = nil; startingServer = nil
    }

    /// Before the first system prompt when reading, Pippa's own sentence (texts like the permission card of the
    /// connections, `PermissionContent`). "Erlauben …" → then the Mac asks; "Später" → nothing asked, nothing read.
    static func explain(_ subject: PippaMCPAccessSubject, _ sentence: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = T("Just a quick question.", table: "Settings")
        alert.informativeText = sentence + "\n\n" + T("Your Mac will ask you in a moment.", table: "App")
        alert.addButton(withTitle: T("Allow…", table: "Settings"))
        alert.addButton(withTitle: T("Later", table: "Settings"))
        return alert.runModal() == .alertFirstButtonReturn
    }


    /// The server's integrations (with PIPPA_DEMO=1 a substitute appointment lives only in this substitute's memory).
    private static var host: PippaMCPHost?

    private static var currentHost: PippaMCPHost {
        if let host { return host }
        var fresh: PippaMCPHost = ProcessInfo.processInfo.environment["PIPPA_DEMO"] == "1" ? .demo() : .system()
        fresh.onRead = { note in readNotes.append(note) }
        fresh.onWrite = { receipt in writeNotes.append(receipt) }
        fresh.requireActiveWriteTurn = true
        fresh.explainAccess = { subject, sentence in await explain(subject, sentence) }
        host = fresh
        return fresh
    }



    /// Undo from the receipt row: removes the event or reminder only if it is unchanged since Pippa added it.
    static func undo(_ receipt: PippaMCPWriteReceipt) async -> PippaMCPWriteReceipt { await currentHost.undo(receipt) }

    /// Bring mail to the front ("Entwurf öffnen"). With PIPPA_DEMO=1 nothing (no real apps).
    static func showMail() async {
        guard ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1",
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Integration.mail.bundleIdentifier) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private static func started() async throws -> PippaMCPServer {
        if let server { return server }
        let generation = Self.generation
        let host = currentHost
        do {
            let fresh = try PippaMCPServer(host: host)
            startingServer = fresh
            defer { if startingServer === fresh { startingServer = nil } }
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await fresh.start() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        fresh.revoke()
                        throw EndpointFailure.serverUnavailable
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
            } onCancel: { fresh.revoke() }
            guard generation == Self.generation, !Task.isCancelled else { fresh.revoke(); throw CancellationError() }
            server = fresh
            return fresh
        } catch {
            if Task.isCancelled || generation != Self.generation { throw CancellationError() }
            DiagnosticsLog.shared.event("mcp-server-fehler", ["fehler": "listener unavailable"])
            throw EndpointFailure.serverUnavailable
        }
    }
}
