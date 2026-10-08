import Foundation

// Setup as the UI sees it, with no technical questions. Pi, Node, model folder, adopting existing models and models.json run silently;
// the only question is the download. Errors are one sentence plus "Nochmal versuchen", technical details only in `details`.
//
// Order: detect → Pi → model folder → model → models.json → ready. The model step only checks and adopts (no network);
// its answer decides which model goes into models.json: the table's model, or, while that one still has to be
// downloaded, the model Pippa used so far (`fallback`). models.json is written before the download question either way,
// so only the model needs checking after loading.

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
    private let catalog: ModelCatalog
    private let lock = NSLock()
    private var adopted: String?
    private var pending: Int64?
    private var active: String?

    /// `searchRoots`: `nil` = all known places (old container, LM Studio, Ollama, Hugging Face …).
    /// `download`: a stand-in only for tests and recordings; otherwise the real ModelDownloader.
    public init(roots: PiInstallRoots, model: CatalogModel, contextWindow: Int, searchRoots: [ModelLocation]? = nil,
                port: Int? = nil, catalog: ModelCatalog = .bundled(), download: @escaping PiInstaller.Download = PiInstaller.modelDownloader) {
        installer = PiInstaller(roots: roots)
        self.model = model
        self.catalog = catalog
        options = PiInstallOptions(model: model, modelSearchRoots: searchRoots,
                                   providerModels: [PiProviderModel(id: model.key, name: model.label, contextWindow: contextWindow)],
                                   port: port ?? PiInstaller.stablePort(support: roots.support))
        self.download = download
    }

    /// The model for this Mac: the table by memory size (`ModelSelector.choose`); `preference` is the one setting
    /// "Standard" / "Gründlicher" (24 GB and up, docs/settings-simplification.md). `override`: developers only (`PIPPA_PI_MODEL`).
    public static func choice(override: String?, preference: ModelPreference = .standard,
                              physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                              catalog: ModelCatalog = .bundled()) -> ModelChoice? {
        if let override, let model = catalog.model(override), model.pinned != nil {
            return ModelSelector.choice(model, ctx: min(model.ctx, 16384), overrides: [:], catalog: catalog)
        }
        return try? ModelSelector.choose(physicalMemory: physicalMemory, preference: preference, catalog: catalog).get()
    }

    /// After `prepare`: bytes still to download for `model` while the previous model keeps working (`.ready` with the
    /// fallback in models.json). `nil`: `model` is the one in use, or there was no fallback (then `.askDownload`).
    public var pendingDownload: Int64? { lock.withLock { pending } }

    /// After `prepare`: the catalog key now in models.json (`model.key`, or the fallback's).
    public var activeModelKey: String? { lock.withLock { active } }

    /// The model Pippa used so far, kept while `model` still has to be downloaded (e.g. Gemma 4 12B after the table moved
    /// to K2 Horizon 7B, or the standard model while "Gründlicher" loads): the first `pippa-local` model in models.json that
    /// is a pinned catalog model, verified in the model folder. Its context stays as listed there. Nothing is deleted.
    func fallback() -> (model: CatalogModel, provider: PiProviderModel)? {
        guard let folder = installer.state.modelsFolder else { return nil }
        let downloader = ModelDownloader(directory: URL(fileURLWithPath: folder, isDirectory: true))
        let modelsJSON = installer.roots.modelsJSON
        for id in PiInstaller.providerModelIDs(modelsJSON: modelsJSON) where id != model.key {
            guard let previous = catalog.model(id), previous.pinned != nil, downloader.isInstalled(previous) else { continue }
            let context = PiInstaller.providerContextWindow(modelsJSON: modelsJSON, id: id) ?? min(previous.ctx, 16384)
            return (previous, PiProviderModel(id: previous.key, name: previous.label, contextWindow: context))
        }
        return nil
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

    /// All without network. Stops only at the download question or an error. If the model is missing but the previous one
    /// is there, setup is `.ready` with the previous one and `pendingDownload` says what the switch still needs.
    public func prepare() -> PiSetupState {
        for step in [PiInstallStep.detect, .pi, .modelsFolder] {
            if case .failed(let failure) = installer.perform(step, options).outcome { return .failed(PiSetupProblem(failure)) }
        }
        var use = options
        var missing: Int64?
        switch installer.perform(.model, options).outcome {
        case .failed(let failure): return .failed(PiSetupProblem(failure))
        case .needsDownload(let bytes):
            missing = bytes
            if let previous = fallback() {
                use = PiInstallOptions(model: previous.model, modelSearchRoots: options.modelSearchRoots,
                                       providerModels: [previous.provider], port: options.port)
            }
        case .modelReady(_, .some, let source): lock.withLock { adopted = source }
        default: break
        }
        if case .failed(let failure) = installer.perform(.provider, use).outcome { return .failed(PiSetupProblem(failure)) }
        lock.withLock { active = use.model?.key; pending = use.model == options.model ? nil : missing }
        if let missing, use.model == options.model { return .askDownload(bytes: missing) }
        if case .failed(let failure) = installer.perform(.ready, use).outcome { return .failed(PiSetupProblem(failure)) }
        return .ready(adoptedFrom: lock.withLock { adopted })
    }

    /// After "Laden": downloads (resumable), verifies, then the rest as in `prepare`.
    public func download(progress: @escaping @Sendable (Double, TimeInterval?) -> Void) async -> PiSetupState {
        let result = await installer.downloadModel(model, using: download, progress: progress)
        if case .failed(let failure) = result.outcome { return .failed(PiSetupProblem(failure)) }
        return prepare()
    }
}
