import AppKit
import UniformTypeIdentifiers
import PiRPC
import PippaCore

/// One step Pi took while answering (a tool call), shown as a quiet line under the answer.
struct ChatStep: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var done = false
    var failed = false
}

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var files: [String] = []
    var steps: [ChatStep] = []
    var cards: [ResultCard] = []
    var receipts: [PippaMCPWriteReceipt] = []
    /// The model's reasoning before it answered (local models think first); shown folded.
    var thinking: String?
    /// Dates in the answer that nothing Pippa read shows (`DateEvidence`); named under the answer.
    var unsupportedDates: [String]?
    /// Dates in the answer that a source shows.
    var checkedDates: [String]?
    /// What the answer read, from its tool calls.
    var sources: [ChatSource]?
    /// How full the conversation's context was afterwards.
    var context: ContextUsage?
    var error: String?
    /// How long the answer took, for "Worked for 18 s".
    var duration: TimeInterval?
    /// The person stopped the answer.
    var stopped: Bool?
}

struct Conversation: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var updated: Date
    var messages: [ChatMessage]
    var pinned: Bool?
}

/// The chat: conversations on disk (what the window shows), one answer at a time through `PiSession`.
/// Pi keeps the model's side of each conversation in its own session file.
@MainActor
final class ChatModel: ObservableObject {
    static let shared = ChatModel()

    @Published private(set) var conversations: [Conversation] = []
    @Published var currentID: String?
    @Published var draft = ""
    @Published var attachments: [URL] = []
    /// The app that was in front when Pippa was called ("Mail"), told to Pi with the next question so "this mail"
    /// works; Pi reads it with `front_read`. Not shown: most questions have nothing to do with it.
    var frontApp: String?
    /// An answer came in or failed while the chat window was not in front: the pill says so until the chat opens.
    @Published var unseen: Unseen?
    enum Unseen { case answer, failed }
    @Published private(set) var isAnswering = false
    /// The conversation the running answer belongs to. The person may look at another one meanwhile.
    @Published private(set) var answeringID: String?
    /// Conversations whose answer arrived while the person looked at another one: a dot in the sidebar.
    @Published private(set) var unseenIDs: Set<String> = []
    /// What the current answer read, for its dates.
    private var evidence = DateEvidence()
    /// Sources of tool calls that have started but not ended.
    private var pendingSources: [String: ChatSource] = [:]
    /// When the running answer started, for the live "Thinking … 12 s".
    @Published private(set) var answerStarted: Date?
    private var answer: Task<Void, Never>?
    private var pdfTask: Task<Void, Never>?
    /// "Stop" was pressed for the running answer.
    private var stopRequested = false
    /// Counts answers, so a late result of an earlier one never lands on a newer one.
    private var generation = 0

    private static var folder: URL { Pippa.supportDirectory.appendingPathComponent("conversations", isDirectory: true) }

    var current: Conversation? { conversations.first { $0.id == currentID } }
    /// The conversation with the running answer (not necessarily the one on screen).
    var answering: Conversation? { answeringID.flatMap { id in conversations.first { $0.id == id } } }
    /// The running answer belongs to the conversation on screen (Stop shows there, not elsewhere).
    var isAnsweringHere: Bool { isAnswering && (answeringID == nil || answeringID == currentID) }

    init() { load() }

    // MARK: Conversations

    func newConversation() {
        if let current, current.messages.isEmpty { return }
        currentID = nil
        draft = ""; attachments = []
    }

    /// Works while an answer runs: it keeps arriving in its own conversation.
    func select(_ id: String) {
        currentID = id
        unseenIDs.remove(id)
    }

    func delete(_ id: String) {
        guard !isAnswering || id != answeringID else { return }
        unseenIDs.remove(id)
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
        try? FileManager.default.trashItem(at: Self.folder.appendingPathComponent("\(id).json"), resultingItemURL: nil)
        Task { await PiSession.shared.forget(id) }
    }

    func rename(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = String(title.prefix(80))
        save(id)
    }

    func togglePin(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned = conversations[index].pinned == true ? nil : true
        save(id)
    }

    // MARK: Asking

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAnswering, !text.isEmpty || !attachments.isEmpty else { return }
        let id = currentID ?? UUID().uuidString.lowercased()
        if current == nil {
            let title = String((text.isEmpty ? attachments.first?.lastPathComponent ?? "" : text).prefix(60))
            conversations.insert(Conversation(id: id, title: title, updated: Date(), messages: []), at: 0)
            currentID = id
        }
        let files = attachments.map(\.path)
        append(ChatMessage(role: .user, text: text, files: files), to: id)
        // The question is on disk before the answer starts: a crash or quit mid-answer never loses it.
        save(id)
        let reply = ChatMessage(role: .assistant, text: "")
        append(reply, to: id)
        let prompt = Self.prompt(text, files: files, frontApp: frontApp)
        draft = ""; attachments = []; frontApp = nil
        let started = Date()
        begin(started, in: id)
        _ = PippaMCPService.readNotes.take(); _ = PippaMCPService.writeNotes.take()
        evidence = DateEvidence(); pendingSources = [:]
        evidence.add(prompt: prompt)
        let turn = generation
        answer = Task {
            do {
                try await PiSession.shared.ask(prompt, conversation: id) { event in self.apply(event, in: id) }
            } catch is CancellationError {
            } catch {
                if !stopRequested { update(reply.id, in: id) { $0.error = error.localizedDescription } }
            }
            let cards = PippaMCPService.readNotes.take().compactMap(\.card)
            let receipts = PippaMCPService.writeNotes.take()
            let stopped = stopRequested
            update(reply.id, in: id) { message in
                message.cards = cards
                message.receipts = receipts
                let dates = evidence.unsupported(in: message.text)
                message.unsupportedDates = dates.isEmpty ? nil : dates
                let checked = evidence.supported(in: message.text)
                message.checkedDates = checked.isEmpty ? nil : checked
                for index in message.steps.indices where !message.steps[index].done { message.steps[index].done = true }
                message.duration = Date().timeIntervalSince(started)
                if stopped {
                    message.stopped = true
                    // Pi reports the abort as an error; the person asked for it, so it is no failure.
                    message.error = nil
                }
            }
            // Done before the stats: a slow `get_session_stats` never leaves the window stuck in "answering".
            end()
            if !stopped {
                if !ChatWindow.shared.isKey {
                    unseen = conversations.first(where: { $0.id == id })?.messages.last?.error == nil ? .answer : .failed
                }
                if currentID != id { unseenIDs.insert(id) }
            }
            save(id)
            guard let usage = await PiSession.shared.contextUsage(), generation == turn else { return }
            update(reply.id, in: id) { $0.context = usage }
            save(id)
        }
    }

    /// The person picks up their question again: its words and files go back into the composer.
    func edit(_ message: ChatMessage) {
        guard !isAnswering, message.role == .user else { return }
        draft = message.text
        attachments = message.files.map { URL(fileURLWithPath: $0) }
    }

    /// The last answer failed: ask the same question again.
    func retry() {
        guard !isAnswering, let id = currentID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let messages = conversations[index].messages
        guard messages.count >= 2, messages[messages.count - 1].role == .assistant, messages[messages.count - 2].role == .user else { return }
        let question = messages[messages.count - 2]
        conversations[index].messages.removeLast(2)
        draft = question.text
        attachments = question.files.map { URL(fileURLWithPath: $0) }
        send()
    }

    /// Dropped photos or PDFs, one PDF: done by the app itself, no model needed.
    func makePDF() {
        guard !isAnswering, !attachments.isEmpty else { return }
        let id = currentID ?? UUID().uuidString.lowercased()
        if current == nil {
            conversations.insert(Conversation(id: id, title: T("One PDF", table: "App"), updated: Date(), messages: []), at: 0)
            currentID = id
        }
        let files = attachments
        append(ChatMessage(role: .user, text: T("Make one PDF", table: "App"), files: files.map(\.path)), to: id)
        save(id)
        let reply = ChatMessage(role: .assistant, text: "")
        append(reply, to: id)
        attachments = []
        let started = Date()
        begin(started, in: id)
        pdfTask = Task {
            let result = await PippaMCPService.makePDF(files)
            let stopped = stopRequested
            update(reply.id, in: id) { message in
                message.duration = Date().timeIntervalSince(started)
                if stopped { message.stopped = true; return }
                if let card = result.card { message.cards = [card] }
                if result.failed { message.error = result.text } else if result.card == nil { message.text = result.text }
            }
            end()
            save(id)
        }
    }

    /// The button shows when everything attached is a photo or a PDF.
    var canMakePDF: Bool {
        !attachments.isEmpty && attachments.allSatisfy { url in
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            return type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true
        }
    }

    /// "Stop": Pi aborts the answer and settles, the answer is marked as stopped. Should Pi not settle soon after,
    /// the answer task is cancelled, so the window never stays in "answering".
    func stop() {
        guard isAnswering, !stopRequested else { return }
        stopRequested = true
        if let pdfTask { pdfTask.cancel(); return }
        let running = answer
        Task { await PiSession.shared.stop() }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if isAnswering, answer == running { running?.cancel() }
        }
    }

    private func begin(_ started: Date, in id: String) {
        generation += 1
        stopRequested = false
        answeringID = id
        isAnswering = true
        answerStarted = started
    }

    private func end() {
        isAnswering = false
        answeringID = nil
        answerStarted = nil
        answer = nil
        pdfTask = nil
        stopRequested = false
    }

    /// What Pi receives: the person's words, then the files they added and the app they called Pippa from.
    /// An online provider's failure mid-answer ("401 {…}", "usage limit") as one plain sentence; anything else as Pi said it.
    static func modelError(_ error: String, online: Bool) -> String {
        guard online, let problem = PiProviderClient.problem(in: error) else { return error }
        return problem == .limit
            ? T("Your online AI limit is reached for now. Try again later, or switch to the AI on this Mac in Settings.", table: "App")
            : T("Reconnect your online AI in Settings.", table: "App")
    }

    static func prompt(_ text: String, files: [String], frontApp: String?) -> String {
        var parts = [text]
        if !files.isEmpty { parts.append("Files:\n" + files.map { "- \($0)" }.joined(separator: "\n")) }
        if let frontApp { parts.append("[Background context only: \(frontApp) was in front when Pippa opened. This is not a request to read that app. Use it only if the person asks about its content.]") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func apply(_ event: PiRPCEvent, in id: String) {
        evidence.observe(event)
        switch event {
        case .textDelta(let delta):
            updateLast(in: id) { $0.text += delta }
        case .thinkingDelta(let delta):
            updateLast(in: id) { $0.thinking = ($0.thinking ?? "") + delta }
        case .toolStarted(let call, let name, let arguments):
            updateLast(in: id) { $0.steps.append(ChatStep(id: call, label: StepLabel.text(tool: name, arguments: arguments))) }
            if let source = SourceLog.source(tool: name, arguments: arguments) { pendingSources[call] = source }
        case .toolEnded(let call, let name, let isError, let result, let outcome, _):
            let failed = isError || (outcome.map { $0 != .done } ?? false)
            updateLast(in: id) { message in
                guard let index = message.steps.firstIndex(where: { $0.id == call }) else { return }
                message.steps[index].done = true
                message.steps[index].failed = failed
            }
            // A source counts once it was read; the same file read twice shows once, with its latest pages.
            if var source = pendingSources.removeValue(forKey: call), !failed {
                if name.hasSuffix("read_document") { source.detail = SourceLog.detail(result: result) }
                updateLast(in: id) { message in
                    var sources = message.sources ?? []
                    sources.removeAll { $0.kind == source.kind && $0.name == source.name && $0.location == source.location }
                    sources.append(source)
                    message.sources = sources
                }
            }
        case .assistantEnded(_, let reason, let error):
            if reason == "toolUse" { updateLast(in: id) { if !$0.text.isEmpty, !$0.text.hasSuffix("\n") { $0.text += "\n\n" } } }
            let online = SettingsModel.shared.inferenceSettings.usesOnlineAI
            if reason == "error", let error { updateLast(in: id) { $0.error = Self.modelError(error, online: online) } }
            // The model used up its answer length (usually while thinking) and stopped mid-way: say so, never end quietly.
            if reason == "length" {
                updateLast(in: id) {
                    $0.error = online ? T("That was too much at once for the AI. Ask for a smaller part, for example one document at a time.", table: "App")
                        : T("That was too much at once for the AI on this Mac. Ask for a smaller part, for example one document at a time.", table: "App")
                }
            }
        case .notice(let text, let kind) where kind == "error" || kind == "warning":
            updateLast(in: id) { $0.error = text }
        default:
            break
        }
    }

    /// Snapshots only (`Snapshots`): never saved.
    func replaceForSnapshot(_ conversations: [Conversation], current: String?, answering: Bool) {
        self.conversations = conversations
        currentID = current
        isAnswering = answering
        answeringID = answering ? current : nil
        answerStarted = answering ? Date().addingTimeInterval(-42) : nil
    }

    // MARK: Storage

    private func append(_ message: ChatMessage, to id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.append(message)
        conversations[index].updated = Date()
    }

    /// Changes one message by its id (not "the last one": a new question may have come since).
    private func update(_ messageID: UUID, in id: String, _ change: (inout ChatMessage) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              let message = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&conversations[index].messages[message])
    }

    private func updateLast(in id: String, _ change: (inout ChatMessage) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), !conversations[index].messages.isEmpty else { return }
        change(&conversations[index].messages[conversations[index].messages.count - 1])
    }

    private func load() {
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        conversations = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    private func save(_ id: String) {
        guard let conversation = conversations.first(where: { $0.id == id }),
              let data = try? JSONEncoder().encode(conversation) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.folder.appendingPathComponent("\(id).json"), options: .atomic)
    }
}

/// A short everyday line for a tool call ("Reading Lease.pdf"). Display only; Pi never sees it.
enum StepLabel {
    static func text(tool: String, arguments: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let name = tool.hasPrefix("mcp__pippa__") ? String(tool.dropFirst("mcp__pippa__".count)) : tool
        func file(_ key: String) -> String { (args[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
        func value(_ key: String) -> String { (args[key] as? String) ?? "" }
        switch name {
        case "read", "read_document": return T("Reading %@", table: "App", file("path"))
        case "write": return T("Writing %@", table: "App", file("path"))
        case "bash": return T("Running a command", table: "App")
        case "search_files": return T("Searching files for “%@”", table: "App", value("query"))
        case "list_folder": return T("Looking in %@", table: "App", file("path"))
        case "move_files": return T("Moving files", table: "App")
        case "web_search": return T("Searching the web", table: "App")
        case "fetch_content": return T("Reading a web page", table: "App")
        case "remember": return T("Remembering", table: "App")
        case "calendar_read": return T("Reading Calendar", table: "App")
        case "calendar_add": return T("Adding to Calendar", table: "App")
        case "reminders_read": return T("Reading Reminders", table: "App")
        case "reminder_add": return T("Adding a reminder", table: "App")
        case "mail_search", "mail_read": return T("Reading Mail", table: "App")
        case "mail_draft": return T("Writing a Mail draft", table: "App")
        case "photos_search": return T("Searching Photos", table: "App")
        case "front_read": return T("Reading the app in front", table: "App")
        case "prepare_files": return T("Preparing files", table: "App")
        default: return name
        }
    }
}
