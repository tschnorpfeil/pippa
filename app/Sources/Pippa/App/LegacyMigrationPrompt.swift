import AppKit
import PippaCore

/// Once on the first launch without the sandbox, before AppModel (which creates the folders and reads "onboarded").
/// Flow and rules: `LegacyContainerMigration`.
@MainActor
enum LegacyMigrationPrompt {
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        // Only the real app (not `swift run`, not developer recordings), and only until decided once.
        guard Bundle.main.bundleIdentifier == LegacyContainerMigration.bundleID,
              DevEnvironment.value("PIPPA_SNAPSHOT") == nil,
              defaults.string(forKey: LegacyContainerMigration.markerKey) == nil else { return }
        // If the old Pippa is still running it might be writing: try again on the next launch.
        let mine = ProcessInfo.processInfo.processIdentifier
        guard NSRunningApplication.runningApplications(withBundleIdentifier: LegacyContainerMigration.bundleID)
            .allSatisfy({ $0.processIdentifier == mine }) else { return }

        let migration = LegacyContainerMigration(home: ExistingModels.realHome, destination: Pippa.supportDirectory)
        switch migration.evaluate() {
        case .nothing:
            defaults.set("nothing", forKey: LegacyContainerMigration.markerKey)
        case .denied:
            // macOS refused to read the old folder. Nothing lost: the container stays, no marker,
            // Pippa quietly tries again on the next launch. No dialog from Pippa itself.
            DiagnosticsLog.shared.event("legacy_migration", ["result": "denied"])
        case .offer(let items):
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = T("Bring over your conversations?", table: "App")
            alert.informativeText = T("Pippa found the conversations, settings and history of her previous version. She can copy them here. The originals stay where they are.", table: "App")
            alert.addButton(withTitle: T("Copy Over", table: "App"))
            alert.addButton(withTitle: T("Start Fresh", table: "App"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                defaults.set("declined", forKey: LegacyContainerMigration.markerKey)
                DiagnosticsLog.shared.event("legacy_migration", ["result": "declined"])
                return
            }
            do {
                let outcome = try migration.run(items: items, defaults: defaults)
                defaults.set("done", forKey: LegacyContainerMigration.markerKey)
                DiagnosticsLog.shared.event("legacy_migration", ["result": "done", "items": "\(outcome.copied.count)",
                                                                 "defaults": "\(outcome.importedDefaults.count)",
                                                                 "clone": outcome.cloned ? "1" : "0"])
            } catch {
                // No marker: Pippa asks again on the next launch as long as the new folder is empty.
                DiagnosticsLog.shared.event("legacy_migration", ["result": "failed", "error": "\(error)"])
                let failed = NSAlert()
                failed.messageText = T("Pippa couldn’t copy everything.", table: "App")
                failed.informativeText = T("Your previous conversations are unchanged. Pippa will ask again next time she starts.", table: "App")
                failed.runModal()
            }
        }
    }

    /// `Pippa --probe-legacy-container`: metadata only (lstat, opendir), prints `absent`, `accessible` or `denied`.
    /// For acceptance on a fresh account (macOS protection for app data); reads no file.
    static func probe() -> String {
        LegacyContainerMigration(home: ExistingModels.realHome, destination: Pippa.supportDirectory).access().rawValue
    }
}
