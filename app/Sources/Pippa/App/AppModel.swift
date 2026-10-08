import AppKit
import Combine
import PippaCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let engine: any PippaEngine
    let conversations = ConversationController()
    /// The tray on Pippa: given things and results, with the one line (TrayController.swift).
    let tray = TrayController()
    /// Call in Mail ("Letter"): first line, actions, draft, insert (LetterController.swift).
    let letter = LetterController()
    /// Call in Excel ("Sheet"): first line from "Check the total", actions, read-only (SheetController.swift).
    let sheet = SheetController()
    @Published var inferenceSettings = InferenceSettings.load(from: AppModel.inferenceSettingsDirectory)

    @Published var conversationSize = CGSize(width: Theme.conversationWidth, height: 700)
    @Published var compactInputWidth: CGFloat = Theme.inputWidth
    var conversationViewports: [UUID: ConversationViewport] = [:]
    private var conversationActivity: [UUID: Date] = [:]
    private var conversationPresentations: [UUID: ShellMode] = [:]

    @Published private(set) var mode: ShellMode = .pill { didSet { updateMark() } }
    @Published private(set) var context: WorkContext?
    /// The last file/text task stays reachable for follow-ups.
    @Published private(set) var taskCard: ShellMode?
    @Published private(set) var dropTargeted = false
    struct PendingDrop {
        let payload: DropPayload
        let items: [URL]
        let startsFresh: Bool
    }
    @Published private(set) var pendingDrops: [PendingDrop] = []
    @Published private(set) var composerFocus = 0
    /// The system prompt (e.g. Calendar) is open: a click on it does not collapse the conversation.
    var awaitingSystemPrompt = false
    @Published private(set) var parked: ShellMode? { didSet { updateMark() } }
    @Published private(set) var lastJob: String?
    @Published private(set) var lastReceipt: JobReceipt?
    @Published private(set) var modelStatus: ModelStatus = .loading
    @Published var busy = false {
        didSet {
            updateMark()
            if busy && !oldValue { startProgressPolling() }
            if !busy { workProgress = nil; schedulePendingDrops() }
        }
    }
    /// A native compose operation cannot be cancelled safely once Mail may have created it.
    @Published var mailDraftOpening = false {
        didSet {
            updateMark()
            if !mailDraftOpening { schedulePendingDrops() }
        }
    }
    /// While the card's reply looks for the original in Mail (mailboxes searched, total). Only then is Stop offered.
    @Published var mailDraftSearch: (done: Int, total: Int)?
    var mailDraftTask: Task<Void, Never>?
    /// File by file while reading: counter, current file and linear progress.
    @Published private(set) var workProgress: WorkProgress?
    private var progressTask: Task<Void, Never>?

    private func startProgressPolling() {
        progressTask?.cancel()
        let engine = self.engine
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                let p = await engine.workProgress
                guard let self, self.busy else { return }
                if p != self.workProgress { self.workProgress = p }
            }
        }
    }
    @Published var query = "" {
        didSet {
            if oldValue != query {
                selection = 0
                if mode.isConversation || mode.key == "resume" { recordConversationActivity() }
            }
        }
    }
    @Published var selection = 0
    @Published var pillVisible: Bool {
        didSet { UserDefaults.standard.set(pillVisible, forKey: "pill.visible"); shell?.pillVisibilityChanged() }
    }
    @Published var toastShowing = false { didSet { updateMark() } }

    // Tidy
    @Published var plan: Plan?
    /// The preview is already there, documents are still being read or classified. Approving works anyway.
    @Published private(set) var sortFilling = false
    /// Does a growing preview still belong to the current round? (Not after approve or back.)
    private var sortRound: UUID?
    /// Documents left in place when tidying without a model (`Plan.later`); once Pippa is awake, she offers them.
    private(set) var sortLater: (files: [URL], scope: URL)?
    /// Already offered (once per remembered round)?
    private var sortLaterOffered = false
    @Published var excluded: Set<UUID> = []
    @Published var showReasons = false
    /// Open groups in the tidy preview (target folders) and those that show all rows.
    @Published var openGroups: Set<String> = []
    @Published var fullGroups: Set<String> = []
    // Invoices
    @Published var invoices: [InvoiceRow] = []
    @Published var exportFormat: ExportFormat = .xlsx
    // Deadlines
    @Published var deadlines: [Deadline] = []
    @Published var entryDraft: CalendarEntry?
    @Published var entryDeadline: Deadline?
    var deadlineSender: String?
    /// What was last attempted (head of the error message).
    @Published private(set) var lastWorkTitle = ""
    /// Waiting for permission (after the sentence before the system prompt).
    var afterAccess: (@MainActor () -> Void)?

    /// Last shown overview, target of "back" from a sheet.
    var lastOverview: Overview?
    /// Task log: chosen actions and their outcome, without content. Without a file it writes nothing.
    let taskLog = TaskLogRecorder(log: try? TaskLog())
    private var retry: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var conversationChanges: AnyCancellable?
    private var trayChanges: AnyCancellable?
    private var letterChanges: AnyCancellable?
    private var sheetChanges: AnyCancellable?

    weak var shell: ShellController?
    weak var toasts: ToastController?

    private init() {
        engine = EngineShim.make()
        let defaults = UserDefaults.standard
        pillVisible = defaults.object(forKey: "pill.visible") as? Bool ?? true
        restoreConversationContext()
        conversationChanges = conversations.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send(); self?.updateMark(); self?.schedulePendingDrops() }
        }
        tray.model = self
        trayChanges = tray.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send(); self?.updateMark() }
        }
        letter.model = self
        letterChanges = letter.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send(); self?.updateMark(); self?.schedulePendingDrops() }
        }
        sheet.model = self
        sheetChanges = sheet.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }

    // MARK: Figure

    var markState: MarkState {
        if busy || mailDraftOpening || conversations.isRunning || tray.isWorking || letter.isWorking { return .arbeitet }
        if case .message(_, _, true) = mode { return .fehler }
        switch mode {
        // The visible task owns the mark. A parked result must not turn a fresh
        // question into a green completion/attention signal.
        case .input, .resume, .target: return .ruht
        case .line:
            switch tray.phase {
            case .result: return .offen
            case .failure: return .fehler
            default: return .ruht
            }
        case .overview, .sortSheet, .invoiceSheet, .deadlines, .entryPreview, .notice: return .offen
        case .working: return .arbeitet
        default: break
        }
        if parked != nil || toastShowing { return .offen }
        return .ruht
    }

    private func updateMark() {
        MarkHub.shared.set(markState)
    }

    var spokenState: String { "Pippa, \(markState.spoken)" }

    // MARK: Model

    /// Who can answer in the local chat: large model, system model ("still tired"), or nobody yet.
    @Published private(set) var chatReadiness: ChatReadiness = .unavailable
    /// Size of the model for the question before the first load.
    @Published private(set) var downloadSize: ModelDownloadSize?
    /// Has the person agreed to loading? Without consent Pippa loads nothing from the internet.
    @Published private(set) var downloadAllowed = UserDefaults.standard.bool(forKey: AppModel.downloadAllowedKey)
    static let downloadAllowedKey = "model.download.allowed"
    /// No progress for 30 s while loading, or the last attempt failed because of the network.
    @Published private(set) var downloadStalled = false
    private var stallWatch = DownloadStallWatch(limit: 30)

    /// "Load now": remember consent and load.
    func startModelDownload() {
        UserDefaults.standard.set(true, forKey: Self.downloadAllowedKey)
        downloadAllowed = true
        downloadNote = nil
        setStalled(false)
        prepareWithRetry()
        watchModelStatus()
    }

    /// Cancel download: stop the running download. Started files are kept for later.
    func cancelModelDownload() {
        prepareTask?.cancel()
        setStalled(false)
        downloadNote = nil
        let engine = self.engine
        Task { [weak self] in
            await engine.cancelModelPreparation()
            if let self {
                self.modelStatus = await self.engine.modelStatus
                self.downloadSize = await self.engine.modelDownloadSize
            }
        }
    }

    /// "Try again": end the running attempt and restart immediately (continues where it left off).
    func retryDownloadNow() {
        guard mayPrepareWithoutAsking else { return startModelDownload() }
        prepareTask?.cancel()
        setStalled(false)
        stallWatch = DownloadStallWatch(limit: 30)
        let engine = self.engine
        Task { [weak self] in
            await engine.cancelModelPreparation()
            self?.prepareWithRetry()
        }
    }
    var isActiveWork: Bool { busy || mailDraftOpening || conversations.isRunning || letter.isWorking }

    private func watchModelStatus() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                // Settled (model ready, chat ready): look less often. Every published assignment redraws the views,
                // so unchanged values are not assigned again; a resting Pippa should cost next to no CPU.
                let settled = self.map { $0.modelStatus == .ready && $0.chatReadiness == .ready && !$0.isDownloading } ?? true
                do { try await Task.sleep(for: .seconds(settled ? 5 : 1)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let status = await self.engine.modelStatus
                if status != self.modelStatus { self.modelStatus = status }
                // While loading, a found file can be rejected: then stop claiming it "adopts".
                if self.isDownloading { self.downloadSize = await self.engine.modelDownloadSize }
                self.offerSortLater()
                let readiness = await self.engine.chatReadiness
                if readiness != self.chatReadiness { self.chatReadiness = readiness }
                self.updateStall()
                if case .unsupported = self.modelStatus { return }
            }
        }
    }

    /// Calm note when the download is not working right now (it retries by itself).
    @Published private(set) var downloadNote: String?
    private var prepareTask: Task<Void, Never>?

    /// Is the download stuck? On transition, a note at the pill with "Try again" (in onboarding it appears there).
    private func updateStall() {
        if modelStatus == .ready { return setStalled(false) }
        guard case .downloading(let progress, _) = modelStatus else { return }
        lastProgress = progress
        // The note stays until data really arrives again; a new attempt alone does not clear it.
        if stallWatch.update(progress: progress) { setStalled(true) }
        else if let at = stalledAt, progress > at { setStalled(false) }
    }
    private var lastProgress = 0.0
    private var stalledAt: Double?

    private func setStalled(_ stalled: Bool) {
        stalledAt = stalled ? (stalledAt ?? lastProgress) : nil
        guard stalled != downloadStalled else { return }
        downloadStalled = stalled
        guard stalled, !mode.isExpanded else { return }
        toasts?.show(title: T("I can’t get online right now", table: "App"),
                     detail: T("I’ll keep trying. Loading picks up where it left off.", table: "App"),
                     buttons: [.init(title: T("Try Again", table: "App"), primary: true) { [weak self] in self?.retryDownloadNow() }], log: false)
    }

    func inferenceSettingsDidChange(wasConnectionOnly: Bool) {
        // In the RPC path approvals lapse, and Pi takes the new route at its next start (PiRPCChat.launchRoute).
        if PiRPCChat.isLive { PiRPCChat.shared.onlineSettingsChanged() }
        // Only if the connected model always does the work is the local one not needed.
        // With "ask first", "On this Mac" remains a real choice: keep preparing.
        if alwaysUsesConnection {
            prepareTask?.cancel()
            Task { await engine.cancelModelPreparation() }
        } else if wasConnectionOnly {
            Task { [weak self] in
                guard let self else { return }
                // Here too, load only with consent; an existing model starts.
                self.downloadSize = await self.engine.modelDownloadSize
                self.modelStatus = await self.engine.modelStatus
                if self.mayPrepareWithoutAsking { self.prepareWithRetry() }
                self.watchModelStatus()
            }
        }
    }

    /// Load the model; on errors retry silently: after 30 s, 2 min, 10 min, then every 30 min,
    /// each time only once the network is back. No error messages, just a calm sentence in the progress.
    private func prepareWithRetry() {
        // Pi path (default): PiRPCChat starts the llama-server for Pi; a second one for the old path
        // would stay loaded beside it and cost the same memory again. LocalEngine uses that server.
        if PiRPCChat.isLive { return }
        prepareTask?.cancel()
        let engine = self.engine
        prepareTask = Task { [weak self] in
            let delays: [Double] = [30, 120, 600]
            var attempt = 0
            while !Task.isCancelled {
                do {
                    try await engine.prepareModel(allowDownload: self?.downloadAllowed ?? false)
                    self?.downloadNote = nil
                    self?.setStalled(false)
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if error is ModelDownloader.AdoptionFailed {
                        // The found file did not fit, and loading happens only with consent: silently back to the question.
                        guard let self else { return }
                        self.downloadSize = await engine.modelDownloadSize
                        self.modelStatus = await engine.modelStatus
                        return
                    }
                    UserMessage.record(error, context: "modell-laden")
                    if let p = error as? PippaError {
                        switch p {
                        case .unsupportedHardware, .serverMissing: return
                        default: break
                        }
                    }
                    switch error as? PippaError {
                    case .notEnoughSpace, .writeFailed, .checksumMismatch, .modelFailed:
                        // Not a network problem: show the own message (full disk, corrupt download, start failure).
                        self?.downloadNote = UserMessage.text(for: error, context: "download")
                        // An earlier network note would otherwise hide this message.
                        self?.setStalled(false)
                    default:
                        // Network: the same calm sentence as for a stuck download, with "Try again".
                        self?.downloadNote = nil
                        self?.setStalled(true)
                    }
                    let wait = attempt < delays.count ? delays[attempt] : 1800
                    attempt += 1
                    try? await Task.sleep(for: .seconds(wait))
                    await NetworkWatch.shared.waitUntilOnline()
                }
            }
        }
    }

    func start() {
        refreshJobs()
        // Pi path (default): set up silently; the only question (download) is in Welcome.
        PiSetupController.shared?.attach(to: self)
        // Sorting, invoices, deadlines and letter suggestions use the one llama-server of the Pi path.
        if PiRPCChat.isLive { PiRPCChat.shared.shareServer(with: engine) }
        tray.load()
        // Delete tray copies older than 30 days, unless a conversation or the tray on Pippa still has them.
        // Without a readable history (store missing) and in developer recordings (own history) delete nothing.
        if conversations.current != nil, DevEnvironment.value("PIPPA_SNAPSHOT") == nil {
            let keeping = conversations.contextFiles + tray.items.map(\.url), inbox = Inbox.directory
            Task.detached(priority: .utility) { InboxCleanup.prune(inbox, keeping: keeping) }
        }
        // Show the first greeting before the model search: foreign model folders can be large.
        // A call or file task already begun keeps its surface.
        let forceOnboarding = DevEnvironment.value("PIPPA_ONBOARDING") == "1"
        let firstRun = !UserDefaults.standard.bool(forKey: "onboarded")
        if (firstRun || forceOnboarding), mode.key == "pill", !isActiveWork,
           !letter.isActive, !sheet.isActive, context == nil, pendingDrops.isEmpty, tray.items.isEmpty {
            show(.onboarding)
        }
        statusTask = Task { [weak self] in
            guard let self else { return }
            let first = await engine.modelStatus
            self.modelStatus = first
            self.chatReadiness = await engine.chatReadiness
            self.downloadSize = await engine.modelDownloadSize
            if case .unsupported = first, !self.hasConfiguredInference { return }
            if first != .ready && !self.alwaysUsesConnection {
                // No network by default: loading starts only after "Load now". An already loaded model starts immediately.
                // If the model already lies with LM Studio, Ollama & co., adopting works without internet: start right away.
                if self.mayPrepareWithoutAsking { self.prepareWithRetry() }
            }
            self.watchModelStatus()
        }
        Task { [weak self] in
            guard let self else { return }
            let pending = await engine.pendingRecovery()
            if let receipt = pending.first { self.offerRecovery(receipt) }
        }
    }

    private func offerRecovery(_ receipt: JobReceipt) {
        toasts?.show(title: T("A task was interrupted", table: "App"), detail: receipt.summary, buttons: [
            .init(title: T("Continue", table: "App"), primary: true) { [weak self] in self?.resume(receipt) },
            .init(title: T("Undo", table: "App"), primary: false) { [weak self] in self?.undo(receipt) },
            .init(title: T("Leave It", table: "App"), primary: false) { [weak self] in
                guard let engine = self?.engine else { return }
                Task { await engine.dismissRecovery(receipt) }
            },
        ])
    }

    func resume(_ receipt: JobReceipt) {
        perform(title: T("Picking up where I left off…", table: "App"), subtitle: "", writes: T("I’m only moving things, nothing gets deleted", table: "App"), retry: { [weak self] in self?.resume(receipt) }) { engine in
            try await engine.resume(receipt)
        } done: { [weak self] done in
            guard let self else { return }
            self.finish(done)
            self.showReceipt(done)
        }
    }

    // MARK: Shell

    /// Set while a result arrives after the shell was closed.
    private var deferResults = false
    /// After how many messages the open card sits in the conversation.
    @Published private(set) var cardAnchor = 0

    func show(_ mode: ShellMode, recordResult: Bool = true, receipt: UUID? = nil, preserveCardAnchor: Bool = false) {
        switch mode {
        case .overview, .sortSheet, .invoiceSheet, .deadlines, .entryPreview, .notice:
            taskCard = mode
        default: break
        }
        if recordResult {
            // Overviews, previews and receipts stay as a line in the history, even if the card goes later.
            switch mode {
            case .notice(let title, let detail, _):
                conversations.append(.assistant, title + (detail.isEmpty ? "" : "\n" + detail), receipt: receipt)
            case .overview(let o):
                let heading = o.subtitle.isEmpty ? o.title : o.title + " · " + o.subtitle
                conversations.append(.system, T("Overview: %@", table: "App", heading))
            case .sortSheet:
                break   // The line is added only when the preview is complete (see proposeSort); at the first interim state N would be too small.
            case .invoiceSheet:
                let line = invoices.count == 1
                    ? T("Invoice table preview: 1 invoice", table: "App")
                    : T("Invoice table preview: %lld invoices", table: "App", invoices.count)
                conversations.append(.system, line)
            case .deadlines:
                let line = deadlines.count == 1
                    ? T("Found 1 deadline", table: "App")
                    : T("Found %lld deadlines", table: "App", deadlines.count)
                conversations.append(.system, line)
            default: break
            }
        }
        // The card follows the messages so far; follow-ups to it come below.
        if !preserveCardAnchor, mode.isConversation, mode.key != "input" { cardAnchor = conversations.current?.messages.count ?? 0 }
        if deferResults && mode.isResult {
            parked = mode
            return
        }
        if mode.isResult { parked = nil }
        if mode.key != self.mode.key {
            if case .message = mode {} else { messageList = []; partialReceipt = nil }
            selection = 0
            if !(self.mode.isConversation && mode.isConversation) { shell?.modeWillChange() }
        }
        if mode.isConversation, let id = conversations.current?.id { conversationPresentations[id] = mode }
        self.mode = mode                // The transition is done by the shell (Core Animation), not SwiftUI
        shell?.modeChanged()
    }

    var isExpanded: Bool { mode.isExpanded }

    /// User interaction only: background streaming and elapsed time do not refresh this clock.
    func recordConversationActivity(at date: Date = Date()) {
        guard let id = conversations.current?.id else { return }
        conversationActivity[id] = date
    }

    var hasResumableConversation: Bool {
        guard let current = conversations.current else { return false }
        return !current.messages.isEmpty || current.context != nil || !query.isEmpty
            || conversationPresentations[current.id] != nil || isActiveWork
    }

    /// Evaluated only on an explicit reopen, never by a timer while the surface is visible.
    func openConversationFromPill(now: Date = Date()) {
        guard hasResumableConversation, let current = conversations.current else { return openInput() }
        let requiresAttention = isActiveWork || tray.isWorking
            || parked?.requiresReviewOnReopen == true || taskCard?.requiresReviewOnReopen == true
            || conversationPresentations[current.id]?.requiresReviewOnReopen == true
            || current.messages.contains { message in
                guard let draft = message.mailDraft else { return false }
                return draft.state == .draft || draft.state == .opening || draft.state == .uncertain
            }
        let lastActivity = conversationActivity[current.id] ?? current.lastActivity
        switch ConversationReopenPolicy.destination(lastActivity: lastActivity, now: now, requiresAttention: requiresAttention) {
        case .conversation:
            restoreConversationPresentation()
            recordConversationActivity(at: now)
        case .compact:
            show(.resume, recordResult: false)
            composerFocus += 1
        }
    }

    func resumeConversation() {
        restoreConversationPresentation()
        recordConversationActivity()
    }

    private func restoreConversationPresentation() {
        if parked != nil { resumeParked(); return }
        if let id = conversations.current?.id, let presentation = conversationPresentations[id] {
            // Completed work must not revive its obsolete progress display.
            if case .working = presentation, !isActiveWork { openInput(); return }
            show(presentation, recordResult: false, preserveCardAnchor: true)
            composerFocus += 1
        } else { openInput() }
    }

    func openInput() {
        selection = 0
        show(.input)
        composerFocus += 1
    }

    func toggleInput() {
        if mode.key == "resume" { collapse(); return }
        if mode.isConversation { collapse() } else { openInput() }
    }

    /// Back to the pill. An open result waits silently (no number; preview image from R1).
    func collapse() {
        if mode.isConversation { recordConversationActivity() }
        if mode.key == "line" {
            if sheet.isActive { sheet.lineClosed() } else if letter.isActive { letter.lineClosed() } else { tray.lineClosed() }
        }
        if mode.isResult { parked = mode }
        if case .onboarding = mode { UserDefaults.standard.set(true, forKey: "onboarded") }
        show(.pill)
    }

    /// Esc: one step back in the sheet, otherwise to the pill.
    func escape() {
        switch mode {
        case .sortSheet, .invoiceSheet, .deadlines:
            stopSortFilling()
            if let o = lastOverview { show(.overview(o), recordResult: false) } else { collapse() }
        case .entryPreview:
            entryDraft = nil
            if deadlines.isEmpty { collapse() } else { show(.deadlines, recordResult: false) }
        case .pill, .target:
            break
        default:
            collapse()
        }
    }

    func resumeParked() {
        guard let p = parked else { return openInput() }
        parked = nil
        show(p, recordResult: false, preserveCardAnchor: true)
    }

    // MARK: Dropping

    func dragEntered() {
        dropTargeted = true
        switch mode {
        case .pill, .target: show(.target(hot: true))
        default: break
        }
    }

    func dragAnnounced() {
        if case .pill = mode { show(.target(hot: false)) }
    }

    func dragEnded() {
        dropTargeted = false
        if case .target = mode { show(.pill) }
    }

    func dragExited() {
        dropTargeted = false
        if case .target(true) = mode { show(.target(hot: false)) }
    }

    /// Fresh Give starts a topic after prior work; explicit attachments keep the conversation.
    func receive(_ payload: DropPayload, items: [URL], startsFresh: Bool = true) {
        dropTargeted = false
        // Files at the pill: onto the tray, with the one line; this also works while Pippa is working.
        // Text, links and trays into the open conversation as before.
        if case .files = payload, !items.isEmpty, dropsOnTray {
            // Give owns the line even if a Call is still waiting for permission or a selected item.
            // Existing sessions keep their draft; their isActive rule yields to the newly given things.
            if !letter.hasSession { letter.end() }
            if !sheet.hasSession { sheet.end() }
            if case .onboarding = mode { UserDefaults.standard.set(true, forKey: "onboarded") }
            tray.add(items, origin: nil)
            openLine()
            return
        }
        if isActiveWork {
            pendingDrops.append(.init(payload: payload, items: items, startsFresh: startsFresh && !mode.isConversation && mode.key != "resume"))
            return
        }
        attach(payload, items: items, startsFresh: startsFresh && !mode.isConversation && mode.key != "resume", open: true)
    }

    /// Attach things to the conversation (the former body of `receive`). `open`: show the input afterwards.
    func attach(_ payload: DropPayload, items: [URL], startsFresh: Bool, open: Bool) {
        guard !isActiveWork else { return }
        if startsFresh, case .files = payload, let current = conversations.current,
           ConversationContext.startsNewConversation(messages: current.messages) {
            // Start visibly anew, with a way back; the previous conversation stays in the history.
            stashFileWork()
            conversations.newConversation()
            guard conversations.current?.id != current.id else { return }
            query = ""
            _ = conversations.takeAllQueued()
            conversations.append(.system, T("I started a new conversation for this. You’ll find the previous one in the history.", table: "App"),
                                 notice: true, previousConversation: current.id)
        }
        resetFileWork()
        taskLog.dropPending()
        var files = conversations.current?.context?.files ?? []
        switch payload {
        case .text, .link: break     // Text and links are not a file attachment (no "Link.txt" in the file branch).
        case .files: for url in items where !files.contains(url) { files.append(url) }
        }
        let selectedText: String? = switch payload {
        case .text(let text): text
        case .link(let url): url.absoluteString
        case .files: nil
        }
        var name: String
        if files.isEmpty { name = T("Text", table: "App") }
        else if files.count == 1 { name = files[0].lastPathComponent }
        else { name = T("%lld files", table: "App", files.count) }
        if case .link(let url) = payload, files.isEmpty { name = url.host ?? T("Link", table: "App") }
        let effectivePayload: DropPayload = if case .link = payload { payload } else if files.isEmpty { payload } else { .files(files) }
        context = WorkContext(name: name, items: files, payload: effectivePayload)
        conversations.setContext(name: name, files: files, selectedText: selectedText, focusedFiles: items, addingFiles: items)
        if open { openInput() }
    }

    var pendingDropLabel: String {
        let count = pendingDrops.reduce(0) { $0 + max(1, $1.items.count) }
        if count == 1 { return T("1 attachment waiting · coming right up", table: "App") }
        return T("%lld attachments waiting · coming right up", table: "App", count)
    }

    func discardPendingDrops() { pendingDrops = [] }

    private func schedulePendingDrops() {
        // Switch only after the completion handler, so its result is kept.
        Task { @MainActor [weak self] in
            guard let self, !self.isActiveWork else { return }
            guard !self.pendingDrops.isEmpty else { return self.sendQueued() }
            let next = self.pendingDrops.removeFirst()
            self.attach(next.payload, items: next.items, startsFresh: next.startsFresh, open: true)
            if !self.isActiveWork { self.schedulePendingDrops() }
        }
    }

    /// Things queued during work go out after the waiting attachments, one by one;
    /// while the answer to that runs, ConversationController passes the rest on to Pi right away.
    private func sendQueued() {
        guard !isActiveWork, let next = conversations.takeQueued() else { return }
        route(next, queued: true)
    }

    /// "Stop" in the conversation: whatever was still queued comes back into the input field.
    func stopChat() {
        conversations.stop()
        restoreQueued()
    }

    private func restoreQueued(_ extra: [String] = []) {
        let texts = extra + conversations.takeAllQueued()
        guard !texts.isEmpty else { return }
        query = (texts + [query]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }

    private func resetFileWork() {
        taskCard = nil; plan = nil; invoices = []; deadlines = []; lastOverview = nil; parked = nil
        entryDraft = nil; entryDeadline = nil; excluded = []; deadlineSender = nil
    }

    /// Open preview, overview or receipt per conversation: kept when switching (while Pippa is running).
    private struct FileWork {
        var taskCard: ShellMode?, plan: Plan?, excluded: Set<UUID>, invoices: [InvoiceRow]
        var deadlines: [Deadline], lastOverview: Overview?, deadlineSender: String?
    }
    private var savedWork: [UUID: FileWork] = [:]

    private func stashFileWork() {
        guard let id = conversations.current?.id else { return }
        savedWork[id] = FileWork(taskCard: taskCard, plan: plan, excluded: excluded, invoices: invoices,
                                 deadlines: deadlines, lastOverview: lastOverview, deadlineSender: deadlineSender)
    }

    private func restoreFileWork() {
        resetFileWork()
        guard let id = conversations.current?.id, let w = savedWork[id] else { return }
        taskCard = w.taskCard; plan = w.plan; excluded = w.excluded; invoices = w.invoices
        deadlines = w.deadlines; lastOverview = w.lastOverview; deadlineSender = w.deadlineSender
    }

    var taskCardTitle: String {
        switch taskCard {
        case .sortSheet: return T("Sorting Preview", table: "App")
        case .invoiceSheet: return T("Invoice Table", table: "App")
        case .notice: return T("Result & Undo", table: "App")
        case .deadlines, .entryPreview: return T("Dates & Deadlines", table: "App")
        default: return T("Files & Suggestions", table: "App")
        }
    }

    func resumeTaskCard() {
        guard !isActiveWork else { return }
        if let taskCard { show(taskCard, recordResult: false) }
        else if context != nil { runOverview() }
    }

    /// Deliver only the actual preview/result state. Pi must not invent an execution from it.
    var workflowSummary: String {
        var parts: [String] = []
        if let draft = conversations.current?.messages.last(where: { $0.mailDraft != nil })?.mailDraft {
            parts.append(draft.contextSummary)
        }
        if let o = lastOverview {
            parts.append("Übersicht: " + o.title + " · " + o.subtitle)
            parts += o.facts.map { $0.label + ": " + $0.value }
        }
        if taskCard?.key == "sort", let plan {
            parts.append("Sortiervorschau, noch NICHT ausgeführt. Änderungen nur nach Klick auf den Ausführen-Knopf. Ausgewählt: \(plan.ops.filter { !excluded.contains($0.id) }.count).")
            parts += plan.ops.prefix(40).map { op in
                (excluded.contains(op.id) ? "Abgewählt: " : "Geplant: ") + (op.source?.lastPathComponent ?? "Neuer Ordner") + " → " + op.target.path + " · " + op.reason
            }
            if plan.ops.count > 40 { parts.append("Weitere Vorschauzeilen hier nicht enthalten.") }
        }
        if taskCard?.key == "invoice", !invoices.isEmpty { parts.append("Rechnungsvorschau: \(invoices.count) Zeilen; noch kein Export durch diese Vorschau.") }
        if case .notice(let title, let detail, _) = taskCard { parts.append("Bestätigtes Ergebnis: " + title + "\n" + detail) }
        return String(parts.joined(separator: "\n").prefix(12000))
    }

    func chooseFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = T("Look", table: "App")
        panel.message = T("What should Pippa look at?", table: "App")
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, !panel.urls.isEmpty else { return }
                self?.receive(.files(panel.urls), items: panel.urls)
            }
        }
    }

    /// Folder choice when the working place is not unambiguous.
    private func chooseFolder(prompt: String, message: String, start: URL?, then: @escaping @MainActor (URL) -> Void) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = start
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                then(url)
            }
        }
    }

    func runOverview() {
        guard let ctx = context else { return }
        let subtitle: String
        switch ctx.payload {
        case .files(let urls) where ctx.isFolder:
            subtitle = T("I’m taking a quick look in “%@”. Only reading, changing nothing.", table: "App", urls[0].lastPathComponent)
        case .files(let urls) where urls.count == 1:
            subtitle = T("Taking a quick read. Nothing gets changed.", table: "App")
        case .files(let urls):
            subtitle = T("I’m looking at %lld files. Nothing gets changed.", table: "App", urls.count)
        default:
            subtitle = T("Taking a quick read.", table: "App")
        }
        perform(title: T("Taking a quick look…", table: "App"), subtitle: subtitle, retry: { [weak self] in self?.runOverview() }) { engine in
            try await engine.overview(of: ctx.payload)
        } done: { [weak self] overview in
            self?.lastOverview = overview
            self?.show(.overview(overview))
        }
    }

    // MARK: Flows

    /// Runs an engine step with a working indicator. If the shell has been
    /// closed in the meantime, the result waits silently at the pill.
    /// The type parameter is not called `T`, so `T(_:table:)` (translation) stays reachable in the body.
    func perform<Output: Sendable>(title: String, subtitle: String, showsPanel: Bool = true, writes: String? = nil,
                                      retry: (@MainActor () -> Void)?,
                                      _ op: @escaping @Sendable (any PippaEngine) async throws -> Output,
                                      done: @escaping @MainActor (Output) -> Void) {
        // A running write is never cancelled.
        if !taskWrites { task?.cancel() }
        self.retry = retry
        lastWorkTitle = Self.workName(title)
        taskWrites = writes != nil
        busy = true
        if showsPanel { show(.working(title: title, subtitle: subtitle, writes: writes)) }
        let engine = self.engine
        // A superseded step (e.g. the still-growing tidy preview on approve) no longer cleans up.
        taskGeneration += 1
        let generation = taskGeneration
        task = Task { [weak self] in
            do {
                guard let self else { return }
                let value = try await op(engine)
                guard !Task.isCancelled else { return }
                self.busy = false
                self.taskWrites = false
                var collapsed = true
                if case .working = self.mode { collapsed = false }
                self.deferResults = collapsed
                done(value)
                self.deferResults = false
            } catch is CancellationError {
                guard let self, self.taskGeneration == generation else { return }
                self.busy = false
                self.taskWrites = false
                if case .working = self.mode { self.show(.input) }
            } catch {
                guard let self, self.taskGeneration == generation else { return }
                self.busy = false
                self.taskWrites = false
                self.showError(error)
            }
        }
    }

    /// Engine errors are short German sentences and are shown as they are.
    private func showError(_ error: Error) {
        partialReceipt = nil
        UserMessage.record(error, context: "aufgabe")
        if error is InferenceError || error is AnswerFailure {
            show(.message(title: T("Can’t answer right now", table: "App"), body: error.localizedDescription, isError: true))
            return
        }
        if let p = error as? PippaError {
            if case .undoIncomplete(_, _, let notRestored) = p {
                retry = nil
                refreshJobs()
                messageList = notRestored
                messageReveal = context?.folder
                show(.message(title: T("Almost everything is back as it was", table: "App"), body: p.localizedDescription, isError: false))
                return
            }
            if let r = p.receipt { partialReceipt = r; refreshJobs() }
            show(.message(title: T("That didn’t work", table: "App"), body: p.localizedDescription, isError: true))
            return
        }
        show(.message(title: T("That didn’t work", table: "App"), body: T("Nothing was changed.", table: "App"), isError: true))
    }

    /// Whether the running step changes something.
    private(set) var taskWrites = false
    /// Counts `perform` steps; only the newest resets `busy`.
    private var taskGeneration = 0

    /// "Stop": cancel reading steps. Writing always runs to the end (then receipt with undo).
    func stop() {
        if taskWrites || mailDraftOpening { show(.pill); return }
        stopSortFilling()
        task?.cancel()
        busy = false
        restoreQueued()
        show(.pill)
    }

    /// Removing a tray card also revokes its current conversation context. Never delete the source.
    func removeConversationAttachment(_ url: URL) {
        guard !isActiveWork, let saved = conversations.current?.context,
              saved.files.contains(url) else { return }
        let files = saved.files.filter { $0 != url }
        if files.isEmpty && (saved.selectedText?.isEmpty ?? true) {
            conversations.clearContext()
        } else {
            let name = files.isEmpty ? T("Text", table: "App")
                : files.count == 1 ? files[0].lastPathComponent : T("%lld files", table: "App", files.count)
            conversations.setContext(name: name, files: files, selectedText: saved.selectedText,
                                     focusedFiles: saved.focusedFiles?.filter { $0 != url }, announce: false)
        }
        resetFileWork()
        restoreConversationContext()
    }

    /// Removing the text chip must not silently remove documents beside it.
    func removeSelectedTextContext() {
        guard !isActiveWork, let saved = conversations.current?.context, saved.selectedText != nil else { return }
        if saved.files.isEmpty {
            conversations.clearContext()
        } else {
            let name = saved.files.count == 1 ? saved.files[0].lastPathComponent : T("%lld files", table: "App", saved.files.count)
            conversations.setContext(name: name, files: saved.files, selectedText: nil,
                                     focusedFiles: saved.focusedFiles, announce: false)
        }
        resetFileWork()
        restoreConversationContext()
    }

    /// Detach attachment (× on the attachment chip).
    func clearContext() {
        guard !isActiveWork else { return }
        context = nil
        resetFileWork()
        conversations.clearContext()
        show(.input)
    }

    func newConversation() {
        guard !isActiveWork else { return }
        stashFileWork()
        conversations.newConversation()
        resetConversationPresentation()
    }

    /// "Back to the previous conversation": the tray comes along, the one just started disappears if nothing was asked in it yet.
    func continueInPrevious(_ previous: UUID) {
        guard !isActiveWork, let fresh = conversations.current, fresh.id != previous,
              conversations.history.contains(where: { $0.id == previous }) else { return }
        let files = fresh.context?.files ?? []
        let untouched = !fresh.messages.contains { $0.role == .user }
        stashFileWork()
        conversations.select(previous)
        if untouched { conversations.delete(fresh.id); savedWork[fresh.id] = nil }
        resetConversationPresentation()
        if !files.isEmpty { receive(.files(files), items: files, startsFresh: false) }
    }

    func selectConversation(_ id: UUID) {
        guard !isActiveWork else { return }
        stashFileWork()
        conversations.select(id)
        resetConversationPresentation()
    }

    /// Menu bar ("Recent conversations"): delete the open conversation, after confirmation. Files stay untouched.
    func deleteCurrentConversation() {
        guard !isActiveWork, let id = conversations.current?.id else { return }
        NSApp.activate()
        guard confirm(T("Delete this conversation?", table: "App"), T("The messages will be removed from this Mac. Your files stay as they are.", table: "App"),
                      button: T("Delete", table: "App"), destructive: true), !isActiveWork else { return }
        conversations.delete(id)
        savedWork[id] = nil
        resetConversationPresentation()
    }

    private func resetConversationPresentation() {
        query = ""; _ = conversations.takeAllQueued(); restoreFileWork()
        restoreConversationContext()
        show(.input)
        recordConversationActivity()
        composerFocus += 1
    }

    private func restoreConversationContext() {
        guard let saved = conversations.current?.context,
              !saved.files.isEmpty || !(saved.selectedText?.isEmpty ?? true) else { context = nil; return }
        // A dropped link is stored as text; a single http(s) address stays a link.
        let payload: DropPayload = if !saved.files.isEmpty { .files(saved.files) }
            else if let text = saved.selectedText, let url = Self.savedLink(text) { .link(url) }
            else { saved.selectedText.map { .text($0) } ?? .files([]) }
        context = WorkContext(name: saved.name, items: saved.files, payload: payload)
    }

    static func savedLink(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// "I'm reading the invoices …" → "Read invoices" (head of the error message).
    /// Compares with the translated titles from `perform(title:)`, not with word parts of one language.
    static func workName(_ title: String) -> String {
        let map: [(String, String)] = [
            (T("Reading the invoices…", table: "App"), T("Read Invoices", table: "App")),
            (T("Preparing a preview…", table: "App"), T("Prepare Tidying", table: "App")),
            (T("Tidying the files…", table: "App"), T("Tidy Up", table: "App")),
            (T("Looking for deadlines…", table: "App"), T("Find Deadlines", table: "App")),
            (T("Creating the table…", table: "App"), T("Create Table", table: "App")),
            (T("Undoing everything…", table: "App"), T("Undo Changes", table: "App")),
            (T("Reading the mail…", table: "App"), T("Read Mail", table: "App")),
            (T("Adding it to Reminders…", table: "App"), T("Add Entry", table: "App")),
            (T("Adding it to Calendar…", table: "App"), T("Add Entry", table: "App")),
        ]
        for (k, v) in map where title == k { return v }
        return T("Look", table: "App")
    }

    func retryLast() {
        if let r = retry { r() } else { collapse() }
    }

    private func needsModel() -> Bool {
        if canRunModelWork { return false }
        if needsDownloadConsent {
            let detail: String
            if let size = downloadSize {
                detail = T("Invoices work once it has loaded (%@). Tidying, overviews and deadlines work right now.", table: "App", ModelDownloadSize.gigabytes(size.remaining))
            } else {
                detail = T("Invoices work once it has loaded. Tidying, overviews and deadlines work right now.", table: "App")
            }
            show(.notice(title: T("I need my knowledge for this", table: "App"), detail: detail,
                         buttons: [.init(title: T("Load Now", table: "App"), primary: true) { [weak self] in self?.startModelDownload(); self?.collapse() },
                                   .init(title: T("Later", table: "App"), primary: false) { [weak self] in self?.collapse() }]), recordResult: false)
            return true
        }
        let status = unsupportedReason ?? learningText ?? T("Pippa is just waking up.", table: "App")
        let body = status + "\n" + T("Invoices work once my knowledge has loaded. Tidying, overviews and deadlines work right now.", table: "App")
        show(.message(title: T("Not ready yet", table: "App"), body: body, isError: false))
        return true
    }

    func run(_ action: Action) {
        if let o = lastOverview, o.actions.contains(action), action != .ask,
           let kind = TaskKind.guess(for: o.kind, fileExtension: context?.items.first?.pathExtension, count: context?.items.count ?? 1) {
            taskLog.chose(action.rawValue, offered: o.actions.map(\.rawValue), kind: kind, bindsReceipt: true)
        }
        switch action {
        case .sort: startSort()
        case .invoiceTable: startInvoices()
        case .ask: openInput()
        case .deadlines: startDeadlines()
        }
    }

    func startSort() {
        guard let ctx = context, !ctx.items.isEmpty else { return askForContext() }
        guard let folder = ctx.folder else {
            return chooseFolder(prompt: T("Tidy Here", table: "App"), message: T("Your files are in different places. Which folder should I tidy? Anything outside it stays where it is.", table: "App"),
                                start: ctx.commonAncestor) { [weak self] chosen in self?.startSort(in: chosen) }
        }
        startSort(in: folder)
    }

    /// First suggestion on first launch, even while knowledge is still loading: tidy Downloads, with preview first.
    nonisolated static var downloadsSuggestion: String { T("Shall I tidy up your Downloads folder?", table: "App") }

    /// "Tidy Downloads" in Welcome: Downloads becomes the working place, and the tidy preview starts right away
    /// (without an overview before). Nothing changes until approve. `folder` only for developer recordings.
    func tidyDownloads(folder: URL? = nil) {
        guard !isActiveWork, let downloads = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        UserDefaults.standard.set(true, forKey: "onboarded")
        resetFileWork()
        let name = downloads.lastPathComponent
        context = WorkContext(name: name, items: [downloads], payload: .files([downloads]))
        conversations.setContext(name: name, files: [downloads], selectedText: nil)
        startSort(in: downloads)
    }

    private func startSort(in folder: URL) {
        guard let ctx = context else { return askForContext() }
        let items = ctx.isFolder || ctx.items.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) ? nil : ctx.items
        proposeSort(items: items, scope: folder, limit: PreSort.firstRunLimit)
    }

    /// Preview for tidying. It appears as soon as the files have a place without a model (by kind, name, photo data);
    /// read documents and model classifications are added while it is already open.
    /// Also works without a model (first launch, knowledge still loading): whatever only the model could classify stays in place
    /// (`Plan.later`) and is handled once Pippa is awake. No waiting, no guessing.
    func proposeSort(items: [URL]?, scope folder: URL, limit: Int?) {
        resetPlanSheet()
        let round = UUID()
        sortRound = round
        sortFilling = false
        perform(title: T("Preparing a preview…", table: "App"), subtitle: T("Nothing is changed yet.", table: "App"),
                retry: { [weak self] in self?.proposeSort(items: items, scope: folder, limit: limit) }) { [weak self] engine in
            try await engine.proposeSort(items: items, scope: folder, limit: limit) { plan in
                Task { @MainActor in self?.sortGrew(plan, round: round) }
            }
        } done: { [weak self] plan in
            guard let self, self.sortRound == round else { return }
            self.sortFilling = false
            self.plan = plan
            if plan.ops.isEmpty, plan.skipped.isEmpty, plan.later.isEmpty, plan.remaining.isEmpty {
                self.sortRound = nil
                self.plan = nil
                let body = T("I didn’t find any loose files in “%@”. Did your Mac ask for permission and you declined? Then you can allow it in System Settings under “Privacy & Security” → “Files & Folders”.", table: "App", plan.scope.lastPathComponent)
                return self.show(.message(title: T("Nothing to tidy here", table: "App"),
                                          body: body,
                                          isError: false))
            }
            // Nothing that could be moved without a model, only documents for later: no empty preview, but a sentence.
            if !plan.later.isEmpty, !plan.ops.contains(where: { $0.kind != .mkdir && $0.certainty != .unreadable }) {
                self.sortRound = nil
                self.rememberSortLater(plan.later, scope: plan.scope)
                self.plan = nil
                return self.showLaterOnly(plan.later.count)
            }
            if case .sortSheet = self.mode {} else { self.show(.sortSheet) }
            let n = plan.ops.filter { $0.kind != .mkdir }.count
            let line = n == 1
                ? T("Sorting preview: 1 file, nothing changed yet", table: "App")
                : T("Sorting preview: %lld files, nothing changed yet", table: "App", n)
            self.conversations.append(.system, line)
        }
    }

    /// How Pippa says "later": without consent to load "once my knowledge is loaded", otherwise "awake".
    /// If no model fits this Mac, it only works with an own connection.
    var laterPhrase: String {
        if unsupportedReason != nil { return T("once online help is connected (Settings → Advanced)", table: "App") }
        if needsDownloadConsent { return T("once my knowledge has loaded", table: "App") }
        return T("once I’m fully awake", table: "App")
    }

    static func laterCount(_ n: Int) -> String {
        if n == 1 { return T("1 document", table: "App") }
        return T("%lld documents", table: "App", n)
    }

    private func rememberSortLater(_ files: [URL], scope: URL) {
        guard !files.isEmpty else { return }
        var all = sortLater.flatMap { $0.scope.standardizedFileURL == scope.standardizedFileURL ? $0.files : nil } ?? []
        for f in files where !all.contains(f) { all.append(f) }
        sortLater = (all, scope)
        sortLaterOffered = false
    }

    private func showLaterOnly(_ count: Int) {
        var buttons: [ToastButton] = []
        if needsDownloadConsent {
            buttons.append(.init(title: T("Load Now", table: "App"), primary: true) { [weak self] in self?.startModelDownload(); self?.collapse() })
        }
        buttons.append(.init(title: T("OK", table: "App"), primary: buttons.isEmpty) { [weak self] in self?.collapse() })
        let detail = count == 1
            ? T("Without my knowledge I can’t place it reliably. I won’t guess: it stays where it is, and I’ll ask you again then.", table: "App")
            : T("Without my knowledge I can’t place them reliably. I won’t guess: they stay where they are, and I’ll ask you again then.", table: "App")
        show(.notice(title: T("I’ll sort %@ more carefully %@", table: "App", Self.laterCount(count), laterPhrase),
                     detail: detail,
                     buttons: buttons))
    }

    /// Pippa is awake: offer leftover documents once (only what is still there). Not in the middle of
    /// work or an open preview: then again at the next look (every second).
    private func offerSortLater() {
        guard let later = sortLater, !sortLaterOffered, canRunModelWork, !isActiveWork,
              ["pill", "input"].contains(mode.key) else { return }
        sortLaterOffered = true
        let files = later.files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { sortLater = nil; return }
        toasts?.show(title: T("I’m fully awake now", table: "App"),
                     detail: T("I can now sort %1$@ from “%2$@” more carefully. You’ll see everything first.", table: "App", Self.laterCount(files.count), later.scope.lastPathComponent),
                     buttons: [.init(title: T("Tidy Now", table: "App"), primary: true) { [weak self] in self?.sortLaterNow() },
                               .init(title: T("Later", table: "App"), primary: false) {}])
    }

    /// "Tidy now": the leftover documents in a new preview.
    func sortLaterNow() {
        guard let later = sortLater else { return }
        guard !isActiveWork else {
            toasts?.show(title: T("I’m still working", table: "App"), detail: T("Click again once I’m done.", table: "App"), buttons: [], log: false)
            return
        }
        sortLater = nil
        proposeSort(items: later.files.filter { FileManager.default.fileExists(atPath: $0.path) }, scope: later.scope, limit: nil)
    }

    /// An interim state of the preview: show the preview at the first, then only refresh.
    private func sortGrew(_ plan: Plan, round: UUID) {
        guard sortRound == round, busy, !taskWrites else { return }
        self.plan = plan
        sortFilling = !plan.pending.isEmpty
        if case .working = mode { show(.sortSheet) }
    }

    /// Back or Stop in the still-growing preview: reading and classifying end, nothing was changed.
    /// What was not yet classified counts among the remaining files for later.
    private func stopSortFilling() {
        guard sortFilling else { return }
        sortRound = nil
        sortFilling = false
        if let pending = plan?.pending { plan?.remaining.insert(contentsOf: pending, at: 0); plan?.pending = [] }
        task?.cancel()
        busy = false
    }

    /// Only the visible, valid preview can be approved from the keyboard.
    var canConfirmPreview: Bool {
        // While the tidy preview is still growing, what is already there can be approved.
        let sortStillReading = if case .sortSheet = mode { sortFilling && !taskWrites } else { false }
        guard !isActiveWork || sortStillReading else { return false }
        switch mode {
        case .sortSheet:
            return plan?.ops.contains { $0.kind != .mkdir && $0.certainty != .unreadable && !excluded.contains($0.id) } == true
        case .invoiceSheet: return !invoices.isEmpty
        case .entryPreview: return entryDraft?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        default: return false
        }
    }

    func confirmPreview() {
        guard canConfirmPreview else { return }
        switch mode {
        case .sortSheet: applySort()
        case .invoiceSheet: exportInvoices()
        case .entryPreview: applyEntry()
        default: break
        }
    }

    /// Runs the preview as it currently stands. What was still being read or was not part of this round stays in place
    /// and can then be classified via "Tidy more …".
    func applySort() {
        guard let plan else { return }
        let excluded = self.excluded
        // Leftover documents: if Pippa is awake by now, offer them right away, otherwise remember.
        let wakeful = canRunModelWork
        let more = plan.pending + plan.remaining + (wakeful ? plan.later : [])
        if !wakeful { rememberSortLater(plan.later, scope: plan.scope) }
        let laterCount = wakeful ? 0 : plan.later.count
        // The still-running preview ends here; `perform` cancels it, its interim states no longer count.
        sortRound = nil
        sortFilling = false
        perform(title: T("Tidying the files…", table: "App"), subtitle: "", writes: T("I’m only moving things, nothing gets deleted", table: "App"),
                retry: { [weak self] in self?.applySort() }) { engine in
            try await engine.apply(plan, excluding: excluded)
        } done: { [weak self] receipt in
            guard let self else { return }
            self.plan = nil
            self.finish(receipt)
            self.showReceipt(receipt, more: more, scope: plan.scope, later: laterCount)
        }
    }

    func startInvoices() {
        guard let ctx = context, !ctx.items.isEmpty else { return askForContext() }
        if needsModel() { return }
        let items = ctx.items
        perform(title: T("Reading the invoices…", table: "App"), subtitle: T("Date, sender and amount. Nothing gets changed.", table: "App"),
                retry: { [weak self] in self?.startInvoices() }) { engine in
            try await engine.extractInvoices(in: items)
        } done: { [weak self] rows in
            guard let self else { return }
            if rows.isEmpty {
                self.show(.message(title: T("No invoices found", table: "App"), body: T("I didn’t recognize an invoice in these files.", table: "App"), isError: false))
            } else {
                self.invoices = rows
                self.show(.invoiceSheet)
            }
        }
    }

    func exportInvoices() {
        guard let ctx = context else { return }
        guard let folder = ctx.folder else {
            return chooseFolder(prompt: T("Create Here", table: "App"), message: T("Your invoices are in different places. Where should the table go?", table: "App"),
                                start: ctx.commonAncestor) { [weak self] chosen in self?.exportInvoices(to: chosen) }
        }
        exportInvoices(to: folder)
    }

    private func exportInvoices(to folder: URL) {
        let rows = invoices, format = exportFormat
        perform(title: T("Creating the table…", table: "App"), subtitle: "", writes: T("I’m creating a new file", table: "App"),
                retry: { [weak self] in self?.exportInvoices(to: folder) }) { engine in
            try await engine.exportInvoices(rows, format: format, to: folder)
        } done: { [weak self] receipt in
            guard let self else { return }
            self.finish(receipt)
            self.showResultToast(receipt, open: T("Open", table: "App"), openFirst: true) { if let u = receipt.revealURL { NSWorkspace.shared.open(u) } }
        }
    }

    /// Receipt with "Undo" and a button that shows the result (file, calendar, notes).
    /// `openFirst`: for a new file, viewing is the obvious step, otherwise undo.
    func showResultToast(_ receipt: JobReceipt, open title: String, openFirst: Bool = false, _ open: @escaping @MainActor () -> Void) {
        let undo = ToastButton(title: T("Undo", table: "App"), primary: !openFirst) { [weak self] in self?.undo(receipt) }
        let show = ToastButton(title: title, primary: openFirst, action: open)
        toasts?.show(title: receipt.summary, detail: receipt.detail, buttons: openFirst ? [show, undo] : [undo, show], receipt: receipt.id)
    }

    /// Undo from a list of older jobs (menu bar, Settings): ask briefly first,
    /// because there the job is not right in front of you.
    func confirmUndo(_ receipt: JobReceipt) {
        guard receipt.canUndo else { return }
        NSApp.activate()
        let text = receipt.integration == nil
            ? T("The files go back to where they were. Nothing is deleted.", table: "App")
            : T("The entry will be removed again.", table: "App")
        guard confirm(T("Undo “%@”?", table: "App", receipt.summary), text,
                      button: T("Undo Changes", table: "App")) else { return }
        undo(receipt)
    }

    func undo(_ receipt: JobReceipt) {
        guard receipt.canUndo else { return }
        // While working, do not silently undo in between (menu bar, message, history).
        guard !isActiveWork else {
            toasts?.show(title: T("I’m still working", table: "App"), detail: T("Undo works once I’m done. Then click again.", table: "App"), buttons: [], log: false)
            return
        }
        toasts?.dismiss()
        perform(title: T("Undoing everything…", table: "App"), subtitle: "", writes: T("Everything goes back to where it was", table: "App"), retry: { [weak self] in self?.undo(receipt) }) { engine in
            try await engine.undo(receipt)
        } done: { [weak self] _ in
            guard let self else { return }
            self.taskLog.undone(receipt.id)
            self.lastJob = T("Undone", table: "App")
            self.lastReceipt = nil
            self.refreshJobs()
            self.toasts?.show(title: T("Everything is back as it was", table: "App"), detail: receipt.undoDetail ?? T("The files are back where they were.", table: "App"), buttons: [])
        }
    }

    func finish(_ receipt: JobReceipt) {
        taskLog.finished(receipt.id)
        lastJob = receipt.summary
        lastReceipt = receipt
        refreshJobs()
    }

    /// Receipt after tidying: "In 4 folders · 1 stays", "Show" opens the list (or Finder).
    /// `more`: files not yet handled in this round; "Tidy more …" makes a new preview with them.
    /// `later`: documents that stay in place until awake (one sentence in the message).
    private func showReceipt(_ receipt: JobReceipt, more: [URL] = [], scope: URL? = nil, later: Int = 0) {
        var buttons: [ToastButton] = [
            .init(title: T("Undo", table: "App"), primary: true) { [weak self] in self?.undo(receipt) },
            .init(title: T("Show", table: "App"), primary: false) { [weak self] in
                if receipt.stayed.isEmpty { Self.reveal(receipt.revealURL) } else { self?.showStayed(receipt.stayed, reveal: receipt.revealURL) }
            },
        ]
        if let scope, !more.isEmpty {
            let moreTitle = more.count == 1
                ? T("Tidy 1 More File", table: "App")
                : T("Tidy %lld More", table: "App", more.count)
            buttons.append(.init(title: moreTitle, primary: false) { [weak self] in
                self?.proposeSort(items: more, scope: scope, limit: nil)
            })
        }
        var detail = receipt.detail
        if later > 0 {
            let note = later == 1
                ? T("I’ll sort %@ more carefully %@. Until then it stays put.", table: "App", Self.laterCount(later), laterPhrase)
                : T("I’ll sort %@ more carefully %@. Until then they stay put.", table: "App", Self.laterCount(later), laterPhrase)
            detail += (detail.isEmpty ? "" : "\n") + note
        }
        toasts?.show(title: receipt.summary, detail: detail, buttons: buttons, receipt: receipt.id)
    }

    // MARK: Left in place, history

    /// List under a calm message (what was left, with reason).
    @Published private(set) var messageList: [FileReason] = []
    private(set) var messageReveal: URL?

    func showStayed(_ items: [FileReason], reveal: URL?) {
        messageList = items
        messageReveal = reveal
        let n = items.count
        let title = n == 1
            ? T("1 file stays put", table: "App")
            : T("%lld files stay put", table: "App", n)
        show(.message(title: title,
                      body: T("I didn’t touch these:", table: "App"), isError: false))
    }

    func revealMessageFolder() { Self.reveal(messageReveal) }

    /// Recent jobs (Settings, menu bar), each with undo.
    @Published private(set) var recentJobs: [JobReceipt] = []

    func refreshJobs() {
        let engine = self.engine
        Task { [weak self] in
            // Enough so that "Undo" stays reachable on older receipts in the conversation.
            let jobs = await engine.recentJobs(limit: 30)
            self?.recentJobs = jobs
        }
    }

    /// On an error after something was already changed: the part that can be undone.
    @Published private(set) var partialReceipt: JobReceipt?

    func askForContext() {
        show(.message(title: T("What’s this about?", table: "App"), body: T("First drag something onto me or choose a folder.", table: "App"), isError: false))
    }

    static func reveal(_ url: URL?) {
        guard let url else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    /// Source chip of a deadline: opens the place.
    func openDeadlineSource(_ d: Deadline) {
        openSource(Answer(text: d.title, source: d.source ?? context?.items.first, location: d.location, quote: d.quote, found: true))
    }

    /// Target of a deadline (reminder or calendar), remembered.
    var preferredEntryTarget: CalendarEntry.Target {
        get { CalendarEntry.Target(rawValue: UserDefaults.standard.string(forKey: "entry.target") ?? "") ?? .reminder }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "entry.target") }
    }

    /// Segment Reminder | Calendar in the preview.
    func switchEntryTarget(_ target: CalendarEntry.Target) {
        preferredEntryTarget = target
        entryDraft?.target = target
    }

    func openSource(_ answer: Answer) {
        guard let url = answer.source else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            toasts?.show(title: T("The file is no longer there", table: "App"), detail: url.lastPathComponent, buttons: [], log: false)
            return
        }
        if url.pathExtension.lowercased() == "pdf" {
            PDFViewerWindow.open(url: url, location: answer.location, quote: answer.quote)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Input

    /// Jobs in the overview, with approval depending on model state.
    func overviewActions(_ o: Overview) -> [(action: Action, enabled: Bool)] {
        // Tidy works without a model (unclear items stay); only invoices need the knowledge.
        o.actions.map { a in (a, a == .invoiceTable ? canRunModelWork : true) }
    }

    /// Deselection, reasons and expanded groups apply to one preview only.
    private func resetPlanSheet() {
        excluded = []; showReasons = false; openGroups = []; fullGroups = []
    }

    /// Free text belongs to the Pi conversation. Fixed file actions are chosen explicitly via cards.
    /// While Pippa works, the message is queued instead of swallowed (`queued`: it comes from there).
    /// `skill`: explicitly chosen skill (button in the conversation, `runSkill`).
    func route(_ text: String, queued: Bool = false, skill: PippaSkill? = nil) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        recordConversationActivity()
        if isActiveWork {
            // Buttons are off during work; a skill is not queued as ordinary text.
            if skill != nil { return }
            conversations.enqueue(q)
            if query.trimmingCharacters(in: .whitespacesAndNewlines) == q { query = "" }
            return
        }
        // An open preview or overview stays; the answer comes below it.
        if !mode.staysWhileChatting { show(.input) }
        // Questions about the person's own appointments are answered by code from the calendar, without model and without attachment.
        if skill == nil, let intent = calendarIntent(for: q) {
            if query.trimmingCharacters(in: .whitespacesAndNewlines) == q { query = "" }
            answerCalendar(q, range: intent.range)
            composerFocus += 1
            return
        }
        // "Tidy my Downloads" and similar via a folder: Pippa's native flow (preview, one run,
        // one undo), not Pi. Recognized in code (TidyIntent); questions and single files stay with Pi.
        if skill == nil, let tidy = tidyIntent(for: q) {
            if query.trimmingCharacters(in: .whitespacesAndNewlines) == q { query = "" }
            answerTidy(q, intent: tidy)
            composerFocus += 1
            return
        }
        // Free text and skills go to the real Pi (PiRPCChat); model choice and approvals are handled by the Pi path itself.
        if piSetupHolds(queued: queued ? q : nil) { return }
        if query.trimmingCharacters(in: .whitespacesAndNewlines) == q { query = "" }
        // What is shown (files, folder, mail, table, text) and Pippa's working state go along (PiRPCChat+Shown.swift).
        conversations.send(q, workflowSummary: workflowSummary, modelLabel: piModelLabel, skill: skill)
        composerFocus += 1
    }

    /// If setup is not finished, Pi does not start. Instead of a technical error, a calm sentence in the
    /// conversation; for the download question or an error, the setup itself ("Load" or "Try again").
    /// The message stays in the field. `true`: held back.
    private func piSetupHolds(queued: String?) -> Bool {
        guard let line = piSetupBlockedReason else { return false }
        if conversations.current?.messages.last?.text != line { conversations.append(.system, line, notice: true) }
        if let queued { restoreQueued([queued]) }
        if case .showSetup = piSetupGate { show(.onboarding) }
        return true
    }

    var piSetupGate: PiConversationDefault.SetupGate {
        guard PiRPCChat.isLive else { return .open }
        return PiConversationDefault.gate(PiSetupController.shared?.state, online: PiRPCChat.onlineConnection != nil,
                                          devModel: DevEnvironment.value("PIPPA_MODEL_FILE") != nil || DevEnvironment.value("PIPPA_PI_OWN_LLAMA") == "0")
    }

    /// The sentence while setup does not yet allow a conversation (Pi path); `nil`: it works.
    var piSetupBlockedReason: String? {
        switch piSetupGate {
        case .open: nil
        case .wait: T("I’m still getting my AI ready. Ask me again in a moment.", table: "App")
        case .showSetup(let problem): problem ?? T("I still need to load my AI before I can answer.", table: "App")
        }
    }

    /// Where the answer is produced, in the wording of Settings: the own online service or this Mac.
    var piModelLabel: String {
        guard let connection = PiRPCChat.onlineConnection else { return Self.localStatus }
        if connection.isLocal { return T("On this Mac · Connected service", table: "App") }
        let name = connection.provider == .compatible ? T("Connected service", table: "App") : connection.provider.displayName
        return T("Online · %@", table: "App", name)
    }

    /// What Pippa can do (buttons on the letter, on text, in the empty conversation): Pi gets the instructions from the app bundle.
    /// The result is text in the conversation; Pippa writes no file and sends nothing.
    /// `offered` and `place`: the buttons beside it and their position, for the task log.
    func runSkill(_ skill: PippaSkill, offered: [PippaSkill] = [], place: PippaSkill.Place? = nil) {
        guard !isActiveWork else { return }
        if let kind = place.flatMap(TaskKind.init(place:)) {
            taskLog.chose(skill.name, offered: (offered.isEmpty ? [skill] : offered).map(\.name), kind: kind)
        }
        route(skill.prompt, skill: skill)
    }

    /// Question with Confirm and Cancel; true if confirmed.
    private func confirm(_ title: String, _ text: String, button: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button).hasDestructiveAction = destructive
        alert.addButton(withTitle: T("Cancel", table: "App"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
