import Foundation

/// `contacts_search`: read-only Apple Contacts tool backed by `ContactsReading` (`CNContactStore`, zero Full Disk Access).
public struct PippaMCPContactsTool: Sendable {
    public static let name = "contacts_search"
    public static let defaultLimit = 10
    public static let maxLimit = ContactsStore.maxLimit

    private let store: any ContactsReading
    private let askForAccess: Bool
    private let explainAccess: (@Sendable (PippaMCPAccessSubject, String) async -> Bool)?

    public init(store: any ContactsReading = SystemContactsStore(),
                askForAccess: Bool = true,
                explainAccess: (@Sendable (PippaMCPAccessSubject, String) async -> Bool)? = nil) {
        self.store = store
        self.askForAccess = askForAccess
        self.explainAccess = explainAccess
    }

    public init(host: PippaMCPHost, store: any ContactsReading = SystemContactsStore()) {
        self.init(store: store, askForAccess: host.askForAccess, explainAccess: host.explainAccess)
    }

    public static func toolList() -> [[String: Any]] {
        let title = "Kontakte suchen"
        return [[
            "name": name,
            "title": title,
            "description": "Contacts by name/email/company. limit≤20.",
            "inputSchema": [
                "type": "object",
                "additionalProperties": false,
                "required": ["query"],
                "properties": ["query": ["type": "string"], "limit": ["type": "integer"]],
            ],
            "annotations": (PippaActionClasses.of(name) ?? .read).annotations.merging(["title": title]) { a, _ in a },
        ]]
    }

    public func call(_ raw: [String: Any]) async -> PippaMCPToolResult {
        let allowed: Set<String> = ["query", "limit"]
        func parseInt(_ key: String) -> Int? {
            guard let n = raw[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return Int(exactly: n.doubleValue)
        }
        let unknown = raw.keys.filter { key in
            guard allowed.contains(key) else { return true }
            if key == "limit" { return parseInt(key) == nil }
            return !(raw[key] is String)
        }.sorted()
        guard unknown.isEmpty else {
            return Self.invalid("Unknown or invalid arguments: \(unknown.joined(separator: ", ")).")
        }
        guard let rawQuery = raw["query"] as? String else {
            return Self.invalid("query is required.")
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(query.count) else {
            return Self.invalid("query must be 1 to 120 characters.")
        }
        let limit = parseInt("limit") ?? Self.defaultLimit
        guard (1...Self.maxLimit).contains(limit) else {
            return Self.invalid("limit must be 1 to \(Self.maxLimit).")
        }

        var access = await store.access(ask: false)
        if access == .notDetermined && askForAccess {
            let go: Bool
            if let explainAccess {
                go = await explainAccess(.front(ContactsStore.appName),
                                         L("To answer this, I need to search your contacts on this Mac – only when you ask, and I don’t change anything.", table: "MCP"))
            } else {
                go = true
            }
            if go { access = await store.access(ask: true) }
        }
        switch access {
        case .granted: break
        case .notDetermined:
            return Self.blocked("needs_access", PippaMCPTools.notYet(app: ContactsStore.appName))
        case .denied:
            return Self.blocked("denied", Self.deniedContacts, repair: .contacts)
        case .unavailable(let why):
            let tell = why.isEmpty ? L("Pippa couldn’t read %@ just now. Please try again.", table: "MCP", ContactsStore.appName) : why
            return Self.blocked("unavailable", tell)
        }

        do {
            let matches = try await store.search(query: query, limit: limit)
            var items: [[String: Any]] = []
            var usedBytes = 0
            let budget = PippaMCPTools.maxResultBytes - 1400
            for contact in matches {
                var entry: [String: Any] = ["name": String(contact.name.prefix(120))]
                if let org = contact.organization, !org.isEmpty { entry["organization"] = String(org.prefix(120)) }
                if !contact.emails.isEmpty { entry["emails"] = contact.emails.prefix(5).map { String($0.prefix(120)) } }
                if !contact.phones.isEmpty { entry["phones"] = contact.phones.prefix(5).map { String($0.prefix(60)) } }
                if let birthday = contact.birthday, !birthday.isEmpty { entry["birthday"] = birthday }
                let size = PippaMCPTools.encode(entry).count + 2
                guard usedBytes + size <= budget else { break }
                items.append(entry)
                usedBytes += size
            }
            let data: [String: Any] = [
                "query": query,
                "contacts": items,
                "shown": items.count,
                "truncated": matches.count > items.count,
            ]
            return PippaMCPTools.bounded(source: "Contacts on this Mac", data: data,
                                         next: "Use only the contact details shown. If contacts is empty, no matching contact was found.")
        } catch PippaError.accessDenied {
            return Self.blocked("denied", Self.deniedContacts, repair: .contacts)
        } catch {
            return Self.blocked("failed", L("Pippa couldn’t read %@ just now. Please try again.", table: "MCP", ContactsStore.appName))
        }
    }

    public static var deniedContacts: String {
        L("Pippa may not read your contacts. To change that, open System Settings → Privacy & Security → Contacts and turn on Pippa.", table: "MCP")
    }

    private static func blocked(_ status: String, _ tell: String, repair: PermissionRepairTarget? = nil) -> PippaMCPToolResult {
        PippaMCPToolResult(
            text: PippaMCPTools.json([
                "read": false, "status": status, "tell": tell,
                "next": "Nothing was read. Repeat the sentence in tell word for word: it says exactly what the person can do. Do not guess and never say it is empty.",
            ]),
            isError: true, permissionRepair: repair)
    }

    private static func invalid(_ why: String) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json(["read": false, "status": "invalid_arguments", "error": why]), isError: true)
    }
}
