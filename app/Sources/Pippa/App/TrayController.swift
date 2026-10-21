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
    /// All applicable actions, cached alongside suggestions so rendering never inspects files.
    @Published private(set) var availableActions: [ThingAction] = []
    var actionChoices: ThingActionChoices { ThingActionChoices(offered: offered, candidates: availableActions) }
    /// Only after one second of work: before that the line shows no progress.
    @Published private(set) var progressVisible = false
    /// Kept when collapsed.
    @Published var draft = "" { didSet { if !draft.isEmpty { freezeSuggestions() } } }
    /// A failed Open or Save keeps the generated file and its Undo beside the recovery message.
    @Published private(set) var resultProblem: String?
    @Published private(set) var preparation: FilePreparationDraft?
    @Published private(set) var preparationJobs: [DurableJobRecord] = []
    @Published private(set) var preparationBusy = false
    @Published private(set) var preparationProblem: String?
    var hasPendingPreparationJobs: Bool { !preparationJobs.isEmpty }
    var canPrepareFiles: Bool { !isWorking && FilePreparation.accepts(givenItems.map(\.url)) }
    var canRunPreparation: Bool { !isWorking && preparation != nil && preparationRecord != nil }

    weak var model: AppModel?

    var items: [TrayItem] { state.items }
    var peek: [TrayItem] { TrayRules.peek(state) }
    var givenItems: [TrayItem] { state.items.filter { $0.role == .given } }
    var isWorking: Bool {
        if preparationBusy { return true }
        if case .working = phase { return true }
        return false
    }

    private let store: TrayStore
    private let preparationStore: DurableJobStore?
    private var preparationRecord: DurableJobRecord?
    private var preparationRun: DurableJobRun?
    private var preparationGeneration = UUID()
    private var preparationCaptureTask: Task<FilePreparationDraft, Error>?
    private var preparationRestoreGeneration = UUID()
    private var dismissedPreparationIDs = Set<UUID>()
    private var preparationResultJobs: [UUID: DurableJobRecord] = [:]
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
    private var pendingRequest: NativeFileRequest?
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
        self.preparationStore = try? DurableJobStore(baseDirectory: store.directory)
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
        restorePreparationJobs()
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
        if !isWorking { closePreparation() }
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
            settle()
        }
        changed()
    }

    /// Takes an item off Pippa. The file stays where it is.
    func remove(_ id: UUID) {
        guard !isWorking, model?.isActiveWork != true,
              let index = state.items.firstIndex(where: { $0.id == id }) else { return }
        let removed = state.items[index]
        if removed.role == .result, let record = preparationResultJobs[id] {
            persistPreparationDismissal(record) { [weak self] in
                self?.preparationResultJobs[id] = nil
                self?.remove(id)
            }
            return
        }
        else { closePreparation() }
        state.items.removeAll { $0.id == id }
        release(id)
        model?.removeConversationAttachment(removed.url)
        switch phase {
        case .result(let shown) where shown == id:
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
        guard !isWorking, availableActions.contains(action) else { return false }
        if case .tool = action.handler { return true }
        return model?.isActiveWork != true
    }

    func choose(_ action: ThingAction) {
        // Unavailable offers record nothing: no habit, no frozen suggestions, no silent hand-over attempt.
        guard canChoose(action), let model else { return }
        closePreparation()
        freezeSuggestions()
        let given = givenItems
        guard !given.isEmpty else { return }
        let urls = given.map { url(for: $0) }
        let ids = actionChoices.all.map(\.id)
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
        }
    }

    /// "Stop": the tool aborts, nothing is left lying around; the items stay on Pippa.
    func stop() {
        guard isWorking else { return }
        let generation = UUID()
        preparationGeneration = generation
        preparationRestoreGeneration = UUID()
        let stopping = preparationRecord
        let stoppingRun = preparationRun
        let revision = preparationRun?.revision ?? stopping?.revision
        preparationCaptureTask?.cancel()
        preparationCaptureTask = nil
        preparationBusy = false
        preparationRun = nil
        toolTask?.cancel()
        toolTask = nil
        runID = nil
        pendingTool = nil
        pendingRequest = nil
        passwords = [:]
        stopClock()
        if let stopping, let revision, let store = preparationStore {
            preparationBusy = true
            Task { [weak self] in
                let cancelled: DurableJobRecord?
                if let stoppingRun { cancelled = try? await store.cancel(run: stoppingRun) }
                else { cancelled = try? await store.cancel(id: stopping.id, expectedRevision: revision) }
                guard let self, self.preparationGeneration == generation else { return }
                self.preparationRecord = cancelled
                self.preparationBusy = false
                if cancelled != nil { self.settle() }
                else {
                    self.preparation = nil
                    self.fail(T("I couldn’t save that change. Your request and result are still here.", table: "FilePreparationUI"))
                }
            }
        } else { settle() }
    }

    func submitPassword(_ password: String) {
        guard !password.isEmpty, case .failure(_, let url?) = phase, let tool = pendingTool,
              pendingRequest?.matches(givenItems.map(\.id)) == true else { return }
        passwords[url] = password
        if preparation != nil { runPreparation() } else { startTool(tool) }
    }

    var canRetryTool: Bool {
        guard case .failure(_, nil) = phase, let request = pendingRequest, pendingTool == request.tool else { return false }
        return request.matches(givenItems.map(\.id)) && (preparation != nil || availableActions.contains(.tool(request.tool)))
    }

    /// Retry is an explicit click, only for the unchanged selection. The file tool reopens every source and creates
    /// a fresh result folder; no Calendar, Mail, shell, or model request can enter this recovery path.
    func retryTool() {
        guard canRetryTool, let tool = pendingTool else { return }
        passwords = [:]
        if preparation != nil { runPreparation() } else { startTool(tool) }
    }

    func chooseAnotherAction() {
        guard !isWorking else { return }
        closePreparation()
        pendingTool = nil; pendingRequest = nil; passwords = [:]
        settle()
        recomputeOffered()
    }

    /// Take back the result: the file leaves Pippa's cache, the consumed items come back.
    func undoResult(_ id: UUID) {
        guard !isWorking, let item = state.items.first(where: { $0.id == id && $0.role == .result }) else { return }
        if !Self.isCachedResult(item.url), (item.receipt == nil || model?.engine == nil) {
            resultProblem = T("I can’t safely remove this saved result without its original record. The file is still here.", table: "FilePreparationUI")
            announce(resultProblem!)
            return
        }
        if let record = preparationResultJobs[id] {
            persistPreparationDismissal(record) { [weak self] in
                self?.preparationResultJobs[id] = nil
                self?.undoResult(id)
            }
            return
        }
        guard let receiptID = item.receipt, let engine = model?.engine else {
            // Without a journal entry: only remove Pippa's own file.
            if Self.isCachedResult(item.url) { try? FileManager.default.removeItem(at: item.url) }
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
        guard let item = state.items.first(where: { $0.id == id && $0.role == .result }) else { return }
        guard let source = resultURL(id) else { return resultUnavailable(id) }
        NSApp.activate()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let target = panel.url else { return }
                self?.save(id, to: target)
            }
        }
    }

    /// Resolve an actual retained result, never a source file or a stale thumbnail's URL.
    func resultURL(_ id: UUID) -> URL? {
        guard !isWorking, let item = state.items.first(where: { $0.id == id && $0.role == .result }),
              ResultsFolder.contains(item.url, durableBaseDirectory: store.directory), FileManager.default.isReadableFile(atPath: item.url.path) else { return nil }
        return item.url
    }

    func openResult(_ id: UUID) {
        guard let url = resultURL(id) else { return resultUnavailable(id) }
        if NSWorkspace.shared.open(url) { resultProblem = nil }
        else {
            resultProblem = T("I couldn’t open this file. You can still save it or show it in Finder.", table: "NativeFlow")
            announce(resultProblem!)
        }
    }

    func revealResult(_ id: UUID) {
        guard let url = resultURL(id) else { return resultUnavailable(id) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        resultProblem = nil
    }

    func save(_ id: UUID, to target: URL, expectedSource: DurableFileIdentity? = nil,
              completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let source = resultURL(id) else { resultUnavailable(id); completion?(false); return }
        let clean = target.standardizedFileURL.resolvingSymlinksInPath()
        let targetIdentity = FileFingerprint.of(clean)
        let originals = consumedItems.values.map(\.url) + givenItems.map(\.url)
        guard !originals.contains(where: { original in
            if original.standardizedFileURL.resolvingSymlinksInPath() == clean { return true }
            guard let targetIdentity, let originalIdentity = FileFingerprint.of(original) else { return false }
            return targetIdentity.device == originalIdentity.device && targetIdentity.inode == originalIdentity.inode
        }) else {
            resultProblem = T("Choose a different name or location to keep your original file.", table: "FilePreparationUI")
            completion?(false)
            return
        }
        write(source, to: target, id: id, expectedSource: expectedSource, completion: completion)
    }

    private func resultUnavailable(_ id: UUID) {
        guard state.items.contains(where: { $0.id == id && $0.role == .result }) else { return }
        resultProblem = T("This result is no longer available. Your original files are unchanged.", table: "NativeFlow")
        announce(resultProblem!)
    }

    /// An item was successfully dragged out or saved. Results leave Pippa afterwards
    /// (the cache file stays for the promise and disappears with the cleanup after 24 h).
    func took(_ id: UUID, target: TaskTarget.Kind) {
        guard let item = state.items.first(where: { $0.id == id }), item.role == .result else { return }
        if let record = preparationResultJobs[id] {
            persistPreparationDismissal(record) { [weak self] in
                self?.preparationResultJobs[id] = nil
                self?.took(id, target: target)
            }
            return
        }
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
        closePreparation()
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
        resultProblem = nil
        model?.openLine()
    }

    /// The line closes: without a choice logged as "passed over". Result and error step back.
    func lineClosed() {
        if !choseSinceOpen {
            let urls = givenItems.map { url(for: $0) }
            let ids = actionChoices.all.map(\.id)
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
            pendingRequest = nil
            passwords = [:]
            settle()
        default: break
        }
    }

    // MARK: Tool

    func retainedPreparationInputs() async throws -> [URL] {
        guard let preparationStore else { throw DurableJobError.persistenceFailed }
        return try await preparationStore.records().filter { $0.kind == .filePreparation && $0.state != .cancelled }
            .flatMap { $0.inputs.map(\.url) }
    }

    func pruneDismissedPreparationArtifacts(keeping: [URL]) async {
        guard let preparationStore else { return }
        do { _ = try await preparationStore.pruneCancelledArtifacts(keeping: keeping + items.map(\.url)) }
        catch { UserMessage.record(error, context: "file-preparation-cleanup") }
    }

    /// Choosing the native action creates a durable preview. Nothing is run merely because files were dropped.
    func prepareFiles() {
        guard canPrepareFiles else { return }
        let items = givenItems
        let inputs = items.map { (item: $0, url: url(for: $0)) }
        let generation = UUID()
        preparationGeneration = generation
        preparationBusy = true
        freezeSuggestions()
        phase = .working(title: T("Checking your files", table: "FilePreparationUI"), progress: nil)
        startClock()
        let capture = Task.detached(priority: .userInitiated) {
                    var sources: [FilePreparationSource] = []
                    var grants: [DurableJobInput] = []
                    for input in inputs {
                        sources.append(try FilePreparationSource.capture(input.url))
                        grants.append(try DurableJobInput.capture(url: input.url, bookmark: input.item.bookmark))
                    }
                    return FilePreparationDraft(items: items, sources: sources, grants: grants, plan: .init())
                }
        preparationCaptureTask = capture
        Task { [weak self] in
            do {
                let draft = try await capture.value
                guard let self, self.preparationGeneration == generation else { return }
                self.preparationCaptureTask = nil
                self.preparation = draft
                self.persistPreparation(draft)
            } catch {
                guard let self, self.preparationGeneration == generation else { return }
                self.preparationBusy = false
                self.stopClock()
                self.fail((error as? LocalizedError)?.errorDescription ?? T("I couldn’t keep this request. Your files are unchanged. Please try again.", table: "FilePreparationUI"))
            }
        }
    }

    func movePreparationInput(_ id: UUID, by offset: Int) {
        guard !isWorking, var draft = preparation,
              let index = draft.items.firstIndex(where: { $0.id == id }), draft.items.indices.contains(index + offset) else { return }
        draft.items.swapAt(index, index + offset)
        draft.sources.swapAt(index, index + offset)
        draft.grants.swapAt(index, index + offset)
        preparation = draft
        persistPreparation(draft)
    }

    func setPreparationQuality(_ quality: FilePreparationPlan.Quality) {
        guard !isWorking, var draft = preparation else { return }
        draft.plan.quality = quality
        preparation = draft
        persistPreparation(draft)
    }

    func setPreparationSizeGoal(_ goal: FilePreparationPlan.SizeGoal?) {
        guard !isWorking, var draft = preparation else { return }
        draft.plan.sizeGoal = goal
        preparation = draft
        persistPreparation(draft)
    }

    /// Each changed ordered preview replaces its old queued request. A stale write cannot replace a newer preview.
    private func persistPreparation(_ draft: FilePreparationDraft) {
        let generation = UUID()
        preparationGeneration = generation
        preparationBusy = true
        let previous = preparationRecord
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let store = self.preparationStore else { throw DurableJobError.persistenceFailed }
                let record = try await store.create(kind: .filePreparation, requestKey: UUID().uuidString,
                    title: T("Ready to send", table: "FilePreparationUI"), inputs: draft.grants,
                    payload: JSONEncoder().encode(draft))
                guard self.preparationGeneration == generation else {
                    _ = try? await store.cancel(id: record.id, expectedRevision: record.revision)
                    return
                }
                if let previous {
                    do { _ = try await store.cancel(id: previous.id, expectedRevision: previous.revision) }
                    catch {
                        _ = try? await store.cancel(id: record.id, expectedRevision: record.revision)
                        throw error
                    }
                }
                guard self.preparationGeneration == generation else {
                    _ = try? await store.cancel(id: record.id, expectedRevision: record.revision)
                    return
                }
                self.preparationRestoreGeneration = UUID()
                self.preparationRecord = record
                self.preparationRun = nil
                self.preparationJobs.removeAll { $0.id == previous?.id }
                self.preparationBusy = false
                self.stopClock()
                self.settle()
            } catch {
                guard self.preparationGeneration == generation else { return }
                self.preparationRecord = nil
                self.preparationBusy = false
                self.stopClock()
                self.fail(T("I couldn’t keep this request. Your files are unchanged. Please try again.", table: "FilePreparationUI"))
            }
        }
    }

    func closePreparation() {
        guard !isWorking else { return }
        preparationGeneration = UUID()
        preparation = nil
        preparationRecord = nil
        preparationRun = nil
        passwords = [:]
        restorePreparationJobs()
    }

    func resumePreparation(_ record: DurableJobRecord) {
        guard record.state != .running else {
            preparationProblem = T("This request is already running. Let it finish, or stop it in the Pippa window where you started it.", table: "FilePreparationUI")
            return
        }
        guard !isWorking, record.kind == .filePreparation,
              let draft = try? JSONDecoder().decode(FilePreparationDraft.self, from: record.payload),
              !draft.items.isEmpty, draft.items.count == draft.sources.count, draft.items.count == draft.grants.count else { return }
        preparation = draft
        preparationRecord = record
        let existing = Set(state.items.map(\.id))
        state.items.append(contentsOf: draft.items.filter { !existing.contains($0.id) })
        preparationJobs.removeAll { $0.id == record.id }
        // Resuming means reviewing saved inputs. It grants no permission to execute an interrupted run.
        persistPreparation(draft)
        changed()
        model?.openLine()
    }

    func dismissPreparation(_ record: DurableJobRecord) {
        guard !isWorking else { return }
        persistPreparationDismissal(record) { [weak self] in self?.preparationJobs.removeAll { $0.id == record.id } }
    }

    private func persistPreparationDismissal(_ record: DurableJobRecord, then: @escaping @MainActor () -> Void) {
        preparationRestoreGeneration = UUID()
        dismissedPreparationIDs.insert(record.id)
        preparationBusy = true
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let store = self.preparationStore else { throw DurableJobError.persistenceFailed }
                _ = try await store.cancel(id: record.id, expectedRevision: record.revision)
                self.preparationBusy = false
                self.preparationProblem = nil
                then()
            } catch {
                self.preparationBusy = false
                self.dismissedPreparationIDs.remove(record.id)
                self.preparationProblem = T("I couldn’t save that change. Your request and result are still here.", table: "FilePreparationUI")
                self.resultProblem = self.preparationProblem
            }
        }
    }

    private func restorePreparationJobs() {
        guard let store = preparationStore else {
            preparationProblem = T("I couldn’t open your saved requests. Your files haven’t been changed.", table: "FilePreparationUI")
            return
        }
        let generation = UUID()
        preparationRestoreGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            let records: [DurableJobRecord]
            do { records = try await store.records() }
            catch {
                guard self.preparationRestoreGeneration == generation else { return }
                self.preparationProblem = T("I couldn’t open your saved requests. Your files haven’t been changed.", table: "FilePreparationUI")
                return
            }
            guard self.preparationRestoreGeneration == generation else { return }
            var pending: [DurableJobRecord] = []
            for record in records where record.kind == .filePreparation && record.state != .cancelled {
                guard !self.dismissedPreparationIDs.contains(record.id) else { continue }
                guard record.id != self.preparationRecord?.id else { continue }
                if record.state == .completed, let data = record.resultData,
                   let saved = try? JSONDecoder().decode(FilePreparationSavedResult.self, from: data),
                   let artifacts = try? await store.verifiedArtifacts(id: record.id),
                   Set(saved.items.map(\.url)) == Set(artifacts.map(\.url)),
                   let current = try? await store.record(id: record.id), current.revision == record.revision,
                   current.state == .completed {
                    guard self.preparationRestoreGeneration == generation else { return }
                    for item in saved.items {
                        self.state = TrayRules.consumed(saved.sources.map(\.id), by: item, in: self.state)
                        self.preparationResultJobs[item.id] = current
                    }
                    for source in saved.sources { self.consumedItems[source.id] = source }
                } else { pending.append(record) }
            }
            guard self.preparationRestoreGeneration == generation else { return }
            self.preparationJobs = pending.sorted { $0.updated > $1.updated }
            self.changed()
        }
    }

    /// A native tool completion refreshes retained results without opening or replacing the chat.
    func refreshSavedPreparations() { restorePreparationJobs() }

    /// Cards carry evidence from a native result. Resolve that job and verify its current artifact,
    /// never open an arbitrary path merely because it appeared in a conversation.
    func preparedFileAccess(_ card: PreparedFilesCard, file: URL) async -> PreparedFileAccess {
        guard !isWorking else { return .busy }
        guard card.files.contains(file), file.isFileURL, let preparationStore else { return .unavailable }
        do {
            let record = try await preparationStore.record(id: card.jobID)
            guard record.kind == .filePreparation else { return .unavailable }
            guard record.state == .completed else { return record.state == .cancelled ? .retired : .unavailable }
            guard let data = record.resultData,
                  let saved = try? JSONDecoder().decode(FilePreparationSavedResult.self, from: data),
                  Set(saved.items.map(\.url)) == Set(card.files),
                  let item = saved.items.first(where: { $0.url == file && $0.role == .result }) else { return .unavailable }
            let artifacts = try await preparationStore.verifiedArtifacts(id: card.jobID)
            guard Set(artifacts.map(\.url)) == Set(card.files),
                  let artifact = artifacts.first(where: { $0.url == file }) else { return .unavailable }
            let current = try await preparationStore.record(id: card.jobID)
            guard current.state == .completed, current.revision == record.revision else { return .retired }
            guard !isWorking else { return .busy }
            if !state.items.contains(where: { $0.id == item.id && $0.url == item.url && $0.role == .result }) {
                state = TrayRules.consumed(saved.sources.map(\.id), by: item, in: state)
                for source in saved.sources { consumedItems[source.id] = source }
                changed()
            }
            preparationResultJobs[item.id] = current
            return .available(item.id, artifact.identity)
        } catch DurableJobError.artifactChanged { return .changed }
        catch DurableJobError.artifactOutsideJob { return .changed }
        catch DurableJobError.sourceChanged { return .changed }
        catch DurableJobError.unknownJob { return .unavailable }
        catch {
            if !FileManager.default.isReadableFile(atPath: file.path) { return .unavailable }
            return .unverified
        }
    }

    func actOnPreparedFile(_ action: PreparedFileAction, card: PreparedFilesCard, file: URL,
                           completion: @escaping @MainActor (String?) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            let access = await self.preparedFileAccess(card, file: file)
            guard case .available(let id, _) = access else { completion(access.message); return }
            switch action {
            case .open:
                if DevEnvironment.value("PIPPA_DEMO") != "1" { self.openResult(id) }
                completion(self.resultProblem)
            case .finder:
                if DevEnvironment.value("PIPPA_DEMO") != "1" { self.revealResult(id) }
                completion(nil)
            case .save:
                guard DevEnvironment.value("PIPPA_DEMO") != "1" else { completion(nil); return }
                NSApp.activate()
                let panel = NSSavePanel()
                panel.nameFieldStringValue = file.lastPathComponent; panel.canCreateDirectories = true
                panel.allowedContentTypes = [.pdf]
                panel.begin { [weak self] response in
                    MainActor.assumeIsolated {
                        guard response == .OK, let target = panel.url else { completion(nil); return }
                        Task { @MainActor [weak self] in
                            await self?.savePreparedFile(card, file: file, to: target, completion: completion)
                        }
                    }
                }
            }
        }
    }

    /// Revalidate after the save panel: it may have stayed open while another window removed the result.
    func savePreparedFile(_ card: PreparedFilesCard, file: URL, to target: URL,
                          completion: @escaping @MainActor (String?) -> Void) async {
        let access = await preparedFileAccess(card, file: file)
        guard case .available(let id, let identity) = access else { completion(access.message); return }
        resultProblem = nil
        save(id, to: target, expectedSource: identity) { [weak self] copied in
            completion(copied ? nil : self?.resultProblem
                       ?? T("I couldn’t save this copy. The prepared file is still available in Pippa.", table: "FilePreparationUI"))
        }
    }

    func runPreparation() {
        guard !isWorking, let draft = preparation, let record = preparationRecord,
              let store = preparationStore else { return }
        let generation = UUID()
        preparationGeneration = generation
        preparationBusy = true
        let secrets = passwords
        Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await store.record(id: record.id)
                let ready = current.state == .queued ? current : try await store.retry(id: current.id, expectedRevision: current.revision)
                let token = try await store.start(id: ready.id, expectedRevision: ready.revision)
                guard self.preparationGeneration == generation else {
                    _ = try? await store.cancel(id: token.jobID, expectedRevision: token.revision)
                    return
                }
                let run = UUID()
                self.runID = run
                self.preparationRun = token
                self.preparationBusy = false
                self.pendingTool = .makeOnePDF
                self.pendingRequest = NativeFileRequest(tool: .makeOnePDF, inputIDs: self.givenItems.map(\.id))
                self.resultProblem = nil
                self.phase = .working(title: T("Preparing your PDF", table: "FilePreparationUI"), progress: nil)
                self.startClock()
                let report: @Sendable (ToolProgress) -> Void = { [weak self] progress in
                    Task { @MainActor [weak self] in self?.progressed(progress, run: run) }
                }
                let work = Task.detached(priority: .userInitiated) {
                    try await FilePreparation.run(sources: draft.sources, plan: draft.plan, passwords: secrets, progress: report)
                }
                self.toolTask = work
                Task { [weak self] in
                    do {
                        let output = try await work.value
                        await self?.finish(output, tool: .makeOnePDF, inputs: zip(draft.items, draft.sources).map { ($0, $1.url) }, run: run)
                    } catch { self?.failed(error, run: run) }
                }
            } catch {
                guard self.preparationGeneration == generation else { return }
                self.preparationBusy = false
                self.fail(T("I couldn’t keep this request. Your files are unchanged. Please try again.", table: "FilePreparationUI"))
            }
        }
    }

    private func startTool(_ tool: ToolID) {
        let given = givenItems
        guard !given.isEmpty else { return }
        let inputs = given.map { (item: $0, url: url(for: $0)) }
        let urls = inputs.map(\.url)
        let secrets = passwords
        let run = UUID()
        runID = run
        pendingTool = tool
        pendingRequest = NativeFileRequest(tool: tool, inputIDs: given.map(\.id))
        resultProblem = nil
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
        for file in output.files where Self.isCachedResult(file) {
            do { try FileManager.default.removeItem(at: file) }
            catch { UserMessage.record(error, context: "werkzeug-abbruch") }
        }
    }

    private func finish(_ initialOutput: ToolOutput, tool: ToolID, inputs: [(item: TrayItem, url: URL)], run: UUID) async {
        var output = initialOutput
        guard runID == run else {
            await discard(output, receipt: nil)
            return
        }
        let durableRun = preparationRun
        var artifacts: [DurableJobArtifact] = []
        if let durableRun, let preparationStore {
            do {
                for file in output.files { artifacts.append(try await preparationStore.retainArtifact(from: file, run: durableRun)) }
                guard runID == run else {
                    await discardPromotedArtifacts(artifacts)
                    await discard(output, receipt: nil)
                    return
                }
                for file in output.files where Self.isCachedResult(file) { try? FileManager.default.removeItem(at: file) }
                output.files = artifacts.map(\.url)
            } catch {
                await discardPromotedArtifacts(artifacts)
                await discard(output, receipt: nil)
                failed(error, run: run)
                return
            }
        }
        let detail = output.detailSentence ?? ""
        var receipt: JobReceipt?
        if let engine = model?.engine, !output.files.isEmpty {
            do { receipt = try await engine.recordResult(output.files, summary: output.summary, detail: detail) }
            catch { UserMessage.record(error, context: "werkzeug-journal") }
        }
        // Recording yields to Stop or a new run. A stale completion must never replace that state.
        guard runID == run else {
            await discard(output, receipt: receipt)
            await discardPromotedArtifacts(artifacts)
            return
        }
        let consumed = Set(output.consumedInputs.map(\.standardizedFileURL))
        let used = inputs.filter { consumed.contains($0.url.standardizedFileURL) }.map(\.item)
        for item in used { consumedItems[item.id] = item }
        let usedIDs = used.map(\.id)
        var next = state
        var results: [TrayItem] = []
        for file in output.files.reversed() {
            let made = TrayItem(role: .result, url: file, receipt: receipt?.id, sources: usedIDs, tool: tool,
                                note: output.detailSentence)
            next = TrayRules.consumed(results.isEmpty ? usedIDs : [], by: made, in: next)
            results.insert(made, at: 0)
        }
        if let durableRun, let preparationStore {
            do {
                let saved = FilePreparationSavedResult(items: results, sources: used)
                let record = try await preparationStore.finish(run: durableRun, state: .completed,
                    resultData: JSONEncoder().encode(saved), artifacts: artifacts)
                guard runID == run else {
                    await discard(output, receipt: receipt); await discardPromotedArtifacts(artifacts); return
                }
                for item in results { preparationResultJobs[item.id] = record }
                preparation = nil
                preparationRecord = nil
                preparationRun = nil
            } catch {
                await discard(output, receipt: receipt)
                await discardPromotedArtifacts(artifacts)
                failed(error, run: run)
                return
            }
        }
        runID = nil
        toolTask = nil
        pendingTool = nil
        pendingRequest = nil
        passwords = [:]
        stopClock()
        state = next
        if let receipt {
            receipts[receipt.id] = receipt
            model?.taskLog.finished(receipt.id)
        }
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

    /// A cancelled promotion has no published result record yet. Remove only its exact, still-unmodified copies.
    private func discardPromotedArtifacts(_ artifacts: [DurableJobArtifact]) async {
        let base = store.directory
        await Task.detached(priority: .utility) {
            for artifact in artifacts where ResultsFolder.contains(artifact.url, durableBaseDirectory: base) {
                guard (try? DurableFileIdentity.capture(artifact.url)) == artifact.identity else { continue }
                try? FileManager.default.removeItem(at: artifact.url)
                let folder = artifact.url.deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }.value
    }

    /// Legacy fallback cleanup owns only ephemeral cache results. Durable copies require their
    /// recorded content identity; a shared directory prefix alone does not authorize deletion.
    nonisolated private static func isCachedResult(_ url: URL) -> Bool {
        let root = ResultsFolder.directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/") && path.count > root.count + 1
    }

    private func failed(_ error: Error, run: UUID) {
        guard runID == run else { return }
        if let token = preparationRun, let store = preparationStore {
            preparationRun = nil
            preparationBusy = true
            Task { [weak self] in
                let record = try? await store.finish(run: token, state: .needsAttention, issue: "file-preparation-needs-review")
                guard let self, self.runID == run else { return }
                if let record { self.preparationRecord = record }
                self.preparationBusy = false
                self.failed(error, run: run)
            }
            return
        }
        runID = nil
        toolTask = nil
        stopClock()
        if error is CancellationError {
            pendingTool = nil
            pendingRequest = nil
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
                // A smaller file cannot be made smaller by repeating the same operation.
                if failure == .alreadySmall { pendingTool = nil; pendingRequest = nil }
                passwords = [:]
                fail(failure.errorDescription ?? T("That didn’t work. Your files are unchanged.", table: "TrayApp"))
                return
            }
        }
        passwords = [:]
        if let failure = error as? FilePreparationFailure {
            fail(failure.localizedDescription)
            return
        }
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
        resultProblem = nil
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
            settle()
        }
        changed()
    }

    private func write(_ source: URL, to target: URL, id: UUID, expectedSource: DurableFileIdentity? = nil,
                       completion: (@MainActor (Bool) -> Void)? = nil) {
        Task { [weak self] in
            let copied = await Task.detached(priority: .userInitiated) {
                TrayController.copy(source, to: target, expectedSource: expectedSource)
            }.value
            guard let self else { return }
            if copied { self.took(id, target: .file) }
            else if self.state.items.contains(where: { $0.id == id && $0.role == .result }) {
                let message = T("I couldn’t save it there. Your result is still here. Choose another location or drag it out.", table: "NativeFlow")
                if self.phase == .result(id) { self.resultProblem = message }
                self.announce(message)
            }
            completion?(copied)
        }
    }

    /// Copy to the chosen location. Replacing (confirmed in the save panel) goes via an intermediate copy
    /// on the same volume, so that no half file ever stands at the destination.
    nonisolated private static func copy(_ source: URL, to target: URL, expectedSource: DurableFileIdentity? = nil) -> Bool {
        let fm = FileManager.default
        guard source.standardizedFileURL.resolvingSymlinksInPath() != target.standardizedFileURL.resolvingSymlinksInPath(),
              let identity = try? DurableFileIdentity.capture(source),
              expectedSource == nil || expectedSource == identity else { return false }
        func verified(_ url: URL) -> Bool {
            guard let copy = try? DurableFileIdentity.capture(url), let current = try? DurableFileIdentity.capture(source) else { return false }
            return copy.size == identity.size && copy.sha256 == identity.sha256 && current == identity
        }
        guard fm.fileExists(atPath: target.path) else {
            do {
                try fm.copyItem(at: source, to: target)
                return verified(target)
            } catch { return false }
        }
        guard let folder = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true) else { return false }
        let temp = folder.appendingPathComponent(target.lastPathComponent)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.copyItem(at: source, to: temp)
            guard verified(temp) else { return false }
            _ = try fm.replaceItemAt(target, withItemAt: temp)
            return verified(target)
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
        // Pictures of items that left Pippa are let go too.
        TrayThumbnails.shared.forget(keeping: state.items)
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
                    self.updateActions(for: urls, role: role)
                }
            }
        } else if suggestionsFrozen { return }
        updateActions(for: urls, role: suggestionRole)
    }

    private func updateActions(for urls: [URL], role: DocumentRole) {
        // Both ranking and availability use the same size snapshot, once per suggestion update.
        var sizes: [URL: Int64] = [:]
        func size(_ url: URL) -> Int64 {
            if let cached = sizes[url] { return cached }
            let value = ThingActions.fileSize(url)
            sizes[url] = value
            return value
        }
        let candidates = ThingActions.candidates(for: urls, size: size, role: role)
        let next = ThingActions.offered(for: urls, records: records, size: size, role: role)
        if candidates != availableActions { availableActions = candidates }
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
