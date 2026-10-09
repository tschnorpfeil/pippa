import AppKit
import PippaCore

// Call: pill, shortcut and the "View selected mail" menu entries.
// With Mail in front, Pippa reads the selected mail and shows the letter in the line (LetterController.swift).
// With Excel in front, Pippa reads the active sheet (read-only) and shows the table in the line (SheetController.swift).
// Otherwise as before: pill → pending result, tray line or input; shortcut → toggle input.

/// Where a call came from.
enum CallTrigger { case pill, shortcut, menu }

/// Remembers the last active app other than Pippa. The shell is an ordinary panel: when the pill is clicked,
/// Pippa may already be in front before `mouseDown` arrives. So every app is noted on activation, not on click.
@MainActor
final class FrontmostTracker {
    static let shared = FrontmostTracker()

    private var last: NSRunningApplication?
    private var observer: (any NSObjectProtocol)?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    /// Once at launch (AppDelegate).
    func start() {
        guard observer == nil else { return }
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Pass only the process id across the boundary (Sendable); the app is fetched again on the main thread.
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            // Observation runs on the main queue.
            MainActor.assumeIsolated { self?.remember(pid: pid) }
        }
    }

    /// The app the call was made in: the front one if it is not Pippa, otherwise the last active other app.
    func capture() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID { return front }
        return last
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ownPID else { return }
        last = app
    }

    private func remember(pid: pid_t?) {
        guard let pid, pid != ownPID else { return }
        remember(NSRunningApplication(processIdentifier: pid))
    }
}

extension AppModel {
    /// A call. `front`: the app that was in front at the call (`FrontmostTracker.capture()`, fetched before activating).
    func call(_ trigger: CallTrigger, front: NSRunningApplication?) {
        let fromMail = front?.bundleIdentifier == Integration.mail.bundleIdentifier
        let fromExcel = front?.bundleIdentifier == ExcelScript.bundleIdentifier
        switch trigger {
        case .menu:
            // The menu entries read the selected mail even if Mail is not in front.
            callMail()
        case .pill:
            // An explicit Give takes precedence over ambient Mail/Excel selection.
            if !tray.givenItems.isEmpty || tray.isWorking { return openLine() }
            if hasResumableConversation { return openConversationFromPill() }
            if fromMail { return callMail() }
            if fromExcel { return callExcel() }
            openPillDefault()
        case .shortcut:
            // A second press closes again: letter or table in the line, like the open conversation.
            let callShown = mode.key == "line" && (letter.isActive || sheet.isActive)
            if callShown || mode.isConversation || mode.key == "resume" { return collapse() }
            if fromMail { return callMail() }
            if fromExcel { return callExcel() }
            toggleInput()
        }
    }

    /// Click on the pill as before: a pending result comes back; if something is on Pippa, the line; otherwise the input.
    func openPillDefault() {
        if !tray.givenItems.isEmpty || tray.isWorking { return openLine() }
        if hasResumableConversation { return openConversationFromPill() }
        if parked != nil { return resumeParked() }
        if !tray.items.isEmpty { return openLine() }
        openInput()
    }

    /// Call in Mail: the local model stays loaded for a while afterwards, the letter takes over.
    private func callMail() {
        keepModelWarm()
        sheet.end()
        letter.callMail()
    }

    /// Call in Excel: as in Mail, the model stays loaded for a while afterwards (for *Explain this table*).
    private func callExcel() {
        keepModelWarm()
        sheet.callExcel()
    }

    /// Pi's llama-server (the one the app runs) stays loaded longer after a call. Starts nothing. LocalEngine's own
    /// `keepWarmAfterCall` reached no server since it shares Pi's.
    private func keepModelWarm() {
        let server = PiRPCChat.shared.ownedServer
        Task { await server?.keepWarm(for: LlamaServer.afterCallSeconds) }
    }
}
