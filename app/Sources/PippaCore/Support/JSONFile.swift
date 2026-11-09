import Darwin
import Foundation

/// JSON files that Pippa merges into or writes for Pi and the local server (models.json, settings.json, the launch file).
enum JSONFile {
    static let writingOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    /// The top-level object, or `nil` if the file is missing, unreadable or not an object (comments are not JSON).
    static func readObject(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Key-sorted bytes to compare two values regardless of key order.
    static func canonical(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    /// The file's text: pretty, sorted keys, a final newline.
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: writingOptions) + Data("\n".utf8)
    }

    /// Writes next to the target as `.<name>.pippa-<uuid>`, sets the mode, then renames over it (atomic). `mode`:
    /// `nil` keeps the mode of an existing file and uses 0600 for a new one. The parent folder must exist.
    static func writeAtomically(_ data: Data, to url: URL, mode: Int? = nil) throws {
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).pippa-\(UUID().uuidString)")
        do {
            try data.write(to: temporary)
            let existing = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            try fm.setAttributes([.posixPermissions: mode ?? existing ?? 0o600], ofItemAtPath: temporary.path)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: code))
        }
    }
}
