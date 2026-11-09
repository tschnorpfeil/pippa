import Foundation

extension PiInstaller {
    // MARK: 1. Detect

    public func detect() -> PiStepResult {
        begin(.detect)
        // Already decided (earlier, maybe aborted run): keep it. Otherwise a half-created official layout
        // would look "foreign" when resuming.
        if let detection = state.detection, state.layout != nil, state.pin == roots.pin {
            return finish(.detect, .detected(detection))
        }
        // New pin (Pippa update with a new Pi): remember the old one, its release stays during cleanup.
        if let old = state.pin, old != roots.pin { state.previousPin = old }
        let detection = Self.detect(roots)
        // The official layout that Pippa created itself looks like "managed Pi present" at the next pin.
        // It stays Pippa's: otherwise the terminal Pi would never follow (`advanceTerminalPi`).
        let marker = roots.managedRoot.appendingPathComponent("managed-install.json")
        if state.layout == .official, case .managed = detection, state.didCreate(marker) {
            state.detection = detection
        } else {
            state.detection = detection
            state.layout = detection.layout
        }
        state.pin = roots.pin
        return finish(.detect, .detected(detection))
    }

    /// Pure detection without state.
    public static func detect(_ roots: PiInstallRoots) -> PiDetection {
        let fm = FileManager.default
        let marker = roots.managedRoot.appendingPathComponent("managed-install.json")
        if fm.fileExists(atPath: marker.path) {
            guard isValidMarker(marker) else { return .unmanaged(path: roots.managedRoot.path) }
            let current = (try? String(contentsOf: roots.managedRoot.appendingPathComponent("current-version"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .managed(currentVersion: current?.isEmpty == false ? current : nil)
        }
        // Install folder without marker: not Pi's layout, so not ours to touch.
        if fm.fileExists(atPath: roots.managedRoot.path) { return .unmanaged(path: roots.managedRoot.path) }
        let agent = roots.agentDirectory.resolvingSymlinksInPath().path + "/"
        for directory in roots.searchPath {
            let candidate = directory.appendingPathComponent("pi")
            let exists = fm.isExecutableFile(atPath: candidate.path) || (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) != nil
            guard exists else { continue }
            // A launcher pointing into ~/.pi/agent belongs to the (maybe incomplete) managed installation.
            if candidate.resolvingSymlinksInPath().path.hasPrefix(agent) { continue }
            return .unmanaged(path: candidate.path)
        }
        return .none
    }

    static func isValidMarker(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return marker["kind"] as? String == "pi-managed-install" && marker["schemaVersion"] as? Int == 1
            && marker["layout"] as? String == "releases-v1"
    }
}
