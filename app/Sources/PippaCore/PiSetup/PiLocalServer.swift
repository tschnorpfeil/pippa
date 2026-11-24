import Foundation

// What the oMLX server for Pi's provider `pippa-local` starts with; `OMLXServer` runs it. One server for the app and
// for Pi in the terminal (docs/omlx-switch.md).
//
// - Runtime: `<Support>/mlx-runtime/<version>/bin/python3` (`MLXRuntime`).
// - Base folder `<Support>/omlx`: Pippa writes its settings.json (port, key, model folder, idle unload); models in
//   `<Support>/omlx/models/<key>/`, oMLX's prefix cache in `<Support>/omlx/cache`.
// - Port: fixed, from Pippa's settings.json (`PiInstaller.stablePort`), must match `baseUrl` in models.json.
// - Key: from the 0600 key file that Pi also reads via `apiKey: "!/bin/cat …"` (`PiInstaller.stableKey`).
public enum PiLocalServer {
    /// oMLX unloads the model after this long without a request; the next request loads it again (a few seconds).
    public static let idleUnloadSeconds = 600
    public static let logName = "local-server.log"

    public struct Plan: Sendable, Equatable {
        public var choice: ModelChoice
        public var python: URL
        public var baseDirectory: URL
        public var port: Int
        public var key: String
        /// Model id in models.json and the model's folder name, which is the id oMLX serves it under.
        public var modelID: String
        /// Lock file shared with the terminal extension (`PiServerLock`).
        public var lockFile: URL
        /// Key file (0600) from which Pi also reads the key.
        public var keyFile: URL

        public var arguments: [String] {
            ["-c", "from omlx.cli import main; main()", "serve", "--base-path", baseDirectory.path, "--headless"]
        }
        public var settingsFile: URL { baseDirectory.appendingPathComponent("settings.json") }
        public var modelSettingsFile: URL { baseDirectory.appendingPathComponent("model_settings.json") }
        public var modelsDirectory: URL { baseDirectory.appendingPathComponent("models", isDirectory: true) }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case runtimeMissing
        case unknownModel(String)
        case modelMissing(String)
        case portMismatch(modelsJSON: Int, settings: Int)

        public var errorDescription: String? {
            switch self {
            case .runtimeMissing: "Pippas KI-Laufzeit fehlt. Öffne Pippa; die Einrichtung lädt sie."
            case .unknownModel(let id): "Modell \(id) steht nicht mehr in Pippas Katalog. Öffne Pippa; die Einrichtung holt das aktuelle Modell."
            case .modelMissing(let id): "Modell \(id) liegt nicht in Pippas Modellordner."
            case .portMismatch(let a, let b): "Port in models.json (\(a)) passt nicht zu Pippas Einstellungen (\(b)); Installer-Schritt „models.json“ reparieren."
            }
        }
    }

    /// `<Support>/omlx`, Pippa's own oMLX folder (never the person's `~/.omlx`).
    public static func baseDirectory(support: URL) -> URL { support.appendingPathComponent("omlx", isDirectory: true) }

    /// Everything the server needs, without starting anything.
    public static func plan(roots: PiInstallRoots, agentDirectory: URL? = nil, modelID: String,
                            physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Plan {
        guard let runtime = MLXRuntime(support: roots.support, environment: environment), runtime.isInstalled else { throw Failure.runtimeMissing }
        let catalog = ModelCatalog.bundled()
        guard let model = catalog.model(modelID) else { throw Failure.unknownModel(modelID) }
        let modelsJSON = (agentDirectory ?? roots.agentDirectory).appendingPathComponent("models.json")
        let port = PiInstaller.stablePort(support: roots.support)
        if let listed = PiInstaller.providerPort(modelsJSON: modelsJSON), listed != port {
            throw Failure.portMismatch(modelsJSON: listed, settings: port)
        }
        let base = baseDirectory(support: roots.support)
        guard ModelDownloader(directory: base.appendingPathComponent("models/\(model.key)", isDirectory: true)).isInstalled(model) else {
            throw Failure.modelMissing(modelID)
        }
        var choice = ModelChoice(model: model, ctx: ModelSelector.contextWindow(for: model, physicalMemory: physicalMemory))
        if let listed = PiInstaller.providerContextWindow(modelsJSON: modelsJSON, id: modelID) { choice.ctx = min(listed, choice.ctx) }
        return Plan(choice: choice, python: runtime.python, baseDirectory: base, port: port,
                    key: try PiInstaller.stableKey(support: roots.support), modelID: modelID,
                    lockFile: PiServerLock.url(support: roots.support), keyFile: PiInstaller.keyFile(support: roots.support))
    }

    /// No network from the server: models come only from Pippa's folder, never from a hub at run time. `HOME` is a
    /// folder of Pippa's own: oMLX writes a helper into `~/.omlx/bin` on every start, which would repoint the person's own
    /// oMLX. Python may write its bytecode cache, which makes later starts about twice as fast.
    public static func environment(_ plan: Plan, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": plan.baseDirectory.appendingPathComponent("home").path,
                   "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "PYTHONNOUSERSITE": "1", "OMLX_HEADLESS": "1"]
        if let tmp = base["TMPDIR"] { env["TMPDIR"] = tmp }
        return env
    }

    /// oMLX's settings.json and per-model model_settings.json in Pippa's base folder (0600: settings.json holds the key).
    /// Merged into what oMLX itself wrote, so its own defaults stay; Pippa's values win.
    public static func writeServerSettings(_ plan: Plan) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plan.modelsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: plan.baseDirectory.appendingPathComponent("home"), withIntermediateDirectories: true)
        var document = JSONFile.readObject(plan.settingsFile) ?? [:]
        func merge(_ section: String, _ values: [String: Any], remove: [String] = []) {
            var current = document[section] as? [String: Any] ?? [:]
            for key in remove { current.removeValue(forKey: key) }
            for (key, value) in values { current[key] = value }
            document[section] = current
        }
        let model = plan.choice.model
        merge("server", ["host": "127.0.0.1", "port": plan.port, "log_level": "info"])
        merge("model", ["model_dirs": [plan.modelsDirectory.path], "model_dir": plan.modelsDirectory.path])
        merge("auth", ["api_key": plan.key, "skip_api_key_verification": false, "allow_unauthenticated_inference": false])
        merge("cache", ["enabled": true, "ssd_cache_max_size": "8GB"])
        merge("huggingface", ["endpoint": ""])
        merge("idle_timeout", ["idle_timeout_seconds": idleUnloadSeconds])
        merge("memory", ["prefill_memory_guard": true, "memory_guard_tier": model.memoryGuardTier ?? "balanced",
                         "memory_guard_custom_ceiling_gb": 0])
        merge("scheduler", ["chunked_prefill": model.chunkedPrefill ?? false, "max_concurrent_requests": 4])
        // Pi sends no sampling of its own, so these come from the active catalog model (falling back to Qwen 3.5's
        // defaults when unspecified). Keys omitted by the active model are cleared so an earlier model's knobs never leak.
        let sampling = model.sampling ?? CatalogModel.Sampling(temperature: 0.6, topP: 0.95, topK: 20)
        var samplingValues: [String: Any] = [:]
        var samplingRemove: [String] = []
        if let t = sampling.temperature { samplingValues["temperature"] = t } else { samplingRemove.append("temperature") }
        if let p = sampling.topP { samplingValues["top_p"] = p } else { samplingRemove.append("top_p") }
        if let k = sampling.topK { samplingValues["top_k"] = k } else { samplingRemove.append("top_k") }
        merge("sampling", samplingValues, remove: samplingRemove)
        let data = try JSONSerialization.data(withJSONObject: document, options: JSONFile.writingOptions)
        if (try? Data(contentsOf: plan.settingsFile)) != data {
            try JSONFile.writeAtomically(data, to: plan.settingsFile, mode: 0o600)
        }
        try writeModelSettings(plan)
    }

    /// Per-model settings in `<Support>/omlx/model_settings.json` (sampling + MTP flag) so oMLX never falls back to
    /// mismatched defaults or loads a slow draft head when the catalog disables it.
    private static func writeModelSettings(_ plan: Plan) throws {
        let model = plan.choice.model
        guard model.sampling != nil || model.mtpEnabled != nil else { return }
        var document = JSONFile.readObject(plan.modelSettingsFile) ?? ["version": 2]
        if document["version"] == nil { document["version"] = 2 }
        var models = document["models"] as? [String: Any] ?? [:]
        var entry = models[plan.modelID] as? [String: Any] ?? [:]
        if let sampling = model.sampling {
            if let t = sampling.temperature { entry["temperature"] = t } else { entry.removeValue(forKey: "temperature") }
            if let p = sampling.topP { entry["top_p"] = p } else { entry.removeValue(forKey: "top_p") }
            if let k = sampling.topK { entry["top_k"] = k } else { entry.removeValue(forKey: "top_k") }
            entry["force_sampling"] = false
        }
        if let mtp = model.mtpEnabled {
            entry["mtp_enabled"] = mtp
            entry["vlm_mtp_enabled"] = mtp
        }
        models[plan.modelID] = entry
        document["models"] = models
        let data = try JSONSerialization.data(withJSONObject: document, options: JSONFile.writingOptions)
        if (try? Data(contentsOf: plan.modelSettingsFile)) == data { return }
        try JSONFile.writeAtomically(data, to: plan.modelSettingsFile, mode: 0o600)
    }

    /// The server for it (not yet started). Log `<Support>/local-server.log`.
    public static func server(_ plan: Plan, logDirectory: URL) -> OMLXServer {
        OMLXServer(plan: plan, logDirectory: logDirectory)
    }

    // MARK: Launch file for the terminal extension

    /// `<Support>/pippa-local-server.json`: what Pippa's terminal extension (runtime/pippa-local-server, copied by the
    /// installer to ~/.pi/agent/extensions) starts the server with when `pi` in the terminal uses `pippa-local` and no
    /// server runs. The key is never in it; oMLX reads it from its settings.json.
    public static let launchFileName = "pippa-local-server.json"
    public static func launchFile(support: URL) -> URL { support.appendingPathComponent(launchFileName) }

    public static func launchConfiguration(_ plan: Plan, support: URL) -> [String: Any] {
        var config: [String: Any] = [
            "schemaVersion": 2, "provider": PiInstaller.providerKey, "port": plan.port, "binary": plan.python.path,
            "arguments": plan.arguments, "environment": environment(plan, base: [:]),
            "modelID": plan.modelID, "logFile": support.appendingPathComponent(logName).path, "keyFile": plan.keyFile.path,
        ]
        if let app = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : nil { config["app"] = app }
        return config
    }

    /// Write the launch file and oMLX's settings (atomic, 0600), only if something changed. `true`: written.
    @discardableResult
    public static func publishLaunchFile(_ plan: Plan, support: URL) throws -> Bool {
        try writeServerSettings(plan)
        let config = launchConfiguration(plan, support: support)
        let data = try JSONFile.encode(config)
        let url = launchFile(support: support)
        if (try? Data(contentsOf: url)) == data { return false }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONFile.writeAtomically(data, to: url, mode: 0o600)
        return true
    }
}
