import Foundation

extension PippaMCPWriteTools {
    // MARK: Permissions and errors

    enum Gate { case open, blocked(String, String) }

    /// As for reading, but with Pippa's sentence about adding (before the first system prompt).
    func ensure(_ integration: Integration, openMail: Bool = false) async -> Gate {
        do { try PippaMCPWriteLease.current?.check() } catch { return .blocked("cancelled", Self.stoppedText) }
        var access = openMail && integration == .mail
            ? await host.integrations.prepareMailAccess() : await host.integrations.access(integration)
        do { try PippaMCPWriteLease.current?.check() } catch { return .blocked("cancelled", Self.stoppedText) }
        if access == .notDetermined && host.askForAccess {
            let go = await host.explainAccess?(.integration(integration), Self.writeExplanation(integration)) ?? true
            do { try PippaMCPWriteLease.current?.check() } catch { return .blocked("cancelled", Self.stoppedText) }
            if go { access = await host.integrations.requestAccess(integration) }
        }
        do { try PippaMCPWriteLease.current?.check() } catch { return .blocked("cancelled", Self.stoppedText) }
        switch access {
        case .granted: return .open
        case .notDetermined: return .blocked("needs_access", PippaMCPTools.notYet(integration))
        case .denied: return .blocked("denied", Self.denied(integration))
        case .unavailable(let why): return .blocked("unavailable", why)
        }
    }

    /// Pippa's sentence before the first system prompt, when she is to add something.
    public static func writeExplanation(_ integration: Integration) -> String {
        switch integration {
        case .calendar: L("To do this, I need access to your calendar on this Mac – I only add what you ask for.", table: "MCP")
        case .reminders: L("To do this, I need access to your reminders on this Mac – I only add what you ask for.", table: "MCP")
        case .mail: L("To do this, I need access to Mail on this Mac – I only create drafts and never send anything.", table: "MCP")
        }
    }

    static func denied(_ integration: Integration) -> String {
        switch integration {
        case .calendar: L("Pippa may not add to your calendar. To change that, open System Settings → Privacy & Security → Calendars and allow full access for Pippa.", table: "MCP")
        case .reminders: L("Pippa may not add reminders. To change that, open System Settings → Privacy & Security → Reminders and allow full access for Pippa.", table: "MCP")
        case .mail: PippaMCPTools.deniedAutomation(integration.appName)
        }
    }

    func failure(_ error: Error, _ integration: Integration, receipt: PippaMCPWriteReceipt) -> PippaMCPToolResult {
        var receipt = receipt
        if PippaMCPWriteLease.current?.hasDispatched == true {
            receipt.outcome = "unclear"; receipt.reason = "unconfirmed"
            return PippaMCPToolResult(text: PippaMCPTools.json([
                "done": false, "state": "unclear", "sent": false,
                "tell": L("Pippa couldn’t confirm whether the change in %@ finished. Please check the app before trying again.", table: "MCP", integration.appName),
                "next": "The native write was dispatched but its outcome is unknown. Repeat tell; do not retry this action automatically.",
            ]), isError: false, receipt: receipt)
        }
        if error is CancellationError { return Self.stopped(receipt: receipt) }
        switch error {
        case PippaError.accessDenied:
            receipt.reason = "denied"
            return Self.blocked("denied", Self.denied(integration), receipt: receipt)
        case PippaError.appNotOpen:
            receipt.reason = "unavailable"
            return Self.blocked("unavailable", L("Open %@ first. Then ask again.", table: "MCP", integration.appName), receipt: receipt)
        default:
            return Self.blocked("failed", L("Pippa couldn’t add to %@ just now. Nothing was changed.", table: "MCP", integration.appName), receipt: receipt)
        }
    }

    /// Not done: a sentence for the person, which the model passes on.
    static func blocked(_ status: String, _ tell: String, receipt: PippaMCPWriteReceipt) -> PippaMCPToolResult {
        if status == "cancelled" { return stopped(receipt: receipt) }
        return PippaMCPToolResult(text: PippaMCPTools.json(["done": false, "status": status, "tell": tell,
                                                     "next": "Nothing was changed. Repeat the sentence in tell word for word."]),
                           isError: true, receipt: receipt)
    }

    static var stoppedText: String { L("Stopped before anything was changed.", table: "MCP") }
    static func stopped(receipt: PippaMCPWriteReceipt) -> PippaMCPToolResult {
        var receipt = receipt
        receipt.outcome = "cancelled"; receipt.reason = "stopped"
        return PippaMCPToolResult(text: PippaMCPTools.json([
            "done": false, "status": "cancelled", "dispatched": false, "tell": stoppedText,
            "next": "Nothing was changed. The request was stopped; do not retry it automatically.",
        ]), isError: true, receipt: receipt)
    }

    /// Wrong arguments: the model can retry with correct ones; nothing happened, no receipt row
    /// except Pi's own (tool failed).
    static func invalid(_ why: String) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json(["done": false, "status": "invalid_arguments", "error": why]), isError: true)
    }
}
