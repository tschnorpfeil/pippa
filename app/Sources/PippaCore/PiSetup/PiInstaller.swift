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
    /// From Pippa's choice: id = catalog key (also the model's folder name, which oMLX serves it under), context as the server.
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
    /// Where to look for existing models; `nil` = oMLX, LM Studio, Hugging Face ...
    public var modelSearchRoots: [ModelLocation]?
    public var providerModels: [PiProviderModel]
    public var port: Int
    public init(model: CatalogModel?, modelSearchRoots: [ModelLocation]? = nil, providerModels: [PiProviderModel], port: Int) {
        self.model = model; self.modelSearchRoots = modelSearchRoots; self.providerModels = providerModels; self.port = port
    }
}

/// The installer: detect -> Pi -> model folder -> model -> models.json -> ready. Every step is idempotent, writes
/// its state to install-state.json and can be repeated on its own ("Repair"). Foreign things stay untouched:
/// Pippa deletes and replaces only what is listed in `state.created`, plus releases carrying its own marker
/// (`managedReleaseMarker`), which outlives a lost record.
public final class PiInstaller: @unchecked Sendable {
    public static let providerKey = "pippa-local"
    public let roots: PiInstallRoots
    public internal(set) var state: PiInstallState
    /// Order when adopting models; checks force e.g. the hardlink here.
    public var adoptionMethods: [PiAdoptionMethod] = [.clone, .hardlink, .copy]
    let fm = FileManager.default
    private var exclusiveDepth = 0

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
        if step == .detect {
            // Inside the lock: its state refresh would otherwise bring the forgotten decision back.
            do { return try exclusive { state.layout = nil; state.detection = nil; return detect() } }
            catch { return finish(.detect, .failed(failure(error, path: roots.support))) }
        }
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
            // Compaction threshold and thinking level per model. Not fatal: without them Pi runs on its defaults.
            if result.isDone, !writeModelTuning(models: options.providerModels) {
                DiagnosticsLog.shared.event("pi-settings-unverändert", ["datei": roots.piSettingsJSON.lastPathComponent])
            }
            return result
        case .ready: return checkReady(modelIDs: options.providerModels.map(\.id), model: options.model)
        }
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
            guard let folder = modelDirectory(model), ModelDownloader(directory: folder).isInstalled(model) else {
                return finish(.ready, .failed(.missingStep(.model)))
            }
            for old in Self.oldModelFiles(support: roots.support, home: roots.home, state: state) {
                try? fm.trashItem(at: old, resultingItemURL: nil)
            }
        }
        return finish(.ready, .ready(version: found))
    }

    // MARK: Helpers

    /// One writer per installation. The app's setup and the first Pi start each have their own `PiInstaller` and can
    /// both install the pinned Pi in the same minute; without this the second deletes the first one's staging copy
    /// (`ensureRelease`) and a release lacking files can be published. The lock is on the support folder, so it holds
    /// across instances and processes and ends with its holder. A waiting installer then reads the state the other one
    /// saved, so it neither decides the layout again on a half-built folder nor overwrites the other's records.
    /// Re-entrant for the same instance.
    func exclusive<T>(_ body: () throws -> T) throws -> T {
        if exclusiveDepth > 0 { return try body() }
        let file = roots.support.appendingPathComponent(".install.lock")
        do { try fm.createDirectory(at: roots.support, withIntermediateDirectories: true) }
        catch { throw PiInstallFailure.notWritable(path: roots.support.path, reason: SystemError.reason(error)) }
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PiInstallFailure.notWritable(path: file.path, reason: SystemError.reason(errno: errno)) }
        defer { close(descriptor) } // also releases the lock
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw PiInstallFailure.notWritable(path: file.path, reason: SystemError.reason(errno: errno)) }
        }
        exclusiveDepth += 1
        defer { exclusiveDepth -= 1 }
        // Everything this instance changed is saved at once (`begin`, `finish`, `makeDirectory`); the file is newer.
        if fm.fileExists(atPath: roots.stateFile.path) { state = PiInstallState.load(from: roots.stateFile) }
        return try body()
    }

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

    func begin(_ step: PiInstallStep) {
        state.steps[step.rawValue] = .init(status: "started", at: Date())
        save()
    }

    @discardableResult
    func finish(_ step: PiInstallStep, _ outcome: PiStepResult.Outcome) -> PiStepResult {
        let result = PiStepResult(step: step, outcome: outcome, message: Self.message(outcome))
        let status = switch outcome {
        case .failed: "failed"
        default: result.isDone ? "done" : "needsInput"
        }
        state.steps[step.rawValue] = .init(status: status, at: Date())
        save()
        return result
    }

    /// Not fatal: the next step writes the whole state again. A failure is logged, not shown.
    func save() {
        do { try state.save(to: roots.stateFile) }
        catch { UserMessage.record(error, context: "install-state-save") }
    }

    func failure(_ error: Error, path: URL) -> PiInstallFailure {
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
}
