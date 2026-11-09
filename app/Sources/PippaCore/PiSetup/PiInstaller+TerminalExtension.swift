import Foundation

extension PiInstaller {
    // MARK: Terminal extension

    public static let terminalExtensionName = "pippa-local-server"
    /// Lives in Pippa's extension folder; that is how the installer recognizes its own (foreign ones of the same name stay).
    public static let terminalExtensionMarker = ".pippa-managed"

    public enum TerminalExtensionOutcome: Equatable, Sendable { case installed, updated, unchanged, foreign, unavailable, failed(String) }

    /// Copies the terminal extension from the payload to `~/.pi/agent/extensions/pippa-local-server` (as in Pi's docs:
    /// folder with `index.ts`) or brings Pippa's own copy up to the payload's state. Replacing is atomic via rename; the
    /// intermediate copy lies outside `extensions/` so that a concurrently starting Pi does not load it.
    @discardableResult
    public func installTerminalExtension() -> TerminalExtensionOutcome {
        guard let source = roots.payload.terminalExtension else { return .unavailable }
        let dest = roots.extensionsDirectory.appendingPathComponent(Self.terminalExtensionName, isDirectory: true)
        let marker = dest.appendingPathComponent(Self.terminalExtensionMarker)
        let exists = fm.fileExists(atPath: dest.path)
        if exists {
            guard fm.fileExists(atPath: marker.path) || state.didCreate(dest) else { return .foreign }
            if Self.sameFiles(source, dest) { return .unchanged }
        }
        do {
            try makeDirectory(roots.extensionsDirectory)
            let staging = roots.agentDirectory.appendingPathComponent(".pippa-extension-\(UUID().uuidString)", isDirectory: true)
            try fm.copyItem(at: source, to: staging)
            try "Installed and updated by Pippa. Local changes are replaced on the next update.\n"
                .write(to: staging.appendingPathComponent(Self.terminalExtensionMarker), atomically: true, encoding: .utf8)
            if exists {
                let old = roots.agentDirectory.appendingPathComponent(".pippa-extension-old-\(UUID().uuidString)", isDirectory: true)
                try fm.moveItem(at: dest, to: old)
                do { try fm.moveItem(at: staging, to: dest) } catch { try? fm.moveItem(at: old, to: dest); try? fm.removeItem(at: staging); throw error }
                try? fm.removeItem(at: old) // Pippa's own old copy
            } else {
                try fm.moveItem(at: staging, to: dest)
                state.record(dest)
                save()
            }
            return exists ? .updated : .installed
        } catch {
            return .failed(SystemError.reason(error))
        }
    }

    /// Same files (names and content) in both folders, ignoring Pippa's marker.
    static func sameFiles(_ a: URL, _ b: URL) -> Bool {
        func files(_ root: URL) -> [String: Data] {
            var out: [String: Data] = [:]
            let base = root.standardizedFileURL.path + "/"
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
            for case let url as URL in walk where url.lastPathComponent != terminalExtensionMarker {
                if let data = try? Data(contentsOf: url) { out[url.standardizedFileURL.path.replacingOccurrences(of: base, with: "")] = data }
            }
            return out
        }
        return files(a) == files(b)
    }
}
