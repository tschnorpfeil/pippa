import AppKit
import CoreGraphics
import PippaCore
@preconcurrency import Sparkle

/// Automatic updates (Sparkle 2). Feed, key and behavior are in Info.plist:
/// check daily, download silently. Installation happens without a dialog, either on quit or,
/// since Pippa is rarely quit as a menu bar app, as soon as Pippa has nothing to do and
/// nobody is at the Mac. After the restart Pippa says a friendly word once.
@MainActor
final class Updates: NSObject {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var idleTimer: Timer?
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
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    /// "Check for Updates …": Sparkle may show its window here, the person asked for it.
    func checkNow() {
        guard let controller else {
            NSSound.beep()
            return
        }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Once after an update: "Pippa was updated". Not on the very first launch.
    func announceIfUpdated(_ toasts: ToastController?) {
        guard Self.available else { return }
        let defaults = UserDefaults.standard
        let current = AppVersion.build
        let previous = defaults.string(forKey: Self.lastBuildKey)
        defaults.set(current, forKey: Self.lastBuildKey)
        guard let previous, previous != current else { return }
        DiagnosticsLog.shared.event("update-installiert", ["von": previous, "auf": AppVersion.label])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                toasts?.show(title: T("Pippa was updated", table: "App"),
                             detail: T("Now on version %@. Your conversations and settings are all still here.", table: "App", AppVersion.short),
                             buttons: [])
            }
        }
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
        guard let install = pendingInstall else { return }
        let model = AppModel.shared
        guard model.markState == .ruht, !model.isActiveWork, !model.sortFilling,
              NSApp.modalWindow == nil, NSApp.keyWindow == nil else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        guard idle >= Self.quietSeconds else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        pendingInstall = nil
        DiagnosticsLog.shared.event("update-neustart", ["ruhig_s": String(Int(idle))])
        install()
    }
}

extension Updates: SPUUpdaterDelegate {
    /// A silently downloaded update waits for quit. Pippa takes over the when (see above),
    /// so that Sparkle shows no "Install now?" dialog.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let block = UncheckedSendableBox(immediateInstallationBlock)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Updates.shared.installWhenQuiet(block.value) }
        }
        return true
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
