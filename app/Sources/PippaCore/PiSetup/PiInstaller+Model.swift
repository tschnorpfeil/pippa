import Darwin
import Foundation

extension PiInstaller {
    // MARK: 3. Model folder

    /// No question: `<Support>/omlx/models`, the folder Pippa's oMLX server reads; one subfolder per model, named by its key.
    public func prepareModelsFolder() -> PiStepResult {
        begin(.modelsFolder)
        let folder = PiLocalServer.baseDirectory(support: roots.support).appendingPathComponent("models", isDirectory: true)
        do {
            try makeDirectory(folder)
            ModelDownloader(directory: folder).excludeFromBackup()
        } catch { return finish(.modelsFolder, .failed(failure(error, path: folder))) }
        state.modelsFolder = folder.path
        state.modelsFolderShared = false
        return finish(.modelsFolder, .modelsFolder(folder, shared: false))
    }

    /// Where a model's files go: `<models folder>/<key>/`; the folder name is the id oMLX serves.
    public func modelDirectory(_ model: CatalogModel) -> URL? {
        state.modelsFolder.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(model.key, isDirectory: true) }
    }

    /// What Pippa before 0.4 left for llama.cpp, once the new model is ready: her GGUF model folder `<Support>/models`,
    /// the saved prompt cache `<Support>/llama-slots`, and in a shared `~/models` only the files she put there herself.
    /// Several GB on most Macs; they go to the Trash, never deleted for good.
    public static func oldModelFiles(support: URL, home: URL, state: PiInstallState) -> [URL] {
        let fm = FileManager.default
        var result = ["models", "llama-slots"].map { support.appendingPathComponent($0, isDirectory: true) }.filter { fm.fileExists(atPath: $0.path) }
        let shared = home.appendingPathComponent("models", isDirectory: true).standardizedFileURL.path + "/"
        result += state.created.filter { $0.hasPrefix(shared) && ($0.hasSuffix(".gguf") || $0.hasSuffix(".gguf.ok")) }
            .map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
        return result
    }

    // MARK: 4. Model

    /// Is the model verified in the model folder? Otherwise adopt without asking (clone -> hardlink -> copy, the copy only
    /// with enough free space), otherwise `.needsDownload` (then `downloadModel`). Originals are never moved,
    /// changed or deleted. A wrong file of Pippa's own (an older download, a broken adoption) is removed and loaded
    /// again; a found file of another program that doesn't match is skipped. Only a wrong file the person put into a
    /// shared `~/models` stops setup, because the download would have to replace it.
    public func provideModel(_ model: CatalogModel, searchRoots: [ModelLocation]? = nil) -> PiStepResult {
        begin(.model)
        guard let folder = modelDirectory(model) else { return finish(.model, .failed(.missingStep(.modelsFolder))) }
        guard let files = model.pinned?.files, !files.isEmpty else { return finish(.model, .failed(.missingStep(.model))) }
        do { try makeDirectory(folder) } catch { return finish(.model, .failed(failure(error, path: folder))) }
        let downloader = ModelDownloader(directory: folder)
        let found = ExistingModels.find(model, roots: searchRoots ?? ExistingModels.defaultRoots(home: roots.home))
        var lastMethod: PiAdoptionMethod?, lastSource: String?, missing: Int64 = 0, incomplete = false
        do {
            for file in files where !downloader.isInstalled(file) {
                let dest = downloader.localURL(file)
                if fm.fileExists(atPath: dest.path) {
                    if ModelDownloader.fileSize(dest) == file.size, try FileDigest.sha256(of: dest) == file.sha256 {
                        try file.sha256.write(to: dest.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
                        state.record(dest.appendingPathExtension("ok"))
                        continue
                    }
                    DiagnosticsLog.shared.event("modell-ersetzt", ["datei": dest.lastPathComponent])
                    for stale in [dest, dest.appendingPathExtension("ok")] {
                        try? fm.removeItem(at: stale)
                        state.forget(stale)
                    }
                    state.adopted.removeAll { $0.file == dest.path }
                    save()
                }
                // A started download (.part) counts with what is still missing, as in ModelDownloader.downloadSize.
                let rest = max(0, file.size - max(0, ModelDownloader.fileSize(dest.appendingPathExtension("part"))))
                guard let source = found[file.sha256] else { missing += rest; incomplete = true; continue }
                switch try adopt(file, from: source, into: folder) {
                case .adopted(let method): lastMethod = method; lastSource = source.source
                case .unavailable: missing += rest; incomplete = true
                case .mismatch:
                    // Same name and size, other content (e.g. an older upload in LM Studio): load the right one instead.
                    DiagnosticsLog.shared.event("modell-uebernahme-passt-nicht", ["quelle": source.source])
                    missing += rest; incomplete = true
                }
            }
        } catch { return finish(.model, .failed(failure(error, path: folder))) }
        // Also when every byte is in but not yet checked: the download step verifies and renames the .part file.
        if incomplete { return finish(.model, .needsDownload(bytes: missing)) }
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
        guard let folder = modelDirectory(model) else { return finish(.model, .failed(.missingStep(.modelsFolder))) }
        let path = folder.path
        do { try await download(model, folder, progress) }
        catch let error as PippaError {
            switch error {
            case .notEnoughSpace(let bytes): return finish(.model, .failed(.notEnoughSpace(bytes: bytes)))
            case .checksumMismatch: return finish(.model, .failed(.downloadDamaged))
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
        for file in model.pinned?.files ?? [] {
            let dest = folder.appendingPathComponent((file.path as NSString).lastPathComponent)
            state.record(dest); state.record(dest.appendingPathExtension("ok"))
        }
        save()
        return provideModel(model, searchRoots: [])
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
        do { hash = try FileDigest.sha256(of: temporary) } catch { try? fm.removeItem(at: temporary); throw error }
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
}
