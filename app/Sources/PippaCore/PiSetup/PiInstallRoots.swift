import Foundation

// Pippa copies the bundled, pinned Pi release to Pi's default location, sets up the model folder, adopts or downloads
// the model and registers itself as provider `pippa-local` in Pi's models.json. Every path hangs off `PiInstallRoots`, so
// checks run against a fake HOME (.build/fake-home-*), never the real one.

/// The install payload: the pinned release in layout `releases-v1` (scripts/bundle-pi-payload.sh) and Pippa's Node.
public struct PiPayload: Sendable, Equatable {
    /// Folder with package.json, package-lock.json, metadata.json and node_modules (incl. `.bin/pi`).
    public var release: URL
    /// Pippa's own Node (in the app: Contents/Helpers/node).
    public var node: URL
    /// npm from the same Node archive (lib/node_modules/npm), for `pi update` in the terminal. May be missing.
    public var npm: URL?
    /// Version from release/metadata.json, e.g. "1.0.4".
    public var version: String

    public init(release: URL, node: URL, npm: URL? = nil) throws {
        let metadata = release.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadata),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty else { throw PiInstallFailure.payloadMissing(release.path) }
        self.release = release; self.node = node; self.npm = npm; self.version = version
    }

    /// Payload in the app: Contents/Resources/pi-payload, Node in Contents/Helpers.
    public static func inApp(_ bundle: URL) throws -> PiPayload {
        let base = bundle.appendingPathComponent("Contents/Resources/pi-payload", isDirectory: true)
        return try PiPayload(release: base.appendingPathComponent("release", isDirectory: true),
                             node: bundle.appendingPathComponent("Contents/Helpers/node"),
                             npm: base.appendingPathComponent("lib/node_modules/npm", isDirectory: true))
    }

    /// Payload from `bundle-pi-payload.sh <folder> --with-node` (development, checks): Node in <folder>/bin/node.
    public static func inDirectory(_ directory: URL) throws -> PiPayload {
        try PiPayload(release: directory.appendingPathComponent("release", isDirectory: true),
                      node: directory.appendingPathComponent("bin/node"),
                      npm: directory.appendingPathComponent("lib/node_modules/npm", isDirectory: true))
    }

    /// For development PIPPA_PI_PAYLOAD (folder as with `inDirectory`), otherwise the payload in the running app.
    public static func locate(bundle: URL = Bundle.main.bundleURL,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> PiPayload? {
        if let path = environment["PIPPA_PI_PAYLOAD"], !path.isEmpty { return try? inDirectory(URL(fileURLWithPath: path)) }
        return try? inApp(bundle)
    }

    /// Pippa's terminal extension in the payload (`<payload>/extensions/pippa-local-server`, scripts/bundle-pi-payload.sh):
    /// starts `pippa-local`'s llama-server when `pi` needs it in the terminal. `nil` if missing.
    public var terminalExtension: URL? {
        let url = release.deletingLastPathComponent().appendingPathComponent("extensions/\(PiInstaller.terminalExtensionName)", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("index.ts").path) ? url : nil
    }

    /// Entry point of the CLI in the release (the target of node_modules/.bin/pi).
    public static func cliEntry(release: URL) -> URL {
        release.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")
    }
}

/// All places the installer reads or writes. Default: the real user directory.
public struct PiInstallRoots: Sendable {
    public var home: URL
    /// Pippa's support folder (~/Library/Application Support/Pippa): install-state.json, own Pi root folder, models.
    public var support: URL
    public var payload: PiPayload
    /// Where a foreign `pi` might be (npm global, Homebrew, Nix). An app started from Finder has no login PATH.
    public var searchPath: [URL]

    public init(home: URL = ExistingModels.realHome, support: URL? = nil, payload: PiPayload, searchPath: [URL]? = nil) {
        self.home = home
        self.support = support ?? home.appendingPathComponent("Library/Application Support/Pippa", isDirectory: true)
        self.payload = payload
        self.searchPath = searchPath ?? Self.defaultSearchPath(home: home)
    }

    public static func defaultSearchPath(home: URL) -> [URL] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin"].map { URL(fileURLWithPath: $0) }
            + [".npm-global/bin", ".nix-profile/bin", ".volta/bin", ".bun/bin", ".local/bin"].map { home.appendingPathComponent($0) }
    }

    public var pin: String { payload.version }
    /// ~/.pi/agent: Pi's configuration, shared with the terminal.
    public var agentDirectory: URL { home.appendingPathComponent(".pi/agent", isDirectory: true) }
    /// Pi's managed install folder (layout releases-v1).
    public var managedRoot: URL { agentDirectory.appendingPathComponent("install", isDirectory: true) }
    /// Pi's launcher; ~/.local/bin/pi points to it.
    public var launcher: URL { agentDirectory.appendingPathComponent("bin/pi") }
    public var entrypoint: URL { home.appendingPathComponent(".local/bin/pi") }
    /// Node for the terminal launcher (`${XDG_DATA_HOME:-~/.local/share}/pi-node/current/bin`). XDG_DATA_HOME is ignored.
    public var piNode: URL { home.appendingPathComponent(".local/share/pi-node", isDirectory: true) }
    /// Own root folder when a foreign-installed `pi` exists.
    public var pippaRoot: URL { support.appendingPathComponent("pi", isDirectory: true) }
    public var modelsJSON: URL { agentDirectory.appendingPathComponent("models.json") }
    /// Pi's folder for the person's extensions; Pippa's terminal extension lives in it as its own folder.
    public var extensionsDirectory: URL { agentDirectory.appendingPathComponent("extensions", isDirectory: true) }
    public var stateFile: URL { support.appendingPathComponent("install-state.json") }
    /// Key of the llama-server for `pippa-local` (0600), see `PiInstaller.stableKey`.
    public var llamaKeyFile: URL { PiInstaller.keyFile(support: support) }
    /// Shared model folder as in Pi's docs (llama-cpp.md), after one-time consent.
    public var sharedModels: URL { home.appendingPathComponent("models", isDirectory: true) }
    public var pippaModels: URL { support.appendingPathComponent("models", isDirectory: true) }
    /// Models of the old sandbox app.
    public var containerModels: URL {
        home.appendingPathComponent("Library/Containers/io.github.tschnorpfeil.pippa/Data/Library/Application Support/Pippa/models", isDirectory: true)
    }

    /// Root of the chosen layout (contains `releases/<pin>`).
    public func installRoot(_ layout: PiLayout) -> URL { layout == .pippaRoot ? pippaRoot : managedRoot }
    public func release(_ layout: PiLayout) -> URL {
        installRoot(layout).appendingPathComponent("releases/\(pin)", isDirectory: true)
    }
}
