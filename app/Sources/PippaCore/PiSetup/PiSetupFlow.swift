import Foundation

// Setup as the UI sees it, with no technical questions. Pi, Node, model folder, adopting existing models and models.json run silently;
// the only question is the download. Errors are one sentence plus "Nochmal versuchen", technical details only in `details`.
//
// Order: detect → Pi → model folder → models.json → model → ready. models.json comes before the model, so
// everything else is in place before the download question and only the model needs checking after loading.

/// What the UI shows.
public enum PiSetupState: Sendable, Equatable {
    /// Setting up silently (Thought Line). `adoptingFrom`: currently adopting the AI from another program.
    case preparing(adoptingFrom: String?)
    /// The only question: "Pippa lädt jetzt ihre KI: 6,7 GB, etwa 10 Minuten …" · "Laden" · "Später".
    case askDownload(bytes: Int64)
    /// After "Laden". `progress` 0…1, `remaining` in seconds (once estimable).
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

/// Runs the installer for a model. Blocking (cloning, SHA-256, `pi --version`): never on the main thread.
public final class PiSetupFlow: @unchecked Sendable {
    public let installer: PiInstaller
    public let model: CatalogModel
    public let options: PiInstallOptions
    private let download: PiInstaller.Download
    private let lock = NSLock()
    private var adopted: String?

    /// `searchRoots`: `nil` = all known places (old container, LM Studio, Ollama, Hugging Face …).
    /// `download`: a stand-in only for tests and recordings; otherwise the real ModelDownloader.
    public init(roots: PiInstallRoots, model: CatalogModel, contextWindow: Int, searchRoots: [ModelLocation]? = nil,
                port: Int? = nil, download: @escaping PiInstaller.Download = PiInstaller.modelDownloader) {
        installer = PiInstaller(roots: roots)
        self.model = model
        options = PiInstallOptions(model: model, modelSearchRoots: searchRoots,
                                   providerModels: [PiProviderModel(id: model.key, name: model.label, contextWindow: contextWindow)],
                                   port: port ?? PiInstaller.stablePort(support: roots.support))
        self.download = download
    }

    /// The model for this Mac: the table by memory size (`ModelSelector.choose`). There is no choice in
    /// settings any more (docs/settings-simplification.md). `override`: developers only (`PIPPA_PI_MODEL`).
    public static func choice(override: String?, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                              catalog: ModelCatalog = .bundled()) -> ModelChoice? {
        if let override, let model = catalog.model(override), model.pinned != nil {
            return ModelSelector.choice(model, ctx: min(model.ctx, 16384), overrides: [:], catalog: catalog)
        }
        return try? ModelSelector.choose(physicalMemory: physicalMemory, catalog: catalog).get()
    }

    /// Fast, without reading or changing anything: is the AI already with another program? Then the
    /// UI shows "Ich übernehme meine KI aus LM Studio …" instead of the question. `nil`: already done or nothing found.
    public func adoptionSource() -> String? {
        if let folder = installer.state.modelsFolder, ModelDownloader(directory: URL(fileURLWithPath: folder)).isInstalled(model) { return nil }
        let folder = installer.state.modelsFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (PiInstaller.isDirectory(installer.roots.sharedModels) ? installer.roots.sharedModels : installer.roots.pippaModels)
        let roots = installer.modelSearchRoots(folder: folder, extra: options.modelSearchRoots)
        let found = ExistingModels.find(ModelCatalog(sampling: [:], models: [model]), roots: roots)
        return model.pinned?.files.lazy.compactMap { found[$0.sha256]?.source }.first
    }

    /// All without network. Stops only at the download question or an error.
    public func prepare() -> PiSetupState {
        for step in [PiInstallStep.detect, .pi, .modelsFolder, .provider, .model, .ready] {
            let result = installer.perform(step, options)
            switch result.outcome {
            case .failed(let failure): return .failed(PiSetupProblem(failure))
            case .needsDownload(let bytes): return .askDownload(bytes: bytes)
            case .modelReady(_, .some, let source): lock.withLock { adopted = source }
            default: break
            }
        }
        return .ready(adoptedFrom: lock.withLock { adopted })
    }

    /// After "Laden": downloads (resumable), verifies, then the rest as in `prepare`.
    public func download(progress: @escaping @Sendable (Double, TimeInterval?) -> Void) async -> PiSetupState {
        let result = await installer.downloadModel(model, using: download, progress: progress)
        if case .failed(let failure) = result.outcome { return .failed(PiSetupProblem(failure)) }
        return prepare()
    }
}
