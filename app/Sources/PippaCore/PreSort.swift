import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Sorting without a model: whatever can be recognized by file type, name, photo data or identical content gets a place immediately.
/// Only documents are read (PDF, Word, text, images with receipt-like names); the model only sees those whose place stays unclear afterwards.
/// The file name stays for everything that gets a folder here (except camera photos, which are named by date as before).
public enum PreSort {
    /// The first time only the newest files, to keep the preview manageable; the rest follows afterwards.
    public static let firstRunLimit = 30

    static let screenshots = "Bildschirmfotos"
    static let images = "Bilder"
    static let videos = "Videos"
    static let music = "Musik"
    static let installers = "Installer (kann weg?)"
    static let archives = "Archive"
    static let duplicates = "Doppelt"
    static let documents = "Dokumente"

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "app"]
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    /// Office formats Pippa does not read: by kind to "Dokumente".
    static let officeExtensions: Set<String> = ["xlsx", "xls", "pptx", "ppt", "pages", "numbers", "key", "ods", "odp"]
    /// Images without camera data with such names could be photographed receipts: those are read.
    static let receiptHints = ["scan", "beleg", "quittung", "rechnung", "kassenbon", "receipt", "invoice"]

    /// Place without reading. `nil`: a document that has to be read.
    static func place(_ facts: FileFacts) -> DocInsight? {
        let url = facts.url
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        func folder(_ folder: String, _ reason: String) -> DocInsight {
            DocInsight(url: url, facts: facts, category: .other, reason: reason, certainty: .sure, folder: folder)
        }
        if FileFacts.isCloudPlaceholder(url) {
            return DocInsight(url: url, facts: facts, category: .other, reason: "", certainty: .unreadable,
                              skipReason: L("Only in the cloud. I don’t download anything, so the file stays as it is.", table: "Analysis"))
        }
        if facts.isImage {
            if facts.looksLikeScreenshot || isScreenCapture(url) { return folder(screenshots, L("Screenshot", table: "Analysis")) }
            if facts.captureDate != nil || facts.cameraModel != nil {
                let date = facts.captureDate.map(DayDate.init) ?? (facts.created ?? facts.modified).map(DayDate.init)
                let reason = facts.captureDate != nil
                    ? L("Date taken, from the photo’s details", table: "Analysis")
                    : L("File date, since the photo has no date taken", table: "Analysis")
                return DocInsight(url: url, facts: facts, category: .photo, date: date, reason: reason,
                                  certainty: facts.captureDate != nil ? .sure : .unsure)
            }
            if receiptHints.contains(where: name.contains) { return nil }
            return folder(images, L("Picture without camera details", table: "Analysis"))
        }
        if installerExtensions.contains(ext) || name.hasSuffix(".app.zip") { return folder(installers, L("Installer, usually not needed anymore", table: "Analysis")) }
        if facts.type.conforms(to: .movie) { return folder(videos, L("Video", table: "Analysis")) }
        if facts.type.conforms(to: .audio) { return folder(music, L("Music or audio", table: "Analysis")) }
        if archiveExtensions.contains(ext) { return folder(archives, L("Compressed archive", table: "Analysis")) }
        if officeExtensions.contains(ext) { return folder(documents, L("Spreadsheet or presentation", table: "Analysis")) }
        if LocalEngine.documentExtensions.contains(ext) || facts.type.conforms(to: .text) { return nil }
        let other = Naming.folder(for: .other, year: nil)
        return DocInsight(url: url, facts: facts, category: .other, reason: L("Not a document, so it goes to “%@”", table: "Analysis", other), certainty: .sure)
    }

    /// Marked by the system as a screenshot (also after renaming).
    static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    /// When the file arrived here (in Downloads: download time), else created or modified.
    static func arrival(_ url: URL) -> Date {
        let v = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
        return v?.addedToDirectoryDate ?? v?.creationDate ?? v?.contentModificationDate ?? .distantPast
    }

    /// Newest first.
    public static func newestFirst(_ urls: [URL]) -> [URL] {
        urls.map { ($0, arrival($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Exactly identical files (size first, then checksum): copy → original. The original is the oldest, with equal time
    /// the one with the shortest name ("Rechnung.pdf" before "Rechnung (1).pdf"). Empty files and cloud files do not count.
    public static func duplicates(in urls: [URL]) -> [URL: URL] {
        var bySize: [Int: [URL]] = [:]
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true,
                  let size = v.fileSize, size > 0, !FileFacts.isCloudPlaceholder(url) else { continue }
            bySize[size, default: []].append(url)
        }
        var copies: [URL: URL] = [:]
        for group in bySize.values where group.count > 1 {
            var byHash: [Data: [URL]] = [:]
            for url in group { if let h = hash(url) { byHash[h, default: []].append(url) } }
            for same in byHash.values where same.count > 1 {
                let ordered = same.map { ($0, arrival($0)) }.sorted { a, b in
                    if a.1 != b.1 { return a.1 < b.1 }
                    let (na, nb) = (a.0.lastPathComponent, b.0.lastPathComponent)
                    return na.count != nb.count ? na.count < nb.count : na < nb
                }.map(\.0)
                for copy in ordered.dropFirst() { copies[copy] = ordered[0] }
            }
        }
        return copies
    }

    static func hash(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return Data(sha.finalize())
    }

    static func duplicate(_ url: URL, of original: URL) -> DocInsight {
        DocInsight(url: url, facts: FileFacts.read(url), category: .other, reason: L("Same content as “%@”", table: "Analysis", original.lastPathComponent),
                   certainty: .sure, folder: duplicates)
    }
}
