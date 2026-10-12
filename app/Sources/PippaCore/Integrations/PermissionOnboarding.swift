import Foundation

/// When "What Pippa may do" appears on its own, so nobody misses it: after "Load", after "Later" too (the page used to
/// wait for the download, so "Later" skipped it for good), and once more at a later start if it was closed with ×
/// instead of "Continue". Never twice in a row after being closed: a page that keeps coming back would nag.
public enum PermissionOnboarding {
    /// Closed with × this many times, it no longer comes back by itself (Settings › Permissions still has every row).
    public static let reminders = 2

    /// In the Welcome: the page instead of the setup view.
    public static func shows(pending: Bool, setup: PiSetupState?, deferred: Bool) -> Bool {
        guard pending else { return false }
        switch setup {
        case .downloading?, .ready?: return true
        // "Later" to the download: the permissions still come now, the AI waits.
        case .askDownload?: return deferred
        case .preparing?, .failed?, nil: return false
        }
    }

    /// Opening Pippa (pill or shortcut) while the page is still open in this run: back to the page, so it is never
    /// lost when it went away without "Continue" or ×. After × it waits for the next start.
    public static func reopens(pending: Bool, setup: PiSetupState?, deferred: Bool, closedThisRun: Bool) -> Bool {
        !closedThisRun && shows(pending: pending, setup: setup, deferred: deferred)
    }

    /// At a later start, once setup is ready: show the Welcome again so the page comes back (also for someone who went
    /// straight to work on the first day and never saw it).
    public static func remindsAtStart(pending: Bool, dismissals: Int) -> Bool {
        pending && dismissals < reminders
    }

    /// Rows still waiting for an answer: "Continue" says how many, so pressing it is a choice, not an oversight.
    public static func undecided(_ states: [MacPermission: PermissionState]) -> Int {
        states.values.filter { $0 == .notAsked }.count
    }

    /// Tidying found nothing: was it because macOS refused the folder? Reading it again shows no dialog once the person
    /// has answered, so this only tells.
    public static func folderRefused(_ folder: URL) async -> Bool {
        await SystemPermissions.read([folder]) == .denied
    }
}
