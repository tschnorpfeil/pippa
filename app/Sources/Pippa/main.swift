import AppKit

// Pippa lives in the menu bar and as a pill, without a Dock icon.
let app = NSApplication.shared
if CommandLine.arguments.dropFirst().contains("--verify-runtime") {
    do { try BundleVerification.run(); exit(0) }
    catch { FileHandle.standardError.write(Data("Bundle-Prüfung fehlgeschlagen: \(error)\n".utf8)); exit(1) }
}
if CommandLine.arguments.dropFirst().contains("--probe-legacy-container") {
    print("legacy_container \(LegacyMigrationPrompt.probe())")
    exit(0)
}
// Without the sandbox, offer once to take over conversations and settings from the old container (before AppModel).
LegacyMigrationPrompt.runIfNeeded()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
