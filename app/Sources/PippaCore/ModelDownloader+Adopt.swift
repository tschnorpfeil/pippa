import Foundation

extension ModelDownloader {
    // MARK: Adopting

    /// Adopts a file that already lies on this Mac: copy into Pippa's folder, on APFS as a clone (instant, no
    /// extra space, the source stays untouched). As with downloads, the copy itself is verified (SHA256), once;
    /// the hash decides which of the equally sized `candidates` it is. `nil`: none matches, nothing is left behind.
    /// `onBytes`: verified bytes.
    public func adopt(from source: URL, candidates: [CatalogModel.File], onBytes: ((Int64) -> Void)? = nil) throws -> CatalogModel.File? {
        let size = Self.fileSize(source)
        let matching = candidates.filter { $0.size == size }
        guard let first = matching.first else { return nil }
        let fm = FileManager.default
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw writeFailure(error, remaining: size) }
        excludeFromBackup()
        let copy = localURL(first).appendingPathExtension("import")
        try? fm.removeItem(at: copy) // leftover of an aborted adoption
        // Other volume: no clone possible, the copy needs real space.
        if !Self.sameVolume(source, directory),
           let shortfall = Self.spaceShortfall(available: Self.availableSpace(at: directory), remaining: size) {
            throw PippaError.notEnoughSpace(bytes: shortfall)
        }
        do { try fm.copyItem(at: source, to: copy) } // APFS: clonefile
        catch { try? fm.removeItem(at: copy); throw writeFailure(error, remaining: size) }
        let hash: String
        do { hash = try FileDigest.sha256(of: copy, onBytes: onBytes) }
        catch {
            try? fm.removeItem(at: copy)
            if error is CancellationError { throw error }
            throw writeFailure(error, remaining: 0)
        }
        guard let file = matching.first(where: { $0.sha256 == hash }), Self.fileSize(copy) == file.size else {
            try? fm.removeItem(at: copy) // our own copy
            return nil
        }
        let dest = localURL(file)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: copy, to: dest)
            try file.sha256.write(to: dest.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
        } catch { try? fm.removeItem(at: copy); throw writeFailure(error, remaining: 0) }
        try? fm.removeItem(at: dest.appendingPathExtension("part")) // a started download is no longer needed
        return file
    }

    public func adopt(_ file: CatalogModel.File, from source: URL, onBytes: ((Int64) -> Void)? = nil) throws -> Bool {
        try adopt(from: source, candidates: [file], onBytes: onBytes) != nil
    }

    /// Without consent to download: a found file didn't match (content, read error). Nothing is downloaded.
    public struct AdoptionFailed: Error, Sendable { public var sha256: String }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var probe = b
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let left = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let right = try? probe.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let left, let right else { return false }
        return left.isEqual(right)
    }
}
