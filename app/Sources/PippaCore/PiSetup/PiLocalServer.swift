import Foundation

// The app starts and owns the llama-server for Pi's provider `pippa-local`.
// This file only says **what** it starts with; `LlamaServer` runs it (same code as for LocalEngine, there
// with a random port). The app keeps one server for all conversations (PiRPCChat).
//
// - Port: fixed, from Pippa's settings.json (`PiInstaller.stablePort`), must match `baseUrl` in models.json.
// - Key: from the 0600 key file that Pi also reads via `apiKey: "!/bin/cat …"` (`PiInstaller.stableKey`).
// - 127.0.0.1 only, the same tuned flags as LocalEngine's server (`LlamaServer.arguments`), `--alias` with
//   the model id from models.json.
// - Model: developer file (`PIPPA_MODEL_FILE`), else the installer's model folder, else Pippa's current
//   model folder (`LocalEngine.modelsDirectory`). Each only if the file is there and verified (`.ok`).
// - Unloaded after `llamaIdleMinutes` without a request (default 10); `PIPPA_LLAMA_IDLE_SECONDS` only for measurements.
// - Prompt cache across unloading: save the slot before unloading, restore it after the next start before Pi's first request
//   (`<Support>/llama-slots`); `PIPPA_LLAMA_SLOT_CACHE=0` turns this off.
public enum PiLocalServer {
    public static let defaultIdleMinutes = 10

    public struct Plan: Sendable, Equatable {
        public var choice: ModelChoice
        public var modelFile: URL
        public var binary: URL
        public var port: Int
        public var key: String
        /// Model id in models.json; the server answers under this name (`--alias`).
        public var modelID: String
        public var idleSeconds: Double
        /// Where the model file comes from: `dev` (PIPPA_MODEL_FILE), `installer` (its model folder), `pippa` (current location).
        public var source: String
        /// Folder for the saved prompt cache (`<Support>/llama-slots`); `nil` with `PIPPA_LLAMA_SLOT_CACHE=0`.
        public var slotDirectory: URL? = nil
        /// Lock file shared with the terminal extension (`<Support>/llama-server-pi.lock`, `PiServerLock`).
        public var lockFile: URL? = nil
        /// Key file (0600) from which Pi also reads the key; for the terminal extension's launch file.
        public var keyFile: URL? = nil
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case binaryMissing
        case unknownModel(String)
        case modelMissing(String)
        case portMismatch(modelsJSON: Int, settings: Int)

        public var errorDescription: String? {
            switch self {
            case .binaryMissing: "llama-server fehlt (Contents/Helpers oder PIPPA_LLAMA_SERVER)."
            // E.g. Gemma from Pippa 1.0: no longer in the catalog. Pippa's setup sets up the current model.
            case .unknownModel(let id): "Modell \(id) steht nicht mehr in Pippas Katalog. Öffne Pippa; die Einrichtung holt das aktuelle Modell."
            case .modelMissing(let id): "Modell \(id) liegt weder im Modellordner des Installers noch in Pippas Modellordner."
            case .portMismatch(let a, let b): "Port in models.json (\(a)) passt nicht zu Pippas Einstellungen (\(b)); Installer-Schritt „models.json“ reparieren."
            }
        }
    }

    /// Everything the server needs, without starting anything. `legacySupport`: the app's Pippa support folder (current
    /// model location); `agentDirectory`: where models.json lives (else `roots.agentDirectory`).
    public static func plan(roots: PiInstallRoots, agentDirectory: URL? = nil, modelID: String, legacySupport: URL,
                            physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory, binary: URL? = LlamaServer.binaryURL(),
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Plan {
        guard let binary else { throw Failure.binaryMissing }
        let catalog = ModelCatalog.bundled()
        guard let model = catalog.model(modelID) else { throw Failure.unknownModel(modelID) }
        let modelsJSON = (agentDirectory ?? roots.agentDirectory).appendingPathComponent("models.json")

        let port = PiInstaller.stablePort(support: roots.support)
        if let listed = PiInstaller.providerPort(modelsJSON: modelsJSON), listed != port {
            throw Failure.portMismatch(modelsJSON: listed, settings: port)
        }
        let key = try PiInstaller.stableKey(support: roots.support)

        var file: URL?, source = ""
        if let dev = LocalEngine.devModelFile(environment: environment) { file = dev; source = "dev" }
        if file == nil, let folder = PiInstallState.load(from: roots.stateFile).modelsFolder {
            let downloader = ModelDownloader(directory: URL(fileURLWithPath: folder, isDirectory: true))
            if downloader.isInstalled(model) { file = downloader.primaryFile(model); source = "installer" }
        }
        if file == nil {
            let downloader = ModelDownloader(directory: LocalEngine.modelsDirectory(base: legacySupport, environment: environment))
            if downloader.isInstalled(model) { file = downloader.primaryFile(model); source = "pippa" }
        }
        guard let file else { throw Failure.modelMissing(modelID) }

        // Flags like LocalEngine for this model; context as in models.json so Pi and the server assume the same.
        var choice = ModelSelector.named(modelID, physicalMemory: physicalMemory, catalog: catalog)
            ?? ModelSelector.choice(model, ctx: model.ctx, overrides: [:], catalog: catalog)
        if let listed = PiInstaller.providerContextWindow(modelsJSON: modelsJSON, id: modelID) { choice.ctx = min(listed, model.ctx) }

        let settings = PippaSettings.load(from: roots.support)
        let idle = environment["PIPPA_LLAMA_IDLE_SECONDS"].flatMap(Double.init)
            ?? Double(max(1, settings.llamaIdleMinutes ?? defaultIdleMinutes) * 60)
        let slots = environment["PIPPA_LLAMA_SLOT_CACHE"] == "0" ? nil : roots.support.appendingPathComponent("llama-slots", isDirectory: true)
        return Plan(choice: choice, modelFile: file, binary: binary, port: port, key: key, modelID: modelID, idleSeconds: idle, source: source,
                    slotDirectory: slots, lockFile: PiServerLock.url(support: roots.support), keyFile: PiInstaller.keyFile(support: roots.support))
    }

    /// Remove all saved slots (`<Support>/llama-slots/pippa-slot-*.bin`), e.g. when a conversation is deleted;
    /// the slot holds the last conversation as cache. Only Pippa's own cache files.
    public static func discardSavedSlots(support: URL) {
        let dir = support.appendingPathComponent("llama-slots", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix("pippa-slot-") && name.hasSuffix(".bin") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// The server for it (not yet started). Log `llama-server-pi.log` next to LocalEngine's.
    public static func server(_ plan: Plan, logDirectory: URL) -> LlamaServer {
        LlamaServer(choice: plan.choice, modelPath: plan.modelFile, binary: plan.binary, logDirectory: logDirectory,
                    fixedPort: plan.port, fixedKey: plan.key, alias: plan.modelID, idleAfter: plan.idleSeconds,
                    logName: "llama-server-pi.log", slotDirectory: plan.slotDirectory, lockFile: plan.lockFile)
    }

    // MARK: Launch file for the terminal extension

    /// `<Support>/pippa-local-server.json`: what Pippa's terminal extension (runtime/pippa-local-server, copied by the installer
    /// to ~/.pi/agent/extensions) starts the server with when `pi` in the terminal uses `pippa-local` and the app does not
    /// run it. No fixed paths in the extension: program in Pippa.app, model file, exactly the same
    /// arguments as `LlamaServer.ensureRunning`, idle time. The key is never in it, only the key file.
    public static let launchFileName = "pippa-local-server.json"
    public static func launchFile(support: URL) -> URL { support.appendingPathComponent(launchFileName) }

    /// Contents of the launch file. `supported`: the program's flags (`LlamaServer.supportedFlags`), as on app start.
    public static func launchConfiguration(_ plan: Plan, support: URL, supported: Set<String>?,
                                           environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: Any] {
        let swaFull = plan.slotDirectory != nil && environment["PIPPA_LLAMA_SWA_FULL"] != "0"
        let arguments = LlamaServer.arguments(choice: plan.choice, model: plan.modelFile, port: plan.port, supported: supported,
                                              alias: plan.modelID, slotSavePath: plan.slotDirectory, swaFull: swaFull)
        // Pippa.app, if the program lives in it (for the message "Pippa.app is missing").
        var app: String?
        var probe = plan.binary.deletingLastPathComponent()
        while probe.pathComponents.count > 1 {
            if probe.pathExtension == "app" { app = probe.path; break }
            probe = probe.deletingLastPathComponent()
        }
        var config: [String: Any] = [
            "schemaVersion": 1, "provider": PiInstaller.providerKey, "port": plan.port, "binary": plan.binary.path,
            "modelID": plan.modelID, "arguments": arguments, "idleSeconds": Int(plan.idleSeconds.rounded()),
            "logFile": support.appendingPathComponent("llama-server-pi.log").path,
        ]
        if let app { config["app"] = app }
        if let keyFile = plan.keyFile { config["keyFile"] = keyFile.path }
        return config
    }

    /// Write the launch file (atomic, 0600), only if something changed. `true`: written.
    @discardableResult
    public static func publishLaunchFile(_ plan: Plan, support: URL, supported: Set<String>? = nil) throws -> Bool {
        let flags = supported ?? LlamaServer.supportedFlags(binary: plan.binary)
        let config = launchConfiguration(plan, support: support, supported: flags)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        let url = launchFile(support: support)
        if (try? Data(contentsOf: url)) == data { return false }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let temporary = support.appendingPathComponent(".\(launchFileName).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: errno))
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: code))
        }
        return true
    }
}
