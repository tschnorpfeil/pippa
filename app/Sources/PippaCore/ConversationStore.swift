import Foundation

public struct ConversationMessage: Codable, Sendable, Identifiable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant, system }
    public var id: UUID
    public var role: Role
    public var text: String
    public var timestamp: Date
    public var modelLabel: String?
    /// Answer that was halted with "Stop": only the part up to then. Missing in older histories (= no).
    public var stopped: Bool?
    /// System line the person should read (error, missing capability, "still tired"), instead of a quiet side note.
    /// Missing in older histories (= no).
    public var notice: Bool?
    /// Local file references only; this store never reads or copies their contents.
    public var attachments: [URL]
    /// Note "new conversation started": the conversation before it, for the way back. Missing in older histories.
    public var previousConversation: UUID?
    /// Receipt of a job in this conversation: its identifier, so that "Undo" stays reachable from the row.
    public var receipt: UUID?
    /// Answer is a draft (letter, cancellation, objection …) to copy. Missing in older histories (= no).
    public var draft: Bool?
    public var mailDraft: ConversationMailDraft?
    /// FLOW-10: answer from the calendar (or request for access) with period and question. Missing in older histories.
    public var calendar: ConversationCalendarRead?
    /// Thought Line receipt under an answer: what was read and how long it took. Missing in older histories.
    public var work: WorkReceipt?
    /// What tools actually did during this answer (from tool events and the Pippa guard, never from the model's text).
    /// Missing in older histories and on the old path.
    public var actions: ActionReceipt?
    public init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date(), attachments: [URL] = [], modelLabel: String? = nil,
                stopped: Bool = false, notice: Bool = false, previousConversation: UUID? = nil, receipt: UUID? = nil, draft: Bool = false, mailDraft: ConversationMailDraft? = nil,
                calendar: ConversationCalendarRead? = nil, work: WorkReceipt? = nil, actions: ActionReceipt? = nil) {
        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp; self.attachments = attachments; self.modelLabel = modelLabel
        self.stopped = stopped ? true : nil
        self.notice = notice ? true : nil
        self.previousConversation = previousConversation
        self.receipt = receipt
        self.draft = draft ? true : nil
        self.mailDraft = mailDraft
        self.calendar = calendar
        self.work = work
        self.actions = actions.flatMap { $0.items.isEmpty ? nil : $0 }
    }
}

public struct ConversationContext: Codable, Sendable, Equatable {
    public var name: String
    public var files: [URL]
    public var selectedText: String?
    public var bookmarks: [Data]
    /// Most recently supplied batch; all files remain available for explicit comparisons.
    public var focusedFiles: [URL]?
    /// New documents awaiting their user prompt; nil decodes legacy conversations.
    public var pendingFiles: [URL]?
    public init(name: String, files: [URL] = [], selectedText: String? = nil, bookmarks: [Data] = [], focusedFiles: [URL]? = nil, pendingFiles: [URL]? = nil) {
        self.name = name; self.files = files; self.selectedText = selectedText; self.bookmarks = bookmarks; self.focusedFiles = focusedFiles; self.pendingFiles = pendingFiles
    }

    /// One bookmark per file (by path), in the order of `files`. Existing ones are reused:
    /// newly created bookmarks of the same file are never byte-identical, so comparing the data would find no duplicate.
    public static func bookmarks(for files: [URL], existing: [Data], resolve: (Data) -> URL?, make: (URL) -> Data?) -> [Data] {
        func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        var byPath: [String: Data] = [:]
        for data in existing { if let url = resolve(data), byPath[key(url)] == nil { byPath[key(url)] = data } }
        var seen = Set<String>(), result: [Data] = []
        for url in files where seen.insert(key(url)).inserted {
            if let data = byPath[key(url)] ?? make(url) { result.append(data) }
        }
        return result
    }
}

extension ConversationContext {
    /// A fresh Give starts a topic once the prior batch has been used. Before the first
    /// question/action, additions belong together regardless of folder or elapsed time.
    public static func startsNewConversation(messages: [ConversationMessage]) -> Bool {
        messages.contains { $0.role == .user || $0.role == .assistant || $0.receipt != nil }
    }

    /// A unique working location for organizing and new files: the dropped folder or the common folder
    /// of all files. If they are in different places, `nil` (then it asks instead of silently picking one).
    public static func commonFolder(_ urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        if urls.count == 1, first.hasDirectoryPath { return first }
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
        return parents.count == 1 ? parents.first : nil
    }
}

public struct Conversation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ConversationMessage]
    public var context: ConversationContext?
    /// A new model session after removing source context; visible history stays intact.
    public var modelSessionRevision: UUID?
    public var retiredModelSessionRevisions: [UUID]?
    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), updatedAt: Date? = nil, messages: [ConversationMessage] = [], context: ConversationContext? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.messages = messages; self.context = context
    }

    /// When work last happened here: background notes without a receipt
    /// (e.g. "A job was interrupted" at startup) do not count, otherwise an old conversation would look fresh again.
    public var lastActivity: Date {
        messages.last { !($0.role == .system && $0.notice == true && $0.receipt == nil) }?.timestamp ?? createdAt
    }
}

public struct ConversationSummary: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
}

public enum ConversationStoreError: LocalizedError, Sendable {
    case corrupted, unsupportedVersion, unknownConversation, changedExternally, invalidDraftTransition
    public var errorDescription: String? {
        switch self {
        case .corrupted: L("The conversation history couldn’t be read. The saved file is kept.", table: "Core")
        case .unsupportedVersion: L("This conversation history comes from a newer version of Pippa. The saved file is kept.", table: "Core")
        case .unknownConversation: L("I can’t find this conversation anymore.", table: "Core")
        case .invalidDraftTransition: L("This draft can no longer be changed or opened again. Start a new draft to try again.", table: "Core")
        case .changedExternally: L("The conversation history was changed outside this window. Please open Pippa again.", table: "Core")
        }
    }
}

/// Durable UI history, independent of an individual model session or its context window.
/// History is never pruned automatically. A bounded list only limits the displayed metadata.
@MainActor public final class ConversationStore {
    private struct Archive: Codable {
        var version = 1
        var selectedID: UUID?
        var conversations: [Conversation] = []
    }
    public let fileURL: URL
    /// Unreadable (or newer) history that was set aside on opening: `history.corrupt-<time>.json`.
    public private(set) var setAside: URL?
    private var archive: Archive
    private var diskSnapshot: Data?
    public var selectedID: UUID? { archive.selectedID }

    public init(directory: URL = Pippa.supportDirectory.appendingPathComponent("Conversations", isDirectory: true)) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if let decoded = Self.valid(data) {
                archive = decoded; diskSnapshot = data
            } else {
                // Unreadable or from a newer version: set aside unchanged and start over,
                // instead of disabling the chat permanently. The file is kept.
                setAside = try Self.moveAside(fileURL)
                archive = Archive(); diskSnapshot = nil
            }
        } else {
            archive = Archive(); diskSnapshot = nil
        }
        try recoverOpeningDrafts()
    }

    private func recoverOpeningDrafts() throws {
        var next = archive
        var changed = false
        for conversation in next.conversations.indices {
            for message in next.conversations[conversation].messages.indices {
                if next.conversations[conversation].messages[message].mailDraft?.state == .opening {
                    next.conversations[conversation].messages[message].mailDraft?.state = .uncertain
                    changed = true
                }
            }
        }
        if changed { try persist(next) }
    }

    private static func valid(_ data: Data) -> Archive? {
        guard let decoded = try? JSONDecoder().decode(Archive.self, from: data), decoded.version == 1 else { return nil }
        let ids = Set(decoded.conversations.map(\.id))
        guard ids.count == decoded.conversations.count,
              decoded.selectedID.map({ ids.contains($0) }) ?? true,
              decoded.conversations.allSatisfy({ Set($0.messages.map(\.id)).count == $0.messages.count }) else { return nil }
        return decoded
    }

    private static func moveAside(_ url: URL) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        var target = url.deletingLastPathComponent().appendingPathComponent("history.corrupt-\(stamp).json")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("history.corrupt-\(stamp)-\(n).json"); n += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    public func list(limit: Int = 50) -> [ConversationSummary] {
        archive.conversations.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(max(0, limit)).map {
            ConversationSummary(id: $0.id, title: $0.title, createdAt: $0.createdAt, updatedAt: $0.updatedAt, messageCount: $0.messages.count)
        }
    }

    public func load(_ id: UUID) throws -> Conversation {
        guard let result = archive.conversations.first(where: { $0.id == id }) else { throw ConversationStoreError.unknownConversation }
        return result
    }

    @discardableResult public func create(title: String = L("New Conversation", table: "Core")) throws -> Conversation {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = Conversation(title: trimmed.isEmpty ? L("New Conversation", table: "Core") : trimmed)
        var next = archive
        next.conversations.append(conversation); next.selectedID = conversation.id
        try persist(next)
        return conversation
    }

    @discardableResult public func select(_ id: UUID) throws -> Conversation {
        let conversation = try load(id)
        var next = archive; next.selectedID = id
        try persist(next)
        return conversation
    }

    @discardableResult public func append(_ message: ConversationMessage, to id: UUID, capturingAttachments: Bool = false) throws -> Conversation {
        guard let index = archive.conversations.firstIndex(where: { $0.id == id }) else { throw ConversationStoreError.unknownConversation }
        var next = archive
        guard !next.conversations[index].messages.contains(where: { $0.id == message.id }) else { throw ConversationStoreError.corrupted }
        var message = message
        if capturingAttachments && message.role == .user {
            message.attachments = ConversationPromptAttachments.pendingFiles(in: next.conversations[index])
            next.conversations[index].context?.pendingFiles = []
        }
        // Completed workflows consume pending documents too; their historical notice remains.
        if message.receipt != nil {
            if message.attachments.isEmpty { message.attachments = ConversationPromptAttachments.pendingFiles(in: next.conversations[index]) }
            next.conversations[index].context?.pendingFiles = []
        }
        next.conversations[index].messages.append(message)
        next.conversations[index].updatedAt = max(Date(), max(message.timestamp, next.conversations[index].updatedAt))
        try persist(next)
        return next.conversations[index]
    }

    /// Atomically replaces only this card; messages, source context and selected topic stay intact.
    @discardableResult public func updateMailDraft(messageID: UUID, in conversationID: UUID,
                                                   draft: ConversationMailDraft) throws -> Conversation {
        guard let conversation = archive.conversations.firstIndex(where: { $0.id == conversationID }),
              let message = archive.conversations[conversation].messages.firstIndex(where: { $0.id == messageID }),
              let previous = archive.conversations[conversation].messages[message].mailDraft else {
            throw ConversationStoreError.unknownConversation
        }
        guard previous.canUpdate(to: draft) else { throw ConversationStoreError.invalidDraftTransition }
        var next = archive
        next.conversations[conversation].messages[message].mailDraft = draft
        next.conversations[conversation].updatedAt = max(Date(), next.conversations[conversation].updatedAt)
        try persist(next)
        return next.conversations[conversation]
    }

    /// Only change the "Save as draft in Mail" offer of a receipt (used / free again). Rows stay.
    @discardableResult public func updateMailOffer(messageID: UUID, in conversationID: UUID, offer: MailDraftOffer) throws -> Conversation {
        guard let conversation = archive.conversations.firstIndex(where: { $0.id == conversationID }),
              let message = archive.conversations[conversation].messages.firstIndex(where: { $0.id == messageID }),
              archive.conversations[conversation].messages[message].actions?.mailOffer?.id == offer.id else {
            throw ConversationStoreError.unknownConversation
        }
        var next = archive
        next.conversations[conversation].messages[message].actions?.mailOffer = offer
        try persist(next)
        return next.conversations[conversation]
    }

    @discardableResult public func setContext(_ context: ConversationContext?, for id: UUID) throws -> Conversation {
        guard let index = archive.conversations.firstIndex(where: { $0.id == id }) else { throw ConversationStoreError.unknownConversation }
        var next = archive
        let old = next.conversations[index].context
        if old?.files.contains(where: { !(context?.files ?? []).contains($0) }) == true
            || (old?.selectedText != nil && old?.selectedText != context?.selectedText) {
            if let revision = next.conversations[index].modelSessionRevision {
                next.conversations[index].retiredModelSessionRevisions = (next.conversations[index].retiredModelSessionRevisions ?? []) + [revision]
            }
            next.conversations[index].modelSessionRevision = UUID()
        }
        next.conversations[index].context = context
        next.conversations[index].updatedAt = max(Date(), next.conversations[index].updatedAt)
        try persist(next)
        return next.conversations[index]
    }

    @discardableResult public func rename(_ id: UUID, title: String) throws -> Conversation {
        guard let index = archive.conversations.firstIndex(where: { $0.id == id }) else { throw ConversationStoreError.unknownConversation }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = archive
        next.conversations[index].title = trimmed.isEmpty ? L("New Conversation", table: "Core") : trimmed
        next.conversations[index].updatedAt = max(Date(), next.conversations[index].updatedAt)
        try persist(next)
        return next.conversations[index]
    }

    /// Files a conversation still has attached as context (all conversations, including older ones).
    public func contextFiles() -> [URL] { archive.conversations.flatMap { $0.context?.files ?? [] } }

    /// Removes a conversation from the history. If it was selected, none is selected afterwards.
    public func delete(_ id: UUID) throws {
        guard archive.conversations.contains(where: { $0.id == id }) else { throw ConversationStoreError.unknownConversation }
        var next = archive
        next.conversations.removeAll { $0.id == id }
        if next.selectedID == id { next.selectedID = nil }
        try persist(next)
    }

    private func persist(_ next: Archive) throws {
        // Another instance or an external edit must not be silently overwritten.
        let current = FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : nil
        guard current == diskSnapshot else { throw ConversationStoreError.changedExternally }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        try data.write(to: fileURL, options: .atomic)
        archive = next; diskSnapshot = data
    }
}
