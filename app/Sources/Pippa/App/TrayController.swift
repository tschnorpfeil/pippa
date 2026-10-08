import AppKit
import PippaCore
import UniformTypeIdentifiers

// The tray on Pippa: what was given, what Pippa made of it, and the one line for it. Tools run here in
// their own task, never via `AppModel.perform`: no model, no work indicator,
// only the journal entry for Undo goes through the engine.

/// State of the line at the pill.
enum TrayPhase: Equatable {
    case idle, given
    case working(title: String, progress: ToolProgress?)
    /// Tray item of the fresh result.
    case result(UUID)
    /// One sentence; with `passwordFor` a password field is shown below it.
    case failure(message: String, passwordFor: URL?)
}

@MainActor
final class TrayController: ObservableObject {
    @Published private(set) var state: TrayState
    @Published private(set) var phase: TrayPhase = .idle
    @Published private(set) var offered: [ThingAction] = []
    /// Only after one second of work: before that the line shows no progress.
    @Published private(set) var progressVisible = false
    /// Kept when collapsed.
    @Published var draft = "" { didSet { if !draft.isEmpty { freezeSuggestions() } } }
    /// A sentence under the fresh result when the tool left something behind (nil otherwise).
    @Published private(set) var resultNote: String?

    weak var model: AppModel?

    var items: [TrayItem] { state.items }
    var peek: [TrayItem] { TrayRules.peek(state) }
    var givenItems: [TrayItem] { state.items.filter { $0.role == .given } }
    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    private let store: TrayStore
    /// Habits: loaded once, then extended locally so that `offered` is available at once.
    private var records: [TaskRecord] = []
    /// Reloading after Forget invalidates snapshots already being read by an older loader.
    private var habitGeneration = 0
    /// Resolved URLs (bookmarks); `scoped` with access running.
    private var resolved: [UUID: URL] = [:]
    private var scoped: [UUID: URL] = [:]
    /// Consumed given items, for Undo in this session.
    private var consumedItems: [UUID: TrayItem] = [:]
    /// Receipts of this session (after a restart the identifier suffices).
    private var receipts: [UUID: JobReceipt] = [:]
    /// Running tool; `runID` separates a cancelled run from a new one.
    private var toolTask: Task<ToolOutput, Error>?
    private var runID: UUID?
    private var clock: Task<Void, Never>?
    /// Waiting for a password: this tool runs once more afterwards.
    private var pendingTool: ToolID?
    /// In memory only, only until the run ends. Never logged, never saved.
    private var passwords: [URL: String] = [:]
    /// Was anything chosen in this opened line? (Otherwise: "passed over" in the log.)
    private var choseSinceOpen = true
    private var suggestionTask: Task<Void, Never>?
    private var suggestionGeneration = UUID()
    private var suggestionItems: [UUID] = []
    private var suggestionRole: DocumentRole = .unknown
    private var suggestionsFrozen = false
    /// Refinement by the system model; replaceable only by native fixtures to control timing.
    var classify: @Sendable ([URL]) async -> DocumentRole = { await DocumentSuggestions.classify($0) }
    /// A refinement later than this is dropped; the type-based offer stays.
    static let refinementDeadline: Duration = .seconds(4)

    func freezeSuggestions() {
        suggestionsFrozen = true
        suggestionTask?.cancel()
        suggestionTask = nil
    }

    init(store: TrayStore = TrayStore()) {
        self.store = store
        self.state = TrayState()
    }

    // MARK: Load, drop, remove

    /// Load the tray, drop what is missing or faded, clean up old result folders, load habits.
    func load() {
        let loaded = store.load()
        var missing = Set<String>()
        for item in loaded.items where item.role == .given && item.bookmark != nil {
            if access(item, check: true) == nil { missing.insert(Self.key(item.url)) }
        }
        state = TrayRules.pruned(loaded, now: Date(), exists: { url in
            !missing.contains(Self.key(url)) && FileManager.default.fileExists(atPath: url.path)
        })
        let kept = Set(state.items.map(\.id))
        for id in Array(resolved.keys) where !kept.contains(id) { release(id) }
        let keep = state.items.filter { $0.role == .result }.map(\.url)
        Task.detached(priority: .utility) { _ = ResultsFolder.prune(keeping: keep) }
        settle()
        changed()
        guard let recorder = model?.taskLog else { return }
        let generation = habitGeneration
        Task { [weak self] in
            let loadedRecords = await recorder.records(limit: 500)
            guard let self, self.habitGeneration == generation else { return }
            self.records += loadedRecords
            self.recomputeOffered()
        }
    }

    /// Settings changed the persisted habits: replace cached choices and update the visible order.
    func reloadHabits() async {
        habitGeneration += 1
        let generation = habitGeneration
        records = []
        guard let recorder = model?.taskLog else { return }
        let loaded = await recorder.records(limit: 500)
        guard habitGeneration == generation else { return }
        records = loaded
        recomputeOffered()
    }

    /// New items on Pippa, in tray order. Origin: the folder name; Pippa's own copies
    /// (mail, pasted) get `origin` or a word by kind.
    func add(_ urls: [URL], origin: String?) {
        guard !urls.isEmpty else { return }
        let inbox = Inbox.directory
        let now = Date()
        var next = state
        let inboxPath = Self.key(inbox) + "/"
        for url in urls {
            let own = Self.key(url).hasPrefix(inboxPath)
            let shown = own ? (origin ?? Self.inboxOrigin(url)) : (TrayRules.origin(for: url, inbox: inbox) ?? origin)
            next = TrayRules.adding([url], origin: shown, to: next, now: now, bookmark: { own ? nil : TrayStore.bookmark($0) })
        }
        state = next
        switch phase {
        case .working: break
        case .failure(_, let url) where url != nil: break
        default:
            resultNote = nil
            settle()
        }
        changed()
    }

    /// Takes an item off Pippa. The file stays where it is.
    func remove(_ id: UUID) {
        guard !isWorking, model?.isActiveWork != true,
              let index = state.items.firstIndex(where: { $0.id == id }) else { return }
        let removed = state.items[index]
        state.items.removeAll { $0.id == id }
        release(id)
        model?.removeConversationAttachment(removed.url)
        switch phase {
        case .result(let shown) where shown == id:
            resultNote = nil
            settle()
        case .idle, .given:
            settle()
        default: break
        }
        changed()
        announce(T("Removed.", table: "TrayApp") + " " + removed.name)
    }

    // MARK: Actions

    /// Whether a click on this offer would do something now. Tools run beside a conversation; skills, tidying and
    /// invoices hand the things over to it and wait until its current answer or task is done, like typed text.
    func canChoose(_ action: ThingAction) -> Bool {
        guard !isWorking, offered.contains(action) else { return false }
        if case .tool = action.handler { return true }
        return model?.isActiveWork != true
    }

    func choose(_ action: ThingAction) {
        // Unavailable offers record nothing: no habit, no frozen suggestions, no silent hand-over attempt.
        guard canChoose(action), let model else { return }
        freezeSuggestions()
        let given = givenItems
        guard !given.isEmpty else { return }
        let urls = given.map { url(for: $0) }
        let ids = offered.map(\.id)
        let kind = ThingActions.taskKind(for: urls)
        choseSinceOpen = true
        if let kind { records.insert(TaskRecord(kind: kind, offered: ids, chosen: action.id), at: 0) }
        switch action.handler {
        case .tool(let tool):
            if let kind { model.taskLog.chose(action.id, offered: ids, kind: kind, bindsReceipt: true) }
            passwords = [:]
            startTool(tool)
        case .skill(let name):
            guard !model.isActiveWork, let skill = PippaSkill.bundled.first(where: { $0.name == name }) else { return }
            handOver(given, urls: urls) {
                if let kind { model.taskLog.chose(action.id, offered: ids, kind: kind) }
                model.runSkill(skill)
            }
        case .tidy:
            guard !model.isActiveWork else { return }
            handOver(given, urls: urls) {
                if let kind { model.taskLog.chose(action.id, offered: ids, kind: kind, bindsReceipt: true) }
                model.startSort()
            }
        case .invoiceTable:
            guard !model.isActiveWork else { return }
            handOver(given, urls: urls) {
                if let kind { model.taskLog.chose(action.id, offered: ids, kind: kind, bindsReceipt: true) }
                model.startInvoices()
            }
        }
    }

    /// "Stop": the tool aborts, nothing is left lying around; the items stay on Pippa.
    func stop() {
        guard isWorking else { return }
        toolTask?.cancel()
        toolTask = nil
        runID = nil
        pendingTool = nil
        passwords = [:]
        stopClock()
        settle()
    }

    func submitPassword(_ password: String) {
        guard !password.isEmpty, case .failure(_, let url?) = phase, let tool = pendingTool else { return }
        passwords[url] = password
        startTool(tool)
    }

    /// Take back the result: the file leaves Pippa's cache, the consumed items come back.
    func undoResult(_ id: UUID) {
        guard !isWorking, let item = state.items.first(where: { $0.id == id && $0.role == .result }) else { return }
        guard let receiptID = item.receipt, let engine = model?.engine else {
            // Without a journal entry: only remove Pippa's own file.
            if ResultsFolder.contains(item.url) { try? FileManager.default.removeItem(at: item.url) }
            applyUndo(item)
            return
        }
        let receipt = receipts[receiptID] ?? JobReceipt(id: receiptID, summary: item.name, detail: "", revealURL: item.url)
        Task { [weak self] in
            do {
                try await engine.undo(receipt)
                guard let self else { return }
                self.model?.taskLog.undone(receiptID)
                self.receipts[receiptID] = nil
                self.applyUndo(item)
            } catch {
                guard let self else { return }
                UserMessage.record(error, context: "werkzeug-rueckgaengig")
                let message = (error as? PippaError)?.localizedDescription ?? T("That didn’t work. Your files are unchanged.", table: "TrayApp")
                self.fail(message)
            }
        }
    }

    /// "Save…": choose a location, place a copy. Without dragging, for keyboard and VoiceOver.
    func save(_ id: UUID) {
        guard let item = state.items.first(where: { $0.id == id }) else { return }
        let source = url(for: item)
        NSApp.activate()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let target = panel.url else { return }
                self?.write(source, to: target, id: id)
            }
        }
    }

    /// An item was successfully dragged out or saved. Results leave Pippa afterwards
    /// (the cache file stays for the promise and disappears with the cleanup after 24 h).
    func took(_ id: UUID, target: TaskTarget.Kind) {
        guard let item = state.items.first(where: { $0.id == id }), item.role == .result else { return }
        if let receipt = item.receipt { model?.taskLog.took(receipt, target: TaskTarget(kind: target)) }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.removeTaken(id)
        }
    }

    /// Hand over with text to Pippa: the items go into the conversation and off the tray.
    func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isWorking, let model, !model.isActiveWork else { return }
        draft = ""
        choseSinceOpen = true
        let given = givenItems
        let subject = given.isEmpty ? state.items : given
        handOver(subject, urls: subject.map { url(for: $0) }) { model.route(q) }
    }

    /// The line opens; a waiting result stays reachable with Save and Undo.
    func lineOpened() {
        refreshMissing()
        if !isWorking, givenItems.isEmpty, case .idle = phase,
           let result = state.items.first(where: { $0.role == .result }) {
            phase = .result(result.id)
        }
        choseSinceOpen = givenItems.isEmpty
    }

    func showResult(_ id: UUID) {
        guard !isWorking, state.items.contains(where: { $0.id == id && $0.role == .result }) else { return }
        phase = .result(id)
        model?.openLine()
    }

    /// The line closes: without a choice logged as "passed over". Result and error step back.
    func lineClosed() {
        if !choseSinceOpen {
            let urls = givenItems.map { url(for: $0) }
            let ids = offered.map(\.id)
            if !ids.isEmpty, let kind = ThingActions.taskKind(for: urls) {
                model?.taskLog.ignored(offered: ids, kind: kind)
                records.insert(TaskRecord(kind: kind, offered: ids, chosen: nil), at: 0)
                recomputeOffered()
            }
        }
        choseSinceOpen = true
        switch phase {
        case .result, .failure:
            pendingTool = nil
            passwords = [:]
            resultNote = nil
            settle()
        default: break
        }
    }

    // MARK: Tool

    private func startTool(_ tool: ToolID) {
        let given = givenItems
        guard !given.isEmpty else { return }
        let inputs = given.map { (item: $0, url: url(for: $0)) }
        let urls = inputs.map(\.url)
        let secrets = passwords
        let run = UUID()
        runID = run
        pendingTool = tool
        resultNote = nil
        phase = .working(title: tool.workingTitle, progress: nil)
        startClock()
        let report: @Sendable (ToolProgress) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in self?.progressed(p, run: run) }
        }
        let work = Task.detached(priority: .userInitiated) { () async throws -> ToolOutput in
            try await OneAnswerTools.run(tool, inputs: urls, passwords: secrets, progress: report)
        }
        toolTask = work
        Task { [weak self] in
            do {
                let output = try await work.value
                await self?.finish(output, tool: tool, inputs: inputs, run: run)
            } catch {
                self?.failed(error, run: run)
            }
        }
    }

    private func progressed(_ p: ToolProgress, run: UUID) {
        guard runID == run, case .working(let title, _) = phase else { return }
        phase = .working(title: title, progress: p)
    }

    /// A cancelled run owns only its generated cache files; never touch the inputs or a newer run.
    private func discard(_ output: ToolOutput, receipt: JobReceipt?) async {
        if let receipt, let engine = model?.engine {
            do { try await engine.undo(receipt); return }
            catch { UserMessage.record(error, context: "werkzeug-abbruch-journal") }
        }
        for file in output.files where ResultsFolder.contains(file) {
            do { try FileManager.default.removeItem(at: file) }
            catch { UserMessage.record(error, context: "werkzeug-abbruch") }
        }
    }

    private func finish(_ output: ToolOutput, tool: ToolID, inputs: [(item: TrayItem, url: URL)], run: UUID) async {
        guard runID == run else {
            await discard(output, receipt: nil)
            return
        }
        let detail = output.skippedSentence ?? ""
        var receipt: JobReceipt?
        if let engine = model?.engine, !output.files.isEmpty {
            do { receipt = try await engine.recordResult(output.files, summary: output.summary, detail: detail) }
            catch { UserMessage.record(error, context: "werkzeug-journal") }
        }
        // Recording yields to Stop or a new run. A stale completion must never replace that state.
        guard runID == run else {
            await discard(output, receipt: receipt)
            return
        }
        runID = nil
        toolTask = nil
        pendingTool = nil
        passwords = [:]
        stopClock()
        let consumed = Set(output.consumedInputs.map(\.standardizedFileURL))
        let used = inputs.filter { consumed.contains($0.url.standardizedFileURL) }.map(\.item)
        for item in used { consumedItems[item.id] = item }
        let usedIDs = used.map(\.id)
        var next = state
        var results: [TrayItem] = []
        for file in output.files.reversed() {
            let made = TrayItem(role: .result, url: file, receipt: receipt?.id, sources: usedIDs, tool: tool)
            next = TrayRules.consumed(results.isEmpty ? usedIDs : [], by: made, in: next)
            results.insert(made, at: 0)
        }
        state = next
        if let receipt {
            receipts[receipt.id] = receipt
            model?.taskLog.finished(receipt.id)
        }
        resultNote = output.skippedSentence
        guard let first = results.first else {
            settle()
            changed()
            return
        }
        phase = .result(first.id)
        changed()
        // Collapsed: a small notice at the pill, with Undo.
        if let model, model.mode.key != "line" {
            model.toasts?.show(title: output.summary, detail: detail, buttons: [
                ToastButton(title: T("Undo", table: "TrayApp"), primary: false) { [weak self] in self?.undoResult(first.id) },
            ], receipt: receipt?.id)
        }
    }

    private func failed(_ error: Error, run: UUID) {
        guard runID == run else { return }
        runID = nil
        toolTask = nil
        stopClock()
        if error is CancellationError {
            pendingTool = nil
            passwords = [:]
            settle()
            return
        }
        if let failure = error as? ToolFailure {
            switch failure {
            case .locked(let url), .wrongPassword(let url):
                // The password field stays; the tool runs once more after the input.
                fail(failure.errorDescription ?? "", passwordFor: url)
                return
            default:
                pendingTool = nil
                passwords = [:]
                fail(failure.errorDescription ?? T("That didn’t work. Your files are unchanged.", table: "TrayApp"))
                return
            }
        }
        pendingTool = nil
        passwords = [:]
        UserMessage.record(error, context: "werkzeug")
        fail(T("That didn’t work. Your files are unchanged.", table: "TrayApp"))
    }

    /// A sentence in the line; if it is closed, a small notice at the pill that reopens it.
    private func fail(_ message: String, passwordFor: URL? = nil) {
        phase = .failure(message: message, passwordFor: passwordFor)
        guard let model, model.mode.key != "line" else { return }
        model.toasts?.show(title: message, detail: "", buttons: [
            ToastButton(title: T("Show", table: "TrayApp"), primary: true) { [weak model] in model?.openLine() },
        ], log: false)
    }

    private func startClock() {
        clock?.cancel()
        progressVisible = false
        clock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.isWorking else { return }
            self.progressVisible = true
        }
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
        progressVisible = false
    }

    // MARK: Undo, take along, save

    private func applyUndo(_ item: TrayItem) {
        let restoring = item.sources.compactMap { consumedItems[$0] }
        state = TrayRules.undone(item.id, in: state, restoring: restoring)
        for source in restoring { consumedItems[source.id] = nil }
        resultNote = nil
        if !isWorking { settle() }
        changed()
        announce(T("Removed.", table: "TrayApp"))
    }

    /// Removing is quiet: no visual notice, only a polite VoiceOver announcement.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Pippa: " + text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func removeTaken(_ id: UUID) {
        guard state.items.contains(where: { $0.id == id }) else { return }
        state.items.removeAll { $0.id == id }
        if phase == .result(id) {
            resultNote = nil
            settle()
        }
        changed()
    }

    private func write(_ source: URL, to target: URL, id: UUID) {
        Task { [weak self] in
            let copied = await Task.detached(priority: .userInitiated) { TrayController.copy(source, to: target) }.value
            guard let self else { return }
            if copied { self.took(id, target: .file) }
            else { self.fail(T("I couldn’t save it there. Nothing was changed.", table: "TrayApp")) }
        }
    }

    /// Copy to the chosen location. Replacing (confirmed in the save panel) goes via an intermediate copy
    /// on the same volume, so that no half file ever stands at the destination.
    nonisolated private static func copy(_ source: URL, to target: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return (try? fm.copyItem(at: source, to: target)) != nil }
        guard let folder = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true) else { return false }
        let temp = folder.appendingPathComponent(target.lastPathComponent)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.copyItem(at: source, to: temp)
            _ = try fm.replaceItemAt(target, withItemAt: temp)
            return true
        } catch {
            return false
        }
    }

    // MARK: Hand over

    /// Into the conversation: the items leave the tray.
    private func handOver(_ handed: [TrayItem], urls: [URL], then: @MainActor () -> Void) {
        guard let model else { return }
        model.handOver(urls, then: then)
        state = TrayRules.handedOver(handed.map(\.id), in: state)
        resultNote = nil
        settle()
        changed()
    }

    // MARK: Helpers

    /// Phase from the content when nothing is running and nothing is to be shown.
    private func settle() {
        phase = givenItems.isEmpty ? .idle : .given
    }

    /// Save and recompute the offer (on every change).
    private func changed() {
        try? store.save(state)
        recomputeOffered()
    }

    private func recomputeOffered() {
        let ids = givenItems.map(\.id)
        let urls = givenItems.map { url(for: $0) }
        if ids != suggestionItems {
            suggestionTask?.cancel()
            suggestionItems = ids
            suggestionGeneration = UUID()
            suggestionRole = .unknown
            suggestionsFrozen = !draft.isEmpty || isWorking
            let generation = suggestionGeneration
            if !suggestionsFrozen, urls.count == 1 {
                suggestionTask = Task { [weak self] in
                    // Deadline cancels refinement independently, without blocking the input.
                    guard let classify = self?.classify else { return }
                    let analysis = Task.detached(priority: .utility) { await classify(urls) }
                    let deadline = Task { try? await Task.sleep(for: Self.refinementDeadline); analysis.cancel() }
                    let role = await withTaskCancellationHandler { await analysis.value } onCancel: { analysis.cancel(); deadline.cancel() }
                    deadline.cancel()
                    guard !Task.isCancelled, let self, self.suggestionGeneration == generation,
                          !self.suggestionsFrozen, self.draft.isEmpty, !self.isWorking else { return }
                    self.suggestionRole = role
                    self.offered = ThingActions.offered(for: urls, records: self.records, role: role)
                }
            }
        } else if suggestionsFrozen { return }
        let next = ThingActions.offered(for: urls, records: records, role: suggestionRole)
        if next != offered { offered = next }
    }

    /// Files that are missing by now (e.g. a result that was taken back in the conversation) leave Pippa.
    private func refreshMissing() {
        guard !isWorking else { return }
        let fm = FileManager.default
        let gone = state.items.filter { !fm.fileExists(atPath: url(for: $0).path) }
        guard !gone.isEmpty else { return }
        let ids = Set(gone.map(\.id))
        state.items.removeAll { ids.contains($0.id) }
        for id in ids { release(id) }
        switch phase {
        case .result(let id) where ids.contains(id):
            resultNote = nil
            settle()
        case .idle, .given:
            settle()
        default: break
        }
        changed()
    }

    /// The URL for reading: resolved bookmark with access running, otherwise the remembered path.
    private func url(for item: TrayItem) -> URL {
        access(item, check: false) ?? item.url
    }

    /// Resolves once per item and keeps access until removal. `check`: nil if the file is not reachable.
    private func access(_ item: TrayItem, check: Bool) -> URL? {
        if let known = resolved[item.id] { return known }
        guard item.bookmark != nil else { return item.url }
        guard let r = TrayStore.resolve(item) else { return check ? nil : item.url }
        resolved[item.id] = r.url
        if r.scoped { scoped[item.id] = r.url }
        return r.url
    }

    private func release(_ id: UUID) {
        resolved[id] = nil
        scoped.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Origin for Pippa's own copies: mails are labeled "Mail", everything else gets the pasted label.
    private static func inboxOrigin(_ url: URL) -> String {
        url.pathExtension.lowercased() == "eml" ? T("Mail", table: "TrayApp") : T("Pasted", table: "TrayApp")
    }
}
