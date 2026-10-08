import AppKit
import PippaCore
import UniformTypeIdentifiers

// Table in the line (reading Excel, first line, three actions).
//
// Call in Excel → "Looking at your table …" → (first time a sentence, then the system prompt for Excel) → the active
// sheet read via Apple Events (ExcelScript, read only) → first line from `SheetCheck` (pure code) → three actions:
//   - *Check the total*: code, the findings as one short sentence each in the line,
//   - *Explain this table*: the conversation takes over, the sheet as text (values and formulas) in the context,
//   - *Compare with last year*: code, if the sheet has two comparable columns; otherwise the conversation, like *Explain*.
// Without Accessibility permission, so no glow over cells. The line therefore names cells by
// column heading and row label; addresses at most in the help text ("Details").
// Pippa never writes to the table: there is no path to it here.

/// State of the table in the line.
enum SheetPhase: Equatable {
    case idle
    /// "Looking at your table …": check permission, read sheet.
    case calling
    /// A sentence before the system prompt (`denied: false`) or the way to Settings (`denied: true`).
    case permission(denied: Bool)
    /// First line and actions are shown.
    case ready
    /// *Check the total* has run: the findings are shown under the first line.
    case checked
    /// *Compare with last year* in code: one sentence.
    case compared(String)
    /// A calm sentence.
    case failure(String)
}

/// One of the three actions on the table. The identifier goes into the task log (kind `table`).
struct SheetAction: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case checkTotal = "check-total"
        case explain = "explain-table"
        case compare = "compare-last-year"
    }

    var kind: Kind
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .checkTotal: T("Check the total", table: "SheetUI")
        case .explain: T("Explain this table", table: "SheetUI")
        case .compare: T("Compare with last year", table: "SheetUI")
        }
    }

    var help: String {
        switch kind {
        case .checkTotal: T("I add the numbers up again myself. Nothing in the table changes.", table: "SheetUI")
        case .explain: T("I explain what this table shows.", table: "SheetUI")
        case .compare: T("I look at what changed since last year.", table: "SheetUI")
        }
    }

    /// Message into the conversation (model actions). Appears as your message in the history.
    var instruction: String {
        switch kind {
        case .checkTotal, .explain:
            T("Please explain this table in plain words. Name rows and columns by their headings, not by cell address.", table: "SheetUI")
        case .compare:
            T("Please compare this table with last year. What changed most? Name rows and columns by their headings, not by cell address.", table: "SheetUI")
        }
    }

    /// Always the same three, in this order.
    static var all: [SheetAction] { Kind.allCases.map { SheetAction(kind: $0) } }
}

@MainActor
final class SheetController: ObservableObject {
    @Published private(set) var phase: SheetPhase = .idle
    /// "Looking at your table …"; after reading "Looking at your table: Kosten 2026, column Betrag". Never an address.
    @Published private(set) var lookingText = ""
    @Published private(set) var firstLine: FirstLine?
    /// Findings of *Check the total*, one sentence each with heading and label.
    @Published private(set) var findings: [SheetFinding] = []
    /// Did the check find a sum at all? (For the sentence under "The total adds up.")
    @Published private(set) var foundTotals = false
    @Published private(set) var actions: [SheetAction] = []
    /// Sentence for when the sheet was larger than what Pippa reads.
    @Published private(set) var note: String?
    /// Text in the line's field.
    @Published var question = ""

    weak var model: AppModel?

    /// A sheet that has been read, with the result of the check (both from code, without a model).
    private struct Session {
        let snapshot: SheetSnapshot
        let result: SheetCheckResult
        /// Two comparable columns (years or "previous year"), otherwise nil: then the model compares.
        let comparison: SheetComparison?
    }

    private var session: Session?
    /// A call is running before a session exists (permission, reading, a sentence).
    private var pendingCall = false
    /// Since when the table has had the line. If an item lands on Pippa afterwards, the line belongs to the tray again.
    private var claimedAt = Date()
    /// Was anything chosen in this opened line? Otherwise "passed over" in the log.
    private var choseSinceOpen = true
    private var callTask: Task<Void, Never>?

    /// At most this many findings in the line; the conversation tells more.
    static let findingLimit = 4

    // MARK: State for line and figure

    /// Does the line show the table? During the call and as long as a sheet is read, unless an item has landed on Pippa since.
    var isActive: Bool {
        guard pendingCall || session != nil, let model else { return false }
        let claimed = claimedAt
        return !model.tray.items.contains { $0.role == .given && $0.addedAt > claimed }
    }

    var hasSession: Bool { session != nil }

    var canChoose: Bool {
        guard session != nil else { return false }
        switch phase {
        case .ready, .checked, .compared, .failure: return true
        default: return false
        }
    }

    // MARK: Call

    /// Call in Excel (pill, shortcut). Every call reads anew: the selection may have changed, reading is fast.
    func callExcel() {
        guard let model else { return }
        if pendingCall, phase == .calling {
            model.openLine()
            return
        }
        end()
        pendingCall = true
        claimedAt = Date()
        phase = .calling
        lookingText = SheetLine.calling(nil)
        model.openLine()
        callTask = Task { [weak self] in await self?.checkAccess() }
    }

    /// "Continue" after the sentence before the system prompt.
    func continueAfterPermission() {
        guard case .permission(denied: false) = phase, let model else { return }
        model.taskLog.event(.permissionAsked)
        phase = .calling
        let engine = model.engine
        callTask = Task { [weak self] in
            let access = await engine.requestSheetAccess()
            guard let self, self.pendingCall else { return }
            switch access {
            case .granted:
                self.model?.taskLog.event(.granted)
                await self.read()
            case .unavailable(let reason):
                self.phase = .failure(reason)
            case .denied, .notDetermined:
                self.model?.taskLog.event(.declined)
                self.phase = .permission(denied: true)
            }
        }
    }

    /// "Open Settings": Privacy & Security → Automation.
    func openSettings() {
        logPermissionChoice("open-settings")
        NSWorkspace.shared.open(ExcelScript.settingsURL)
        model?.collapse()
        end()
    }

    /// "Give me the file instead": choose the table as a file. It lands on the tray, with the actions for
    /// tables (there `tabelle-pruefen`), like a dropped .xlsx.
    func giveFile() {
        guard let model else { return }
        logPermissionChoice("give-file")
        model.collapse()
        end()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        let types = ["xlsx", "xls", "xlsm", "numbers", "ods", "csv"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types + [.spreadsheet]
        panel.prompt = T("Look", table: "SheetUI")
        panel.message = T("Which table should I look at? I only read it.", table: "SheetUI")
        panel.begin { [weak model] response in
            MainActor.assumeIsolated {
                guard response == .OK, !panel.urls.isEmpty else { return }
                model?.receive(.files(panel.urls), items: panel.urls)
            }
        }
    }

    /// Choice at the permission moment into the log (kind `table`, no content): the buttons of this moment are offered.
    private func logPermissionChoice(_ chosen: String) {
        guard case .permission(let denied) = phase else { return }
        let offered = denied ? ["give-file", "open-settings"] : ["give-file", "continue"]
        model?.taskLog.chose(chosen, offered: offered, kind: .table)
    }

    private func checkAccess() async {
        guard let model else { return }
        let access = await model.engine.sheetAccess()
        guard pendingCall, !Task.isCancelled else { return }
        switch access {
        case .granted:
            await read()
        case .notDetermined:
            phase = .permission(denied: false)
        case .denied:
            phase = .permission(denied: true)
        case .unavailable(let reason):
            phase = .failure(reason)
        }
    }

    private func read() async {
        guard let model else { return }
        let loaded: SheetSnapshot?
        do {
            loaded = try await model.engine.selectedSheet()
        } catch {
            guard pendingCall else { return }
            if let pippa = error as? PippaError, case .accessDenied(_) = pippa {
                phase = .permission(denied: true)
                return
            }
            phase = .failure(UserMessage.text(for: error, context: "tabelle"))
            return
        }
        guard pendingCall else { return }
        guard let snapshot = loaded else {
            phase = .failure(T("No table is open in Excel.", table: "SheetUI"))
            return
        }
        guard !snapshot.grid.isEmpty else {
            phase = .failure(T("This sheet looks empty to me.", table: "SheetUI"))
            return
        }
        await begin(snapshot)
    }

    /// Sheet read: check and comparison in code, off the main thread (GCD, not the cooperative pool).
    private func begin(_ snapshot: SheetSnapshot) async {
        let locale = Locale.current
        let computed = await withCheckedContinuation { (continuation: CheckedContinuation<(SheetCheckResult, SheetComparison?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = SheetCheck.run(snapshot, locale: locale)
                let comparison = SheetComparison.find(in: snapshot.grid, layout: result.layout)
                continuation.resume(returning: (result, comparison))
            }
        }
        guard pendingCall else { return }
        let (result, comparison) = computed
        session = Session(snapshot: snapshot, result: result, comparison: comparison)
        pendingCall = false
        lookingText = SheetLine.calling(snapshot)
        firstLine = result.firstLine
        findings = []
        foundTotals = result.foundTotals
        actions = SheetAction.all
        note = snapshot.isClipped ? T("This table is large. I looked at its first part.", table: "SheetUI") : nil
        choseSinceOpen = false
        phase = .ready
    }

    // MARK: Choosing

    /// Return in the empty field: the first action (or "Continue" before the system prompt).
    func chooseFirst() {
        if case .permission(denied: false) = phase { return continueAfterPermission() }
        guard canChoose, let first = actions.first else { return }
        choose(first)
    }

    func choose(_ action: SheetAction) {
        guard canChoose, let model, let current = session else { return }
        choseSinceOpen = true
        let offered = actions.map(\.id)
        switch action.kind {
        case .checkTotal:
            model.taskLog.chose(action.id, offered: offered, kind: .table)
            findings = current.result.findings
            phase = .checked
        case .compare:
            if let comparison = current.comparison {
                model.taskLog.chose(action.id, offered: offered, kind: .table)
                phase = .compared(comparison.line(locale: .current))
            } else {
                // No two comparable columns: the model gets the sheet and the question.
                handOver(action.instruction, chosen: action.id, offered: offered)
            }
        case .explain:
            handOver(action.instruction, chosen: action.id, offered: offered)
        }
    }

    /// With text to Pippa: the sheet goes into the conversation.
    func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let model else { return }
        question = ""
        guard session != nil else {
            end()
            model.route(q)
            return
        }
        choseSinceOpen = true
        handOver(q, chosen: nil, offered: [])
    }

    /// The sheet as text (values and formulas, read only) to the conversation, then the message. The session ends here.
    private func handOver(_ message: String, chosen: String?, offered: [String]) {
        guard let model, let current = session else { return }
        if model.busy || model.conversations.isRunning {
            phase = .failure(InferenceError.busy.localizedDescription)
            return
        }
        let url: URL
        do {
            url = try Self.writeContext(current.snapshot)
        } catch {
            phase = .failure(UserMessage.text(for: error, context: "tabelle"))
            return
        }
        if let chosen { model.taskLog.chose(chosen, offered: offered, kind: .table) }
        end()
        model.handOver([url]) { model.route(message) }
    }

    /// The sheet as a text file in Pippa's cache (`Inbox`), like a mail's .eml. Extension .tsv: the conversation shows
    /// the buttons for tables with it (`tabelle-pruefen`, `zusammenfassen`). Excel and the workbook stay untouched.
    static func writeContext(_ snapshot: SheetSnapshot) throws -> URL {
        let base = Naming.sanitize(snapshot.tableName, maxLength: 60)
        let name = (base.isEmpty ? T("Table", table: "SheetUI") : base) + ".tsv"
        let url = try Inbox.freshFolder().appendingPathComponent(name)
        try snapshot.contextText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Line open, closed, end

    /// The line opens with this table: if actions are shown, this opening counts for the log.
    func lineOpened() {
        guard session != nil else { return }
        choseSinceOpen = phase != .ready
    }

    /// The line closes. Without a choice, logged as "passed over". After that the table is done; a new call reads anew.
    func lineClosed() {
        if session != nil, !choseSinceOpen, !actions.isEmpty {
            model?.taskLog.ignored(offered: actions.map(\.id), kind: .table)
        }
        end()
    }

    /// End everything and clear the state. No own engine answer is running that would need stopping.
    func end() {
        callTask?.cancel(); callTask = nil
        session = nil
        pendingCall = false
        phase = .idle
        lookingText = ""
        firstLine = nil
        findings = []
        foundTotals = false
        actions = []
        note = nil
        choseSinceOpen = true
    }
}
