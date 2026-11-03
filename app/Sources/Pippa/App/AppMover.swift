import AppKit
import PippaCore

/// First launch outside Applications (AppLocation.swift): one question, then Pippa copies herself to Applications,
/// starts from there and ejects the disk image (or moves the copy in Downloads to the Trash). Runs before the
/// single-instance lock, so the new Pippa can take it. "Not Now" is remembered; Pippa does not ask again.
@MainActor
enum AppMover {
    private static let declinedKey = "appMover.declined"

    /// `true`: the move is under way and this process should end now.
    static func runIfNeeded() -> Bool {
        #if DEBUG
        // Developer builds only on request (try it from a disk image).
        guard ProcessInfo.processInfo.environment["PIPPA_TRY_MOVE"] == "1" else { return false }
        #endif
        let defaults = UserDefaults.standard
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app",
              Bundle.main.bundleIdentifier == Pippa.bundleID,
              ProcessInfo.processInfo.environment["PIPPA_NO_MOVE"] == nil,
              !defaults.bool(forKey: declinedKey) else { return false }
        let place = AppLocation.place(of: bundle, home: FileManager.default.homeDirectoryForCurrentUser)
        if place == .applications { return false }
        // Another Pippa already runs (e.g. the one in Applications): the single-instance check wakes it.
        let mine = ProcessInfo.processInfo.processIdentifier
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Pippa.bundleID)
            .allSatisfy({ $0.processIdentifier == mine }) else { return false }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = T("Move Pippa to your Applications folder?", table: "App")
        alert.informativeText = T("Then she stays up to date by herself and can start with your Mac. It only takes a moment.", table: "App")
        alert.addButton(withTitle: T("Move to Applications", table: "App"))
        alert.addButton(withTitle: T("Not Now", table: "App"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            defaults.set(true, forKey: declinedKey)
            DiagnosticsLog.shared.event("app-verschieben", ["ergebnis": "abgelehnt"])
            return false
        }
        return move()
    }

    /// "Move to Applications…" in Settings: the person asks for it, so no question and an earlier "Not Now" no
    /// longer counts. On success Pippa quits and the moved copy starts.
    static func moveNow() {
        UserDefaults.standard.removeObject(forKey: declinedKey)
        guard Bundle.main.bundleURL.pathExtension == "app", !AppLocation.isInApplications() else { return }
        if move() { NSApp.terminate(nil) }
    }

    /// Copies Pippa to Applications and schedules the restart from there. `false`: it failed (the person was told).
    private static func move() -> Bool {
        let bundle = Bundle.main.bundleURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        let place = AppLocation.place(of: bundle, home: home)
        let source = place == .translocated ? (originalURL(ofTranslocated: bundle) ?? bundle) : bundle
        let fm = FileManager.default
        let destination = AppLocation.destination(appName: source.lastPathComponent,
                                                  systemApplicationsWritable: fm.isWritableFile(atPath: "/Applications"), home: home)
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing: String?? = fm.fileExists(atPath: destination.path) ? .some(Self.build(of: destination)) : .none
            switch AppLocation.install(existing: existing, moving: Self.build(of: source)) {
            case .copy:
                try fm.copyItem(at: source, to: destination)
            case .replaceOlder:
                // Nothing of hers lives in the app itself: an older copy can go to the Trash.
                try fm.trashItem(at: destination, resultingItemURL: nil)
                try fm.copyItem(at: source, to: destination)
            case .openExisting:
                // The same or a newer Pippa is already installed: start that one, change nothing there.
                break
            }
        } catch {
            DiagnosticsLog.shared.event("app-verschieben", ["ergebnis": "fehler", "details": "\(error)"])
            let failed = NSAlert()
            failed.messageText = T("Pippa couldn’t move herself.", table: "App")
            failed.informativeText = T("Drag Pippa into the Applications folder in Finder. Until then she works from here.", table: "App")
            failed.runModal()
            return false
        }
        // The original in Downloads (behind App Translocation) is no longer needed; a disk image is ejected after the
        // restart instead. Anywhere else the running copy stays where it is (never trash the bundle that is running).
        var volume = ""
        if case .volume(let url) = place { volume = url.path }
        else if place == .translocated, source != bundle { try? fm.trashItem(at: source, resultingItemURL: nil) }
        DiagnosticsLog.shared.event("app-verschieben", ["ergebnis": "verschoben", "ziel": destination.deletingLastPathComponent().path])
        relaunch(destination, eject: volume)
        return true
    }

    private static func build(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// Waits until this process has ended, then opens the moved Pippa and ejects the disk image (if any).
    private static func relaunch(_ app: URL, eject volume: String) {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/open "$2"
        if [ -n "$3" ]; then /bin/sleep 1; /usr/bin/hdiutil detach "$3" -quiet || true; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)", app.path, volume]
        try? process.run()
    }

    /// App Translocation: the original path of the read-only copy macOS runs (Security.framework, no public header).
    private static func originalURL(ofTranslocated url: URL) -> URL? {
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(url as CFURL, nil).map { $0.takeRetainedValue() as URL }
    }
}

extension AppLocation {
    /// The running Pippa lies in /Applications or ~/Applications.
    static func isInApplications(bundle: URL = Bundle.main.bundleURL) -> Bool {
        place(of: bundle, home: FileManager.default.homeDirectoryForCurrentUser) == .applications
    }
}
