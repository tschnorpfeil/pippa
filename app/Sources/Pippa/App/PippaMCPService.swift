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

    /// Gives the caller the ID of its answer before Pi starts, so it can collect cards after the answer ends.
    @TaskLocal static var onBeginTurn: (@MainActor @Sendable (UUID) -> Void)?

    /// Binds the MCP tools to one answer: writes outside an answer are refused (`requireActiveWriteTurn`).
    static func begin(_ turn: PippaMCPTurn) {
        currentHost.turns.begin(turn)
        onBeginTurn?(turn.id)
    }
    static func end(_ turn: PippaMCPTurn) {
        currentHost.turns.end(turn)
        serverEgress?.onlineBrowser?.end(turn)
    }

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
        private var collected: [UUID] = []
        func append(_ note: Note, turnID: UUID? = nil) {
            lock.withLock {
                if let turnID, collected.contains(turnID) { return }
                notes.append(note)
            }
        }
        func take() -> [Note] { lock.withLock { defer { notes = [] }; return notes } }
        func take(turnID: UUID, at keyPath: KeyPath<Note, UUID?>) -> [Note] {
            lock.withLock {
                if !collected.contains(turnID) { collected.append(turnID) }
                if collected.count > 512 { collected.removeFirst(collected.count - 512) }
                var taken: [Note] = []
                notes.removeAll { note in
                    guard note[keyPath: keyPath] == turnID else { return false }
                    taken.append(note)
                    return true
                }
                return taken
            }
        }
    }

    static func takeReadCards(turnID: UUID?) -> [ResultCard] {
        guard let turnID else { return [] }
        return readNotes.take(turnID: turnID, at: \.turnID).compactMap(\.card)
    }

    enum EndpointFailure: Error, Equatable { case extensionMissing, serverUnavailable }

    /// Only entry point from `PiRPCChat`: starts the server if needed; address, key and extension for
    /// `PippaPiLaunch.configuration(…, mcp:)`, which turns them into `addMCP`. Failure stops Pi admission before any user prompt.
    /// `egress`: set for an online AI's Pi. The endpoint is new per Pi process (`invalidateEndpoint`), so its limits hold
    /// for exactly that process and never carry over to the AI on this Mac or back.
    static func endpoint(extensions: URL, egress: PippaMCPEgress? = nil) async throws -> (endpoint: PippaPiLaunch.MCPEndpoint, extension: URL) {
        let file = ProcessInfo.processInfo.environment["PIPPA_PI_MCP"] ?? extensions.appendingPathComponent("pippa-mcp.ts").path
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: file) else { throw EndpointFailure.extensionMissing }
        if server != nil, serverEgress != egress { invalidateEndpoint() }
        let running = try await started(egress: egress)
        return (.init(url: running.url, token: running.token), URL(fileURLWithPath: file))
    }

    /// An abandoned Pi process must never borrow a later answer's authority.
    static func invalidateEndpoint() {
        generation &+= 1
        server?.revoke()
        startingServer?.revoke()
        serverEgress?.onlineBrowser?.invalidate()
        serverEgress = nil
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

    /// `false` in `Pippa --ask`: only access that is already granted is used. The tools then say `needs_access` instead of
    /// showing Pippa's sentence and the system prompt (`PippaMCPHost.askForAccess`). Set through `PiSession.interaction`.
    static var asksForAccess = true {
        didSet {
            guard asksForAccess != oldValue else { return }
            invalidateEndpoint()
            host = nil
        }
    }

    /// The server's integrations (with PIPPA_DEMO=1 a substitute appointment lives only in this substitute's memory).
    private static var host: PippaMCPHost?

    /// Where the host starts from; checks replace it with stand-in readers and writers.
    static var baseHost: () -> PippaMCPHost = { ProcessInfo.processInfo.environment["PIPPA_DEMO"] == "1" ? .demo() : .system() } {
        didSet { host = nil }
    }

    static var currentHost: PippaMCPHost {
        if let host { return host }
        let fresh = configured(baseHost(), asksForAccess: asksForAccess)
        host = fresh
        return fresh
    }

    /// Pippa's own wiring of a host. Without `asksForAccess` neither Pippa's sentence nor a system prompt can appear.
    static func configured(_ base: PippaMCPHost, asksForAccess: Bool) -> PippaMCPHost {
        var fresh = base
        fresh.onRead = { note in if let id = note.turnID { readNotes.append(note, turnID: id) } }
        fresh.onWrite = { receipt in writeNotes.append(receipt) }
        fresh.requireActiveWriteTurn = true
        fresh.askForAccess = asksForAccess
        if asksForAccess { fresh.explainAccess = { subject, sentence in await explain(subject, sentence) } }
        // Pippa's browser panel; PIPPA_DEMO=1 keeps the demo host's invented pages.
        if fresh.browser == nil, ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1" {
            let session = WKBrowserSession.shared
            let approvals = fresh.browserApprovals
            let turns = fresh.turns
            session.authorizeNavigation = { url in
                guard let host = PippaMCPBrowserTool.normalizedHost(url) else { return false }
                // Once Pippa handed off login/2FA/CAPTCHA to the human outside an active turn, allow their clicks.
                if turns.active == nil, session.handoffMessage != nil { return true }
                guard let turn = turns.active, !turn.writes.snapshot.cancelled else { return false }
                if approvals.approved(host, turn: turn.id) { return true }
                let prompt = PippaMCPBrowserTool.openHostPrompt(url)
                let ok = await confirmBrowser(title: prompt.title, message: prompt.message, asksForAccess: asksForAccess)
                guard ok, !turn.writes.snapshot.cancelled else { return false }
                approvals.approve(host, turn: turn.id)
                return true
            }
            fresh.browser = session
            fresh.onBrowserHandoff = { _, _ in
                Task { @MainActor in
                    WKBrowserSession.shared.showHandoff(T("Please sign in or finish the check here. Pippa never sees your password. Click Done, then tell Pippa to continue.", table: "App"))
                }
            }
        }
        fresh.confirmBrowser = { _, title, message in await confirmBrowser(title: title, message: message, asksForAccess: asksForAccess) }
        return fresh
    }

    /// The person's OK for `browse`, in Pippa's own approval. `Pippa --ask` never shows it: the question counts as
    /// declined (`PiSession.Interaction.headless`), so the run reports needs_input.
    static func confirmBrowser(title: String, message: String, asksForAccess: Bool) async -> Bool {
        let request = PiUIRequest(id: UUID().uuidString, method: "confirm", title: title, message: message,
                                  options: [], placeholder: nil, prefill: nil, timeout: nil)
        guard asksForAccess else {
            if case .headless(let declined) = PiSession.shared.interaction { declined(request) }
            return false
        }
        return await Confirmations.ask(request) == .confirmed(true)
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

    /// The limits the running server was started with.
    private static var serverEgress: PippaMCPEgress?

    private static func onlineHost(_ host: PippaMCPHost, egress: PippaMCPEgress) -> PippaMCPHost {
        var host = host
        var egress = egress
        host.browser = nil
        host.onBrowserHandoff = nil
        if egress.web {
            let turns = host.turns
            let confirm = host.confirmBrowser
            let demo = ProcessInfo.processInfo.environment["PIPPA_DEMO"] == "1"
            // Navigation policy and the tool's initial open must consult the same turn-scoped approvals.
            let approvals = PippaMCPBrowserApprovals()
            egress.onlineBrowser = PippaMCPOnlineBrowser(approvals: approvals) { turn in
                if demo { return DemoBrowserOperator() }
                guard let session = WKBrowserSession.makeOnline() else { return nil }
                session.authorizeNavigation = { url in
                    guard turns.active === turn, !turn.writes.snapshot.cancelled,
                          let name = PippaMCPBrowserTool.normalizedHost(url) else { return false }
                    if approvals.approved(name, turn: turn.id) { return true }
                    let prompt = PippaMCPBrowserTool.openHostPrompt(url)
                    guard await confirm?("open", prompt.title, prompt.message) == true,
                          turns.active === turn, !turn.writes.snapshot.cancelled else { return false }
                    approvals.approve(name, turn: turn.id)
                    return true
                }
                return session
            }
        }
        host.egress = egress
        return host
    }

    private static func started(egress: PippaMCPEgress?) async throws -> PippaMCPServer {
        if let server, serverEgress == egress { return server }
        let generation = Self.generation
        var host = currentHost
        host.egress = nil
        if let egress { host = onlineHost(host, egress: egress) }
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
            server = fresh; serverEgress = host.egress
            return fresh
        } catch {
            if Task.isCancelled || generation != Self.generation { throw CancellationError() }
            DiagnosticsLog.shared.event("mcp-server-fehler", ["fehler": "listener unavailable"])
            throw EndpointFailure.serverUnavailable
        }
    }
}
