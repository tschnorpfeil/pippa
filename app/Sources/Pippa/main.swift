import AppKit

// Pi, llama-server and Node are children on pipes: if one dies just before a write, the write fails instead of
// SIGPIPE ending Pippa.
signal(SIGPIPE, SIG_IGN)
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
// PIPPA_REGULAR_APP=1 (developers only): a regular app with a Dock icon, so UI automation that only sees regular
// apps can click through it.
app.setActivationPolicy(ProcessInfo.processInfo.environment["PIPPA_REGULAR_APP"] == "1" ? .regular : .accessory)
app.run()
