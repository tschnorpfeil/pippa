import Darwin
import Foundation

/// A model as listed in Pi's models.json under `providers["pippa-local"].models`.
public struct PiProviderModel: Sendable, Equatable {
    public var id: String
    public var name: String
    public var contextWindow: Int
    public var maxTokens: Int
    public init(id: String, name: String, contextWindow: Int, maxTokens: Int = 4096) {
        self.id = id; self.name = name; self.contextWindow = contextWindow; self.maxTokens = maxTokens
    }
    /// From Pippa's choice: id = catalog key (also the llama-server `--alias`), context as the server.
    public init(_ choice: ModelChoice) {
        self.init(id: choice.model.key, name: choice.model.label, contextWindow: choice.ctx)
    }
}

/// How Pippa starts the pinned Pi: Pippa's Node with the release's CLI, never the launcher or ~/.local/bin/pi.
/// For `PiRPCConfiguration`: executable, launcherArguments (before `--mode rpc`), piArguments (after), environment.
public struct PiLaunchSpec: Sendable, Equatable {
    public var executable: URL
    public var launcherArguments: [String]
    public var piArguments: [String]
    public var environment: [String: String]
}

/// Settings of one run. The installer asks no technical questions:
/// model folder and adopting existing models need no consent; the only question is the download
/// (`.needsDownload`), and the UI asks it.
public struct PiInstallOptions: Sendable {
    /// The model that should be ready; `nil` skips the model step.
    public var model: CatalogModel?
    /// Where to look for existing models; `nil` = old container, Pippa, ~/models, LM Studio, Ollama, Hugging Face ...
    public var modelSearchRoots: [ModelLocation]?
    public var providerModels: [PiProviderModel]
    public var port: Int
    public init(model: CatalogModel?, modelSearchRoots: [ModelLocation]? = nil, providerModels: [PiProviderModel], port: Int) {
        self.model = model; self.modelSearchRoots = modelSearchRoots; self.providerModels = providerModels; self.port = port
    }
}

/// The installer: detect -> Pi -> model folder -> model -> models.json -> ready. Every step is idempotent, writes
/// its state to install-state.json and can be repeated on its own ("Repair"). Foreign things stay untouched:
/// Pippa deletes and replaces only what is listed in `state.created`.
public final class PiInstaller: @unchecked Sendable {
    public static let providerKey = "pippa-local"
    public let roots: PiInstallRoots
    public private(set) var state: PiInstallState
    /// Order when adopting models; checks force e.g. the hardlink here.
    public var adoptionMethods: [PiAdoptionMethod] = [.clone, .hardlink, .copy]
    private let fm = FileManager.default

    public init(roots: PiInstallRoots) {
        self.roots = roots
        state = PiInstallState.load(from: roots.stateFile)
    }

    // MARK: Flow

    /// All steps in order; stops at the first one that needs a decision or fails.
    @discardableResult
    public func run(_ options: PiInstallOptions) -> [PiStepResult] {
        var results: [PiStepResult] = []
        for step in PiInstallStep.allCases {
            if step == .model && options.model == nil { continue }
            let result = perform(step, options)
            results.append(result)
            if !result.isDone { break }
        }
        return results
    }

    /// Re-run one step. "Detect" forgets the earlier layout decision.
    public func repair(_ step: PiInstallStep, _ options: PiInstallOptions) -> PiStepResult {
        if step == .detect { state.layout = nil; state.detection = nil }
        if step == .modelsFolder { state.modelsFolder = nil; state.modelsFolderShared = nil }
        return perform(step, options)
    }

    public func perform(_ step: PiInstallStep, _ options: PiInstallOptions) -> PiStepResult {
        switch step {
        case .detect: return detect()
        case .pi: return installPi()
        case .modelsFolder: return prepareModelsFolder()
        case .model:
            return options.model.map { provideModel($0, searchRoots: options.modelSearchRoots) }
                ?? finish(.model, .failed(.missingStep(.model)))
        case .provider:
            let result = writeProvider(models: options.providerModels, port: options.port)
            // Without the extension everything goes into Pippa; only `pi` in the terminal then does not start the server itself.
            if result.isDone { installTerminalExtension() }
            return result
        case .ready: return checkReady(modelIDs: options.providerModels.map(\.id), model: options.model)
        }
    }

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

    // MARK: 2. Pi

    public func installPi() -> PiStepResult {
        if state.layout == nil || state.pin != roots.pin { _ = detect() }
        guard let layout = state.layout else { return finish(.pi, .failed(.missingStep(.detect))) }
        begin(.pi)
        do {
            guard fm.fileExists(atPath: PiPayload.cliEntry(release: roots.payload.release).path),
                  fm.isExecutableFile(atPath: roots.payload.node.path) else { throw PiInstallFailure.payloadMissing(roots.payload.release.path) }
            let (release, reused) = try ensureRelease(root: roots.installRoot(layout))
            if layout == .official {
                try ensureOfficialLayout()
                advanceTerminalPi()
            }
            pruneReleases(root: roots.installRoot(layout))
            return finish(.pi, .piInstalled(layout: layout, release: release, reused: reused))
        } catch {
            return finish(.pi, .failed(failure(error, path: roots.installRoot(layout))))
        }
    }

    /// Create `releases/<pin>`: APFS clone of the payload to `staging/pippa-*`, check `--version` there, then rename
    /// (atomic). An existing release is only checked; it is replaced only if Pippa created it.
    func ensureRelease(root: URL) throws -> (URL, reused: Bool) {
        let pin = roots.pin
        let release = root.appendingPathComponent("releases/\(pin)", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        // Leftovers of an aborted run; Pi's own folders are named "update-*" and stay.
        for leftover in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        where leftover.lastPathComponent.hasPrefix("pippa-") {
            try fm.removeItem(at: leftover)
        }
        if fm.fileExists(atPath: release.path) {
            if (try? version(release: release)) == pin { return (release, true) }
            guard state.didCreate(release) else { throw PiInstallFailure.releaseBroken(release.path) }
            try fm.removeItem(at: release) // Pippa's own, damaged release
        }
        try makeDirectory(staging)
        let temporary = staging.appendingPathComponent("pippa-\(pin)-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: roots.payload.release, to: temporary) // APFS: clonefile, no extra space
        let found: String
        do { found = try version(release: temporary) } catch { try? fm.removeItem(at: temporary); throw error }
        guard found == pin else {
            try? fm.removeItem(at: temporary)
            throw PiInstallFailure.versionMismatch(found: found, expected: pin)
        }
        try makeDirectory(release.deletingLastPathComponent())
        try fm.moveItem(at: temporary, to: release)
        state.record(release)
        save()
        return (release, false)
    }

    /// Official layout next to the release: current-version, launcher, marker, ~/.local/bin/pi, Node for the terminal.
    /// Only what is missing; existing things stay as they are.
    func ensureOfficialLayout() throws {
        let root = roots.managedRoot
        let current = root.appendingPathComponent("current-version")
        if !fm.fileExists(atPath: current.path) {
            try "\(roots.pin)\n".write(to: current, atomically: true, encoding: .utf8)
            state.record(current)
        }
        if !fm.fileExists(atPath: roots.launcher.path) {
            try makeDirectory(roots.launcher.deletingLastPathComponent())
            try Self.launcherScript.write(to: roots.launcher, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roots.launcher.path)
            state.record(roots.launcher)
        }
        let marker = root.appendingPathComponent("managed-install.json")
        if !fm.fileExists(atPath: marker.path) {
            try Self.markerJSON(entrypoint: roots.entrypoint).write(to: marker, atomically: true, encoding: .utf8)
            state.record(marker)
        }
        save()
        // An existing ~/.local/bin/pi (even a broken symlink) belongs to someone else.
        if (try? fm.destinationOfSymbolicLink(atPath: roots.entrypoint.path)) == nil, !fm.fileExists(atPath: roots.entrypoint.path) {
            try makeDirectory(roots.entrypoint.deletingLastPathComponent())
            try fm.createSymbolicLink(atPath: roots.entrypoint.path, withDestinationPath: "../../.pi/agent/bin/pi")
            state.record(roots.entrypoint)
            save()
        }
        try ensurePiNode()
    }

    /// Node (and npm) under ~/.local/share/pi-node/<version>, `current` points to it. The launcher puts it before
    /// PATH; without it `pi` in the terminal would find no Node on a fresh Mac.
    /// If a new Pippa ships a different Node, a `current` created by Pippa follows (next to the old one,
    /// switched atomically via rename); a foreign `current` stays.
    func ensurePiNode() throws {
        let current = roots.piNode.appendingPathComponent("current")
        let existing = try? fm.destinationOfSymbolicLink(atPath: current.path)
        if existing == nil, fm.fileExists(atPath: current.path) { return }
        if existing != nil, !state.didCreate(current) { return }
        guard let nodeVersion = Self.run(roots.payload.node, ["--version"], environment: [:])?.output
            .trimmingCharacters(in: .whitespacesAndNewlines), nodeVersion.hasPrefix("v") else {
            throw PiInstallFailure.payloadMissing(roots.payload.node.path)
        }
        let target = roots.piNode.appendingPathComponent(nodeVersion, isDirectory: true)
        if !fm.fileExists(atPath: target.path) {
            try makeDirectory(roots.piNode)
            for leftover in (try? fm.contentsOfDirectory(at: roots.piNode, includingPropertiesForKeys: nil)) ?? []
            where leftover.lastPathComponent.hasPrefix(".pippa-") { try fm.removeItem(at: leftover) }
            let temporary = roots.piNode.appendingPathComponent(".pippa-\(nodeVersion)-\(UUID().uuidString)", isDirectory: true)
            let bin = temporary.appendingPathComponent("bin", isDirectory: true)
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.copyItem(at: roots.payload.node, to: bin.appendingPathComponent("node"))
            if let npm = roots.payload.npm, fm.fileExists(atPath: npm.path) {
                let modules = temporary.appendingPathComponent("lib/node_modules", isDirectory: true)
                try fm.createDirectory(at: modules, withIntermediateDirectories: true)
                try fm.copyItem(at: npm, to: modules.appendingPathComponent("npm"))
                try fm.createSymbolicLink(atPath: bin.appendingPathComponent("npm").path, withDestinationPath: "../lib/node_modules/npm/bin/npm-cli.js")
                try fm.createSymbolicLink(atPath: bin.appendingPathComponent("npx").path, withDestinationPath: "../lib/node_modules/npm/bin/npx-cli.js")
            }
            try fm.moveItem(at: temporary, to: target)
            state.record(target)
        }
        if existing == nodeVersion { return }
        let link = roots.piNode.appendingPathComponent(".pippa-current-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: nodeVersion)
        guard rename(link.path, current.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: link)
            throw PiInstallFailure.notWritable(path: current.path, reason: SystemError.reason(errno: code))
        }
        state.record(current)
        save()
    }

    // MARK: Pi switch with a Pippa update

    /// The terminal Pi in the official layout that Pippa created follows the pin: only if `current-version`
    /// points to a release Pippa created itself and that is older than the pin. If the person switched
    /// themselves (`pi update`, even to a newer version), everything stays as it is. Switch is atomic (rename),
    /// then `pi --version` via the launcher as in the terminal; if that fails, the old version applies again.
    /// Pippa's own sessions do not depend on this: they always start `releases/<pin>` directly (`launchSpec`).
    @discardableResult
    func advanceTerminalPi() -> Bool {
        let file = roots.managedRoot.appendingPathComponent("current-version")
        guard state.didCreate(file),
              let current = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
              current != roots.pin, Self.isOlder(current, than: roots.pin),
              state.didCreate(roots.managedRoot.appendingPathComponent("releases/\(current)", isDirectory: true)) else { return false }
        guard (try? writeCurrentVersion(roots.pin, to: file)) != nil else { return false }
        let found = Self.run(roots.launcher, ["--version"], environment: ["HOME": roots.home.path, "PATH": "/usr/bin:/bin"])?
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        if found == roots.pin { return true }
        try? writeCurrentVersion(current, to: file)
        return false
    }

    /// Like Pi's `activateManagedRelease`: temporary file next to it, then rename.
    func writeCurrentVersion(_ version: String, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent("current-version.pippa-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try "\(version)\n".write(to: temporary, atomically: false, encoding: .utf8)
        guard rename(temporary.path, file.path) == 0 else {
            throw PiInstallFailure.notWritable(path: file.path, reason: SystemError.reason(errno: errno))
        }
    }

    /// Removes releases that Pippa created itself and nobody needs anymore. Kept: the pin, the previous pin
    /// (running terminal sessions, going back) and whatever `current-version` names. Foreign releases (Pi's
    /// installer, `pi update`) always stay.
    func pruneReleases(root: URL) {
        let releases = root.appendingPathComponent("releases", isDirectory: true)
        let active = (try? String(contentsOf: root.appendingPathComponent("current-version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let keep = Set([roots.pin, state.previousPin, active].compactMap { $0 })
        var changed = false
        for entry in (try? fm.contentsOfDirectory(at: releases, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(entry.lastPathComponent) && state.didCreate(entry) {
            guard (try? fm.removeItem(at: entry)) != nil else { continue }
            state.forget(entry)
            changed = true
        }
        if changed { save() }
    }

    /// `a` < `b` for versions of the form x.y.z; anything else (prereleases, unreadable) does not count as older.
    static func isOlder(_ a: String, than b: String) -> Bool {
        let parse = { (s: String) -> [Int]? in
            let parts = s.split(separator: ".").map { Int($0) }
            return parts.count == 3 && parts.allSatisfy { $0 != nil } ? parts.map { $0! } : nil
        }
        guard let x = parse(a), let y = parse(b) else { return false }
        return x.lexicographicallyPrecedes(y)
    }

    /// `pi --version` of a release with Pippa's Node (like Pi's own check `verifyManagedRelease`: stdout, trimmed).
    func version(release: URL) throws -> String {
        let cli = PiPayload.cliEntry(release: release)
        guard fm.fileExists(atPath: cli.path) else { throw PiInstallFailure.versionMismatch(found: "", expected: roots.pin) }
        guard let result = Self.run(roots.payload.node, [cli.path, "--version"], environment: Self.baseEnvironment(roots)),
              result.status == 0 else { throw PiInstallFailure.versionMismatch(found: "", expected: roots.pin) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Start

    /// Environment for every Pi start: no network at start, no telemetry, Pippa's Node first in PATH.
    public static func baseEnvironment(_ roots: PiInstallRoots) -> [String: String] {
        ["HOME": roots.home.path,
         "PATH": roots.payload.node.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin",
         "PI_TELEMETRY": "0", "PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1"]
    }

    /// Start of the pinned release for PiRPCClient. `nil` until the "Pi" step has run. Pi reads the llama-server
    /// key itself from the key file (`apiKey: "!/bin/cat ..."` in models.json), as in the terminal.
    public func launchSpec(modelID: String) -> PiLaunchSpec? {
        guard let layout = state.layout else { return nil }
        let release = roots.release(layout)
        guard fm.fileExists(atPath: PiPayload.cliEntry(release: release).path) else { return nil }
        var environment = Self.baseEnvironment(roots)
        if layout != .pippaRoot { environment["PI_MANAGED_INSTALL_ROOT"] = roots.managedRoot.path }
        return PiLaunchSpec(executable: roots.payload.node, launcherArguments: [PiPayload.cliEntry(release: release).path],
                            piArguments: ["--provider", Self.providerKey, "--model", modelID], environment: environment)
    }

    /// Fixed port for llama-server and models.json: chosen freely once, then remembered in Pippa's settings.json.
    public static func stablePort(support: URL) -> Int {
        var settings = PippaSettings.load(from: support)
        if let port = settings.llamaPort { return port }
        let port = LlamaServer.freePort()
        settings.llamaPort = port
        try? settings.save(to: support)
        return port
    }

    /// Fixed key for llama-server and `pippa-local`: generated randomly once, then stored in `<Support>/llama-key`
    /// (mode 0600, only the person themselves). Pi in the terminal reads it via `apiKey: "!/bin/cat ..."`; so the
    /// key is never in models.json and needs no environment variable. Too-wide permissions are reset to 0600.
    public static func stableKey(support: URL) throws -> String {
        let fm = FileManager.default
        let url = keyFile(support: support)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.count >= 32 {
                let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                if mode & 0o077 != 0 { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
                return key
            }
        }
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        let temporary = support.appendingPathComponent(".llama-key-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: Data((key + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: errno))
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: code))
        }
        return key
    }

    public static func keyFile(support: URL) -> URL { support.appendingPathComponent("llama-key") }

    // MARK: 3. Model folder

    /// No question: `~/Library/Application Support/Pippa/models`, invisible and
    /// no clutter in the user folder. If `~/models` already exists (e.g. created for llama.cpp or Pi in the terminal),
    /// Pippa uses that folder too. A folder chosen once stays.
    public func prepareModelsFolder() -> PiStepResult {
        begin(.modelsFolder)
        let folder: URL, shared: Bool
        if let path = state.modelsFolder, let wasShared = state.modelsFolderShared, fm.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path, isDirectory: true); shared = wasShared
        } else {
            shared = Self.isDirectory(roots.sharedModels)
            folder = shared ? roots.sharedModels : roots.pippaModels
        }
        do {
            try makeDirectory(folder)
            if !shared { ModelDownloader(directory: folder).excludeFromBackup() }
        } catch { return finish(.modelsFolder, .failed(failure(error, path: folder))) }
        state.modelsFolder = folder.path
        state.modelsFolderShared = shared
        return finish(.modelsFolder, .modelsFolder(folder, shared: shared))
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    // MARK: 4. Model

    /// Is the model verified in the model folder? Otherwise adopt without asking (clone -> hardlink -> copy, the copy only
    /// with enough free space), otherwise `.needsDownload` (then `downloadModel`). Originals are never moved,
    /// changed or deleted.
    public func provideModel(_ model: CatalogModel, searchRoots: [ModelLocation]? = nil) -> PiStepResult {
        begin(.model)
        guard let path = state.modelsFolder else { return finish(.model, .failed(.missingStep(.modelsFolder))) }
        guard let files = model.pinned?.files, !files.isEmpty else { return finish(.model, .failed(.missingStep(.model))) }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let downloader = ModelDownloader(directory: folder)
        let found = ExistingModels.find(ModelCatalog(sampling: [:], models: [model]), roots: modelSearchRoots(folder: folder, extra: searchRoots))
        var lastMethod: PiAdoptionMethod?, lastSource: String?, missing: Int64 = 0
        do {
            for file in files where !downloader.isInstalled(file) {
                let dest = downloader.localURL(file)
                if fm.fileExists(atPath: dest.path) {
                    // Already there (e.g. placed in ~/models by the person): only check, never replace.
                    guard ModelDownloader.fileSize(dest) == file.size, try ModelDownloader.sha256(of: dest) == file.sha256 else {
                        return finish(.model, .failed(.checksumMismatch(dest.path)))
                    }
                    try file.sha256.write(to: dest.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
                    state.record(dest.appendingPathExtension("ok"))
                    continue
                }
                guard let source = found[file.sha256] else { missing += file.size; continue }
                switch try adopt(file, from: source, into: folder) {
                case .adopted(let method): lastMethod = method; lastSource = source.source
                case .unavailable: missing += file.size
                case .mismatch: return finish(.model, .failed(.checksumMismatch(source.url.path)))
                }
            }
        } catch { return finish(.model, .failed(failure(error, path: folder))) }
        if missing > 0 { return finish(.model, .needsDownload(bytes: missing)) }
        return finish(.model, .modelReady(file: downloader.primaryFile(model) ?? folder, method: lastMethod, source: lastSource))
    }

    /// Downloads a model's files into a folder; `progress(0...1, remaining seconds)`. Default: `ModelDownloader`.
    public typealias Download = @Sendable (_ model: CatalogModel, _ folder: URL,
                                           _ progress: @escaping @Sendable (Double, TimeInterval?) -> Void) async throws -> Void

    public static let modelDownloader: Download = { model, folder, progress in
        try await ModelDownloader(directory: folder).download(model, progress: progress)
    }

    /// After "Download": hand over to the ModelDownloader (resumable, SHA-256, space check), then check again.
    /// `download` only for checks and recordings (no real download).
    public func downloadModel(_ model: CatalogModel, using download: Download = PiInstaller.modelDownloader,
                              progress: @escaping @Sendable (Double, TimeInterval?) -> Void) async -> PiStepResult {
        guard let path = state.modelsFolder else { return finish(.model, .failed(.missingStep(.modelsFolder))) }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        do { try await download(model, folder, progress) }
        catch let error as PippaError {
            switch error {
            case .notEnoughSpace(let bytes): return finish(.model, .failed(.notEnoughSpace(bytes: bytes)))
            case .checksumMismatch: return finish(.model, .failed(.checksumMismatch(path)))
            case .writeFailed: return finish(.model, .failed(.notWritable(path: path, reason: error.localizedDescription)))
            default: return finish(.model, .failed(.downloadFailed(error.localizedDescription)))
            }
        } catch let error as PiInstallFailure {
            return finish(.model, .failed(error))
        } catch {
            if ModelDownloader.isOutOfSpace(error) { return finish(.model, .failed(.notEnoughSpace(bytes: ModelDownloader.spaceBuffer))) }
            let code = error as NSError   // for "Details": technical cause, not the everyday wording
            return finish(.model, .failed(.downloadFailed("\(code.domain) \(code.code): \(code.localizedDescription)")))
        }
        return provideModel(model, searchRoots: [])
    }

    func modelSearchRoots(folder: URL, extra: [ModelLocation]?) -> [ModelLocation] {
        var result = [ModelLocation(url: roots.containerModels, source: "Pippa")]
        for (url, source) in [(roots.pippaModels, "Pippa"), (roots.sharedModels, "~/models")]
        where url.standardizedFileURL != folder.standardizedFileURL {
            result.append(ModelLocation(url: url, source: source))
        }
        return result + (extra ?? ExistingModels.defaultRoots(home: roots.home))
    }

    /// `unavailable`: neither clone nor hardlink nor copy worked (e.g. copy without enough space); then it downloads.
    enum Adoption { case adopted(PiAdoptionMethod), unavailable, mismatch }

    func adopt(_ file: CatalogModel.File, from source: ModelLocation, into folder: URL) throws -> Adoption {
        let dest = folder.appendingPathComponent((file.path as NSString).lastPathComponent)
        let temporary = dest.appendingPathExtension("import")
        try? fm.removeItem(at: temporary) // leftover of an aborted adoption (Pippa's own file or link)
        var method: PiAdoptionMethod?
        for candidate in adoptionMethods {
            switch candidate {
            case .clone where clonefile(source.url.path, temporary.path, UInt32(CLONE_NOFOLLOW)) == 0: method = .clone
            case .hardlink where link(source.url.path, temporary.path) == 0: method = .hardlink
            case .copy:
                // Other volume: the copy needs real space. If it is not enough, download instead (the download checks
                // the space itself and says so in one sentence).
                if !ModelDownloader.sameVolume(source.url, folder),
                   ModelDownloader.spaceShortfall(available: ModelDownloader.availableSpace(at: folder), remaining: file.size) != nil {
                    continue
                }
                guard (try? fm.copyItem(at: source.url, to: temporary)) != nil else { try? fm.removeItem(at: temporary); continue }
                method = .copy
            default: continue
            }
            if method != nil { break }
        }
        guard let method else { return .unavailable }
        let hash: String
        do { hash = try ModelDownloader.sha256(of: temporary) } catch { try? fm.removeItem(at: temporary); throw error }
        guard hash == file.sha256, ModelDownloader.fileSize(temporary) == file.size else {
            try? fm.removeItem(at: temporary) // only our copy or link; the original stays
            return .mismatch
        }
        try fm.moveItem(at: temporary, to: dest)
        try file.sha256.write(to: dest.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
        state.record(dest); state.record(dest.appendingPathExtension("ok"))
        state.adopted.append(.init(file: dest.path, source: source.url.path, method: method, sha256: file.sha256))
        save()
        return .adopted(method)
    }

    // MARK: 5. models.json

    /// Write only `providers["pippa-local"]` (merge), atomically via a temporary file, with one backup first.
    /// If the file is not readable JSON (also: comments, which Pi allows), it stays unchanged.
    public func writeProvider(models: [PiProviderModel], port: Int) -> PiStepResult {
        begin(.provider)
        let url = roots.modelsJSON
        var document: [String: Any] = [:]
        var existed = false
        if fm.fileExists(atPath: url.path) {
            existed = true
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["providers"] == nil || object["providers"] is [String: Any] else {
                return finish(.provider, .failed(.modelsJSONUnreadable(url.path)))
            }
            document = object
        }
        var providers = document["providers"] as? [String: Any] ?? [:]
        let keyFile = Self.keyFile(support: roots.support)
        do {
            let had = fm.fileExists(atPath: keyFile.path)
            _ = try Self.stableKey(support: roots.support)
            if !had { state.record(keyFile); save() }
        } catch { return finish(.provider, .failed(failure(error, path: keyFile))) }
        let entry = Self.providerEntry(models: models, port: port, keyFile: keyFile)
        if let current = providers[Self.providerKey], Self.canonical(current) == Self.canonical(entry) {
            state.providerPort = port
            return finish(.provider, .providerWritten(port: port, backup: state.modelsJSONBackup.map(URL.init(fileURLWithPath:)), changed: false))
        }
        providers[Self.providerKey] = entry
        document["providers"] = providers
        do {
            try makeDirectory(url.deletingLastPathComponent())
            if existed, state.modelsJSONBackup == nil {
                let stamp = Self.stampFormatter.string(from: Date())
                let backup = url.deletingLastPathComponent().appendingPathComponent("models.json.pippa-\(stamp).bak")
                try fm.copyItem(at: url, to: backup)
                state.modelsJSONBackup = backup.path
                state.record(backup)
            }
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".models.json.pippa-\(UUID().uuidString)")
            try (data + Data("\n".utf8)).write(to: temporary)
            let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else {
                let code = errno
                try? fm.removeItem(at: temporary)
                throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: code))
            }
            if !existed { state.record(url) }
        } catch { return finish(.provider, .failed(failure(error, path: url))) }
        state.providerPort = port
        return finish(.provider, .providerWritten(port: port, backup: state.modelsJSONBackup.map(URL.init(fileURLWithPath:)), changed: true))
    }

    /// Model ids of `pippa-local` in a models.json (empty if unreadable or not listed).
    public static func providerModelIDs(modelsJSON: URL) -> [String] {
        let providers = (try? Data(contentsOf: modelsJSON))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["providers"] as? [String: Any]
        return ((providers?[providerKey] as? [String: Any])?["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    /// Port from `baseUrl` of `pippa-local` (the app starts its server exactly there). `nil`: not listed.
    public static func providerPort(modelsJSON: URL) -> Int? {
        (provider(modelsJSON: modelsJSON)?["baseUrl"] as? String).flatMap(URL.init(string:))?.port
    }

    /// `contextWindow` of a model of `pippa-local`.
    public static func providerContextWindow(modelsJSON: URL, id: String) -> Int? {
        (provider(modelsJSON: modelsJSON)?["models"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["contextWindow"] as? Int
    }

    static func provider(modelsJSON: URL) -> [String: Any]? {
        let providers = (try? Data(contentsOf: modelsJSON))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["providers"] as? [String: Any]
        return providers?[providerKey] as? [String: Any]
    }

    /// Compatible endpoint (Pi docs models.md): fixed port, key via `!command` from the key file.
    /// Pi 1.0.4 (`resolveConfigValueOrThrow`): a value with a leading `!` runs via `/bin/sh -c` (execSync, 10 s
    /// timeout), trimmed stdout is the key; for models.json **fresh on every request, no cache**. The path
    /// is in single quotes (`Application Support` has a space), `cat` with absolute path so that
    /// a foreign `cat` in the terminal's PATH changes nothing.
    public static func providerEntry(models: [PiProviderModel], port: Int, keyFile: URL) -> [String: Any] {
        ["baseUrl": "http://127.0.0.1:\(port)/v1", "api": "openai-completions", "apiKey": "!/bin/cat " + shellQuoted(keyFile.path),
         "models": models.map { ["id": $0.id, "name": $0.name, "contextWindow": $0.contextWindow, "maxTokens": $0.maxTokens] as [String: Any] }]
    }

    /// For `/bin/sh`: in single quotes, a `'` inside as `'\\''`.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func canonical(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

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

    // MARK: 6. Ready

    /// Checks without changing anything: Pi reports the pin, models.json lists the models, the model is there verified.
    public func checkReady(modelIDs: [String], model: CatalogModel?) -> PiStepResult {
        begin(.ready)
        guard let layout = state.layout else { return finish(.ready, .failed(.missingStep(.detect))) }
        let found = (try? version(release: roots.release(layout))) ?? ""
        guard found == roots.pin else { return finish(.ready, .failed(.versionMismatch(found: found, expected: roots.pin))) }
        let listed = Self.providerModelIDs(modelsJSON: roots.modelsJSON)
        guard modelIDs.allSatisfy(listed.contains) else { return finish(.ready, .failed(.missingStep(.provider))) }
        if let model {
            guard let path = state.modelsFolder, ModelDownloader(directory: URL(fileURLWithPath: path)).isInstalled(model) else {
                return finish(.ready, .failed(.missingStep(.model)))
            }
        }
        return finish(.ready, .ready(version: found))
    }

    // MARK: Helpers

    /// Creates missing folders and remembers each one (to uninstall exactly what was created).
    func makeDirectory(_ url: URL) throws {
        var missing: [URL] = []
        var probe = url.standardizedFileURL
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            missing.append(probe); probe = probe.deletingLastPathComponent()
        }
        for directory in missing.reversed() {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            state.record(directory)
        }
        if !missing.isEmpty { save() }
    }

    private func begin(_ step: PiInstallStep) {
        state.steps[step.rawValue] = .init(status: "started", at: Date())
        save()
    }

    @discardableResult
    private func finish(_ step: PiInstallStep, _ outcome: PiStepResult.Outcome) -> PiStepResult {
        let result = PiStepResult(step: step, outcome: outcome, message: Self.message(outcome))
        let status = switch outcome {
        case .failed: "failed"
        default: result.isDone ? "done" : "needsInput"
        }
        state.steps[step.rawValue] = .init(status: status, at: Date())
        save()
        return result
    }

    private func save() { try? state.save(to: roots.stateFile) }

    private func failure(_ error: Error, path: URL) -> PiInstallFailure {
        if let failure = error as? PiInstallFailure { return failure }
        if ModelDownloader.isOutOfSpace(error) { return .notEnoughSpace(bytes: ModelDownloader.spaceBuffer) }
        return .notWritable(path: path.path, reason: SystemError.reason(error))
    }

    /// Process with timeout; `nil` if it does not start or hangs.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 60) -> (status: Int32, output: String)? {
        let process = Process(), out = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty { process.environment = environment }
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if done.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); return nil }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Files in the official layout

    /// Pi's launcher (~/.pi/agent/bin/pi), content as from Pi's installer (layout releases-v1).
    public static let launcherScript = #"""
    #!/bin/sh
    case "$0" in
      */*) pi_launcher="$0" ;;
      *) pi_launcher=$(command -v "$0") || exit 127 ;;
    esac
    while [ -L "$pi_launcher" ]; do
      pi_link=$(readlink "$pi_launcher") || exit 1
      case "$pi_link" in
        /*) pi_launcher="$pi_link" ;;
        *) pi_launcher=${pi_launcher%/*}/$pi_link ;;
      esac
    done
    pi_bin_dir=${pi_launcher%/*}
    pi_agent_dir=${pi_bin_dir%/*}
    pi_current_file=$pi_agent_dir/install/current-version
    if ! IFS= read -r pi_current_version < "$pi_current_file"; then
      printf 'Could not read managed Pi version from %s.\n' "$pi_current_file" >&2
      exit 1
    fi
    case "$pi_current_version" in
      ""|.|..|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*)
        printf 'Managed Pi version file is invalid: %s\n' "$pi_current_file" >&2
        exit 1
        ;;
    esac
    pi_release_dir=$pi_agent_dir/install/releases/$pi_current_version
    pi_release_bin=$pi_release_dir/node_modules/.bin/pi
    if [ ! -x "$pi_release_bin" ]; then
      printf 'Managed Pi executable is missing: %s\n' "$pi_release_bin" >&2
      exit 1
    fi
    # Node.js installed by the Pi installer is not added to shell profiles, so put
    # it on PATH for pi's shebang and for child processes: npm in pi update and
    # commands run through pi's bash tool.
    pi_node_bin=${XDG_DATA_HOME:-$HOME/.local/share}/pi-node/current/bin
    if [ -x "$pi_node_bin/node" ]; then
      PATH=$pi_node_bin:$PATH
      export PATH
    fi
    PI_MANAGED_INSTALL_ROOT=$pi_agent_dir/install
    export PI_MANAGED_INSTALL_ROOT
    exec "$pi_release_bin" "$@"

    """#

    /// managed-install.json as from Pi's installer.
    static func markerJSON(entrypoint: URL) -> String {
        """
        {
          "kind": "pi-managed-install",
          "schemaVersion": 1,
          "layout": "releases-v1",
          "entrypoint": {
            "type": "symlink",
            "path": "\(entrypoint.path)"
          }
        }

        """
    }
}
