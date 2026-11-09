import Foundation

extension PippaMCPTools {
    /// Pippa's sentence before the first system prompt: what she reads and when. One sentence, then the Mac asks.
    public static func accessExplanation(_ subject: PippaMCPAccessSubject) -> String {
        switch subject {
        case .integration(.calendar):
            L("To answer this, I need to read your calendar on this Mac – only the period you ask about, and only when you ask.", table: "Calendar")
        case .integration(.reminders):
            L("To answer this, I need to read your reminders on this Mac – only when you ask, and I don’t change anything.", table: "MCP")
        case .integration(.mail):
            L("To answer this, I need to read Mail on this Mac – only when you ask, and I never send anything.", table: "MCP")
        case .excel:
            L("To answer this, I need to read the open table in Excel – only when you ask, and I don’t change it.", table: "MCP")
        case .photos:
            L("To find your pictures, I need to search Photos on this Mac and show them here – only when you ask, and I don’t change anything.", table: "MCP")
        case .front(let name):
            L("To answer this, I need to read what’s open in %@ – only when you ask, and I don’t change anything.", table: "MCP", name)
        }
    }

    /// Never asked before: first Pippa's sentence (if the app shows one), then the system prompt. `false`: "Later".
    func mayAsk(_ subject: PippaMCPAccessSubject, explanation: String? = nil) async -> Bool {
        guard let explain = host.explainAccess else { return true }
        let go = await explain(subject, explanation ?? Self.accessExplanation(subject))
        DiagnosticsLog.shared.event("mcp-erklaerung", ["app": subject.appName, "weiter": String(go)])
        return go
    }

    // MARK: Permissions and errors

    enum Gate { case open, blocked(PippaMCPToolResult) }

    /// Check permission; on first use (and only with `askForAccess`) show Pippa's sentence first, then the system prompt.
    /// `closed`: own sentence if the app is not open (otherwise the connection's sentence).
    func ensure(_ integration: Integration, openMail: Bool = false, closed: String? = nil) async -> Gate {
        var access = openMail && integration == .mail
            ? await host.integrations.prepareMailAccess() : await host.integrations.access(integration)
        if access == .notDetermined && host.askForAccess, await mayAsk(.integration(integration)) {
            access = await host.integrations.requestAccess(integration)
        }
        switch access {
        case .granted: return .open
        case .notDetermined: return .blocked(blocked("needs_access", Self.notYet(integration)))
        case .denied: return .blocked(blocked("denied", Self.denied(integration), repair: PermissionRepairTarget(integration: integration)))
        case .unavailable(let why): return .blocked(blocked("unavailable", closed ?? why))
        }
    }

    func failure(_ error: Error, _ integration: Integration) -> PippaMCPToolResult {
        switch error {
        case PippaError.accessDenied: return blocked("denied", Self.denied(integration), repair: PermissionRepairTarget(integration: integration))
        case PippaError.appNotOpen:
            return blocked("unavailable", L("Open %@ first. Then ask again.", table: "MCP", integration.appName))
        default:
            return blocked("failed", L("Pippa couldn’t read %@ just now. Please try again.", table: "MCP", integration.appName))
        }
    }

    /// Not read: one sentence for the person, which the model passes on. Never says "empty".
    func blocked(_ status: String, _ tell: String, repair: PermissionRepairTarget? = nil) -> PippaMCPToolResult {
        PippaMCPToolResult(text: Self.json(["read": false, "status": status, "tell": tell,
                                            "next": "Nothing was read. Repeat the sentence in tell word for word: it says exactly what the person can do. Do not guess and never say it is empty."]),
                           isError: true, permissionRepair: repair)
    }

    func invalid(_ why: String) -> PippaMCPToolResult {
        PippaMCPToolResult(text: Self.json(["read": false, "status": "invalid_arguments", "error": why]), isError: true)
    }

    public static func denied(_ i: Integration) -> String {
        switch i {
        case .calendar:
            L("Pippa may not read your calendar. To change that, open System Settings → Privacy & Security → Calendars and turn on Pippa.", table: "MCP")
        case .reminders:
            L("Pippa may not read your reminders. To change that, open System Settings → Privacy & Security → Reminders and turn on Pippa.", table: "MCP")
        case .mail: deniedAutomation(i.appName)
        }
    }

    static func deniedAutomation(_ app: String) -> String {
        L("Pippa may not read %@. To change that, open System Settings → Privacy & Security → Automation and turn it on under Pippa.", table: "MCP", app)
    }

    static func notYet(_ i: Integration) -> String { notYet(app: i.appName) }
    static func notYet(app: String) -> String {
        L("Pippa isn’t allowed to read %@ yet. Ask again and click “Allow” when your Mac asks.", table: "MCP", app)
    }
}
