import AppKit
import Combine
import CoreGraphics
import PippaCore
@preconcurrency import Sparkle

/// Automatic updates (Sparkle 2). Feed, key and behavior are in Info.plist:
/// check daily, download silently. Installation happens without a dialog, either on quit or,
/// if Pippa stays running after its windows close, as soon as Pippa has nothing to do and
/// nobody is at the Mac. After the restart Pippa says a friendly word once.
///
/// Once an update waits, Sparkle's cycle is stalled and `checkForUpdates` does nothing. So
/// "Check for Updates …" installs the waiting update instead (see `UpdateCheckDecision`).
@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    /// Version of the downloaded update that waits for installation, if any.
    @Published private(set) var readyVersion: String?
    /// Sparkle is in an update cycle (a check, or an install that is starting).
    @Published private(set) var isChecking: Bool = false

    private var controller: SPUStandardUpdaterController?
    private var state = UpdateState() { didSet { publish() } }
    private var pendingInstall: (() -> Void)?
    private var idleTimer: Timer?
    private var canCheckObservation: NSKeyValueObservation?
    /// Mirrors Sparkle's KVO-compliant `canCheckForUpdates`.
    private var canCheck = false { didSet { publish() } }
    private static let lastBuildKey = "updates.lastLaunchedBuild"
    /// For this long nobody may have used mouse or keyboard before Pippa restarts itself silently.
    private static let quietSeconds: CFTimeInterval = 20 * 60

    /// Only in the finished bundle with feed and public key; `swift run` has neither,
    /// Sparkle would otherwise start there with an error message.
    static var available: Bool {
        let info = Bundle.main
        return info.bundleURL.pathExtension == "app"
            && info.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && info.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    func start() {
        guard Self.available, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { _, change in
            let value = change.newValue ?? false
            if Thread.isMainThread {
                MainActor.assumeIsolated { Updates.shared.canCheck = value }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Updates.shared.canCheck = value }
                }
            }
        }
    }

    /// "Check for Updates …": Sparkle may show its window here, the person asked for it.
    /// A waiting update is installed instead, because Sparkle would ignore the check.
    func checkNow() {
        let liveCanCheck = controller?.updater.canCheckForUpdates ?? false
        canCheck = liveCanCheck
        let decision = UpdateCheckDecision.decide(hasController: controller != nil, state: state,
                                                  canCheckForUpdates: liveCanCheck,
                                                  isAnswering: ChatModel.shared.isAnswering)
        DiagnosticsLog.shared.event("update-pruefen", ["entscheidung": String(describing: decision)])
        switch decision {
        case .unavailable:
            NSSound.beep()
        case .installReady(let version, let needsConfirm):
            installReady(version: version, confirm: needsConfirm)
        case .checkNow:
            NSApp.activate()
            state.checkStarted()
            controller?.checkForUpdates(nil)
        case .busy:
            showBusy()
        }
    }

    /// For a direct "Install and Restart" button: routes through `UpdateCheckDecision` so double-clicks
    /// while an install is already starting cannot re-enter `installReady` or show a duplicate alert.
    func installReadyNow() {
        checkNow()
    }

    private func installReady(version: String, confirm: Bool) {
        idleTimer?.invalidate()
        idleTimer = nil
        if confirm {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = T("Pippa is answering right now.", table: "App")
            alert.informativeText = T("Install the update now and restart? The current answer will stop.", table: "App")
            alert.addButton(withTitle: T("Install and Restart", table: "App"))
            alert.addButton(withTitle: T("Later", table: "App"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                // Not now: the update keeps waiting for a quiet moment.
                if let install = pendingInstall { installWhenQuiet(install) }
                return
            }
        }
        startInstall(reason: "knopf", version: version)
    }

    /// Sparkle runs a cycle without a waiting update: bring its window forward, or say so.
    private func showBusy() {
        NSApp.activate()
        let sparkleWindow = NSApp.windows.first { window in
            guard window.isVisible || window.isMiniaturized, let controller = window.windowController else { return false }
            let name = String(describing: type(of: controller))
            return name.hasPrefix("SPU") || name.hasPrefix("SU")
        }
        if let sparkleWindow {
            if sparkleWindow.isMiniaturized { sparkleWindow.deminiaturize(nil) }
            sparkleWindow.makeKeyAndOrderFront(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = T("Pippa is already checking for updates.", table: "App")
        alert.informativeText = T("Please try again in a moment.", table: "App")
        alert.runModal()
    }

    private func startInstall(reason: String, version: String, idleSeconds: Int? = nil) {
        guard let install = pendingInstall else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        state.installStarted()
        var fields = ["grund": reason, "version": version]
        if let idleSeconds { fields["ruhig_s"] = String(idleSeconds) }
        DiagnosticsLog.shared.event("update-neustart", fields)
        install()
    }

    private func publish() {
        if readyVersion != state.readyVersion { readyVersion = state.readyVersion }
        let checking = state.isChecking || state.isInstalling || (controller != nil && !canCheck && state.readyVersion == nil)
        if isChecking != checking { isChecking = checking }
    }

    // MARK: Install silently when nobody is there

    private func installWhenQuiet(_ install: @escaping () -> Void) {
        pendingInstall = install
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Updates.shared.installIfQuiet() }
        }
    }

    private func installIfQuiet() {
        guard let version = state.readyVersion, pendingInstall != nil, !state.isInstalling else { return }
        guard !ChatModel.shared.isAnswering, NSApp.modalWindow == nil, NSApp.keyWindow == nil else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        guard idle >= Self.quietSeconds else { return }
        startInstall(reason: "ruhig", version: version, idleSeconds: Int(idle))
    }

    fileprivate func updateReady(version: String, install: @escaping () -> Void) {
        state.readyToInstall(version: version)
        installWhenQuiet(install)
    }

    fileprivate func cycleEnded() {
        idleTimer?.invalidate()
        idleTimer = nil
        pendingInstall = nil
        state.cycleEnded()
    }
}

extension Updates: SPUUpdaterDelegate {
    /// A silently downloaded update waits for quit. Pippa takes over the when (see above),
    /// so that Sparkle shows no "Install now?" dialog.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let block = UncheckedSendableBox(immediateInstallationBlock)
        let version = item.displayVersionString
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Updates.shared.updateReady(version: version, install: block.value) }
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Updates.shared.cycleEnded() }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Updates.shared.cycleEnded() }
        }
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    /// Menu bar app: scheduled notices gently instead of a window in the foreground.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}

// The type parameter is not named `T`, otherwise it would shadow `T(_:table:)` (translation).
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
