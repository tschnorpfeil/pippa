import Foundation

/// Common version and paths of Pippa.
public enum Pippa {
    public static let version = "0.2.0"

    /// ~/Library/Application Support/Pippa
    public static var supportDirectory: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PIPPA_SNAPSHOT"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("support", isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pippa", isDirectory: true)
    }
}

/// Tray copies (stored mails, images, text) live per tray in a subfolder of the cache.
public enum InboxCleanup {
    /// Removes subfolders of `directory` that are older than `maxAge` and contain no file from `keeping`
    /// (still attached to a conversation). Only Pippa's own copies, never anything outside. Returns the count.
    @discardableResult
    public static func prune(_ directory: URL, keeping: [URL], maxAge: TimeInterval = 30 * 86_400, now: Date = Date()) -> Int {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isDirectoryKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        let kept = keeping.map { $0.standardizedFileURL.path }
        var removed = 0
        for folder in folders {
            guard let values = try? folder.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                  let date = values.creationDate ?? values.contentModificationDate, now.timeIntervalSince(date) > maxAge else { continue }
            let prefix = folder.standardizedFileURL.path + "/"
            guard !kept.contains(where: { $0.hasPrefix(prefix) }) else { continue }
            if (try? FileManager.default.removeItem(at: folder)) != nil { removed += 1 } // Pippa's own tray copy
        }
        return removed
    }
}
