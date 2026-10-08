import AppKit
import PiRPC
import PippaCore

/// Pippa's MCP server for the app's own Pi processes. Starts at the first Pi start,
/// one server per app run, one key per app run. Reading happens here in the Pippa process, so every
/// system prompt (calendar, reminders, automation for Mail/Excel) names Pippa.
///
/// With `PIPPA_DEMO=1` only invented data (never real apps). `PIPPA_PI_MCP`: path to the extension, otherwise `pippa-mcp.ts`
/// next to the guard. If the extension is missing or the server does not start, Pi continues without these tools.
@MainActor
enum PippaMCPService {
    private static var server: PippaMCPServer?

    /// What Pippa's readers read in this app run, in order; PiRPCChat collects it per answer.
    nonisolated static let readNotes = ReadNotes()

    final class ReadNotes: @unchecked Sendable {
        private let lock = NSLock()
        private var notes: [PippaMCPReadNote] = []
        func append(_ note: PippaMCPReadNote) { lock.withLock { notes.append(note) } }
        func take() -> [PippaMCPReadNote] { lock.withLock { defer { notes = [] }; return notes } }
    }

    /// Only entry point from `PiRPCChat`: starts the server if needed; address, key and extension for
    /// `PippaPiLaunch.configuration(…, mcp:)`, which turns them into `addMCP`. `nil`: Pi runs without these tools.
    static func endpoint(guardPath: String) async -> (endpoint: PippaPiLaunch.MCPEndpoint, extension: URL)? {
        let file = DevEnvironment.value("PIPPA_PI_MCP")
            ?? URL(fileURLWithPath: guardPath).deletingLastPathComponent().appendingPathComponent("pippa-mcp.ts").path
        guard FileManager.default.fileExists(atPath: file), let running = await started() else { return nil }
        return (.init(url: running.url, token: running.token), URL(fileURLWithPath: file))
    }

    /// Before the first system prompt when reading, Pippa's own sentence (texts like the permission card of the
    /// connections, `PermissionContent`). "Erlauben …" → then the Mac asks; "Später" → nothing asked, nothing read.
    static func explain(_ subject: PippaMCPAccessSubject, _ sentence: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = T("Just a quick question.", table: "Settings")
        alert.informativeText = sentence + "\n\n" + T("Your Mac will ask you in a moment.", table: "App")
        alert.addButton(withTitle: T("Allow…", table: "Settings"))
        alert.addButton(withTitle: T("Later", table: "Settings"))
        if let answer = explainForSnapshot { return answer(alert, sentence) }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Recordings and checks only: answers in the person's place (sentence is recorded). `nil`: the person answers.
    static var explainForSnapshot: ((NSAlert, String) -> Bool)?

    /// The server's integrations. "Rückgängig" removes with the same integration that created (with
    /// PIPPA_DEMO=1 a substitute appointment lives only in this substitute's memory).
    private static var host: PippaMCPHost?

    private static var currentHost: PippaMCPHost {
        if let host { return host }
        var fresh: PippaMCPHost = DevEnvironment.value("PIPPA_DEMO") == "1" ? .demo() : .system()
        fresh.onRead = { note in readNotes.append(note) }
        fresh.explainAccess = { subject, sentence in await explain(subject, sentence) }
        // Undo entries for appointments and reminders next to the guard's (same folder, same cleanup).
        fresh.undoRoot = PiRPCChat.undoRoot
        host = fresh
        return fresh
    }

    /// Remove an appointment or reminder created by Pippa (only if unchanged; `AppIntegrations.remove`).
    static func remove(_ item: CreatedItem) async throws -> RemoveResult {
        try await currentHost.integrations.remove(item)
    }

    /// "Als Entwurf in Mail" creates the draft the same way as Pi's `mail_draft` (same rights,
    /// same states, same receipt), as a reply to exactly the offer's mail (Message-ID), never to the
    /// selection at click time. Never send.
    static func saveDraft(_ offer: MailDraftOffer) async -> (item: ActionReceipt.Item, missing: Bool) {
        await MailDraftOfferRule.save(offer, with: PippaMCPWriteTools(host: currentHost))
    }

    /// Bring mail to the front ("Entwurf öffnen"). With PIPPA_DEMO=1 nothing (no real apps).
    static func showMail() async {
        guard DevEnvironment.value("PIPPA_DEMO") != "1",
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Integration.mail.bundleIdentifier) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private static func started() async -> PippaMCPServer? {
        if let server { return server }
        let host = currentHost
        do {
            let fresh = try PippaMCPServer(host: host)
            try await fresh.start()
            server = fresh
            return fresh
        } catch {
            DiagnosticsLog.shared.event("mcp-server-fehler", ["fehler": String(describing: error)])
            return nil
        }
    }
}
