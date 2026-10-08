import AppKit
@preconcurrency import Sparkle

// Developer tool, not part of Pippa.app. Uses Sparkle's real installation
// with an unmodified host bundle and a signed update DMG; only a loopback test feed is allowed.
@MainActor
final class Probe: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    let feed: String
    let host: Bundle
    let target: String
    let logURL: URL
    /// Without a button press: background check, automatic download, immediate installation
    /// (the same path as Pippa's automatic update, just without the 20-minute idle wait).
    let automatic: Bool
    private var updater: SPUUpdater?
    init(feed: String, host: Bundle, target: String, logURL: URL, automatic: Bool) {
        self.feed = feed; self.host = host; self.target = target; self.logURL = logURL; self.automatic = automatic
    }
    func log(_ text: String) {
        let data = Data(("\(ISO8601DateFormatter().string(from: Date())) \(text)\n").utf8)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: logURL) {
            _ = try? file.seekToEnd(); try? file.write(contentsOf: data); try? file.close()
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let fresh = Bundle(url: host.bundleURL)
        let build = fresh?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log("Host \(host.bundleURL.path), build \(build), target \(target)")
        guard build != target else { log("UPDATE INSTALLED"); NSApp.terminate(nil); return }
        let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
        let updater = SPUUpdater(hostBundle: host, applicationBundle: Bundle.main, userDriver: driver, delegate: self)
        self.updater = updater
        log("Mode \(automatic ? "automatic" : "button"), installer XPC \(Bundle.main.object(forInfoDictionaryKey: "SUEnableInstallerLauncherService") as? Bool ?? false)")
        do {
            try updater.start()
            if automatic { updater.checkForUpdatesInBackground() } else { updater.checkForUpdates() }
        }
        catch { log("START FAILED: \(error.localizedDescription)"); NSApp.terminate(nil) }
    }
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { feed }
    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.versionString
        DispatchQueue.main.async { self.log("UPDATE FOUND \(version)") }
    }
    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let version = item.versionString
        DispatchQueue.main.async { self.log("DOWNLOADED \(version)") }
    }
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.versionString
        DispatchQueue.main.async { self.log("INSTALLING \(version)") }
    }
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.versionString
        nonisolated(unsafe) let install = immediateInstallHandler
        DispatchQueue.main.async {
            self.log("READY ON QUIT \(version)")
            if self.automatic { self.log("INSTALL NOW"); install() }
        }
        return true
    }
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let text = error.map { ($0 as NSError).localizedDescription } ?? "ok"
        DispatchQueue.main.async { self.log("CYCLE DONE \(text)") }
    }
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let text = error.localizedDescription
        DispatchQueue.main.async { self.log("ABORT: \(text)") }
    }
}

let info = Bundle.main
let hostPath = info.object(forInfoDictionaryKey: "PippaProbeHost") as? String ?? ""
let feed = info.object(forInfoDictionaryKey: "PippaProbeFeed") as? String ?? ""
let target = info.object(forInfoDictionaryKey: "PippaProbeTarget") as? String ?? ""
let logPath = info.object(forInfoDictionaryKey: "PippaProbeLog") as? String ?? ""
guard !hostPath.isEmpty, let host = Bundle(path: hostPath), let url = URL(string: feed),
      url.scheme == "http", url.host == "127.0.0.1", !target.isEmpty, !logPath.isEmpty else {
    print("Probe needs an app bundle with an explicit host, loopback feed, target build and log path.")
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let automatic = info.object(forInfoDictionaryKey: "PippaProbeAutomatic") as? Bool ?? false
let probe = Probe(feed: feed, host: host, target: target, logURL: URL(fileURLWithPath: logPath), automatic: automatic)
app.delegate = probe
app.run()
