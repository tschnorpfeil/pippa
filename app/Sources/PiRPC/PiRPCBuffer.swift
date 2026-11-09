import Foundation

/// Buffer for the read queues: split lines at LF (stdout) or keep only the tail (stderr).
final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var discarding = false
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func lines(appending chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        var result: [Data] = []
        // Scan only new bytes and discard oversized frames through the next LF.
        for byte in chunk {
            if byte == 10 {
                if !discarding {
                    if data.last == 13 { data.removeLast() }
                    result.append(data)
                }
                data.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if data.count >= 16 * 1024 * 1024 { data.removeAll(keepingCapacity: true); discarding = true }
                else { data.append(byte) }
            }
        }
        return result
    }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
