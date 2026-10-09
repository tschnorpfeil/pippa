import Combine
import PippaCore
import SwiftUI

/// Setup in the Welcome: no technical questions.
/// Like PiRPCChat, in every build.
///
/// Quiet: Pi, Node, model folder, adopting existing models, models.json (`PiSetupFlow`, off the
/// main thread). The only question is the download ("Laden" · "Später"). Then a calm progress with examples,
/// at the end "Probier's aus". Errors: one sentence, "Nochmal versuchen", technical detail behind "Details".
///
/// Environment like PiRPCChat: `PIPPA_PI_PAYLOAD` (otherwise the payload in the app), `PIPPA_PI_HOME` (fake HOME for
/// test runs), `PIPPA_PI_MODEL` (otherwise by memory like LocalEngine).
///
/// New knowledge while the old one keeps working (`update`): after an app update whose table names a different model
/// (e.g. the 1.0 move to K2 Horizon 7B), or after "Gründlicher" in settings, setup stays `.ready` with the previous model and
/// offers the download ("Pippas Wissen jetzt laden (5,6 GB)"). After loading, models.json names the new model; Pi and the
/// llama-server follow on the next request. The previous model's file stays on disk.
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
    private var updateTask: Task<Void, Never>?
    private var updateID: UUID?
    /// After a switch in settings: load right away (choosing counts as consent), and on "Cancel" go back to this.
    private var loadsUpdate = false
    private var switchedFrom: ModelPreference?
    private weak var model: AppModel?
    private var task: Task<Void, Never>?
    private var forward: AnyCancellable?
    /// "Laden" was already said: do not ask again after "Nochmal versuchen".
    private var downloadChosen = false
    private var lastProgressAt = Date.distantPast
    /// No new bytes for 30 s, or no network, while loading. The downloader keeps retrying by itself; the views say so
    /// in one calm sentence with "Try Again" instead of a progress bar that silently stands still.
    @Published private(set) var stalled = false
    private var stallWatch = DownloadStallWatch(limit: 30)
    private var stallTask: Task<Void, Never>?
    /// Latest progress as reported (before the display throttle), so slow but moving downloads never count as stuck.
    private var rawProgress = 0.0
    /// The running "Laden": a restart ("Try Again") ignores the result of the attempt it replaced.
    private var loadID: UUID?

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
        // The model comes from the memory table; the only setting is "Standard" / "Gründlicher" (24 GB and up).
        let preference = PippaSettings.load(from: roots.support).preference
        guard let choice = PiSetupFlow.choice(override: env["PIPPA_PI_MODEL"], preference: preference) else {
            // Also an unpinned table model (scripts/pin-model.sh): loud on purpose, a release must never get here.
            let unpinned = ModelSelector.tableKeys.filter { ModelCatalog.bundled().model($0)?.pinned == nil }
            return PiSetupController(flow: nil, state: .failed(PiSetupProblem(message: T("Pippa needs a Mac with Apple silicon (M1 or later).", table: "Settings"),
                                                                              details: unpinned.isEmpty ? "No catalog model fits this Mac" : "Not pinned in catalog.json: \(unpinned.joined(separator: ", "))",
                                                                              canRetry: false)))
        }
        let setup = PiSetupController(flow: PiSetupFlow(roots: roots, model: choice.model, contextWindow: choice.ctx))
        setup.roots = roots
        setup.preference = preference
        return setup
    }

    var isReady: Bool { if case .ready = state { true } else { false } }
    var asksDownload: Bool { if case .askDownload = state { true } else { false } }

    /// At app start: pass changes on to the shell (size), then set up quietly.
    func attach(to model: AppModel) {
        self.model = model
        forward = objectWillChange.sink { [weak model] _ in model?.objectWillChange.send() }
        begin()
    }

    /// Everything without network; stops only at the download question or an error.
    func begin() {
        guard let flow, task == nil else { return }
        showsDetails = false
        state = .preparing(adoptingFrom: nil)
        task = Task { [weak self] in
            let source = await Task.detached(priority: .userInitiated) { flow.adoptionSource() }.value
            if let source { self?.state = .preparing(adoptingFrom: source) }
            let result = await Task.detached(priority: .userInitiated) { flow.prepare() }.value
            self?.finish(result)
        }
    }

    /// "Laden": the only consent. Downloads resumably, then the rest of setup.
    func load() {
        guard let flow, task == nil else { return }
        downloadChosen = true
        showsDetails = false
        state = .downloading(progress: 0, remaining: nil)
        let id = UUID()
        loadID = id
        watchStall()
        task = Task { [weak self] in
            let result = await flow.download { progress, remaining in
                Task { @MainActor in self?.progress(progress, remaining) }
            }
            guard let self, self.loadID == id else { return }
            self.loadID = nil
            self.finish(result)
        }
    }

    /// "Später" and "Ausblenden": back to the pill. A running download continues.
    func later() { model?.collapse() }

    /// "Nochmal versuchen": from scratch (idempotent); if "Laden" was already said, continues without a question.
    func retry() { begin() }

    /// "Try Again" while a download hangs: stop the attempt and start a fresh one right away. It continues where the
    /// previous one stopped (the part file stays).
    func retryDownload() {
        if case .downloading = state {
            task?.cancel()
            task = nil
            loadID = nil
            load()
        } else if case .downloading? = update {
            stopUpdate()
            loadUpdate()
        }
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

    /// "Probier's aus": a real first step, tidy Downloads with a preview (changes only after approval,
    /// "Rückgängig" restores everything).
    func tryIt() { model?.tidyDownloads() }

    func showExample(_ index: Int) {
        let count = SetupExample.all.count
        exampleIndex = ((index % count) + count) % count
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
        task = nil
        stallTask?.cancel()
        if stalled { stalled = false; model?.downloadStallChanged() }
        let wantsUpdate = loadsUpdate
        loadsUpdate = false
        if case .askDownload = result, downloadChosen { return load() }
        state = result
        if case .ready = result {
            DiagnosticsLog.shared.event("pi-setup", ["stand": "bereit", "modell": flow?.activeModelKey ?? ""])
            PiRPCChat.refreshLaunchFile()
            if updateTask == nil { update = flow?.pendingDownload.map { .offer(bytes: $0) } }
            if flow?.pendingDownload == nil { switchedFrom = nil }
            if wantsUpdate { loadUpdate() }
        } else if case .failed(let problem) = result {
            DiagnosticsLog.shared.event("pi-setup", ["stand": "fehler", "details": problem.details])
        }
        // Not done yet (e.g. earlier "Später"): show the Welcome once at start. Not in recordings.
        guard let model, DevSnapshot.directory == nil, !isReady, model.mode.key == "pill", !model.isActiveWork else { return }
        model.show(.onboarding)
    }
}

// MARK: Knowledge switch ("Pippas Wissen" in settings) and new knowledge beside the working one

extension PiSetupController {
    /// Download size of the knowledge for `preference` on this Mac (for the plain labels "Standard (schnell, 5,6 GB)").
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

    /// "Pippas Wissen jetzt laden (5,6 GB)": loads the new knowledge beside the working one (resumable).
    func loadUpdate() {
        guard let flow, updateTask == nil, flow.pendingDownload != nil else { return }
        let id = UUID()
        updateID = id
        update = .downloading(progress: 0, remaining: nil)
        watchStall()
        DiagnosticsLog.shared.event("wissen-laden", ["modell": flow.model.key])
        updateTask = Task { [weak self] in
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
