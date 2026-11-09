import Foundation

/// Downloads model files from Hugging Face: resumable (.part + Range), SHA256 verified before renaming.
public final class ModelDownloader: @unchecked Sendable {
    public static let endpoint = ProcessInfo.processInfo.environment["PIPPA_HF_ENDPOINT"] ?? "https://huggingface.co"

    public let directory: URL
    /// Where `download` fetches from; checks point it at a loopback fixture.
    public var source = ModelDownloader.endpoint
    /// The transfer of one file at a time (`download`).
    private let transfer: ResumableDownload
    /// No bytes and no completion for this long ends a download attempt.
    public var stallTimeout: TimeInterval {
        get { transfer.stallTimeout }
        set { transfer.stallTimeout = newValue }
    }
    public init(directory: URL) { self.directory = directory; transfer = ResumableDownload(directory: directory) }

    public static func url(repo: String, revision: String, path: String, endpoint: String = endpoint) -> URL {
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "\(endpoint)/\(repo)/resolve/\(revision)/\(encoded)")!
    }

    public func localURL(_ file: CatalogModel.File) -> URL {
        directory.appendingPathComponent((file.path as NSString).lastPathComponent)
    }

    /// Fully downloaded and verified? (Size plus `.ok` marker with the hash.)
    public func isInstalled(_ model: CatalogModel) -> Bool {
        guard let files = model.pinned?.files, !files.isEmpty else { return false }
        return files.allSatisfy(isInstalled)
    }

    /// Current file size (of the target, for a symlinked model), -1 if the file does not exist. Not via `URL.resourceValues`: it caches the first
    /// value per URL, and resuming then kept restarting from the same spot (the .part file grew endlessly).
    public static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    func isInstalled(_ f: CatalogModel.File) -> Bool {
        let url = localURL(f)
        let size = Self.fileSize(url)
        let mark = try? String(contentsOf: url.appendingPathExtension("ok"), encoding: .utf8)
        return size == f.size && mark?.trimmingCharacters(in: .whitespacesAndNewlines) == f.sha256
    }

    public func primaryFile(_ model: CatalogModel) -> URL? { model.pinned?.files.first.map(localURL) }

    /// Total size and what is still missing (finished files don't count, partial ones only with the remainder).
    /// What is in `existing` (with another program) is not missing: it is adopted instead of downloaded.
    public func downloadSize(_ model: CatalogModel, existing: [String: ModelLocation] = [:]) -> ModelDownloadSize? {
        guard let files = model.pinned?.files, !files.isEmpty else { return nil }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var remaining: Int64 = 0, found: Int64 = 0
        var source: String?
        for f in files where !isInstalled(f) {
            if let e = existing[f.sha256] { found += f.size; source = source ?? e.source; continue }
            remaining += max(0, f.size - max(0, Self.fileSize(localURL(f).appendingPathExtension("part"))))
        }
        return ModelDownloadSize(total: total, remaining: remaining, existing: found, existingSource: source)
    }


    // MARK: Download

    /// Downloads all files. `progress(done 0…1, remaining time in s)`. Files from `existing` are adopted instead of downloaded.
    /// If one does not match, `rejected` reports its hash; it is then downloaded only with `allowNetwork`, else `AdoptionFailed`.
    public func download(_ model: CatalogModel, existing: [String: ModelLocation] = [:], allowNetwork: Bool = true,
                         rejected: @Sendable (String) -> Void = { _ in },
                         progress: @escaping @Sendable (Double, TimeInterval?) -> Void) async throws {
        guard let pinned = model.pinned else { throw PippaError.modelUnavailable }
        let total = pinned.files.reduce(Int64(0)) { $0 + $1.size }
        // File errors are not network errors: report as write error or full disk, not as "no internet".
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw writeFailure(error, remaining: total) }
        excludeFromBackup()
        // Check beforehand that the rest fits on disk, so it doesn't fail hours in.
        let remainingBytes = downloadSize(model, existing: existing)?.remaining ?? total
        if let shortfall = Self.spaceShortfall(available: Self.availableSpace(at: directory), remaining: remainingBytes) {
            throw PippaError.notEnoughSpace(bytes: shortfall)
        }
        var completed: Int64 = 0
        let started = Date()
        var startBytes: Int64? = nil
        for file in pinned.files {
            try Task.checkCancellation()
            let dest = localURL(file)
            if isInstalled(file) {
                completed += file.size; continue
            }
            if let found = existing[file.sha256] {
                let base = completed
                do {
                    if try adopt(file, from: found.url, onBytes: { progress(Double(base + $0) / Double(total), nil) }) {
                        DiagnosticsLog.shared.event("modell-uebernommen", ["quelle": found.source])
                        completed += file.size
                        progress(Double(completed) / Double(total), nil)
                        continue
                    }
                    DiagnosticsLog.shared.event("modell-uebernahme-passt-nicht", ["quelle": found.source])
                } catch is CancellationError { throw CancellationError() }
                catch let p as PippaError where Self.isOutOfSpace(p) { throw p }
                catch { DiagnosticsLog.shared.event("modell-uebernahme-fehler", ["quelle": found.source]) }
                rejected(file.sha256)
                // Without consent never silently fall back to the network.
                guard allowNetwork else { throw AdoptionFailed(sha256: file.sha256) }
                // Otherwise download as usual (the space checked earlier may not suffice then; the download notices).
            } else if !allowNetwork {
                throw AdoptionFailed(sha256: file.sha256)
            }
            let part = dest.appendingPathExtension("part")
            let base = completed
            let have = max(0, Self.fileSize(part))
            if startBytes == nil, have < file.size { startBytes = base + have }
            try await transfer.download(Self.url(repo: model.repo, revision: pinned.revision, path: file.path, endpoint: source), to: part, size: file.size) { bytes in
                let done = base + bytes
                let elapsed = Date().timeIntervalSince(started)
                let rate = elapsed > 2 ? Double(done - (startBytes ?? 0)) / elapsed : 0
                progress(Double(done) / Double(total), rate > 0 ? Double(total - done) / rate : nil)
            }
            let size = Self.fileSize(part)
            guard size == file.size else {
                try? FileManager.default.removeItem(at: part) // our own, incomplete temp file
                DiagnosticsLog.shared.event("download-unvollstaendig"); throw PippaError.downloadFailed("Die Datei ist unvollständig.")
            }
            let hash: String
            do { hash = try FileDigest.sha256(of: part) }
            catch { if error is CancellationError { throw error }; throw writeFailure(error, remaining: 0) }
            guard hash == file.sha256 else {
                try? FileManager.default.removeItem(at: part)
                DiagnosticsLog.shared.event("download-pruefsumme"); throw PippaError.checksumMismatch
            }
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: part, to: dest)
                try file.sha256.write(to: dest.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
            } catch { throw writeFailure(error, remaining: 0) }
            completed += file.size
            progress(Double(completed) / Double(total), nil)
        }
    }
}
