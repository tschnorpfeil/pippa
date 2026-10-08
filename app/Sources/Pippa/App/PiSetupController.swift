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
@MainActor
final class PiSetupController: ObservableObject {
    /// Recordings (`PIPPA_SNAPSHOT_ONLY=setup-*`) inject a state here without the installer.
    static var shared: PiSetupController? = makeLive()

    @Published private(set) var state: PiSetupState
    @Published var showsDetails = false
    /// Which example is currently showing (here rather than in the view, so measurement and display passes match).
    @Published var exampleIndex = 0

    private let flow: PiSetupFlow?
    private weak var model: AppModel?
    private var task: Task<Void, Never>?
    private var forward: AnyCancellable?
    /// "Laden" was already said: do not ask again after "Nochmal versuchen".
    private var downloadChosen = false
    private var lastProgressAt = Date.distantPast

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
        // The model is dictated by the memory table; there is no choice in settings.
        guard let choice = PiSetupFlow.choice(override: env["PIPPA_PI_MODEL"]) else {
            return PiSetupController(flow: nil, state: .failed(PiSetupProblem(message: T("Pippa needs a Mac with Apple silicon (M1 or later).", table: "Settings"),
                                                                              details: "No catalog model fits this Mac", canRetry: false)))
        }
        return PiSetupController(flow: PiSetupFlow(roots: roots, model: choice.model, contextWindow: choice.ctx))
    }

    var isReady: Bool { if case .ready = state { true } else { false } }

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
        task = Task { [weak self] in
            let result = await flow.download { progress, remaining in
                Task { @MainActor in self?.progress(progress, remaining) }
            }
            self?.finish(result)
        }
    }

    /// "Später" and "Ausblenden": back to the pill. A running download continues.
    func later() { model?.collapse() }

    /// "Nochmal versuchen": from scratch (idempotent); if "Laden" was already said, continues without a question.
    func retry() { begin() }

    /// "Probier's aus": a real first step, tidy Downloads with a preview (changes only after approval,
    /// "Rückgängig" restores everything).
    func tryIt() { model?.tidyDownloads() }

    func showExample(_ index: Int) {
        let count = SetupExample.all.count
        exampleIndex = ((index % count) + count) % count
    }

    private func progress(_ value: Double, _ remaining: TimeInterval?) {
        guard case .downloading(let shown, _) = state else { return }
        // Calm: at most twice per second, and only on a visible change.
        guard value >= 1 || (abs(value - shown) >= 0.002 && Date().timeIntervalSince(lastProgressAt) >= 0.5) else { return }
        lastProgressAt = Date()
        state = .downloading(progress: value, remaining: remaining)
    }

    private func finish(_ result: PiSetupState) {
        task = nil
        if case .askDownload = result, downloadChosen { return load() }
        state = result
        if case .ready = result {
            DiagnosticsLog.shared.event("pi-setup", ["stand": "bereit"])
            PiRPCChat.refreshLaunchFile()
        } else if case .failed(let problem) = result {
            DiagnosticsLog.shared.event("pi-setup", ["stand": "fehler", "details": problem.details])
        }
        // Not done yet (e.g. earlier "Später"): show the Welcome once at start. Not in recordings.
        guard let model, DevSnapshot.directory == nil, !isReady, model.mode.key == "pill", !model.isActiveWork else { return }
        model.show(.onboarding)
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
