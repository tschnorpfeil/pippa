import Carbon
import Foundation

// MARK: Apple Notes (read only, in-process Apple Events, zero Full Disk Access)

/// Metadata for one unlocked Apple Note.
public struct NoteSummary: Sendable, Equatable {
    public var id: String
    public var title: String
    public var folder: String
    public var modified: Date?

    public init(id: String, title: String, folder: String = "", modified: Date? = nil) {
        self.id = id
        self.title = title
        self.folder = folder
        self.modified = modified
    }
}

/// Result of listing or searching Apple Notes. Locked notes are always excluded and counted in `skippedLocked`.
public struct NotesListResult: Sendable, Equatable {
    public var notes: [NoteSummary]
    public var total: Int
    public var skippedLocked: Int

    public init(notes: [NoteSummary], total: Int, skippedLocked: Int = 0) {
        self.notes = notes
        self.total = total
        self.skippedLocked = skippedLocked
    }
}

/// Full plaintext content of one Apple Note. Locked notes never carry text.
public struct NoteContent: Sendable, Equatable {
    public var id: String
    public var title: String
    public var folder: String
    public var modified: Date?
    public var text: String
    public var locked: Bool

    public init(id: String, title: String, folder: String = "", modified: Date? = nil, text: String, locked: Bool = false) {
        self.id = id
        self.title = title
        self.folder = folder
        self.modified = modified
        self.text = locked ? "" : text
        self.locked = locked
    }
}

/// Read-only access to Apple Notes. Real implementation uses in-process Apple Events; checks use `DemoNotesReader`.
public protocol NotesReading: Sendable {
    func access(ask: Bool) async -> IntegrationAccess
    func listNotes(query: String?, limit: Int) async throws -> NotesListResult
    func readNote(id: String) async throws -> NoteContent?
}

/// Apple Notes scripting metadata and source (read only, plaintext only, no hardcoded localized folder names).
public enum NotesScript {
    public static let bundleIdentifier = "com.apple.Notes"

    /// Name of the app in the app's language.
    public static var appName: String { L("Notes", table: "Core") }

    /// Maximum recent unlocked notes whose plaintext is checked when a query does not match titles or folders.
    static let contentFallbackCap = 25

    /// Read-only AppleScript for Apple Notes.
    /// - Fetches bulk metadata (`id`, `name`, `modification date`, `password protected`, `container` name) first so Swift
    ///   filters locally (never `every note whose body contains`).
    /// - Always reads `plaintext`, never HTML `body`.
    /// - Checks `password protected` before touching `plaintext`; locked notes return empty text and `true`.
    /// - Never hardcodes localized folder names such as "Notes" or "Notizen".
    static let source = """
    on listNotesMetadata()
        tell application id "com.apple.Notes"
            with timeout of 30 seconds
                set noteCount to count of notes
                if noteCount is 0 then return {}
                set noteIDs to id of every note
                set noteNames to name of every note
                set noteDates to modification date of every note
                set noteLocked to password protected of every note
                set noteFolders to {}
                try
                    set noteFolders to name of container of every note
                on error
                    set noteFolders to {}
                end try
            end timeout
            return {noteIDs, noteNames, noteDates, noteLocked, noteFolders}
        end tell
    end listNotesMetadata

    on readNoteByID(noteID)
        tell application id "com.apple.Notes"
            with timeout of 30 seconds
                set foundNote to missing value
                try
                    set foundNote to note id noteID
                end try
                if foundNote is missing value then return {}
                set isLocked to false
                try
                    set isLocked to password protected of foundNote
                end try
                set theName to ""
                try
                    set v to name of foundNote
                    if v is not missing value then set theName to v as text
                end try
                set theFolder to ""
                try
                    set v to name of container of foundNote
                    if v is not missing value then set theFolder to v as text
                end try
                set theDate to missing value
                try
                    set theDate to modification date of foundNote
                end try
                if isLocked then
                    return {noteID, theName, theFolder, theDate, true, ""}
                end if
                set theText to ""
                try
                    set v to plaintext of foundNote
                    if v is not missing value then set theText to v as text
                end try
                return {noteID, theName, theFolder, theDate, false, theText}
            end timeout
        end tell
    end readNoteByID
    """

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func matches(_ query: String, in haystack: String) -> Bool {
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let target = normalized(haystack)
        return words.allSatisfy { target.contains($0) }
    }
}

/// Real Apple Notes reader via in-process `NSAppleScript` (zero Full Disk Access).
public struct SystemNotesReader: NotesReading {
    public init() {}

    public func access(ask: Bool) async -> IntegrationAccess {
        _ = await AppleEvents.launchHidden(bundle: NotesScript.bundleIdentifier)
        return await AppleEvents.permission(bundle: NotesScript.bundleIdentifier, appName: NotesScript.appName, ask: ask)
    }

    public func listNotes(query: String?, limit: Int) async throws -> NotesListResult {
        let cap = max(1, min(limit, 50))
        let fetched = try await fetchMetadata()
        let unlocked = fetched.unlocked.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NotesListResult(notes: Array(unlocked.prefix(cap)), total: unlocked.count, skippedLocked: fetched.skippedLocked)
        }
        let byMetadata = unlocked.filter { NotesScript.matches(trimmed, in: $0.title + " " + $0.folder) }
        if !byMetadata.isEmpty {
            return NotesListResult(notes: Array(byMetadata.prefix(cap)), total: byMetadata.count, skippedLocked: fetched.skippedLocked)
        }
        // Bounded plaintext fallback across the newest unlocked notes when titles/folders did not match.
        var contentMatches: [NoteSummary] = []
        for summary in unlocked.prefix(NotesScript.contentFallbackCap) {
            guard let note = try await readNote(id: summary.id), !note.locked else { continue }
            if NotesScript.matches(trimmed, in: note.title + "\n" + note.folder + "\n" + note.text) {
                contentMatches.append(summary)
                if contentMatches.count >= cap { break }
            }
        }
        return NotesListResult(notes: contentMatches, total: contentMatches.count, skippedLocked: fetched.skippedLocked)
    }

    public func readNote(id: String) async throws -> NoteContent? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try await AppleEvents.perform { () throws -> NoteContent? in
            let reply = try AppleEvents.call(NotesScript.source, handler: "readNoteByID",
                                             [NSAppleEventDescriptor(string: trimmed)], appName: NotesScript.appName)
            let parts = AppleEvents.items(reply)
            guard parts.count >= 6 else { return nil }
            let noteID = parts[0].stringValue ?? trimmed
            let title = parts[1].stringValue ?? ""
            let folder = parts[2].stringValue ?? ""
            let modified = parts[3].dateValue
            let locked = parts[4].booleanValue
            let text = locked ? "" : (parts[5].stringValue ?? "")
            return NoteContent(id: noteID, title: title, folder: folder, modified: modified, text: text, locked: locked)
        }
    }

    private func fetchMetadata() async throws -> (unlocked: [NoteSummary], skippedLocked: Int) {
        try await AppleEvents.perform { () throws -> (unlocked: [NoteSummary], skippedLocked: Int) in
            let reply = try AppleEvents.call(NotesScript.source, handler: "listNotesMetadata", appName: NotesScript.appName)
            let columns = AppleEvents.items(reply)
            guard columns.count >= 4 else { return ([], 0) }
            let ids = AppleEvents.items(columns[0])
            let names = AppleEvents.items(columns[1])
            let dates = AppleEvents.items(columns[2])
            let locks = AppleEvents.items(columns[3])
            let folders = columns.count >= 5 ? AppleEvents.items(columns[4]) : []
            let count = min(ids.count, min(names.count, min(dates.count, locks.count)))
            var unlocked: [NoteSummary] = []
            var skippedLocked = 0
            for index in 0..<count {
                if locks[index].booleanValue {
                    skippedLocked += 1
                    continue
                }
                guard let id = ids[index].stringValue, !id.isEmpty else { continue }
                let title = names[index].stringValue ?? ""
                let folder = index < folders.count ? (folders[index].stringValue ?? "") : ""
                unlocked.append(NoteSummary(id: id, title: title, folder: folder, modified: dates[index].dateValue))
            }
            return (unlocked, skippedLocked)
        }
    }
}

/// In-memory Apple Notes reader for checks and `PIPPA_DEMO=1`. Includes a locked note to verify skipping.
public final class DemoNotesReader: NotesReading, @unchecked Sendable {
    public struct StoredNote: Sendable, Equatable {
        public var id: String
        public var title: String
        public var folder: String
        public var modified: Date?
        public var plaintext: String
        public var locked: Bool

        public init(id: String, title: String, folder: String = "", modified: Date? = nil, plaintext: String, locked: Bool = false) {
            self.id = id
            self.title = title
            self.folder = folder
            self.modified = modified
            self.plaintext = plaintext
            self.locked = locked
        }
    }

    private let lock = NSLock()
    private var storedAccess: IntegrationAccess
    private var storedNotes: [StoredNote]

    public static var defaultNotes: [StoredNote] {
        let base = Date(timeIntervalSince1970: 1_791_360_000) // Oct 2026
        return [
            StoredNote(id: "x-coredata://demo/ICNote/p1", title: "Wohnungsübergabe Checkliste", folder: "Privat",
                       modified: base,
                       plaintext: "Wohnungsübergabe Checkliste\nZählerstand Strom: 48210 kWh\nSchlüssel: 3 Haustür, 2 Briefkasten, 1 Keller."),
            StoredNote(id: "x-coredata://demo/ICNote/p2", title: "Packliste Herbsturlaub", folder: "Reisen",
                       modified: base.addingTimeInterval(-86_400),
                       plaintext: "Packliste Herbsturlaub\nReisepass, Regenjacke, Ladegerät, Bahncard."),
            StoredNote(id: "x-coredata://demo/ICNote/p3", title: "Meeting Notes Q4", folder: "Work",
                       modified: base.addingTimeInterval(-172_800),
                       plaintext: "Meeting Notes Q4\nBudget sign-off with Clara Miller on Friday."),
            StoredNote(id: "x-coredata://demo/ICNote/p4-locked", title: "Tresor & Zugangsdaten", folder: "Privat",
                       modified: base.addingTimeInterval(-3_600),
                       plaintext: "LOCKED-SECRET-MUST-NEVER-LEAK-991", locked: true),
        ]
    }

    public init(access: IntegrationAccess = .granted, notes: [StoredNote] = DemoNotesReader.defaultNotes) {
        storedAccess = access
        storedNotes = notes
    }

    public var accessState: IntegrationAccess {
        get { lock.withLock { storedAccess } }
        set { lock.withLock { storedAccess = newValue } }
    }

    public func access(ask: Bool) async -> IntegrationAccess {
        lock.withLock {
            if storedAccess == .notDetermined && ask { storedAccess = .granted }
            return storedAccess
        }
    }

    public func listNotes(query: String?, limit: Int) async throws -> NotesListResult {
        let (access, notes) = lock.withLock { (storedAccess, storedNotes) }
        guard access == .granted else { throw PippaError.accessDenied(NotesScript.appName) }
        let cap = max(1, min(limit, 50))
        var skippedLocked = 0
        var unlocked: [StoredNote] = []
        for note in notes {
            if note.locked {
                skippedLocked += 1
            } else {
                unlocked.append(note)
            }
        }
        unlocked.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty
            ? unlocked
            : unlocked.filter { NotesScript.matches(trimmed, in: $0.title + "\n" + $0.folder + "\n" + $0.plaintext) }
        let items = filtered.prefix(cap).map {
            NoteSummary(id: $0.id, title: $0.title, folder: $0.folder, modified: $0.modified)
        }
        return NotesListResult(notes: Array(items), total: filtered.count, skippedLocked: skippedLocked)
    }

    public func readNote(id: String) async throws -> NoteContent? {
        let (access, notes) = lock.withLock { (storedAccess, storedNotes) }
        guard access == .granted else { throw PippaError.accessDenied(NotesScript.appName) }
        guard let found = notes.first(where: { $0.id == id }) else { return nil }
        return NoteContent(id: found.id, title: found.title, folder: found.folder, modified: found.modified,
                           text: found.locked ? "" : found.plaintext, locked: found.locked)
    }
}
