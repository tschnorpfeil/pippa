import Foundation
import UniformTypeIdentifiers

/// Pi runs chat jobs; fixed file flows and the approved executor stay in Swift.
/// Pattern variants apply only to fixed flows; chat needs the real local agent.
public actor LocalEngine: PippaEngine {
    public let baseDirectory: URL
    let physicalMemory: UInt64
    let catalog: ModelCatalog
    /// Measurements only (PippaLive, spikes): a specific catalog model instead of the table (`ModelSelector.named`).
    /// The app never sets this; there is no model choice (docs/settings-simplification.md).
    private let measuredModel: String?
    private var executor: Executor?
    private var executorError: Error?
    private let downloader: ModelDownloader
    /// Where other programs keep models (empty: don't search, e.g. in checks with their own folder).
    private let existingRoots: [ModelLocation]
    /// Running or last search (in the background, never on the start path) and when it began.
    private var existingScan: Task<[String: ModelLocation], Never>?
    private var existingScannedAt: Date?
    /// Found files whose content did not fit: don't offer them again.
    private var rejectedExisting: Set<String> = []
    private var server: LlamaServer?
    /// The app's one llama-server (`pippa-local`, PiRPCChat) instead of its own on a random port. Set as soon as
    /// the Pi RPC path drives the conversation: sorting classification, invoices, deadlines and letter suggestions then use
    /// the same model, and a second server never runs. State and download then belong to setup.
    private var shared: SharedModelServer?
    private var structuredBusy = false
    /// Slot 0 of the shared llama-server is Pi's conversation cache. A direct model call saves it first and puts it back
    /// afterwards, during a tidy round only once its model stage ends (`holdSlot`), so the next answer does not read the
    /// whole conversation again and an idle unload does not save the tidy prompt instead. `slotSaveTried`: save at most
    /// once per round; a second save would store the tidy prompt over the conversation.
    private var parkedSlot: LlamaServer?
    private var holdSlot = false
    private var slotSaveTried = false
    private var inferenceWorkBusy = false

    /// One model job at a time. Callers reset the state via `defer`.
    private func beginInferenceWork() throws {
        guard !inferenceWorkBusy else { throw InferenceError.busy }
        inferenceWorkBusy = true
    }
    private var download: (progress: Double, remaining: TimeInterval?)?
    private var preparation: Task<Void, Error>?
    private var preparationID: UUID?
    private var validatedModel: String?
    private var preparationError: String?
    private var textCache: [String: (FileFingerprint, DocumentText)] = [:]
    private var progress: WorkProgress?
    public var workProgress: WorkProgress? { get async { progress } }

    /// Progress for the UI: file `index` of `total` is being processed.
    private func step(_ index: Int, of total: Int, _ url: URL) {
        progress = WorkProgress(done: index, total: total, current: url.lastPathComponent)
    }
    /// Switch the model off, e.g. for checks.
    public var modelEnabled: Bool
    /// Reminders, calendar, mail. Checks pass `DemoIntegrations`.
    let integrations: any AppIntegrations
    /// Excel, read only. By default: the real Apple Events if the other integrations are real too; with
    /// other integrations (checks, `DemoIntegrations`) a stand-in without a spreadsheet, so no check touches Excel.
    let sheets: any SheetReading

    public init(baseDirectory: URL = Pippa.supportDirectory, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                modelEnabled: Bool = true, integrations: (any AppIntegrations)? = nil, sheets: (any SheetReading)? = nil,
                existingModelRoots: [ModelLocation]? = nil, measuredModel: String? = nil) {
        self.baseDirectory = baseDirectory
        let resolved = integrations ?? SystemIntegrations()
        self.integrations = resolved
        // The same real integrations also read Excel; stand-in integrations get a stand-in without a spreadsheet.
        self.sheets = sheets ?? (resolved as? any SheetReading) ?? (DemoSheetReader(granted: false, snapshot: nil) as any SheetReading)
        self.physicalMemory = physicalMemory
        self.modelEnabled = modelEnabled
        catalog = .bundled()
        self.measuredModel = measuredModel
        let downloader = ModelDownloader(directory: Self.modelsDirectory(base: baseDirectory))
        // Search foreign folders only for the real app (on demand, in the background); checks with their own folder
        // stay independent of the Mac.
        existingRoots = existingModelRoots
            ?? (modelEnabled && Self.devModelFile() == nil && baseDirectory.standardizedFileURL == Pippa.supportDirectory.standardizedFileURL
                ? ExistingModels.defaultRoots() : [])
        self.downloader = downloader
        do { executor = try Executor(baseDirectory: baseDirectory) } catch { executorError = error }
    }

    /// Server and state come from outside (the app: PiRPCChat and PiSetupController).
    public struct SharedModelServer: Sendable {
        /// The running server, or one started on demand; throws if it is not ready.
        public var server: @Sendable () async throws -> LlamaServer
        /// State for the UI (setup, loading, ready).
        public var status: @Sendable () async -> ModelStatus
        public init(server: @escaping @Sendable () async throws -> LlamaServer, status: @escaping @Sendable () async -> ModelStatus) {
            self.server = server; self.status = status
        }
    }

    /// From now on use the shared server (`nil`: the own one again). An own server that already started is stopped.
    public func useSharedServer(_ shared: SharedModelServer?) async {
        self.shared = shared
        guard shared != nil else { return }
        preparation?.cancel(); preparation = nil; preparationID = nil; download = nil; preparationError = nil
        if let own = server { server = nil; validatedModel = nil; await own.stop() }
    }

    /// Does the engine use the shared server (checks)?
    public var usesSharedServer: Bool { shared != nil }

    /// Model folder: `<Support>/models`; for development via PIPPA_MODELS_DIR (e.g. a folder outside the repo).
    public nonisolated static func modelsDirectory(base: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let env = environment["PIPPA_MODELS_DIR"], !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
        return base.appendingPathComponent("models", isDirectory: true)
    }

    /// Catalog files held by other programs. The search runs off the actor (blocks neither start nor chat) and
    /// stays valid for half a minute.
    private func existingFiles() async -> [String: ModelLocation] {
        guard !existingRoots.isEmpty else { return [:] }
        if existingScan == nil || Date().timeIntervalSince(existingScannedAt ?? .distantPast) > 30 {
            let catalog = catalog, roots = existingRoots
            existingScan = Task.detached(priority: .utility) { ExistingModels.find(catalog, roots: roots) }
            existingScannedAt = Date()
        }
        let found = await existingScan?.value ?? [:]
        return found.filter { !rejectedExisting.contains($0.key) }
    }

    private func reject(_ sha256: String) {
        rejectedExisting.insert(sha256)
    }

    private func requireExecutor() throws -> Executor {
        if let executor { return executor }
        throw PippaError.writeFailed(executorError.map(SystemError.reason) ?? "")
    }

    // MARK: Model

    var choice: Result<ModelChoice, PippaError> {
        guard let measuredModel else { return ModelSelector.choose(physicalMemory: physicalMemory, catalog: catalog) }
        return ModelSelector.named(measuredModel, physicalMemory: physicalMemory, catalog: catalog).map { .success($0) } ?? .failure(.modelUnavailable)
    }

    public var modelStatus: ModelStatus {
        get async {
            if let shared { return await shared.status() }
            // If the model is missing, first find out whether another program already has it.
            if case .success(let c) = choice, !downloader.isInstalled(c.model) { _ = await existingFiles() }
            switch choice {
            case .failure(.unsupportedHardware(let why)): return .unsupported(reason: why)
            case .failure: return .unsupported(reason: L("I don’t have anything suitable for this Mac right now.", table: "Core"))
            case .success(let c):
                guard LlamaServer.binaryURL() != nil else {
                    return .unsupported(reason: L("Part of the app is missing. Please open Pippa from the Applications folder.", table: "Core"))
                }
                if let download { return .downloading(progress: download.progress, remaining: download.remaining) }
                if let preparationError { return .failed(reason: preparationError) }
                guard downloader.isInstalled(c.model) || Self.devModelFile() != nil else { return .notInstalled }
                return validatedModel == c.model.key ? .ready : .loading
            }
        }
    }

    public var modelDownloadSize: ModelDownloadSize? {
        get async {
            if shared != nil { return nil }   // the setup asks and downloads
            guard case .success(let c) = choice, Self.devModelFile() == nil, !downloader.isInstalled(c.model) else { return nil }
            return downloader.downloadSize(c.model, existing: await existingFiles())
        }
    }

    /// `allowDownload`: the person agreed to the download. Without it, only what is already on the Mac is adopted;
    /// if that doesn't fit, `ModelDownloader.AdoptionFailed` is thrown (then the app asks as usual).
    public func prepareModel(allowDownload: Bool) async throws {
        if shared != nil { return }   // the setup or PiRPCChat loads and starts, never a second server
        guard LlamaServer.binaryURL() != nil else { throw PippaError.serverMissing }
        if let preparation { return try await preparation.value }
        if case .success(let c) = choice, validatedModel == c.model.key { return }
        let existing = await existingFiles()
        if let preparation { return try await preparation.value }
        let c = try choice.get()
        if validatedModel == c.model.key { return }
        let id = UUID()
        preparationID = id
        preparationError = nil
        let task = Task { [self] in
            if !downloader.isInstalled(c.model), Self.devModelFile() == nil {
                download = (0, nil)
                try await downloader.download(c.model, existing: existing, allowNetwork: allowDownload,
                                              rejected: { [weak self] sha in Task { await self?.reject(sha) } }) { [weak self] progress, remaining in
                    Task { await self?.setDownload(progress, remaining, id: id) }
                }
                download = nil
            }
            try Task.checkCancellation()
            guard let server = llm() else { throw PippaError.serverMissing }
            try await server.ensureRunning()
            try Task.checkCancellation()
            validatedModel = c.model.key
            // Preparing or switching models must not delete previously downloaded models.
            // Storage cleanup requires an explicit user action, separate from model selection.
        }
        preparation = task
        do { try await task.value }
        catch {
            if let failed = error as? ModelDownloader.AdoptionFailed { reject(failed.sha256) }
            if preparationID == id, !(error is CancellationError), !(error is ModelDownloader.AdoptionFailed) { preparationError = UserMessage.text(for: error, context: "modell-vorbereiten") }
            if preparationID == id { preparation = nil; preparationID = nil; download = nil }
            throw error
        }
        if preparationID == id { preparation = nil; preparationID = nil; download = nil }
    }

    /// Cancel and await the downloader before changing inference routes. Partial GGUFs remain resumable.
    public func cancelModelPreparation() async {
        let id = preparationID
        let task = preparation
        task?.cancel()
        if let task { _ = await task.result }
        // A newer preparation must not be cleared or have its server stopped.
        guard preparationID == nil || preparationID == id else { return }
        preparation = nil; preparationID = nil; download = nil; preparationError = nil
        if !structuredBusy, !inferenceWorkBusy, let idleServer = server {
            server = nil
            validatedModel = nil
            await idleServer.stop()
        }
    }

    private func setDownload(_ p: Double, _ r: TimeInterval?, id: UUID) {
        if preparationID == id, download != nil { download = (p, r) }
    }

    /// Server if model loaded and program present; otherwise nil (pattern variant).
    private func llm() -> LlamaServer? {
        guard shared == nil, modelEnabled, case .success(let c) = choice, let file = modelFile(c), let binary = LlamaServer.binaryURL() else { return nil }
        if let server, server.choice == c { return server }
        if let old = server { Task { await old.stop() } }
        let s = LlamaServer(choice: c, modelPath: file, binary: binary, logDirectory: baseDirectory)
        server = s
        return s
    }

    /// The server for model work: the shared one or the own one. `nil`: no model ready.
    private func modelServer() async -> LlamaServer? {
        if let shared {
            do { return try await shared.server() } catch {
                DiagnosticsLog.shared.event("gemeinsamer-server-fehlt", ["art": String(describing: type(of: error))])
                return nil
            }
        }
        return llm()
    }

    /// Verified model file; replaceable for development via PIPPA_MODEL_FILE (any GGUF file, unverified).
    private func modelFile(_ c: ModelChoice) -> URL? {
        if let dev = Self.devModelFile() { return dev }
        guard downloader.isInstalled(c.model) else { return nil }
        return downloader.primaryFile(c.model)
    }

    nonisolated static func devModelFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment["PIPPA_MODEL_FILE"], !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var warmUpTask: Task<Void, Never>?

    /// Warm up text recognition: once per app run, in the background. The first recognition after a new app version
    /// otherwise took about 30 s (Vision loads and compiles its models).
    public func warmUp() async {
        guard warmUpTask == nil else { return }
        warmUpTask = Task.detached(priority: .utility) { TextReader.warmUp() }
    }

    /// For measurements and checks: waits until warm-up is finished (immediately without `warmUp()`).
    public func waitForWarmUp() async { await warmUpTask?.value }

    /// A dedicated fixture-sized request; no task history or user context is attached.
    public static func testModelConnection(_ connection: ModelConnection, apiKey: String) async throws {
        try connection.validated()
        guard connection.isLocal || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InferenceError.missingCredential }
        // Directly in Swift (ModelConnectionTest).
        try await ModelConnectionTest.run(connection, apiKey: apiKey)
    }

    /// Can Pippa answer in conversation? Yes, as soon as a model is on this Mac and not being prepared.
    public nonisolated static func chatRoute(modelInstalled: Bool, preparing: Bool) -> ChatReadiness {
        modelInstalled && !preparing ? .ready : .unavailable
    }

    public var chatReadiness: ChatReadiness {
        get async {
            // with a shared server the setup decides (PiSetupController).
            if let shared { return await shared.status() == .ready ? .ready : .unavailable }
            return Self.chatRoute(modelInstalled: localModelOnDisk, preparing: preparation != nil)
        }
    }

    /// The chosen local model and llama-server are on this Mac (whether or not the server runs yet).
    private var localModelOnDisk: Bool {
        guard modelEnabled, case .success(let c) = choice else { return false }
        return modelFile(c) != nil && LlamaServer.binaryURL() != nil
    }

    /// Prepare only caller-granted read-only context; a moved/unavailable attachment remains explicit.
    public nonisolated static func snapshots(for context: ChatContext) async throws -> [DocumentSnapshot] {
        try context.validate()
        let reading = Task.detached(priority: .userInitiated) {
            var result: [DocumentSnapshot] = []
            if !context.selectedText.isEmpty {
                let text = String(decoding: context.selectedText.utf8.prefix(24000), as: UTF8.self)
                result.append(.init(name: "Ausgewählter Text", text: text, truncated: text.count < context.selectedText.count))
            }
            if !context.workflowSummary.isEmpty {
                let prefix = "Nativer Arbeitsstand aus Pippas Oberfläche. Dies ist Kontext zu einer Übersicht, Vorschau oder einem Beleg; es bestätigt keine neu ausgeführte Agent-Aktion. Vorschläge sind erst nach einer ausdrücklich bestätigten Ausführung erledigt.\n\n"
                let remaining = max(0, 24000 - prefix.utf8.count)
                let summary = String(decoding: context.workflowSummary.utf8.prefix(remaining), as: UTF8.self)
                result.append(.init(name: "Aktueller Arbeitsstand (native Oberfläche)", text: prefix + summary,
                                    truncated: summary.utf8.count < context.workflowSummary.utf8.count))
            }
            for (number, url) in context.files.enumerated() {
                try Task.checkCancellation()
                let shownName = String(url.lastPathComponent.prefix(200))
                context.onWork?(.phase(.reading(name: shownName, index: number + 1, count: context.files.count)))
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if values.isDirectory == true {
                        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
                        let listing = children.prefix(100).map(\.lastPathComponent).joined(separator: "\n")
                        let text = String(decoding: listing.utf8.prefix(24000), as: UTF8.self)
                        result.append(.init(name: String(url.lastPathComponent.prefix(200)), text: "Ordnerinhalt (nur Namen):\n" + text, truncated: children.count > 100 || text.count < listing.count, readStatus: .metadataOnly))
                    } else if (values.fileSize ?? 0) > 20_000_000 {
                        result.append(.init(name: String(url.lastPathComponent.prefix(200)), text: "Diese Datei ist größer als 20 MB und wurde noch nicht gelesen.", truncated: true, readStatus: .unreadable))
                    } else {
                        var options = TextReader.Options(maxPages: 12, ocr: true)
                        options.onRecognize = { page, pages in context.onWork?(.phase(.recognizing(name: shownName, page: page, pages: pages))) }
                        let doc = TextReader.read(url, options: options)
                        context.onWork?(.sourceRead(name: shownName, pagesRead: doc.isPaged ? doc.pages.count : nil, pageCount: doc.pageCount, recognizedText: doc.usedOCR))
                        let text = String(decoding: doc.capped(maxChars: 24000).utf8.prefix(24000), as: UTF8.self)
                        result.append(.init(name: String(url.lastPathComponent.prefix(200)), text: text.isEmpty ? "Kein lesbarer Text verfügbar (\(doc.problem.rawValue))." : text,
                                            truncated: doc.isTruncated || doc.fullText.count > text.count,
                                            readStatus: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unreadable : (doc.isTruncated || doc.fullText.count > text.count ? .partial : .readable)))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    result.append(.init(name: String(url.lastPathComponent.prefix(200)),
                                        text: "Diese angehängte Quelle ist nicht mehr verfügbar oder konnte nicht gelesen werden. Ihr Inhalt wurde nicht gelesen. Ein vorhandener nativer Arbeitsstand kann frühere bestätigte Aktionen beschreiben.",
                                        truncated: true, readStatus: .unavailable))
                }
            }
            let focused = Set(context.focusedFiles.map { $0.standardizedFileURL.path })
            for (index, url) in context.files.enumerated() where focused.contains(url.standardizedFileURL.path) {
                let snapshotIndex = result.count - context.files.count + index
                let source = result[snapshotIndex]
                result[snapshotIndex] = .init(name: source.name, text: source.text, truncated: source.truncated, focused: true, readStatus: source.readStatus)
            }
            return result
        }
        return try await withTaskCancellationHandler { try await reading.value } onCancel: { reading.cancel() }
    }

    public func shutdown() async {
        preparation?.cancel()
        if let preparation { _ = await preparation.result }
        if let server { await server.stop() }
    }

    /// After a server start failure, keep working without a model for a while instead of waiting anew for every file.
    private var modelPausedUntil: Date?

    /// For checks: model answers from recordings (task, user text → JSON text) instead of from the server; `nil` = no answer.
    public typealias ModelReplay = @Sendable (Prompts.Task, String) -> String?
    private var replay: ModelReplay?
    public func setModelReplay(_ replay: ModelReplay?) { self.replay = replay }

    private func askModel<T: Decodable>(_ task: Prompts.Task, user: String, schema: String, name: String, as: T.Type) async throws -> T? {
        if let replay { return replay(task, user).flatMap { Self.decodeModelJSON(T.self, from: Data($0.utf8)) } }
        // During the first start the fixed flows keep working. A second
        // start from a document request would stop the still-starting server.
        guard preparation == nil else { return nil }
        if let until = modelPausedUntil, until > Date() { return nil }
        guard let server = await modelServer() else { return nil }
        let lease: LlamaServer.AgentLease
        do { lease = try await server.acquireAgentLease() }
        catch { return nil }
        // Directly to llama-server (LocalModelJSON).
        structuredBusy = true
        defer { structuredBusy = false }
        if !slotSaveTried {
            slotSaveTried = true
            if await server.saveConversationSlot() { parkedSlot = server }
        }
        do {
            // Classifying fills a few fields; a quarter of the context would let a runaway answer hold the slot for long.
            let data = try await LocalModelJSON.request(lease, system: Prompts.system(task), user: user, schema: schema, name: name,
                                                        maxTokens: task == .classify ? 300 : nil)
            if !holdSlot { await unparkSlot() }
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["PIPPA_ANALYSIS_TRACE_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent("\(name)-\(UUID().uuidString).json"))
            }
            #endif
            validatedModel = server.choice.model.key
            await server.releaseAgentLease(lease)
            return Self.decodeModelJSON(T.self, from: data)
        } catch {
            if !holdSlot { await unparkSlot() }
            await server.releaseAgentLease(lease)
            let code = (error as? LocalModelJSON.Failure).map { String(describing: $0).components(separatedBy: "(").first ?? "json" } ?? "modell"
            DiagnosticsLog.shared.event("analyse-fehler", ["code": code])
            #if DEBUG
            if ProcessInfo.processInfo.environment["PIPPA_LIVE"] == "1" { print("Pi-Analyse fehlgeschlagen: \(error.localizedDescription)") }
            #endif
            if await server.state != .ready { modelPausedUntil = Date().addingTimeInterval(120) }
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    private func unparkSlot() async {
        slotSaveTried = false
        guard let server = parkedSlot else { return }
        parkedSlot = nil
        await server.restoreConversationSlot()
    }

    /// Read the JSON of the model answer; tolerates text before or after the object (e.g. truncated fences).
    public nonisolated static func decodeModelJSON<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        if let v = try? JSONDecoder().decode(T.self, from: data) { return v }
        let s = String(decoding: data, as: UTF8.self)
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s[a...b].utf8))
    }

    // MARK: Reading

    nonisolated static let documentExtensions: Set<String> = ["pdf", "docx", "doc", "rtf", "rtfd", "odt", "txt", "md", "html", "htm", "eml", "csv"]

    private func text(_ url: URL, options: TextReader.Options = TextReader.Options(maxPages: 30)) async -> DocumentText {
        let fp = FileFingerprint.of(url)
        let key = url.standardizedFileURL.path + "|\(options.maxPages)|\(options.ocr)"
        if let fp, let hit = textCache[key], hit.0.matches(fp) { return hit.1 }
        let doc = await Task.detached(priority: .userInitiated) { TextReader.read(url, options: options) }.value
        if let fp { textCache[key] = (fp, doc) }
        if textCache.count > 2000 { textCache.removeAll() }
        return doc
    }

    /// Files of a folder (without hidden ones), optionally with subfolders.
    nonisolated static func files(in urls: [URL], depth: Int, limit: Int = 2000, onSkipped: ((String) -> Void)? = nil) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        func walk(_ url: URL, _ level: Int) {
            guard out.count < limit else { onSkipped?(L("At most %lld files were included.", table: "Core", limit)); return }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey])
            if v?.isSymbolicLink == true { onSkipped?(L("Linked files weren’t searched.", table: "Core")); return }
            if v?.isDirectory == true && v?.isPackage != true {
                guard level <= depth else { onSkipped?(L("Deeper subfolders weren’t searched.", table: "Core")); return }
                guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                    onSkipped?(L("Some folders couldn’t be read.", table: "Core")); return
                }
                for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) { walk(item, level + 1) }
            } else if v?.isDirectory != true {
                if !url.lastPathComponent.hasPrefix(".") { out.append(url) }
            }
        }
        for u in urls { walk(u, 0) }
        return out
    }

    // MARK: Overview (fast, without model)

    struct QuickLook: Sendable {
        var facts: FileFacts
        var doc: DocumentText?
        var category: DocCategory
    }

    /// Images without photo data are read for the overview (at most this many), so receipts don't count as photos.
    nonisolated static let overviewOCRLimit = 30

    nonisolated static func quickLook(_ url: URL, ocrImage: Bool = false) -> QuickLook {
        let facts = FileFacts.read(url)
        if facts.isImage {
            if facts.looksLikeScreenshot { return QuickLook(facts: facts, doc: nil, category: .other) }
            guard ocrImage, facts.captureDate == nil, facts.cameraModel == nil else { return QuickLook(facts: facts, doc: nil, category: .photo) }
            let doc = TextReader.read(url, options: TextReader.Options(maxPages: 1, ocr: true))
            return QuickLook(facts: facts, doc: doc.hasText ? doc : nil, category: .other)
        }
        let ext = url.pathExtension.lowercased()
        guard documentExtensions.contains(ext) || facts.type.conforms(to: .text) else {
            return QuickLook(facts: facts, doc: nil, category: .other)
        }
        let doc = TextReader.read(url, options: .quick)
        return QuickLook(facts: facts, doc: doc, category: .other)
    }

    nonisolated static func quickLooks(_ urls: [URL]) async -> [QuickLook] {
        // Only the first images without photo data get text recognition (overview speed).
        var budget = overviewOCRLimit
        let ocr: [Bool] = urls.map { u in
            guard budget > 0, UTType(filenameExtension: u.pathExtension.lowercased())?.conforms(to: .image) == true else { return false }
            budget -= 1
            return true
        }
        return await withTaskGroup(of: (Int, QuickLook).self) { group in
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
            var next = 0
            var results = [QuickLook?](repeating: nil, count: urls.count)
            while next < urls.count && next < width { let i = next; group.addTask { (i, quickLook(urls[i], ocrImage: ocr[i])) }; next += 1 }
            while let (i, look) = await group.next() {
                results[i] = look
                if next < urls.count { let j = next; group.addTask { (j, quickLook(urls[j], ocrImage: ocr[j])) }; next += 1 }
            }
            return results.compactMap { $0 }
        }
    }

    public func overview(of payload: DropPayload) async throws -> Overview {
        switch payload {
        case .text(let text):
            var facts: [(label: String, value: String)] = []
            if let d = GermanText.dates(in: text).first { facts.append((L("Date", table: "Core"), d.value.german)) }
            if let iban = GermanText.ibans(in: text).first { facts.append(("IBAN", iban)) }
            let words = text.split(whereSeparator: \.isWhitespace).count
            return Overview(title: L("Text", table: "Core"), subtitle: words == 1 ? L("1 word", table: "Core") : L("%lld words", table: "Core", words), kind: .text, facts: facts, actions: [])
        case .link(let url):
            return Overview(title: url.host ?? "Link", subtitle: L("I haven’t opened the link. Nothing has left this Mac.", table: "Core"), kind: .link)
        case .files(let urls):
            return await overview(files: urls)
        }
    }

    private func overview(files urls: [URL]) async -> Overview {
        let isFolder = urls.count == 1 && (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let files = Self.files(in: urls, depth: isFolder ? 1 : 0, limit: 500).filter { isFolder ? $0.deletingLastPathComponent().standardizedFileURL == urls[0].standardizedFileURL : true }
        let looks = await Self.quickLooks(files)
        var counts: [DocCategory: Int] = [:]
        for l in looks { counts[l.category, default: 0] += 1 }
        let categories = DocCategory.allCases.compactMap { c in counts[c].map { (name: c.label, count: $0) } }
        let readable = looks.contains { $0.doc?.hasText == true || $0.facts.isImage || $0.facts.isPDF }
        var actions: [Action] = []
        if !looks.isEmpty { actions.append(.sort) }
        if looks.contains(where: { $0.doc?.hasText == true || $0.facts.isPDF }) { actions.append(.invoiceTable) }
        if readable { actions.append(.ask) }
        let n = looks.count
        let countText = n == 1 ? L("1 file", table: "Core") : L("%lld files", table: "Core", n)

        if isFolder || looks.count != 1 {
            var facts: [(label: String, value: String)] = []
            let noText = looks.filter { $0.doc?.problem == .noText || $0.doc?.problem == .protected }.count
            if noText > 0 { facts.append((L("No readable text", table: "Core"), "\(noText)")) }
            let cloud = looks.filter { $0.doc?.problem == .cloudOnly }.count
            if cloud > 0 { facts.append((L("Only in the cloud", table: "Core"), "\(cloud)")) }
            let title = isFolder ? urls[0].lastPathComponent : L("%lld files", table: "Core", n)
            let kind: DropKind = isFolder ? .folder : Set(looks.map { Self.dropKind($0.facts) }).count == 1 ? (looks.first.map { Self.dropKind($0.facts) } ?? .mixed) : .mixed
            return Overview(title: title, subtitle: isFolder ? countText : L("Selection", table: "Core"), kind: kind, categories: categories, facts: facts, actions: actions)
        }

        // Single file
        let look = looks[0]
        let text = look.doc?.fullText ?? ""
        var facts: [(label: String, value: String)] = []
        var sender: String?
        var kindWord: String?
        // Same routes as tidying (Apple's on-device model first, ~3 s), then the evidence checks below.
        if let doc = look.doc, doc.hasText,
           let m = try? await classifyForTidy(name: look.facts.url.lastPathComponent, doc: doc).answer {
            if !m.absender.isEmpty, GermanText.normalize(text).contains(GermanText.normalize(m.absender)) { sender = Heuristics.displayName(m.absender) }
            if let sender { facts.append((L("Sender", table: "Core"), sender)) }
            if let d = GermanText.parseDate(m.datum), GermanText.dates(in: text).contains(where: { $0.value == d }) { facts.append((L("Date", table: "Core"), d.german)) }
            if !m.art.isEmpty, GermanText.normalize(text).contains(GermanText.normalize(m.art)) { kindWord = m.art }
        }
        if let iban = GermanText.ibans(in: text).first { facts.append(("IBAN", iban)) }
        if let subject = look.doc?.headers["subject"] { facts.insert((L("Subject", table: "Core"), subject), at: 0) }
        let title = [kindWord ?? (look.category == .photo ? L("Photo", table: "Core") : nil), sender].compactMap { $0 }.joined(separator: " · ")
        var subtitle = look.facts.url.lastPathComponent
        if let pages = look.facts.pdfPageCount { subtitle = pages == 1 ? L("%@ · 1 page", table: "Core", subtitle) : L("%@ · %lld pages", table: "Core", subtitle, pages) }
        if let att = look.doc?.attachments, !att.isEmpty { subtitle = att.count == 1 ? L("%@ · 1 attachment", table: "Core", subtitle) : L("%@ · %lld attachments", table: "Core", subtitle, att.count) }
        if look.doc?.problem == .protected { facts.append((L("Note", table: "Core"), L("Protected, so I can’t look inside.", table: "Core"))) }
        // Deadlines the code finds in the text (no model); for a single letter it's worth reading beyond page 1 (a
        // cancellation is often at the end). Anything further: "Add deadlines" hands the letter to Pi (fristen-erkennen).
        var deadlines: [Deadline] = []
        if look.doc?.hasText == true || look.facts.isPDF {
            let doc = await self.text(look.facts.url, options: TextReader.Options(maxPages: 10))
            let today = DayDate(Date())
            deadlines = Deadlines.find(in: doc, today: today).filter { $0.date.map { $0 >= today } ?? true }
        }
        if let first = deadlines.first {
            let value = deadlines.count == 1 ? first.title : L("%@ · and %lld more", table: "Core", first.title, deadlines.count - 1)
            facts.append((L("Deadline", table: "Core"), value))
        }
        if look.doc?.hasText == true || !deadlines.isEmpty { actions.insert(.deadlines, at: 0) }
        return Overview(title: title.isEmpty ? look.facts.url.lastPathComponent : title, subtitle: subtitle, kind: Self.dropKind(look.facts),
                        categories: categories, facts: facts, actions: actions, deadlines: deadlines, sender: sender)
    }

    nonisolated static func dropKind(_ f: FileFacts) -> DropKind {
        let ext = f.url.pathExtension.lowercased()
        if f.isPDF { return .pdf }
        if f.isImage { return .image }
        if f.isMail { return .mail }
        if DropKind.officeExtensions.contains(ext) { return .office }
        if f.type.conforms(to: .text) { return .text }
        return .other
    }

    // MARK: Sorting

    public func proposeSort(folder: URL) async throws -> Plan {
        try await proposeSort(items: nil, scope: folder, limit: nil, onUpdate: { _ in })
    }

    public func proposeSort(items: [URL], scope: URL) async throws -> Plan {
        try await proposeSort(items: items, scope: scope, limit: nil, onUpdate: { _ in })
    }

    /// Pre-sort immediately by type, name, photo data and identical contents (`PreSort`);
    /// unclear documents are then read by Pi using the bundled skills.
    /// After stage 1 and after each further file, the grown plan goes to `onUpdate`.
    public func proposeSort(items: [URL]?, scope: URL, limit: Int?, onUpdate: @escaping @Sendable (Plan) -> Void) async throws -> Plan {
        try beginInferenceWork()
        defer { inferenceWorkBusy = false; progress = nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scope.path, isDirectory: &isDir), isDir.boolValue else { throw PippaError.scopeMissing }
        let all = (items ?? Self.files(in: [scope], depth: 1).filter { $0.deletingLastPathComponent().standardizedFileURL == scope.standardizedFileURL })
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        var batch = all, remaining: [URL] = []
        if let limit, all.count > limit {
            let newest = PreSort.newestFirst(all)
            batch = Array(newest.prefix(limit)); remaining = Array(newest.dropFirst(limit))
        }
        let guardrail = PathGuard(scope: scope)
        let copies = PreSort.duplicates(in: all.filter { guardrail.contains($0) })
        var insights: [DocInsight] = []
        var skipped: [(url: URL, why: String)] = []
        var later: [URL] = []
        var plan = Plan(scope: scope, ops: [], skipped: [])
        var published = Date.distantPast
        func publish(pending: [URL]) {
            plan = Self.buildPlan(scope: scope, insights: insights, skipped: skipped, keepingIDsOf: plan)
            plan.pending = pending
            plan.remaining = remaining
            plan.later = later
            onUpdate(plan)
            published = Date()
        }

        // 1. Without reading
        var toRead: [URL] = []
        for url in batch {
            guard guardrail.contains(url) else { skipped.append((url, L("It’s outside the folder, so it stays where it is.", table: "Core"))); continue }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                skipped.append((url, L("It’s only a link, so it stays where it is.", table: "Core"))); continue
            }
            if let placed = copies[url].map({ PreSort.duplicate(url, of: $0) }) ?? PreSort.place(FileFacts.read(url)) {
                if let why = placed.skipReason { skipped.append((url, why)) } else { insights.append(placed) }
            } else {
                toRead.append(url)
            }
        }
        publish(pending: toRead)

        // 2. Reading, keywords: clear cases get their place, unclear ones wait for the model.
        var unclear: [URL] = []
        for (i, url) in toRead.enumerated() {
            try Task.checkCancellation()
            step(i, of: toRead.count, url)
            let insight = try await insight(for: url, model: false)
            if let why = insight.skipReason { skipped.append((url, why)) }
            else if insight.certainty == .sure { insights.append(insight) }
            else { unclear.append(url) }
            // Reading is fast: at most one new preview every 0.3 s, the end of this stage always.
            if i == toRead.count - 1 || Date().timeIntervalSince(published) > 0.3 { publish(pending: Array(toRead.dropFirst(i + 1)) + unclear) }
        }

        // 3. Model, only for unclear ones (TidyClassifier: system model first, else the local one; short excerpt, time limit).
        // If none is there (still loading, waking up, not answering), Pippa doesn't guess: the document stays put and goes
        // to `later`, for one round, once the model is ready. Small, text-rich files first, so the progress moves visibly.
        unclear = TidyClassifier.readingOrder(unclear)
        // One save and one restore of Pi's cache for the whole stage, not one per file.
        holdSlot = true
        defer { holdSlot = false }
        do {
            for (i, url) in unclear.enumerated() {
                try Task.checkCancellation()
                guard canClassify else {
                    later += unclear.dropFirst(i)
                    publish(pending: [])
                    break
                }
                step(i, of: unclear.count, url)
                let insight = try await insight(for: url, model: true)
                if let why = insight.skipReason { skipped.append((url, why)) }
                else if insight.fromModel { insights.append(insight) }
                else { later.append(url) }
                publish(pending: Array(unclear.dropFirst(i + 1)))
            }
        } catch {
            await unparkSlot()
            throw error
        }
        await unparkSlot()
        return plan
    }

    /// Can stage 3 classify now (system model or local model)? No side effects.
    var canClassify: Bool {
        TidyClassifier.canClassify(replay: replay != nil, appleAvailable: TidyClassifier.appleAvailable, localReady: canAskModel)
    }

    /// One unclear document while tidying: the routes of `TidyClassifier` in order, each with the per-file time limit.
    private func classifyForTidy(name: String, doc: DocumentText) async throws -> (answer: ClassifyJSON?, outcome: TidyClassifier.Outcome) {
        let prompt = TidyClassifier.prompt(name: name, doc: doc)
        let system = Prompts.system(.classify)
        var outcomes: [TidyClassifier.Outcome] = []
        for route in TidyClassifier.routes(replay: replay != nil, appleAvailable: TidyClassifier.appleAvailable, localReady: canAskModel) {
            let started = Date()
            let (answer, timedOut) = try await TidyClassifier.withTimeout(TidyClassifier.perFileTimeout(route)) { [self] () async throws -> ClassifyJSON? in
                switch route {
                case .apple: try await TidyClassifier.askApple(system: system, prompt: prompt)
                case .local: try await self.askModel(.classify, user: prompt, schema: Prompts.classifySchema, name: "einordnung", as: ClassifyJSON.self)
                }
            }
            DiagnosticsLog.shared.event("einordnen", ["weg": route.rawValue, "ms": String(Int(Date().timeIntervalSince(started) * 1000)),
                                                      "ergebnis": answer != nil ? "ja" : timedOut ? "zeit" : "nein"])
            if let answer { return (answer, .answered) }
            outcomes.append(timedOut ? .timedOut : .declined)
        }
        return (nil, TidyClassifier.settle(outcomes))
    }

    /// Can stage 3 ask the model now? No side effects: starts no server and loads nothing.
    /// On this Mac only with a loaded model file, outside the first start and not shortly after a failure.
    var canAskModel: Bool {
        if replay != nil { return true }
        guard preparation == nil, modelPausedUntil.map({ $0 <= Date() }) ?? true else { return false }
        if shared != nil { return modelEnabled }
        guard modelEnabled, case .success(let c) = choice, modelFile(c) != nil, LlamaServer.binaryURL() != nil else { return false }
        return true
    }

    /// Classification of an unclear document by Pi with native evidence check.
    func insight(for url: URL, model: Bool) async throws -> DocInsight {
        let facts = FileFacts.read(url)
        if facts.isImage {
            // No camera photo, name sounds like a receipt: maybe a photographed receipt
            let doc = await text(url)
            if doc.hasText { return try await documentInsight(url: url, facts: facts, doc: doc, model: model) }
            return DocInsight(url: url, facts: facts, category: .other, reason: L("Image without camera details, no receipt recognized", table: "Core"),
                              certainty: .sure, folder: PreSort.images)
        }
        let doc = await text(url)
        switch doc.problem {
        case .protected:
            return DocInsight(url: url, facts: facts, text: doc, category: .other, reason: "", certainty: .unreadable,
                              skipReason: L("Protected. I can’t look inside, so the file stays where it is.", table: "Core"))
        case .noText, .unsupported, .damaged:
            return DocInsight(url: url, facts: facts, text: doc, category: .other, reason: "", certainty: .unreadable,
                              skipReason: L("I can’t make out any text. I won’t guess, so the file stays where it is.", table: "Core"))
        default: break
        }
        return try await documentInsight(url: url, facts: facts, doc: doc, model: model)
    }

    private func documentInsight(url: URL, facts: FileFacts, doc: DocumentText, model: Bool) async throws -> DocInsight {
        let text = doc.fullText
        let name = url.lastPathComponent
        var insight = DocInsight(url: url, facts: facts, text: doc, category: .other, reason: "", certainty: .unsure)
        var fromModel = false
        var unbacked = false
        var classified: ClassifyJSON?
        if model {
            let (answer, outcome) = try await classifyForTidy(name: name, doc: doc)
            // Too slow everywhere: no guessing and no waiting, the file stays where it is (calm note in the preview).
            if outcome == .timedOut {
                return DocInsight(url: url, facts: facts, text: doc, category: .other, reason: "", certainty: .unreadable,
                                  skipReason: L("Reading this one took too long. It stays where it is for now.", table: "Core"))
            }
            classified = answer
        }
        if let m = classified {
            fromModel = true
            insight.fromModel = true
            let modelCategory: DocCategory? = switch m.kategorie {
            case "rechnung": .invoice
            case "vertrag", "brief": .contract
            default: nil
            }
            if let modelCategory { insight.category = modelCategory }
            unbacked = m.beleg.map { !GermanText.isVerbatim($0, in: text, minLength: 8) } ?? true
            let norm = GermanText.normalize(text)
            let sender = Heuristics.stripLegalForm(m.absender)
            if sender.count >= 3, norm.contains(GermanText.normalize(sender)) { insight.sender = Heuristics.displayName(sender) }
            if let d = GermanText.parseDate(m.datum), GermanText.dates(in: text).contains(where: { $0.value == d }) { insight.date = d }
            let subject = Naming.sanitize(m.betreff, maxLength: 50)
            if !subject.isEmpty, norm.contains(GermanText.normalize(subject)) { insight.subject = subject }
            let art = Naming.sanitize(m.art, maxLength: 30)
            if !art.isEmpty, norm.contains(art.lowercased()) { insight.kind = art.prefix(1).uppercased() + art.dropFirst() }
            // "Draft" only if it appears in the text or name; the model's self-report is not enough.
            if m.entwurf, let beleg = m.entwurf_beleg, GermanText.isVerbatim(beleg, in: text, minLength: 4),
               beleg.range(of: #"(?i)\b(?:Entwurf|Draft)\b"#, options: .regularExpression) != nil { insight.draft = true }
        }
        if insight.category == .invoice && insight.kind == nil { insight.kind = "Rechnung" }
        let confident = !unbacked && insight.sender != nil && (insight.date != nil || insight.category == .contract)
        insight.certainty = confident ? .sure : .unsure
        if insight.category == .other {
            insight.folder = PreSort.documents
            // Without a model, contents stay unclassified.
            if !fromModel { insight.certainty = .unsure }
        }
        var parts: [String] = []
        if insight.sender != nil { parts.append(L("sender", table: "Core")) }
        if insight.date != nil { parts.append(insight.category == .invoice ? L("invoice date", table: "Core") : L("date", table: "Core")) }
        if let k = insight.kind, insight.category == .contract { parts.insert(L("heading “%@”", table: "Core", k), at: 0) }
        var reason = L("Suggested from the content", table: "Core")
        if !parts.isEmpty { reason = L("Recognized: %@", table: "Core", parts.joined(separator: L(" and ", table: "Core"))) }
        if doc.isPaged { reason = L("%@ in the pages read", table: "Core", reason) }
        if doc.usedOCR { reason = L("%@ (text read from the image)", table: "Core", reason) }
        if insight.draft { reason = L("%@, marked as a draft", table: "Core", reason) }
        if !fromModel && insight.category == .other { reason = L("Not sorted yet", table: "Core") }
        if unbacked { reason = L("%@. The kind of document isn’t confirmed by its text", table: "Core", reason) }
        insight.reason = reason
        return insight
    }

    /// Builds names and folders (code only) and from them the plan.
    /// `keepingIDsOf`: an earlier plan of the same preview. The same source (or same new folder) keeps its ID,
    /// so deselections hold while the preview grows.
    nonisolated static func buildPlan(scope: URL, insights: [DocInsight], skipped: [(url: URL, why: String)], keepingIDsOf previous: Plan? = nil) -> Plan {
        let fm = FileManager.default
        var ids: [String: UUID] = [:]
        for op in previous?.ops ?? [] { ids[(op.source ?? op.target).standardizedFileURL.path] = op.id }
        func id(_ url: URL) -> UUID { ids[url.standardizedFileURL.path] ?? UUID() }
        var ops: [PlanOp] = []
        var taken = Set<String>()
        var folders: [String] = []
        var photoCounter: [String: Int] = [:]

        func folderURL(_ rel: String) -> URL {
            var url = scope
            for part in rel.split(separator: "/") { url = url.appendingPathComponent(String(part), isDirectory: true) }
            return url
        }
        // If already in "Rechnungen" or "Rechnungen/2024", don't create "Rechnungen/2024" inside again.
        // If in another subfolder of the category ("Rechnungen/2026" for a 2025 invoice),
        // the file stays here: not "Rechnungen/2026/Rechnungen/2025" and not out of the chosen folder.
        let scopeParts = scope.standardizedFileURL.pathComponents.map { $0.lowercased() }
        func withinScope(_ rel: String) -> String {
            let parts = rel.split(separator: "/").map(String.init)
            let lower = parts.map { $0.lowercased() }
            for k in stride(from: min(parts.count, scopeParts.count), through: 1, by: -1)
            where Array(scopeParts.suffix(k)) == Array(lower.prefix(k)) {
                return parts.dropFirst(k).joined(separator: "/")
            }
            for k in stride(from: min(parts.count, scopeParts.count - 1), through: 1, by: -1)
            where Array(scopeParts.dropLast().suffix(k)) == Array(lower.prefix(k)) {
                return ""
            }
            return rel
        }

        // Number photos in capture order
        let ordered = insights.sorted { a, b in
            if a.category == .photo && b.category == .photo {
                return (a.facts.captureDate ?? a.facts.created ?? .distantPast) < (b.facts.captureDate ?? b.facts.created ?? .distantPast)
            }
            return false
        }
        let sorted = ordered.filter { $0.category != .photo } + ordered.filter { $0.category == .photo }

        for i in sorted {
            if i.duplicateOf != nil {
                ops.append(PlanOp(id: id(i.url), kind: .trash, source: i.url, target: i.url, reason: i.reason, certainty: i.certainty,
                                  fingerprint: FileFingerprint.of(i.url)))
                continue
            }
            let ext = i.url.pathExtension
            let rel: String
            var name: String
            switch i.category {
            case .invoice:
                rel = withinScope(Naming.folder(for: .invoice, year: i.date?.year))
                name = Naming.document(date: i.date, sender: i.sender, kind: i.kind ?? "Rechnung", ext: ext, draft: i.draft)
            case .contract:
                rel = withinScope(Naming.folder(for: .contract, year: nil))
                if let k = i.kind, k.lowercased().hasSuffix("vertrag") {
                    // "Mietvertrag Wohnung 2021", otherwise with sender: "Mobilfunkvertrag Vodafone 2025"
                    name = Naming.contract(kind: k, subject: k == "Mietvertrag" ? i.subject : i.sender, year: i.date?.year, ext: ext, draft: i.draft)
                } else {
                    name = Naming.document(date: i.date, sender: i.sender, kind: i.kind ?? "Brief", ext: ext, draft: i.draft)
                }
            case .photo:
                rel = withinScope(Naming.folder(for: .photo, year: i.date?.year))
                if let d = i.date {
                    var n = photoCounter[d.iso, default: 0]
                    repeat {
                        n += 1
                        name = Naming.photo(date: d, number: n, ext: ext)
                    } while fm.fileExists(atPath: folderURL(rel).appendingPathComponent(name).path) || taken.contains(folderURL(rel).appendingPathComponent(name).standardizedFileURL.path.lowercased())
                    photoCounter[d.iso] = n
                } else {
                    name = Naming.sanitize(i.url.lastPathComponent)
                }
            case .other:
                rel = withinScope(i.folder ?? Naming.folder(for: .other, year: nil))
                name = Naming.sanitize(i.url.lastPathComponent)
            }
            if name.isEmpty { name = i.url.lastPathComponent }
            // Create multiple folder levels individually
            var path = ""
            for part in rel.split(separator: "/") {
                path = path.isEmpty ? String(part) : path + "/" + part
                if !folders.contains(path) && !fm.fileExists(atPath: folderURL(path).path) { folders.append(path) }
            }
            let dir = folderURL(rel)
            let target = Naming.unique(name, in: dir, taken: &taken)
            if target.standardizedFileURL.path == i.url.standardizedFileURL.path { continue }
            let kind: PlanOp.Kind = dir.standardizedFileURL.path == i.url.deletingLastPathComponent().standardizedFileURL.path ? .rename : .move
            ops.append(PlanOp(id: id(i.url), kind: kind, source: i.url, target: target, reason: i.reason, certainty: i.certainty,
                              fingerprint: FileFingerprint.of(i.url)))
        }
        let mkdirs = folders.map { PlanOp(id: id(folderURL($0)), kind: .mkdir, source: nil, target: folderURL($0), reason: L("New folder", table: "Core"), certainty: .sure) }
        return Plan(scope: scope, ops: mkdirs + ops, skipped: skipped)
    }

    public func apply(_ plan: Plan, excluding: Set<UUID>) async throws -> JobReceipt {
        try await requireExecutor().apply(plan, excluding: excluding).receipt
    }

    // MARK: Integrations

    public func integrationAccess(_ integration: Integration) async -> IntegrationAccess { await integrations.access(integration) }
    public func requestIntegrationAccess(_ integration: Integration) async -> IntegrationAccess { await integrations.requestAccess(integration) }

    /// An entry in another app with a journal: started, created (receipt with undo) or failed.
    /// `create` receives the job ID, so the entry can be matched even after a crash.
    private func recordExternal(_ integration: Integration, label: String, summary: String, detail: String, undoDetail: String,
                                create: (UUID) async throws -> CreatedItem) async throws -> JobReceipt {
        let ex = try requireExecutor()
        let (job, seq) = try await ex.beginExternal(integration, label: label)
        do {
            let item = try await create(job)
            var receipt = try await ex.completeExternal(job: job, seq: seq, item: item, summary: summary, detail: detail)
            receipt.undoDetail = undoDetail
            receipt.integration = integration
            return receipt
        } catch {
            try? await ex.failExternal(job: job, seq: seq, why: SystemError.reason(error))
            // Never show the other app's error in the system's wording.
            throw (error as? PippaError) ?? PippaError.entryFailed("")
        }
    }

    public func addEntry(_ entry: CalendarEntry) async throws -> JobReceipt {
        let reminder = entry.target == .reminder
        return try await recordExternal(entry.integration, label: entry.title,
                                        summary: reminder ? L("Added to Reminders", table: "Core") : L("Added to Calendar", table: "Core"),
                                        detail: "\(entry.title) · \(entry.date.german)",
                                        undoDetail: reminder ? L("The reminder is gone again.", table: "Core") : L("The event is gone again.", table: "Core")) { job in
            // ID in the entry itself, so it stays recognizable as Pippa's entry even after a crash.
            try await integrations.add(entry, tag: URL(string: "pippa://job/\(job.uuidString)")!)
        }
    }

    public func selectedMail() async throws -> MailMessage? { try await integrations.selectedMail() }
    public func readCalendar(_ range: CalendarRange) async -> CalendarReadResult { await CalendarReader.read(range, from: integrations) }

    // Sheet: read only.
    public func sheetAccess() async -> IntegrationAccess { await sheets.sheetAccess() }
    public func requestSheetAccess() async -> IntegrationAccess { await sheets.requestSheetAccess() }
    public func selectedSheet() async throws -> SheetSnapshot? { try await sheets.selectedSheet() }

    /// Unsent reply window in Mail. Never sends; no attempt without Mail permission.
    public func insertMailReply(_ draft: MailDraft) async throws -> MailInsertResult {
        guard await integrations.access(.mail) == .granted else { throw PippaError.accessDenied(Integration.mail.appName) }
        return try await integrations.insertReply(draft)
    }

    /// After a call, keep the loaded model longer. Starts no model.
    public func keepWarmAfterCall() async {
        await server?.keepWarm(for: LlamaServer.afterCallSeconds)
    }

    // MARK: Undo, resume

    public func undo(_ receipt: JobReceipt) async throws {
        let ex = try requireExecutor()
        if let items = try await ex.externalItems(jobID: receipt.id) {
            var restored = 0
            var notRestored: [FileReason] = []
            let name = receipt.integration.map { $0 == .calendar ? L("Event", table: "Core") : L("Reminder", table: "Core") } ?? L("Entry", table: "Core")
            for e in items {
                switch try await integrations.remove(e.item) {
                case .removed, .gone:
                    try await ex.markExternal(job: receipt.id, seq: e.seq, undone: true); restored += 1
                case .changed:
                    try await ex.markExternal(job: receipt.id, seq: e.seq, undone: false, note: L("changed in the meantime", table: "Core"))
                    notRestored.append(FileReason(name: name, why: L("It has changed since then, so it stays.", table: "Core")))
                }
            }
            try await ex.finishExternalUndo(job: receipt.id, complete: notRestored.isEmpty)
            if !notRestored.isEmpty { throw PippaError.undoIncomplete(restored: restored, conflicts: notRestored.count, notRestored: notRestored) }
            return
        }
        let report = try await requireExecutor().undo(jobID: receipt.id)
        if !report.conflicts.isEmpty {
            throw PippaError.undoIncomplete(restored: report.restored, conflicts: report.conflicts.count,
                                            notRestored: report.conflicts.map { FileReason(name: $0.url.lastPathComponent, why: $0.why) })
        }
    }

    public func recordResult(_ files: [URL], summary: String, detail: String) async throws -> JobReceipt {
        try await requireExecutor().recordResult(files, summary: summary, detail: detail)
    }

    public func recentJobs(limit: Int) async -> [JobReceipt] {
        guard let executor else { return [] }
        return await executor.recentJobs(limit: limit)
    }

    public func pendingRecovery() async -> [JobReceipt] {
        guard let executor else { return [] }
        return await executor.pendingRecovery()
    }

    public func resume(_ receipt: JobReceipt) async throws -> JobReceipt {
        try await requireExecutor().resume(jobID: receipt.id).receipt
    }

    public func dismissRecovery(_ receipt: JobReceipt) async {
        try? await executor?.dismissRecovery(jobID: receipt.id)
    }
}
