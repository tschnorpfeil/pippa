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
        // Scan only new bytes, a segment up to each LF at a time, and discard oversized frames through the next LF.
        let cap = 16 * 1024 * 1024
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 10)
            let segment = chunk[start..<(newline ?? chunk.endIndex)]
            if !discarding {
                // A frame that would grow past the cap is dropped whole, up to and including its LF.
                if segment.count > cap - data.count { data.removeAll(keepingCapacity: true); discarding = true }
                else { data.append(segment) }
            }
            guard let newline else { break }
            if !discarding {
                if data.last == 13 { data.removeLast() }
                result.append(data)
            }
            data.removeAll(keepingCapacity: true); discarding = false
            start = chunk.index(after: newline)
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
