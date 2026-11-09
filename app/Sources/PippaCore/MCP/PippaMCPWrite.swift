import Foundation

// Three write tools on Pippa's MCP server, running in the Pippa process (TCC names Pippa) using the existing paths:
//
// - `calendar_add`: event via EventKit (`HostWriting.addEvent`), with overlaps from the same read as
//   `calendar_read`; `if_free` only adds if nothing else is scheduled at that time.
// - `reminder_add`: reminder via EventKit (`HostWriting.addReminder`).
// - `mail_draft`: unsent draft in Mail via `AppIntegrations.insertReply` (Mail 16: `make new paragraph`, never
//   `set content`, never `send`). Reply in the thread to a shown mail (.eml) or the one selected in Mail, otherwise a new mail.
//
// Pi runs them without asking, like every tool: they change something on the Mac, but nothing leaves it.
// The server builds what happened itself (`PippaMCPWriteReceipt`, the model does not see it) and hands it to the app
// (`PippaMCPHost.onWrite`), which turns it into the receipt line. Mail drafts: the receipt says "not sent", the button
// reads "Open draft".

public struct PippaMCPWriteTools: Sendable {
    public static let names = ["calendar_add", "reminder_add", "mail_draft"]
    static let mailBodyLimit = 20_000

    let host: PippaMCPHost
    let scope: PippaMCPWriteScope
    public init(host: PippaMCPHost, scope: PippaMCPWriteScope = PippaMCPWriteScope()) { self.host = host; self.scope = scope }

    /// Changes something on the Mac (`readOnlyHint: false`), deletes nothing and is at most a draft
    /// (`destructiveHint: false`), does not leave the Mac (`openWorldHint: false`).
    static var hints: [String: Any] { ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false] }

    /// Short: every word costs prompt time with the local model.
    public static func toolList() -> [[String: Any]] {
        // Only names and types: lengths and ranges are checked in `call` (see PippaMCPTools.toolList).
        func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
            ["name": name, "title": title, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required],
             "annotations": hints.merging(["title": title]) { a, _ in a }]
        }
        let text: [String: Any] = ["type": "string"]
        // Formats once in the description instead of per parameter.
        let date = text, time = text
        return [
            tool("calendar_add", "Termin eintragen",
                 "date=YYYY-MM-DD/today/tomorrow/weekday; time/end=HH:MM (omit=all-day); minutes=60 default; if_free=only free.",
                 ["title": text, "date": date, "time": time, "minutes": ["type": "integer"], "end": time,
                  "location": text, "notes": text, "if_free": ["type": "boolean"]],
                 required: ["title", "date"]),
            tool("reminder_add", "Erinnerung anlegen",
                 "date=YYYY-MM-DD/today/tomorrow/weekday; time=HH:MM needs date.",
                 ["title": text, "date": date, "time": time, "list": text, "notes": text], required: ["title"]),
            tool("mail_draft", "Mail-Entwurf",
                 "Unsent Mail; reply_to=exact shown email path/selected; omit=new subject/to.",
                 ["body": text, "reply_to": text, "subject": text, "to": text],
                 required: ["body"]),
        ]
    }

    /// Arguments as plain values; unknown ones and wrong types are named instead of silently ignored.
    struct Input: Sendable {
        var strings: [String: String] = [:]
        var minutes: Int?
        var ifFree: Bool?
        var unknown: [String] = []

        static let allowed: [String: Set<String>] = [
            "calendar_add": ["title", "date", "time", "minutes", "end", "location", "notes", "if_free"],
            "reminder_add": ["title", "date", "time", "list", "notes"],
            "mail_draft": ["body", "reply_to", "subject", "to"],
        ]

        init(_ tool: String, _ raw: [String: Any]) {
            let allowed = Self.allowed[tool] ?? []
            for (key, value) in raw {
                guard allowed.contains(key) else { unknown.append(key); continue }
                switch key {
                case "minutes":
                    if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded() { minutes = n.intValue }
                    else { unknown.append(key) }
                case "if_free":
                    if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { ifFree = n.boolValue } else { unknown.append(key) }
                default:
                    if let s = value as? String { strings[key] = s } else { unknown.append(key) }
                }
            }
            unknown.sort()
        }

        /// Trimmed, empty = missing.
        func text(_ key: String) -> String? {
            let value = strings[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }

    public func call(_ name: String, _ raw: [String: Any]) async -> PippaMCPToolResult {
        let action = ["calendar_add": "calendarAdd", "reminder_add": "reminderAdd", "mail_draft": "mailDraft"][name] ?? name
        return await withLease(action: action) { await callScoped(name, raw) }
    }

    private func withLease(action: String, _ operation: () async -> PippaMCPToolResult) async -> PippaMCPToolResult {
        let lease = scope.lease(action: action)
        var result = await withTaskCancellationHandler {
            await PippaMCPWriteLease.$current.withValue(lease) {
                do { try lease.check() }
                catch is PippaMCPWritePolicyDenied {
                    return PippaMCPToolResult(text: PippaMCPTools.json([
                        "done": false, "status": "not_dispatched", "dispatched": false,
                        "tell": L("This request can only prepare a draft. Nothing was changed.", table: "MCP"),
                        "next": "This request permits preparing text only. Do not retry through another tool.",
                    ]), isError: true, receipt: .init(action: action, outcome: "failed", name: "", reason: "draftOnly"))
                } catch { return Self.stopped(receipt: .init(action: action, outcome: "cancelled", name: "", reason: "stopped")) }
                return await operation()
            }
        } onCancel: { lease.cancel() }
        result.receipt = lease.finish(result.receipt)
        return result
    }

    private func callScoped(_ name: String, _ raw: [String: Any]) async -> PippaMCPToolResult {
        let input = Input(name, raw)
        let started = ContinuousClock.now
        let outcome: PippaMCPToolResult
        if !input.unknown.isEmpty {
            outcome = Self.invalid("Unknown or invalid arguments: \(input.unknown.joined(separator: ", ")).")
        } else {
            switch name {
            case "calendar_add": outcome = await calendarAdd(input)
            case "reminder_add": outcome = await reminderAdd(input)
            default: outcome = await mailDraft(input)
            }
        }
        let ms = (ContinuousClock.now - started).components.seconds * 1000
        DiagnosticsLog.shared.event("mcp-werkzeug", ["name": name, "fehler": String(outcome.isError), "ms": String(ms),
                                                     "ergebnis": outcome.receipt?.outcome ?? "-"])
        return outcome
    }
}

// MARK: Undo from the receipt row

extension PippaMCPHost {
    /// Removes the event or reminder a receipt names, only if it is unchanged since Pippa created it
    /// (`AppIntegrations.remove`). Returns the receipt with `undo` set; a receipt without anything to undo is returned as is.
    public func undo(_ receipt: PippaMCPWriteReceipt) async -> PippaMCPWriteReceipt {
        guard receipt.canUndo, let item = receipt.created else { return receipt }
        var result = receipt
        do {
            result.undo = switch try await integrations.remove(item) {
            case .removed: "removed"
            case .gone: "gone"
            case .changed: "changed"
            }
        } catch {
            result.undo = "failed"
        }
        DiagnosticsLog.shared.event("rueckgaengig", ["aktion": receipt.action, "ergebnis": result.undo ?? "-"])
        return result
    }
}
