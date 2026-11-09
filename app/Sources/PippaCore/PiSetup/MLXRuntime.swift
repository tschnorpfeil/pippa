import Foundation

/// The Python runtime with oMLX that serves Pippa's model, downloaded at setup next to the model (docs/omlx-switch.md).
/// One archive per version, built by scripts/build-mlx-runtime.sh and named in Resources/mlx-runtime.json with size and
/// SHA-256; unpacked to `<Support>/mlx-runtime/<version>/`, marked installed by `.ok` with the archive's hash.
///
/// Development: `PIPPA_MLX_RUNTIME_DIR` uses an unpacked runtime as it is; `PIPPA_MLX_RUNTIME_ARCHIVE` installs from a
/// local archive instead of the URL (the hash is still checked).
public struct MLXRuntime: Sendable {
    public struct Manifest: Codable, Sendable, Equatable {
        public var version: String
        public var omlx: String
        public var file: String
        public var size: Int64
        public var sha256: String
        public var url: URL
    }

    public let manifest: Manifest
    public let support: URL
    let environment: [String: String]

    public init?(support: URL, environment: [String: String] = ProcessInfo.processInfo.environment, manifest: Manifest? = MLXRuntime.bundledManifest()) {
        guard let manifest else { return nil }
        self.manifest = manifest; self.support = support; self.environment = environment
    }

    public static func bundledManifest() -> Manifest? {
        guard let url = Bundle.module.url(forResource: "mlx-runtime", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    var root: URL { support.appendingPathComponent("mlx-runtime", isDirectory: true) }
    public var directory: URL {
        if let dev = environment["PIPPA_MLX_RUNTIME_DIR"], !dev.isEmpty { return URL(fileURLWithPath: dev, isDirectory: true) }
        return root.appendingPathComponent(manifest.version, isDirectory: true)
    }
    public var python: URL { directory.appendingPathComponent("bin/python3") }
    var marker: URL { directory.appendingPathComponent(".ok") }
    var partial: URL { root.appendingPathComponent(manifest.file + ".part") }

    public var isInstalled: Bool {
        if environment["PIPPA_MLX_RUNTIME_DIR"]?.isEmpty == false { return FileManager.default.isExecutableFile(atPath: python.path) }
        let mark = try? String(contentsOf: marker, encoding: .utf8)
        return mark?.trimmingCharacters(in: .whitespacesAndNewlines) == manifest.sha256 && FileManager.default.isExecutableFile(atPath: python.path)
    }

    /// Bytes still to download; 0 when installed or installing from a local archive.
    public var remainingBytes: Int64 {
        if isInstalled || environment["PIPPA_MLX_RUNTIME_ARCHIVE"]?.isEmpty == false { return 0 }
        return manifest.size
    }

    /// Download (or take the local archive), check the hash, unpack, mark installed, remove other versions.
    /// `progress`: 0…1 of the download.
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled { return }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let archive: URL
        if let local = environment["PIPPA_MLX_RUNTIME_ARCHIVE"], !local.isEmpty {
            archive = URL(fileURLWithPath: local)
        } else {
            if let shortfall = ModelDownloader.spaceShortfall(available: ModelDownloader.availableSpace(at: root), remaining: manifest.size * 3) {
                throw PippaError.notEnoughSpace(bytes: shortfall)
            }
            try await ResumableDownload(directory: root).download(manifest.url, to: partial, size: manifest.size) { progress(Double($0) / Double(manifest.size)) }
            archive = partial
        }
        progress(1)
        guard try FileDigest.sha256(of: archive) == manifest.sha256 else {
            if archive == partial { try? fm.removeItem(at: partial) }
            throw PippaError.checksumMismatch
        }
        let unpacking = root.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: unpacking, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: unpacking) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", unpacking.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw PippaError.writeFailed("tar \(tar.terminationStatus)") }
        // The archive holds one top folder (bin/, lib/ …) or the files directly.
        let entries = try fm.contentsOfDirectory(at: unpacking, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        let top = entries.count == 1 && !fm.fileExists(atPath: unpacking.appendingPathComponent("bin").path) ? entries[0] : unpacking
        try? fm.removeItem(at: directory)
        try fm.moveItem(at: top, to: directory)
        try manifest.sha256.write(to: marker, atomically: true, encoding: .utf8)
        if archive == partial { try? fm.removeItem(at: partial) }
        for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != manifest.version && !old.lastPathComponent.hasPrefix(".") && old != partial {
            try? fm.removeItem(at: old)
        }
        try? (root as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }
}
