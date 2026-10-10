import Foundation

// Interface between the UI (target `Pippa`) and the core (`PippaCore`).
// The UI knows only these types. `StubEngine` supplies sample data so
// the UI stays buildable and demoable without a model.

/// What was dropped.
public enum DropKind: String, Sendable, Codable {
    case folder, pdf, image, mail, text, link, office, mixed, other
}

extension DropKind {
    /// Office formats (document, spreadsheet, slides); same list for engine and suggestions.
    public static let officeExtensions: Set<String> = ["docx", "doc", "xlsx", "xls", "pptx", "ppt", "odt", "ods", "pages", "numbers", "key", "rtf"]

    /// Classified by folder and extension only, without reading the file (suggestions on the conversation).
    /// With metadata read, `LocalEngine.dropKind` classifies more precisely.
    public static func guess(for url: URL) -> DropKind {
        if url.hasDirectoryPath { return .folder }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ["jpg", "jpeg", "png", "heic", "webp"].contains(ext) { return .image }
        if ext == "eml" { return .mail }
        if officeExtensions.contains(ext) { return .office }
        return .text
    }
}

/// A dropped item: files/folders as URLs, or text/link.
public enum DropPayload: Sendable {
    case files([URL])
    case text(String)
    case link(URL)
}

/// Rough classification without a model (type, metadata, patterns), fast.
public struct Overview: Sendable {
    public var title: String            // e.g. "Downloads" or "Rechnung · Stadtwerke"
    public var subtitle: String         // e.g. "47 Dateien"
    public var kind: DropKind
    public var categories: [(name: String, count: Int)]
    public var facts: [(label: String, value: String)]   // e.g. amount, date
    public var actions: [Action]
    /// Deadlines Pi recognized in a single letter or contract, with a verified evidence passage.
    public var deadlines: [Deadline]
    /// Sender, if recognized (for reminder titles).
    public var sender: String?
    public init(title: String, subtitle: String, kind: DropKind, categories: [(name: String, count: Int)] = [], facts: [(label: String, value: String)] = [], actions: [Action] = [],
                deadlines: [Deadline] = [], sender: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.kind = kind; self.categories = categories; self.facts = facts; self.actions = actions
        self.deadlines = deadlines; self.sender = sender
    }
}

public enum Action: String, Sendable, CaseIterable {
    case sort          // Sort with preview
    case invoiceTable  // Invoices as a table
    case ask           // Ask something
    case deadlines     // Enter deadlines in Reminders or Calendar (with preview)
}

/// Confidence of a row. Produced in code (evidence check), not as the model's self-assessment.
public enum Certainty: String, Sendable, Codable { case sure, unsure, unreadable }

/// A planned change. Executed only after approval, by the `Executor`.
public struct PlanOp: Sendable, Identifiable, Codable, Hashable {
    /// `trash`: a byte-identical copy goes to the Trash (`source` = `target` = the copy); undo brings it back.
    public enum Kind: String, Sendable, Codable { case rename, move, mkdir, trash }
    public var id: UUID
    public var kind: Kind
    public var source: URL?
    public var target: URL
    public var reason: String
    public var certainty: Certainty
    /// Identity of the source at preview time; the executor skips the operation if it no longer matches.
    public var fingerprint: FileFingerprint?
    public init(id: UUID = UUID(), kind: Kind, source: URL?, target: URL, reason: String, certainty: Certainty, fingerprint: FileFingerprint? = nil) {
        self.id = id; self.kind = kind; self.source = source; self.target = target; self.reason = reason; self.certainty = certainty
        self.fingerprint = fingerprint
    }

    /// The old file name, only when the step really renames the file (exact comparison, extension included).
    /// `nil` for a plain move that keeps the name: the preview then shows no "was: …" line.
    public var previousName: String? {
        guard let old = source?.lastPathComponent, !old.isEmpty, old != target.lastPathComponent else { return nil }
        return old
    }
}

public struct Plan: Sendable {
    public var scope: URL                 // only inside this may anything happen
    public var ops: [PlanOp]
    public var skipped: [(url: URL, why: String)]
    /// Still being read or classified; they join in a later plan (see `proposeSort(items:scope:limit:onUpdate:)`).
    public var pending: [URL]
    /// Not in this round (newest first only); can be sorted afterwards.
    public var remaining: [URL]
    /// Documents whose place only the model could decide, and it is currently unavailable (still loading, waking up, not responding).
    /// Pippa does not guess: they stay where they are and can be sorted once the model is ready.
    public var later: [URL]
    public init(scope: URL, ops: [PlanOp], skipped: [(url: URL, why: String)], pending: [URL] = [], remaining: [URL] = [], later: [URL] = []) {
        self.scope = scope; self.ops = ops; self.skipped = skipped; self.pending = pending; self.remaining = remaining; self.later = later
    }
}

public struct Answer: Sendable {
    public var text: String               // short answer
    public var source: URL?
    public var location: String?          // e.g. "S. 4" (page 4)
    public var quote: String?             // verbatim from the source, verified
    public var found: Bool
    public init(text: String, source: URL?, location: String?, quote: String?, found: Bool) {
        self.text = text; self.source = source; self.location = location; self.quote = quote; self.found = found
    }
}

/// An executed job, undoable.
/// A file (or entry) that stayed in place or was not returned, with a short German reason.
public struct FileReason: Sendable, Hashable {
    public var name: String               // e.g. "Rechnung.pdf"
    public var why: String                // e.g. "Darauf habe ich keinen Zugriff." ("I have no access to that.")
    public init(name: String, why: String) { self.name = name; self.why = why }
}

public struct JobReceipt: Sendable, Identifiable, Hashable {
    public var id: UUID
    public var summary: String            // e.g. "46 Dateien geordnet" (46 files sorted)
    public var detail: String             // e.g. "In 4 Ordnern · 1 bleibt liegen" (in 4 folders, 1 stays)
    public var revealURL: URL?
    /// Text after "Rückgängig" (undo); `nil` = files ("wieder an ihrem alten Platz", back in their old place).
    public var undoDetail: String?
    /// App in which something was entered (to open it from the notice).
    public var integration: Integration?
    /// Files that stayed in place, each with a reason (empty if everything worked).
    public var stayed: [FileReason]
    /// When the job ran (set in the history).
    public var date: Date?
    public var canUndo: Bool { integration != .mail }
    public init(id: UUID, summary: String, detail: String, revealURL: URL?, undoDetail: String? = nil, integration: Integration? = nil,
                stayed: [FileReason] = [], date: Date? = nil) {
        self.id = id; self.summary = summary; self.detail = detail; self.revealURL = revealURL; self.undoDetail = undoDetail; self.integration = integration
        self.stayed = stayed; self.date = date
    }
}

/// State of the local model, for setup and the character.
public enum ModelStatus: Sendable, Equatable {
    case notInstalled
    case downloading(progress: Double, remaining: TimeInterval?)
    case ready
    case loading
    case failed(reason: String)           // installed, but start failed; try again
    case unsupported(reason: String)      // e.g. Intel Mac
}

/// Can the local model answer right now (fixed flows, letter)? The conversation itself is held back by setup
/// (`PiConversationDefault.gate`).
public enum ChatReadiness: Sendable, Equatable {
    case ready
    /// No model ready yet (missing, loading, starting).
    case unavailable
}

public struct ChatContext: Sendable {
    public var files: [URL]
    public var focusedFiles: [URL]
    public var selectedText: String
    /// Native overview/proposal/receipt supplied by the UI, not a new agent action.
    public var workflowSummary: String
    /// Thought Line (ThoughtLine.swift): real phases of this answer, in order. `nil`: nobody listens.
    public var onWork: WorkEventHandler?
    /// The app the person called Pippa from, as the chip above the input shows it (FrontApp.swift). `nil`: no chip.
    public var frontApp: FrontApp?
    public init(files: [URL] = [], focusedFiles: [URL] = [], selectedText: String = "", workflowSummary: String = "") {
        self.files = files; self.focusedFiles = focusedFiles; self.selectedText = selectedText; self.workflowSummary = workflowSummary
    }
    public var maximumFileCount: Int {
        20 - (selectedText.isEmpty ? 0 : 1) - (workflowSummary.isEmpty ? 0 : 1)
    }
    public func validate() throws {
        guard files.count <= maximumFileCount else {
            throw AnswerFailure.runtime(L("With this context, you can attach at most %lld files.", table: "Core", maximumFileCount))
        }
    }
}

public protocol PippaEngine: AnyObject, Sendable {
    var modelStatus: ModelStatus { get async }
    /// Can the local model answer right now?
    var chatReadiness: ChatReadiness { get async }
    /// Download size for the matching model (total and what is still missing); `nil` if nothing needs downloading.
    var modelDownloadSize: ModelDownloadSize? { get async }
    /// Downloads the matching model (one per memory size). Progress via `modelStatus`.
    /// Without `allowDownload`, only what is already on the Mac is adopted; never anything from the network.
    func prepareModel(allowDownload: Bool) async throws
    func cancelModelPreparation() async

    func overview(of payload: DropPayload) async throws -> Overview
    func proposeSort(folder: URL) async throws -> Plan
    func apply(_ plan: Plan, excluding: Set<UUID>) async throws -> JobReceipt
    func undo(_ receipt: JobReceipt) async throws
    func pendingRecovery() async -> [JobReceipt]   // after a crash: resume or undo

    // Additions (with default behavior so existing implementations keep building):

    /// Sort only selected files; `scope` is the approved folder in which target folders are created.
    func proposeSort(items: [URL], scope: URL) async throws -> Plan
    /// Staged sorting: `items` = nil means all files directly in `scope`. `limit`: only the newest that many, the rest
    /// ends up in `Plan.remaining`. `onUpdate` immediately gets the plan without a model, then every grown plan
    /// (`Plan.pending` = still in progress). Without a ready model, documents that would need it go to `Plan.later`
    /// (they stay in place, nothing guessed). The returned plan is final. Whoever approves earlier
    /// cancels the rest; only what the preview already shows is executed.
    func proposeSort(items: [URL]?, scope: URL, limit: Int?, onUpdate: @escaping @Sendable (Plan) -> Void) async throws -> Plan
    /// Resume an interrupted job (from `pendingRecovery`).
    func resume(_ receipt: JobReceipt) async throws -> JobReceipt
    /// Leave an interrupted job as it is and stop offering it.
    func dismissRecovery(_ receipt: JobReceipt) async
    /// When the app quits: stop background processes.
    func shutdown() async
    /// Call shortly after launch: warms up text recognition in the background (low priority, returns immediately),
    /// so the first drop of a scan doesn't wait half a minute.
    func warmUp() async
    /// History: most recently completed jobs that can still be undone, newest first.
    /// Undo works with `undo(_:)` as with a fresh notice.
    func recentJobs(limit: Int) async -> [JobReceipt]    /// Progress of the running reading job (file by file), `nil` if nothing is running or unknown.
    /// The UI polls this several times per second while work is running.
    var workProgress: WorkProgress? { get async }

    // Integrations with other apps (see Integrations/). Reading is free, writing only after "Apply".

    func integrationAccess(_ integration: Integration) async -> IntegrationAccess
    /// Show the system prompt. Call only when the person is currently using the feature.
    func requestIntegrationAccess(_ integration: Integration) async -> IntegrationAccess
    /// Writes the approved entry (journal, undoable).
    func addEntry(_ entry: CalendarEntry) async throws -> JobReceipt
    /// The mail selected in Apple Mail, read only.
    func selectedMail() async throws -> MailMessage?
    /// Events in the time range, read only, limited. Never asks for access itself (`requestIntegrationAccess(.calendar)` does).
    func readCalendar(_ range: CalendarRange) async -> CalendarReadResult
    /// Finished result files of a tool (in the cache, `ResultsFolder`) into the journal so "Rückgängig" (undo) removes them again.
    /// Starts no model.
    func recordResult(_ files: [URL], summary: String, detail: String) async throws -> JobReceipt

    // Letter (ToolBridgeTypes.swift):

    /// Creates an unsent reply window in Mail. Never sends.
    func insertMailReply(_ draft: MailDraft) async throws -> MailInsertResult
    /// After a call: keep the local model loaded for 20 minutes. Starts nothing.
    func keepWarmAfterCall() async

    // Sheet (Integrations/ExcelScript.swift): read Excel only, in the app sandbox, without accessibility.

    /// May Pippa read the active sheet in Excel? Never asks on its own.
    func sheetAccess() async -> IntegrationAccess
    /// Show the system prompt for Excel. Call only when the person is currently using the feature. Does not start Excel.
    func requestSheetAccess() async -> IntegrationAccess
    /// The active sheet with selection (values and formulas of a limited range); nil without an open workbook.
    /// There is no method that writes to a sheet.
    func selectedSheet() async throws -> SheetSnapshot?
}

/// Progress while reading: how many files are done, how many in total, which is current.
public struct WorkProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public var current: String?
    public init(done: Int, total: Int, current: String?) { self.done = done; self.total = total; self.current = current }
}

public extension PippaEngine {
    var chatReadiness: ChatReadiness { get async { .ready } }
    var modelDownloadSize: ModelDownloadSize? { get async { nil } }
    func cancelModelPreparation() async {}
    func proposeSort(items: [URL], scope: URL) async throws -> Plan { try await proposeSort(folder: scope) }
    func proposeSort(items: [URL]?, scope: URL, limit: Int?, onUpdate: @escaping @Sendable (Plan) -> Void) async throws -> Plan {
        let plan = if let items { try await proposeSort(items: items, scope: scope) } else { try await proposeSort(folder: scope) }
        onUpdate(plan)
        return plan
    }
    func resume(_ receipt: JobReceipt) async throws -> JobReceipt { receipt }
    func dismissRecovery(_ receipt: JobReceipt) async {}
    func prepareModel() async throws { try await prepareModel(allowDownload: true) }
    func shutdown() async {}
    func warmUp() async {}
    func recentJobs(limit: Int) async -> [JobReceipt] { [] }
    var workProgress: WorkProgress? { get async { nil } }
    func integrationAccess(_ integration: Integration) async -> IntegrationAccess { .unavailable(L("That isn’t possible here right now.", table: "Core")) }
    func requestIntegrationAccess(_ integration: Integration) async -> IntegrationAccess { await integrationAccess(integration) }
    func addEntry(_ entry: CalendarEntry) async throws -> JobReceipt { throw PippaError.notAvailable }
    func selectedMail() async throws -> MailMessage? { throw PippaError.notAvailable }
    func readCalendar(_ range: CalendarRange) async -> CalendarReadResult { .failed(CalendarReadResult.failureText) }
    func recordResult(_ files: [URL], summary: String, detail: String) async throws -> JobReceipt { throw PippaError.notAvailable }
    func insertMailReply(_ draft: MailDraft) async throws -> MailInsertResult { throw PippaError.notAvailable }
    func keepWarmAfterCall() async {}
    func sheetAccess() async -> IntegrationAccess { .unavailable(L("That isn’t possible here right now.", table: "Core")) }
    func requestSheetAccess() async -> IntegrationAccess { await sheetAccess() }
    func selectedSheet() async throws -> SheetSnapshot? { throw PippaError.notAvailable }
}
