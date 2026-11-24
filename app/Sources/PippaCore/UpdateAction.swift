import Foundation

/// What "Check for Updates …" should do right now. Pure, so it can be checked without Sparkle.
///
/// Background: once Sparkle has silently downloaded an update and Pippa returned `true` from
/// `willInstallUpdateOnQuit`, Sparkle stalls its update cycle and ignores further checks. Calling
/// `checkForUpdates` then does nothing at all. The waiting update must be installed instead.
public enum UpdateCheckDecision: Equatable, Sendable {
    /// No updater (e.g. `swift run` without feed or key).
    case unavailable
    /// A downloaded update waits: install it, don't ask Sparkle again. Confirm first while Pippa answers.
    case installReady(version: String, needsConfirmWhileAnswering: Bool)
    /// Sparkle is free: start a user-initiated check.
    case checkNow
    /// Sparkle is in a cycle (or an install is starting) without a waiting update: give feedback, no silent no-op.
    case busy

    public static func decide(hasController: Bool, state: UpdateState, canCheckForUpdates: Bool,
                              isAnswering: Bool) -> UpdateCheckDecision {
        guard hasController else { return .unavailable }
        if state.isInstalling { return .busy }
        if let version = state.readyVersion {
            return .installReady(version: version, needsConfirmWhileAnswering: isAnswering)
        }
        if state.isChecking || !canCheckForUpdates { return .busy }
        return .checkNow
    }
}

/// Pippa's view of Sparkle's update cycle. The install block itself lives next to it in the app;
/// `readyVersion != nil` means that block is held and still valid.
public struct UpdateState: Equatable, Sendable {
    public private(set) var readyVersion: String?
    public private(set) var isChecking = false
    /// The install block was invoked; Sparkle is about to quit and relaunch Pippa.
    public private(set) var isInstalling = false

    public init(readyVersion: String? = nil, isChecking: Bool = false, isInstalling: Bool = false) {
        self.readyVersion = readyVersion
        self.isChecking = isChecking
        self.isInstalling = isInstalling
    }

    /// Pippa started a user-initiated check.
    public mutating func checkStarted() {
        isChecking = true
    }

    /// `willInstallUpdateOnQuit`: an update is downloaded and waits for Pippa to install it.
    public mutating func readyToInstall(version: String) {
        readyVersion = version
        isChecking = false
        isInstalling = false
    }

    /// The install block was invoked.
    public mutating func installStarted() {
        guard readyVersion != nil else { return }
        isInstalling = true
    }

    /// `didFinishUpdateCycleFor` or `didAbortWithError`. Clears the stale checking flag. A waiting
    /// update is kept: Sparkle's block stays valid and may be invoked again (Sparkle 2.3+), e.g. when
    /// the relaunch was cancelled. An install that ended this way did not happen, so it waits again.
    public mutating func cycleEnded() {
        isChecking = false
        isInstalling = false
    }
}
