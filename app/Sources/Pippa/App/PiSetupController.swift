import Combine
import PippaCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Setup in the Welcome: no technical questions.
/// Like PiRPCChat, in every build.
///
/// Quiet: Pi, Node, model folder, adopting existing models, models.json (`PiSetupFlow`, off the
/// main thread). The only question is the download: "Set Up Pippa's AI · N GB" or "Later", with the free space
/// checked before the click (`checkSpace`). The consent is kept (`PippaSettings.downloadConsent`): an interrupted
/// download goes on by itself at the next start, and "Stop Loading" pauses it and asks again. Then a calm progress
/// with examples, and at the end one ready step: the shortcut, "Open at login" and "Get Started" into the conversation.
/// Errors: one sentence, "Try again", technical detail behind "Details".
///
/// Environment like PiRPCChat: `PIPPA_PI_PAYLOAD` (otherwise the payload in the app), `PIPPA_PI_HOME` (fake HOME for
/// test runs), `PIPPA_PI_MODEL` (otherwise by memory like LocalEngine).
///
/// New knowledge while the old one keeps working (`update`): after an app update whose table names a different model
/// (e.g. the move from K2 Horizon 7B to Qwen3.5 9B), or after "Gründlicher" in settings, setup stays `.ready` with the previous model and
/// offers the download ("Pippas Wissen jetzt laden (5,7 GB)"). After loading, models.json names the new model; Pi and the
/// llama-server follow on the next request. The previous model's file stays on disk; a superseded one (`SupersededModels`)
/// is deleted after the new model has answered once.
@MainActor
final class PiSetupController: ObservableObject {
    /// Loading new knowledge beside a working one.
    enum KnowledgeUpdate: Equatable {
        case offer(bytes: Int64)
        case downloading(progress: Double, remaining: TimeInterval?)
        case failed(String)
    }

    /// Recordings (`PIPPA_SNAPSHOT_ONLY=setup-*`) inject a state here without the installer.
    static var shared: PiSetupController? = makeLive()

    @Published private(set) var state: PiSetupState
    @Published var showsDetails = false
    /// Which example is currently showing (here rather than in the view, so measurement and display passes match).
    @Published var exampleIndex = 0

    private var flow: PiSetupFlow?
    /// Installer roots of the live setup (for switching knowledge); `nil` in recordings without an installer.
    private var roots: PiInstallRoots?
    @Published private(set) var update: KnowledgeUpdate?
    /// "Standard" or "Gründlicher" (settings.json); the control shows only where `offersThorough` holds.
    @Published private(set) var preference: ModelPreference = .standard
    let offersThorough = ModelSelector.offersThorough(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    /// "Picked for your Mac · Apple M2 · 16 GB memory" on the download question.
    let hardware = MacHardware.summary()
    /// Free space checked before "Set Up" (`checkSpace`); `nil` = enough or unknown. Recordings set it directly.
    @Published var spaceShortfall: Int64?
    /// Ready step: "Open at login" only where a login item makes sense (Applications), as in Settings (SMAppService).
    let canOpenAtLogin = AppLocation.place(of: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser) == .applications
    @Published private(set) var opensAtLogin = false
    @Published private(set) var loginProblem: String?
    /// Setup finished while the Welcome was closed: the ready step comes once, at the next click on the pill.
    private var readyStepPending = false
    private var updateTask: Task<Void, Never>?
    private var updateID: UUID?
    /// After a switch in settings: load right away (choosing counts as consent), and on "Cancel" go back to this.
    private var loadsUpdate = false
    private var switchedFrom: ModelPreference?
    private weak var model: AppModel?
    private var task: Task<Void, Never>?
    private var forward: AnyCancellable?
    /// "Set Up" was already said: do not ask again after "Try again".
    private var downloadChosen = false
    /// Consent kept from an earlier run (`PippaSettings.downloadConsent`): the question is skipped, the download goes on.
    private var resumesDownload = false
    private var lastProgressAt = Date.distantPast
    /// No new bytes for 30 s, or no network, while loading. The downloader keeps retrying by itself; the views say so
    /// in one calm sentence with "Try Again" instead of a progress bar that silently stands still.
    @Published private(set) var stalled = false
    private var stallWatch = DownloadStallWatch(limit: 30)
    private var stallTask: Task<Void, Never>?
    /// Latest progress as reported (before the display throttle), so slow but moving downloads never count as stuck.
    private var rawProgress = 0.0
    /// The running "Set Up": a restart ("Try Again") ignores the result of the attempt it replaced.
    private var loadID: UUID?
    /// The first setup result after app start may bring back "What Pippa may do" (`PermissionOnboarding.remindsAtStart`).
    private var remindsPermissions = false

    init(flow: PiSetupFlow?, state: PiSetupState = .preparing(adoptingFrom: nil)) {
        self.flow = flow
        self.state = state
    }

    static func makeLive() -> PiSetupController? {
        guard PiRPCChat.isLive else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let payload = PiPayload.locate(environment: env) else {
            return PiSetupController(flow: nil, state: .failed(PiSetupProblem(.payloadMissing(env["PIPPA_PI_PAYLOAD"] ?? "Contents/Resources/pi-payload"))))
        }
        let roots: PiInstallRoots
        if let home = env["PIPPA_PI_HOME"] {
            let url = URL(fileURLWithPath: home, isDirectory: true)
            roots = PiInstallRoots(home: url, payload: payload, searchPath: [url.appendingPathComponent(".local/bin")])
        } else {
            roots = PiInstallRoots(support: Pippa.supportDirectory, payload: payload)
        }
        // Explicit local configuration takes precedence over the memory table; the environment can override it.
        let saved = PippaSettings.load(from: roots.support)
        let preference = ModelSelector.offersThorough(physicalMemory: ProcessInfo.processInfo.physicalMemory) ? saved.preference : .standard
        guard let choice = PiSetupFlow.choice(override: env["PIPPA_PI_MODEL"] ?? saved.localModelKey, preference: preference) else {
            // Also an unpinned table model (scripts/pin-model.sh): loud on purpose, a release must never get here.
            let unpinned = ModelSelector.tableKeys.filter { ModelCatalog.bundled().model($0)?.pinned == nil }
            return PiSetupController(flow: nil, state: .failed(PiSetupProblem(message: T("Pippa needs a Mac with Apple silicon (M1 or later).", table: "Settings"),
                                                                              details: unpinned.isEmpty ? "No catalog model fits this Mac" : "Not pinned in catalog.json: \(unpinned.joined(separator: ", "))",
                                                                              canRetry: false)))
        }
        let setup = PiSetupController(flow: PiSetupFlow(roots: roots, model: choice.model, contextWindow: choice.ctx))
        setup.roots = roots
        setup.preference = preference
        setup.resumesDownload = saved.downloadConsent == choice.model.key
        return setup
    }

    var isReady: Bool { if case .ready = state { true } else { false } }
    var asksDownload: Bool { if case .askDownload = state { true } else { false } }

    /// At app start: pass changes on to the shell (size), then set up quietly.
    func attach(to model: AppModel) {
        self.model = model
        remindsPermissions = true
        forward = objectWillChange.sink { [weak model] _ in
            model?.objectWillChange.send()
            // After the change has landed: the mark follows the download (AppModel.markState).
            Task { @MainActor [weak model] in model?.updateMark() }
        }
        // The network is watched from now on, so a hotspot is already known when setup decides to resume (finish).
        _ = NetworkWatch.shared
        begin()
    }

    /// Everything without network; stops only at the download question or an error.
    /// `previous`: a stopped download that must have let go of the part file first (`stopDownload`).
    func begin(after previous: Task<Void, Never>? = nil) {
        guard let flow, task == nil else { return }
        showsDetails = false
        state = .preparing(adoptingFrom: nil)
        task = Task { [weak self] in
            await previous?.value
            let source = await Task.detached(priority: .userInitiated) { flow.adoptionSource() }.value
            if let source { self?.state = .preparing(adoptingFrom: source) }
            let result = await Task.detached(priority: .userInitiated) { flow.prepare() }.value
            self?.finish(result)
        }
    }

    /// "Set Up": the only consent. Downloads resumably, then the rest of setup.
    /// `previous`: a cancelled attempt that must have let go of the part file before this one opens it.
    func load(after previous: Task<Void, Never>? = nil) {
        guard let flow, task == nil else { return }
        downloadChosen = true
        spaceShortfall = nil
        // Kept across restarts: an interrupted download goes on by itself at the next start (`resumesDownload`).
        if let roots { try? PippaSettings.saveDownloadConsent(flow.model.key, to: roots.support) }
        showsDetails = false
        state = .downloading(progress: 0, remaining: nil)
        let id = UUID()
        loadID = id
        watchStall()
        task = Task { [weak self] in
            await previous?.value
            let result = await flow.download { progress, remaining in
                Task { @MainActor in self?.progress(progress, remaining) }
            }
            guard let self, self.loadID == id else { return }
            self.loadID = nil
            self.finish(result)
        }
    }

    /// "Später" was chosen: opening Pippa leads to the conversation from now on (until the next start). Clicking away
    /// is no answer, the question comes back.
    private(set) var deferred = false

    /// "Später" and "Ausblenden": back to the pill. A running download continues.
    /// "Später" to the download while "What Pippa may do" is still to come: that page first, the AI waits.
    func later() {
        if asksDownload {
            deferred = true
            if model?.permissions.onboardingPending == true {
                objectWillChange.send()
                return
            }
        }
        model?.collapse()
    }

    /// "Try again": from scratch (idempotent); if "Set Up" was already said, continues without a question.
    func retry() { begin() }

    /// "Try Again" while a download hangs: stop the attempt and start a fresh one right away. It continues where the
    /// previous one stopped (the part file stays). The fresh attempt waits until the old one has really stopped: two
    /// downloaders appending to the same part file would corrupt it, and the checksum would then throw away everything
    /// loaded so far.
    func retryDownload() {
        if case .downloading = state {
            let previous = task
            previous?.cancel()
            task = nil
            loadID = nil
            load(after: previous)
        } else if case .downloading? = update {
            let previous = updateTask
            stopUpdate()
            loadUpdate(after: previous)
        }
    }

    /// "Stop Loading": pauses the download (what came stays for later), forgets the kept consent and asks again.
    /// Not while every byte is in and being checked.
    func stopDownload() {
        guard case .downloading(let progress, _) = state, !DownloadProgress.isFinishing(progress) else { return }
        let previous = task
        previous?.cancel()
        task = nil
        loadID = nil
        downloadChosen = false
        resumesDownload = false
        stallTask?.cancel()
        if stalled { stalled = false; model?.downloadStallChanged() }
        if let roots { try? PippaSettings.saveDownloadConsent(nil, to: roots.support) }
        begin(after: previous)
    }

    private func watchStall() {
        stallTask?.cancel()
        stallWatch = DownloadStallWatch(limit: 30)
        rawProgress = 0
        stalled = false
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let loading: Bool
                if case .downloading = self.state { loading = true }
                else if case .downloading? = self.update { loading = true }
                else { loading = false }
                guard loading else {
                    if self.stalled { self.stalled = false }
                    return
                }
                let now = self.stallWatch.update(progress: self.rawProgress) || !NetworkWatch.shared.online
                if now != self.stalled {
                    self.stalled = now
                    self.model?.downloadStallChanged()
                    if now { self.model?.downloadStalledNotice() }
                }
            }
        }
    }

    func refreshLogin() {
        let on = SMAppService.mainApp.status == .enabled
        if opensAtLogin != on { opensAtLogin = on }
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = nil
        } catch {
            UserMessage.record(error, context: "autostart")
            loginProblem = T("That didn’t work just now. Is Pippa in your Applications folder?", table: "Settings")
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The pill was clicked: `true` once after setup finished in the background.
    func takeReadyStep() -> Bool {
        guard readyStepPending, isReady else { return false }
        readyStepPending = false
        return true
    }

    /// A useful first result needs neither a download nor Apple Intelligence. The open panel grants access only
    /// to the files the person chooses; cancelling it leaves setup exactly where it was.
    func chooseNativeFiles() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf]
        panel.prompt = T("Choose", table: "NativeFlow")
        panel.message = T("Choose photos or PDFs. I’ll offer actions that work right away on this Mac.", table: "NativeFlow")
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.useNativeFiles(panel.urls)
            }
        }
    }

    /// Shared by the chooser and synthetic first-use checks; it never grants download consent.
    func useNativeFiles(_ urls: [URL]) {
        guard !urls.isEmpty, let model else { return }
        if asksDownload { deferred = true; objectWillChange.send() }
        model.receive(.files(urls), items: urls)
    }

    func showExample(_ index: Int) {
        let count = SetupExample.all.count
        exampleIndex = ((index % count) + count) % count
    }

    /// Before the click: a download that cannot fit never starts. Again on "Try Again" under the disabled button.
    func checkSpace() {
        guard let flow, case .askDownload(let bytes) = state else { return }
        Task { [weak self] in
            let shortfall = await Task.detached(priority: .userInitiated) { flow.spaceShortfall(remaining: bytes) }.value
            guard let self, case .askDownload = self.state, self.spaceShortfall != shortfall else { return }
            self.spaceShortfall = shortfall
        }
    }

    private func progress(_ value: Double, _ remaining: TimeInterval?) {
        guard case .downloading(let shown, _) = state else { return }
        rawProgress = value
        // Calm: at most twice per second, and only on a visible change.
        guard value >= 1 || (abs(value - shown) >= 0.002 && Date().timeIntervalSince(lastProgressAt) >= 0.5) else { return }
        lastProgressAt = Date()
        state = .downloading(progress: value, remaining: remaining)
    }

    private func finish(_ result: PiSetupState) {
        let previous = state
        task = nil
        stallTask?.cancel()
        if stalled { stalled = false; model?.downloadStallChanged() }
        let wantsUpdate = loadsUpdate
        loadsUpdate = false
        if case .askDownload = result, downloadChosen { return load() }
        // Consent from an earlier run: an interrupted download goes on by itself, never over a phone hotspot, and
        // nothing opens by itself when it is done (the permissions reminder waits for the next start).
        if case .askDownload = result, resumesDownload, !NetworkWatch.shared.expensive {
            remindsPermissions = false
            return load()
        }
        state = result
        if case .askDownload = result { checkSpace() }
        if case .ready = result {
            DiagnosticsLog.shared.event("pi-setup", ["stand": "bereit", "modell": flow?.activeModelKey ?? ""])
            PiRPCChat.refreshLaunchFile()
            if updateTask == nil { update = flow?.pendingDownload.map { .offer(bytes: $0) } }
            if flow?.pendingDownload == nil {
                switchedFrom = nil
                // In use now: a kept consent must never reload it by itself should its file go away later.
                if downloadChosen || resumesDownload, let roots {
                    try? PippaSettings.saveDownloadConsent(nil, to: roots.support)
                    resumesDownload = false
                }
            }
            if wantsUpdate { loadUpdate() }
            if PiSetupState.justSetUp(from: previous, to: result) {
                // Loaded or adopted just now: into memory already, so the first question does not wait (PiRPCChat+ColdStart).
                PiRPCChat.shared.preloadIfCold()
                // Setup finished while the Welcome was closed: the ready step comes once, at the next click on the pill.
                readyStepPending = model?.mode.key != "onboarding"
            }
        } else if case .failed(let problem) = result {
            DiagnosticsLog.shared.event("pi-setup", ["stand": "fehler", "details": problem.details])
        }
        let remind = remindsPermissions
        remindsPermissions = false
        guard let model, DevSnapshot.directory == nil, model.mode.key == "pill", !model.isActiveWork else { return }
        // Ready, but "What Pippa may do" was closed or never seen: the Welcome brings it back (at most twice).
        if isReady {
            if remind, model.permissions.remindsAtStart { readyStepPending = false; model.show(.onboarding) }
            return
        }
        // Not done yet (e.g. earlier "Später"): show the Welcome once at start. Not in recordings.
        model.show(.onboarding)
    }
}

// MARK: Knowledge switch ("Pippas Wissen" in settings) and new knowledge beside the working one

extension PiSetupController {
    /// Download size of the knowledge for `preference` on this Mac (for the plain labels "Standard (schnell, 5,7 GB)").
    func downloadBytes(_ preference: ModelPreference) -> Int64? {
        guard let model = PiSetupFlow.choice(override: nil, preference: preference)?.model else { return nil }
        return model.pinned?.files.reduce(Int64(0)) { $0 + $1.size } ?? model.approxBytes
    }

    /// "Standard" / "Gründlicher": saves the choice, puts the knowledge in use if it is there, else loads it right away
    /// (choosing in settings, with the size in the label, is the consent) while the previous one keeps working.
    /// `load: false` only for going back after "Cancel".
    func choose(_ new: ModelPreference, load: Bool = true) {
        guard new != preference, offersThorough, isReady, task == nil, let roots,
              let choice = PiSetupFlow.choice(override: nil, preference: new) else { return }
        do { try PippaSettings.savePreference(new, to: roots.support) }
        catch { UserMessage.record(error, context: "wissen-wechseln"); return }
        DiagnosticsLog.shared.event("wissen-wechseln", ["wahl": new.rawValue, "modell": choice.model.key])
        stopUpdate()
        switchedFrom = load ? preference : nil
        preference = new
        let flow = PiSetupFlow(roots: roots, model: choice.model, contextWindow: choice.ctx)
        self.flow = flow
        downloadChosen = load
        loadsUpdate = load
        update = nil
        // Quietly: the conversation keeps working with the knowledge in use until the new one is there.
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { flow.prepare() }.value
            self?.finish(result)
        }
    }

    /// "Pippas Wissen jetzt laden (5,7 GB)": loads the new knowledge beside the working one (resumable).
    /// `previous`: as in `load(after:)`.
    func loadUpdate(after previous: Task<Void, Never>? = nil) {
        guard let flow, updateTask == nil, flow.pendingDownload != nil else { return }
        let id = UUID()
        updateID = id
        update = .downloading(progress: 0, remaining: nil)
        watchStall()
        DiagnosticsLog.shared.event("wissen-laden", ["modell": flow.model.key])
        updateTask = Task { [weak self] in
            await previous?.value
            let result = await flow.download { progress, remaining in
                Task { @MainActor in self?.updateProgress(progress, remaining, id: id) }
            }
            self?.finishUpdate(result, id: id)
        }
    }

    /// "Cancel": stops loading (what came already stays for later). After a switch in settings, back to the previous choice.
    func cancelUpdate() {
        stopUpdate()
        update = flow?.pendingDownload.map { .offer(bytes: $0) }
        if let previous = switchedFrom { switchedFrom = nil; choose(previous, load: false) }
    }

    private func stopUpdate() {
        stallTask?.cancel()
        if stalled { stalled = false; model?.downloadStallChanged() }
        updateTask?.cancel()
        updateTask = nil
        updateID = nil
    }

    private func updateProgress(_ value: Double, _ remaining: TimeInterval?, id: UUID) {
        guard updateID == id, case .downloading(let shown, _) = update else { return }
        rawProgress = value
        guard value >= 1 || abs(value - shown) >= 0.002 else { return }
        update = .downloading(progress: value, remaining: remaining)
    }

    private func finishUpdate(_ result: PiSetupState, id: UUID) {
        guard updateID == id else { return }
        updateTask = nil
        updateID = nil
        stallTask?.cancel()
        if stalled { stalled = false; model?.downloadStallChanged() }
        switch result {
        case .ready:
            switchedFrom = nil
            update = nil
            state = result
            DiagnosticsLog.shared.event("wissen-geladen", ["modell": flow?.activeModelKey ?? ""])
            PiRPCChat.refreshLaunchFile()
        case .failed(let problem):
            // The previous knowledge keeps working; "Try Again" continues where it stopped.
            update = .failed(problem.message)
            DiagnosticsLog.shared.event("wissen-laden-fehler", ["details": problem.details])
        default:
            update = flow?.pendingDownload.map { .offer(bytes: $0) }
        }
    }
}

/// What Pippa can do while loading: the website's use cases (site/index.html, site/en/index.html), briefly.
struct SetupExample {
    var icon: String
    var title: String
    var body: String

    static var all: [SetupExample] {
        [SetupExample(icon: "doc.text", title: T("A letter from your landlord.", table: "Settings"),
                      body: T("I tell you in plain words what it says, what you need to do and by when, and show you the passage it comes from.", table: "Settings")),
         SetupExample(icon: "envelope", title: T("An email that needs an answer.", table: "Settings"),
                      body: T("If someone suggests a time, I check your calendar and draft the reply. You send it yourself.", table: "Settings")),
         SetupExample(icon: "photo.on.rectangle", title: T("Three photos, one PDF.", table: "Settings"),
                      body: T("Drag your phone photos onto me and I make one PDF from them. That works without the internet.", table: "Settings")),
         SetupExample(icon: "folder", title: T("The overflowing Downloads folder.", table: "Settings"),
                      body: T("I sort invoices, photos and installers into folders. If something isn’t right, Undo puts it back.", table: "Settings"))]
    }
}
