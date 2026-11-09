import Foundation

// Setup as the UI sees it, with no technical questions. Pi, Node, model folder, adopting existing models and models.json run silently;
// the only question is the download. Errors are one sentence plus "Nochmal versuchen", technical details only in `details`.
//
// Order: detect → Pi → model folder → model → models.json → ready. The model step only checks and adopts (no network).
// The download question covers the oMLX runtime and the model together.

/// What the UI shows.
public enum PiSetupState: Sendable, Equatable {
    /// Setting up silently (Thought Line). `adoptingFrom`: currently adopting the AI from another program.
    case preparing(adoptingFrom: String?)
    /// The only question: "May I load my AI now? 6.7 GB, about 10 minutes …" · "Load Pippa's AI" · "Later".
    case askDownload(bytes: Int64)
    /// After "Load". `progress` 0…1, `remaining` in seconds (once estimable).
    case downloading(progress: Double, remaining: TimeInterval?)
    case failed(PiSetupProblem)
    /// Done. `adoptedFrom`: the AI came without download from another program (for a calm sentence).
    case ready(adoptedFrom: String?)

}

/// An error for the UI: one sentence, technical details behind "Details".
public struct PiSetupProblem: Sendable, Equatable {
    public var message: String
    public var details: String
    public var canRetry: Bool
    public var failure: PiInstallFailure?
    public init(message: String, details: String, canRetry: Bool = true, failure: PiInstallFailure? = nil) {
        self.message = message; self.details = details; self.canRetry = canRetry; self.failure = failure
    }
    public init(_ failure: PiInstallFailure) {
        self.init(message: PiInstaller.message(failure), details: PiInstaller.details(failure),
                  canRetry: PiInstaller.canRetry(failure), failure: failure)
    }
}

/// Runs the installer for the model and the runtime that serves it. Blocking (SHA-256, `pi --version`): never on the main thread.
public final class PiSetupFlow: @unchecked Sendable {
    public let installer: PiInstaller
    public let model: CatalogModel
    public let options: PiInstallOptions
    public let runtime: MLXRuntime?
    private let download: PiInstaller.Download
    private let freeSpace: @Sendable (URL) -> Int64?
    private let lock = NSLock()
    private var adopted: String?

    /// `searchRoots`: `nil` = all known places (oMLX, LM Studio, Hugging Face).
    /// `download`, `freeSpace`: stand-ins only for tests and recordings; otherwise the real ModelDownloader and the volume's free space.
    public init(roots: PiInstallRoots, model: CatalogModel, contextWindow: Int, searchRoots: [ModelLocation]? = nil,
                port: Int? = nil, runtime: MLXRuntime? = nil, download: @escaping PiInstaller.Download = PiInstaller.modelDownloader,
                freeSpace: @escaping @Sendable (URL) -> Int64? = ModelDownloader.availableSpace(at:)) {
        installer = PiInstaller(roots: roots)
        self.model = model
        self.runtime = runtime ?? MLXRuntime(support: roots.support)
        options = PiInstallOptions(model: model, modelSearchRoots: searchRoots,
                                   providerModels: [PiProviderModel(id: model.key, name: model.label, contextWindow: contextWindow)],
                                   port: port ?? PiInstaller.stablePort(support: roots.support))
        self.download = download
        self.freeSpace = freeSpace
    }

    /// The model for this Mac (`ModelSelector.choose`): Ornith on Apple silicon with 16 GB or more, else `nil`.
    public static func choice(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                              catalog: ModelCatalog = .bundled()) -> ModelChoice? {
        try? ModelSelector.choose(physicalMemory: physicalMemory, catalog: catalog).get()
    }

    /// Fast, without reading or changing anything: is the model already with another program? Then the
    /// UI says "Taking over the AI from oMLX …" instead of asking. `nil`: already done or nothing found.
    public func adoptionSource() -> String? {
        if let folder = installer.modelDirectory(model), ModelDownloader(directory: folder).isInstalled(model) { return nil }
        let found = ExistingModels.find(model, roots: options.modelSearchRoots ?? ExistingModels.defaultRoots(home: installer.roots.home))
        return model.pinned?.files.lazy.compactMap { found[$0.sha256]?.source }.first
    }

    /// How much more free space the download needs (2 GB to spare), checked before the question. `nil`: enough, or unknown.
    public func spaceShortfall(remaining: Int64) -> Int64? {
        let folder = installer.state.modelsFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? installer.roots.support
        return ModelDownloader.spaceShortfall(available: freeSpace(folder), remaining: remaining)
    }

    /// All without network. Stops only at the download question or an error; not enough room for the download is an error,
    /// so the question is never asked for something that cannot fit.
    public func prepare() -> PiSetupState {
        for step in [PiInstallStep.detect, .pi, .modelsFolder] {
            if case .failed(let failure) = installer.perform(step, options).outcome { return .failed(PiSetupProblem(failure)) }
        }
        var missing = runtime?.remainingBytes ?? 0
        if runtime == nil { return .failed(PiSetupProblem(.missingStep(.model))) }
        // Also with 0 bytes left (a complete but unverified .part): the download step verifies it.
        var modelMissing = false
        switch installer.perform(.model, options).outcome {
        case .failed(let failure): return .failed(PiSetupProblem(failure))
        case .needsDownload(let bytes): missing += bytes; modelMissing = true
        case .modelReady(_, .some, let source): lock.withLock { adopted = source }
        default: break
        }
        if case .failed(let failure) = installer.perform(.provider, options).outcome { return .failed(PiSetupProblem(failure)) }
        if modelMissing || missing > 0 || runtime?.isInstalled != true {
            if let shortfall = spaceShortfall(remaining: missing) { return .failed(PiSetupProblem(.notEnoughSpace(bytes: shortfall))) }
            return .askDownload(bytes: missing)
        }
        if case .failed(let failure) = installer.perform(.ready, options).outcome { return .failed(PiSetupProblem(failure)) }
        return .ready(adoptedFrom: lock.withLock { adopted })
    }

    /// After "Load": runtime, then the model (both resumable and verified), then the rest as in `prepare`.
    /// Progress runs over both by their sizes.
    public func download(progress: @escaping @Sendable (Double, TimeInterval?) -> Void) async -> PiSetupState {
        let runtimeBytes = Double(runtime?.remainingBytes ?? 0)
        let modelBytes = Double(model.approxBytes ?? 1)
        let share = runtimeBytes / max(1, runtimeBytes + modelBytes)
        if let runtime, !runtime.isInstalled {
            do { try await runtime.install { progress($0 * share, nil) } }
            catch let error as PippaError {
                if case .notEnoughSpace(let bytes) = error { return .failed(PiSetupProblem(.notEnoughSpace(bytes: bytes))) }
                if case .checksumMismatch = error { return .failed(PiSetupProblem(.downloadDamaged)) }
                return .failed(PiSetupProblem(.downloadFailed(error.localizedDescription)))
            } catch {
                return .failed(PiSetupProblem(.downloadFailed(error.localizedDescription)))
            }
        }
        let result = await installer.downloadModel(model, using: download) { fraction, remaining in
            progress(share + fraction * (1 - share), remaining)
        }
        if case .failed(let failure) = result.outcome { return .failed(PiSetupProblem(failure)) }
        return prepare()
    }
}
