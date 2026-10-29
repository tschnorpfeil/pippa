import Foundation

/// What the detail rail of a conversation lists: the files it works with, what Pippa made in it and the web pages it
/// read. Built from Pippa's own records in the history (receipts, result cards, found-file attachments, task-result
/// notices), never from an answer's text.
public struct ConversationArtifacts: Equatable, Sendable {
    public struct FileInUse: Equatable, Sendable, Identifiable {
        public var url: URL
        /// Waiting for the next message (shown at the composer); otherwise already used by an answer.
        public var pending: Bool
        public var id: String { url.standardizedFileURL.path }
    }

    public struct Made: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case prepared, found, created, updated, result, mailDraft, draftInMail, calendarEvent, reminder, chart
        }
        public var id: String
        public var kind: Kind
        /// File name, draft subject, entry line ("Fri, Nov 6, 09:00 – Tax advisor"), chart title or the task result's first
        /// line.
        public var title: String
        /// A file Pippa's own records point to (prepared, found); `nil` for names only.
        public var file: URL?
        /// The card that vouches for a prepared file: open it only through the tray's check.
        public var preparedCard: PreparedFilesCard?
        /// Journal job of the answer or task (its reveal location finds created files).
        public var receipt: UUID?
        public var messageID: UUID
        public var date: Date
    }

    public struct Source: Equatable, Sendable, Identifiable {
        public var id: String
        public var url: URL
        public var host: String
        public var path: String?
        public var messageID: UUID
    }

    public private(set) var filesInUse: [FileInUse] = []
    public private(set) var selectedText: String?
    public private(set) var made: [Made] = []
    public private(set) var sources: [Source] = []

    public var isEmpty: Bool { filesInUse.isEmpty && selectedText == nil && made.isEmpty && sources.isEmpty }

    /// Newest first, each thing once. Per message: charts and prepared files, the draft card, native results, found files,
    /// then a task result (Pippa's own notice: tidying, invoice table). `exists` drops found files that are gone.
    public init(_ conversation: Conversation?, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        guard let conversation else { return }
        let pending = ConversationPromptAttachments.pendingFiles(in: conversation).map { FileInUse(url: $0, pending: true) }
        let used = ConversationPromptAttachments.currentFiles(in: conversation).map { FileInUse(url: $0, pending: false) }
        filesInUse = pending + used
        selectedText = conversation.context?.selectedText.flatMap { $0.isEmpty ? nil : $0 }
        var made: [Made] = [], sources: [Source] = []
        var seenMade = Set<String>(), seenSources = Set<String>()
        func add(_ item: Made) { if seenMade.insert(item.id).inserted { made.append(item) } }
        // The person's own documents are files in use, never files Pippa found (append copies waiting ones onto a result).
        let ownFiles = Set((conversation.context?.files ?? []).map { Self.key($0) })
        for message in conversation.messages.reversed() where message.role != .user {
            let cards = message.actions?.cards ?? []
            let items = message.actions?.items ?? []
            // Pippa's own task result: its text is her notice, never an answer, and its attachments are the documents
            // it used (ConversationStore.append), not files it found.
            let noticeOnly: Bool = message.work == nil && message.modelLabel == nil
            let taskResult: Bool = message.role == .assistant && message.receipt != nil && items.isEmpty && noticeOnly
            var preparedJobs = Set<UUID>()
            for card in cards {
                // A chart card: its title, shown in the conversation (it has no file of its own).
                if case .chart(let chart) = card {
                    let title = chart.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        add(Made(id: "chart:" + message.id.uuidString + ":" + title, kind: .chart, title: title, file: nil,
                                 preparedCard: nil, receipt: nil, messageID: message.id, date: message.timestamp))
                    }
                    continue
                }
                guard case .preparedFiles(let prepared) = card else { continue }
                preparedJobs.insert(prepared.jobID)
                for file in prepared.files {
                    add(Made(id: "file:" + Self.key(file), kind: .prepared, title: file.lastPathComponent, file: file,
                             preparedCard: prepared, receipt: nil, messageID: message.id, date: message.timestamp))
                }
            }
            if let draft = message.mailDraft, draft.state != .discarded {
                add(Made(id: "draft:" + message.id.uuidString, kind: .mailDraft,
                         title: draft.subject.trimmingCharacters(in: .whitespacesAndNewlines), file: nil, preparedCard: nil,
                         receipt: nil, messageID: message.id, date: message.timestamp))
            }
            for item in items where item.happened {
                let name = item.name ?? ""
                // The native line of a prepared file: its card above already stands for it.
                let preparedLine: Bool = item.reason == "preparedFiles" || item.operationID.map({ preparedJobs.contains($0) }) == true
                let matched: Made.Kind?
                switch item.action {
                case "calendarAdd": matched = .calendarEvent
                case "reminderAdd": matched = .reminder
                case "mailDraft": matched = .draftInMail
                case "create": matched = preparedLine ? nil : .created
                case "overwrite": matched = .updated
                default: matched = nil
                }
                guard let kind = matched, !name.isEmpty else { continue }
                let onDisk = kind == .created || kind == .updated
                let id: String
                if let operation = item.operationID { id = "op:" + operation.uuidString }
                else if onDisk { id = "name:" + name }
                else { id = kind.rawValue + ":" + name }
                add(Made(id: id, kind: kind, title: name, file: nil, preparedCard: nil,
                         receipt: onDisk ? message.receipt : nil, messageID: message.id, date: message.timestamp))
            }
            if message.role == .assistant, !taskResult, message.mailDraft == nil, message.calendar == nil {
                for file in message.attachments where !file.hasDirectoryPath && !ownFiles.contains(Self.key(file)) && exists(file) {
                    add(Made(id: "file:" + Self.key(file), kind: .found, title: file.lastPathComponent, file: file,
                             preparedCard: nil, receipt: nil, messageID: message.id, date: message.timestamp))
                }
            }
            if taskResult, let receipt = message.receipt {
                let first = message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                let title = first.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    add(Made(id: "job:" + receipt.uuidString, kind: .result, title: String(title.prefix(80)), file: nil,
                             preparedCard: nil, receipt: receipt, messageID: message.id, date: message.timestamp))
                }
            }
            let webs = cards.compactMap { card -> WebSourcesCard? in
                if case .web(let web) = card { return web } else { return nil }
            }
            let pages = webs.flatMap(\.items)
            let read = pages.filter(\.read)
            for page in read.isEmpty ? pages : read {
                let key = WebSourcesCard.key(page.url)
                if seenSources.insert(key).inserted {
                    sources.append(Source(id: key, url: page.url, host: page.host, path: page.path, messageID: message.id))
                }
            }
        }
        self.made = made
        self.sources = sources
    }

    /// A created file Pippa knows only by name: next to its answer's reveal location (Executor.recordAgentChanges reveals
    /// the last changed file), else inside it, else `nil`. A name with a path separator is never followed.
    public static func file(named name: String, near reveal: URL?,
                            exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        guard let reveal, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        if reveal.lastPathComponent == name { return exists(reveal) ? reveal : nil }
        for candidate in [reveal.deletingLastPathComponent().appendingPathComponent(name), reveal.appendingPathComponent(name)]
        where exists(candidate) { return candidate }
        return nil
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
