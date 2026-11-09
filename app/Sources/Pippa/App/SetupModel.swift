import Foundation
import PippaCore

/// Setting up the AI on this Mac: Pi, Node, the model folder and models.json happen quietly (`PiSetupFlow`); the only
/// question is the download. An online AI chosen in Settings needs none of this.
@MainActor
final class SetupModel: ObservableObject {
    static let shared = SetupModel()

    @Published private(set) var state: PiSetupState = .preparing(adoptingFrom: nil)
    let hardware = MacHardware.summary()
    private var flow: PiSetupFlow?
    private var roots: PiInstallRoots?
    private var task: Task<Void, Never>?
    private var lastProgressAt = Date.distantPast
    /// The running attempt (`begin`, `load`): results and progress of an older, cancelled one are dropped.
    private var attemptID = UUID()

    var isReady: Bool { if case .ready = state { true } else { false } }
    /// An online AI is switched on in Settings: Pippa can answer without the download.
    /// Reads the settings in memory (`SettingsModel`), never from disk: SwiftUI asks this on every redraw.
    var usesOnlineAI: Bool {
        let settings = SettingsModel.shared.inferenceSettings
        return settings.usesOnlineAI
    }
    var canAnswer: Bool { isReady || usesOnlineAI }
    /// The setup card shows: a question, a download or a problem, and no online AI to fall back on.
    var needsAttention: Bool {
        if usesOnlineAI { return false }
        switch state {
        case .askDownload, .downloading, .failed: return true
        case .preparing, .ready: return false
        }
    }

    /// Snapshots only: they cannot click "Details", so the card starts with it open.
    private(set) var detailsOpenForSnapshot = false

    /// Snapshots only.
    func showForSnapshot(_ state: PiSetupState, detailsOpen: Bool = false) {
        self.state = state
        detailsOpenForSnapshot = detailsOpen
    }

    init() {
        let env = ProcessInfo.processInfo.environment
        guard let payload = PiPayload.locate(environment: env) else {
            state = .failed(PiSetupProblem(.payloadMissing(env["PIPPA_PI_PAYLOAD"] ?? "Contents/Resources/pi-payload")))
            return
        }
        let roots = PiInstallRoots.forApp(payload: payload, environment: env)
        let saved = PippaSettings.load(from: roots.support)
        let choice: ModelChoice
        switch ModelSelector.choose(physicalMemory: ProcessInfo.processInfo.physicalMemory) {
        case .success(let fits): choice = fits
        case .failure(let error):
            state = .failed(PiSetupProblem(message: error.localizedDescription, details: "No local model fits this Mac", canRetry: false))
            return
        }
        self.roots = roots
        flow = PiSetupFlow(roots: roots, model: choice.model, contextWindow: choice.ctx)
        // An interrupted download goes on by itself: the person already said yes.
        if saved.downloadConsent == choice.model.key { resumeConsent = true }
    }

    private var resumeConsent = false

    /// Everything without network; stops at the download question or an error.
    func begin() {
        guard let flow, task == nil else { return }
        let attempt = UUID()
        attemptID = attempt
        state = .preparing(adoptingFrom: nil)
        task = Task { [weak self] in
            let source = await Task.detached(priority: .userInitiated) { flow.adoptionSource() }.value
            if let source, self?.attemptID == attempt { self?.state = .preparing(adoptingFrom: source) }
            let result = await Task.detached(priority: .userInitiated) { flow.prepare() }.value
            self?.finish(result, attempt: attempt)
        }
    }

    /// "Load": the one consent, kept so an interrupted download continues at the next start.
    func load() {
        guard let flow, task == nil else { return }
        if let roots { try? PippaSettings.saveDownloadConsent(flow.model.key, to: roots.support) }
        let attempt = UUID()
        attemptID = attempt
        state = .downloading(progress: 0, remaining: nil)
        task = Task { [weak self] in
            let result = await flow.download { progress, remaining in
                Task { @MainActor in self?.progress(progress, remaining, attempt: attempt) }
            }
            self?.finish(result, attempt: attempt)
        }
    }

    /// "Stop": pauses the download (what came stays) and asks again.
    func stopDownload() {
        guard case .downloading = state else { return }
        task?.cancel(); task = nil
        resumeConsent = false
        if let roots { try? PippaSettings.saveDownloadConsent(nil, to: roots.support) }
        begin()
    }

    private func progress(_ value: Double, _ remaining: TimeInterval?, attempt: UUID) {
        guard attempt == attemptID, case .downloading(let shown, _) = state else { return }
        guard value >= 1 || (abs(value - shown) >= 0.002 && Date().timeIntervalSince(lastProgressAt) >= 0.5) else { return }
        lastProgressAt = Date()
        state = .downloading(progress: value, remaining: remaining)
    }

    private func finish(_ result: PiSetupState, attempt: UUID) {
        // A stopped download ends late with its own result; the newer attempt owns the state by then.
        guard attempt == attemptID else { return }
        task = nil
        state = result
        if case .askDownload = result, resumeConsent { resumeConsent = false; load() }
        if case .ready = result { PiSession.shared.settingsChanged() }
    }
}
