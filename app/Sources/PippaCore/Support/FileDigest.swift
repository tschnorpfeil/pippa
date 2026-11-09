import CryptoKit
import Foundation

/// SHA-256 of a file, read in chunks, as lowercase hex. The one place that streams a file through a hasher for
/// downloads, adoption and the OCR cache.
public enum FileDigest {
    /// `maxBytes` was exceeded before the end of the file.
    public struct TooLarge: Error, Sendable {}

    /// `onBytes`: bytes read so far. Throws `CancellationError` when the task is cancelled, and `TooLarge` when the file
    /// is longer than `maxBytes`.
    public static func sha256(of url: URL, maxBytes: Int64? = nil, onBytes: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var read: Int64 = 0
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            read += Int64(chunk.count)
            if let maxBytes, read > maxBytes { throw TooLarge() }
            hasher.update(data: chunk)
            onBytes?(read)
        }
        return hasher.finalize().hexString
    }
}

extension Sequence where Element == UInt8 {
    /// Lowercase hex, two digits per byte.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
