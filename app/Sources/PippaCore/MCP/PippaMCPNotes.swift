import Foundation

/// `notes_read`: read-only Apple Notes tool backed by `NotesReading` (in-process Apple Events, zero Full Disk Access).
public struct PippaMCPNotesTool: Sendable {
    public static let name = "notes_read"
    public static let defaultLimit = 20
    public static let maxLimit = 50
    public static let maxTextCharacters = 6000

    private let reader: any NotesReading
    private let askForAccess: Bool
    private let calendar: Calendar
    private let explainAccess: (@Sendable (PippaMCPAccessSubject, String) async -> Bool)?

    public init(reader: any NotesReading = SystemNotesReader(),
                askForAccess: Bool = true,
                calendar: Calendar = .autoupdatingCurrent,
                explainAccess: (@Sendable (PippaMCPAccessSubject, String) async -> Bool)? = nil) {
        self.reader = reader
        self.askForAccess = askForAccess
        self.calendar = calendar
        self.explainAccess = explainAccess
    }

    public init(host: PippaMCPHost, reader: any NotesReading = SystemNotesReader()) {
        self.init(reader: reader, askForAccess: host.askForAccess, calendar: host.calendar, explainAccess: host.explainAccess)
    }

    public static func toolList() -> [[String: Any]] {
        let title = "Notizen lesen"
        let string: [String: Any] = ["type": "string"]
        let integer: [String: Any] = ["type": "integer"]
        return [[
            "name": name,
            "title": title,
            "description": "Notes (unlocked). omit=newest; query; id=full; limit≤50.",
            "inputSchema": [
                "type": "object",
                "additionalProperties": false,
                "properties": ["query": string, "id": string, "limit": integer],
            ],
            "annotations": (PippaActionClasses.of(name) ?? .read).annotations.merging(["title": title]) { a, _ in a },
        ]]
    }

    public func call(_ raw: [String: Any]) async -> PippaMCPToolResult {
        let allowed: Set<String> = ["query", "id", "limit"]
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
        let rawQuery = raw["query"] as? String
        let rawID = raw["id"] as? String
        let limit = parseInt("limit") ?? Self.defaultLimit
        guard (1...Self.maxLimit).contains(limit) else {
            return Self.invalid("limit must be 1 to \(Self.maxLimit).")
        }
        if let rawID {
            let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else { return Self.invalid("id must not be empty.") }
            if let rawQuery, !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Self.invalid("Pass either id or query, not both.")
            }
        }

        var access = await reader.access(ask: false)
        if access == .notDetermined && askForAccess {
            let go: Bool
            if let explainAccess {
                go = await explainAccess(.front(NotesScript.appName),
                                         L("To answer this, I need to read your notes on this Mac – only when you ask, and I don’t change anything.", table: "MCP"))
            } else {
                go = true
            }
            if go { access = await reader.access(ask: true) }
        }
        switch access {
        case .granted: break
        case .notDetermined:
            return Self.blocked("needs_access", PippaMCPTools.notYet(app: NotesScript.appName))
        case .denied:
            return Self.blocked("denied", PippaMCPTools.deniedAutomation(NotesScript.appName), repair: .automation)
        case .unavailable(let why):
            let tell = why.isEmpty ? L("Open %@ first. Then ask again.", table: "MCP", NotesScript.appName) : why
            return Self.blocked("unavailable", tell)
        }

        do {
            if let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return try await readSingle(id: id)
            }
            let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await list(query: query?.isEmpty == true ? nil : query, limit: limit)
        } catch PippaError.accessDenied {
            return Self.blocked("denied", PippaMCPTools.deniedAutomation(NotesScript.appName), repair: .automation)
        } catch PippaError.appNotOpen {
            return Self.blocked("unavailable", L("Open %@ first. Then ask again.", table: "MCP", NotesScript.appName))
        } catch {
            return Self.blocked("failed", L("Pippa couldn’t read %@ just now. Please try again.", table: "MCP", NotesScript.appName))
        }
    }

    private func readSingle(id: String) async throws -> PippaMCPToolResult {
        guard let note = try await reader.readNote(id: id) else {
            return Self.blocked("not_found", L("I couldn’t find this note in Notes.", table: "MCP"))
        }
        if note.locked {
            let payload: [String: Any] = [
                "read": false,
                "status": "locked",
                "skippedLocked": 1,
                "tell": L("This note is locked in Notes, so Pippa can’t read it.", table: "MCP"),
                "next": "Nothing was read. Repeat the sentence in tell word for word.",
            ]
            return PippaMCPToolResult(text: PippaMCPTools.json(payload), isError: true)
        }
        let text = PippaMCPTools.compact(note.text)
        let clipped = String(text.prefix(Self.maxTextCharacters))
        var data: [String: Any] = [
            "id": note.id,
            "title": String(note.title.prefix(200)),
            "text": clipped,
            "textTruncated": text.count > Self.maxTextCharacters,
        ]
        if !note.folder.isEmpty { data["folder"] = String(note.folder.prefix(80)) }
        if let modified = note.modified {
            data["modified"] = PippaMCPTools.dateLabel(modified, time: true, calendar: calendar)
        }
        return PippaMCPTools.bounded(source: "Notes on this Mac", data: data,
                                     next: "Use only what the note says; it may be cut (textTruncated). Name the note by its title.", structured: true)
    }

    private func list(query: String?, limit: Int) async throws -> PippaMCPToolResult {
        let fetched = try await reader.listNotes(query: query, limit: limit)
        var items: [[String: Any]] = []
        var usedBytes = 0
        let budget = PippaMCPTools.structuredMaxResultBytes - 1400
        for note in fetched.notes {
            var entry: [String: Any] = [
                "id": note.id,
                "title": String(note.title.prefix(120)),
            ]
            if !note.folder.isEmpty { entry["folder"] = String(note.folder.prefix(60)) }
            if let modified = note.modified {
                entry["modified"] = PippaMCPTools.dateLabel(modified, time: false, calendar: calendar)
            }
            let size = PippaMCPTools.encode(entry).count + 2
            guard usedBytes + size <= budget else { break }
            items.append(entry)
            usedBytes += size
        }
        var data: [String: Any] = [
            "notes": items,
            "shown": items.count,
            "total": fetched.total,
            "truncated": fetched.total > items.count,
        ]
        if let query { data["query"] = query }
        if fetched.skippedLocked > 0 { data["skippedLocked"] = fetched.skippedLocked }
        let lockedHint = fetched.skippedLocked > 0 ? " Password-protected notes were skipped (skippedLocked)." : ""
        return PippaMCPTools.bounded(source: "Notes on this Mac", data: data,
                                     next: "Use notes_read with id to read a note's full plaintext.\(lockedHint)", structured: true)
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
