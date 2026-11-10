import Foundation

/// One file over HTTPS into a `.part` file, resumed with `Range` after every break: the transfer behind model and runtime
/// downloads. A transfer with no bytes and no completion for `stallTimeout` ends the attempt, a failed attempt is
/// retried (up to 8 times, with growing pauses), and a file that is complete counts as done even when URLSession never
/// reports the end. The caller verifies the SHA-256 and renames.
///
/// A file can come from several sources that serve the same bytes (Hugging Face and Pippa's mirror on GitHub
/// releases): each failed attempt switches to the next one, and the 8 attempts are shared by all of them. Because the
/// bytes are the same, a file started at one source is resumed at the other.
///
/// A large file comes over several connections at once (`connections` pieces of `pieceSize` bytes, written in order, so
/// the `.part` file still resumes by its size): one connection to GitHub releases or Hugging Face is often far slower
/// than the line. Whatever goes wrong there, the rest of the file comes the old way, over one connection.
///
/// One instance per download: it holds the state of the running transfer.
final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Error writing the temporary file: not a network error, so no retry.
    struct WriteFailure: Error { let underlying: Error }

    /// Where one file's bytes come from: the file at one URL, or its consecutive parts of `partSize` bytes each (the last
    /// one shorter) that, joined, are the file.
    struct Source: Sendable {
        /// For the diagnostics log, e.g. `huggingface` or `spiegel`.
        var name: String
        var urls: [URL]
        /// `nil`: `urls` holds the whole file.
        var partSize: Int64?

        /// The piece holding byte `offset` of a file of `size` bytes: its URL and its first and end byte in the file.
        func segment(at offset: Int64, size: Int64) -> (url: URL, start: Int64, end: Int64)? {
            let step = partSize.map { max(1, $0) } ?? size
            let index = step > 0 ? Int(offset / step) : 0
            guard index < urls.count else { return nil }
            let start = Int64(index) * step
            return (urls[index], start, partSize == nil ? size : min(size, start + step))
        }
    }

    /// A folder on the volume the file goes to, for the free-space checks.
    let directory: URL
    /// No bytes and no completion for this long ends the attempt (URLSession's own idle timeout is 60 s).
    var stallTimeout: TimeInterval = 90
    /// A file with at least this much left comes over `connections` connections at once, `pieceSize` bytes each.
    var parallelMinimum: Int64 = 64 << 20
    var pieceSize: Int64 = 8 << 20
    var connections = 4

    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Int, Error>?
    /// Bytes of the file so far (not of the piece being fetched).
    private var received: Int64 = 0
    /// Where the piece being fetched starts in the file: a `206` must continue at `received - segmentStart`, a `200`
    /// rewrites the piece from here.
    private var segmentStart: Int64 = 0
    /// End of the piece being fetched in the file: once that many bytes are written the transfer is done, completion or not.
    private var expected: Int64 = 0
    private var lastActivity = Date()
    private var onData: ((Int64) -> Void)?
    private var activeTask: URLSessionDataTask?
    private var transferCancelled = false
    private var writeError: Error?
    /// Bytes written since the last space check (checked about every 256 MB).
    private var sinceSpaceCheck: Int64 = 0
    private let lock = NSLock()

    init(directory: URL) { self.directory = directory }

    /// Brings `part` up to `size` bytes from one URL (the runtime archive).
    func download(_ url: URL, to part: URL, size: Int64, onBytes: @escaping (Int64) -> Void) async throws {
        try await download(from: [Source(name: url.host ?? "url", urls: [url])], to: part, size: size, onBytes: onBytes)
    }

    /// Brings `part` up to `size` bytes, starting with the first source; each failed attempt moves on to the next one.
    /// `onBytes`: bytes of the file so far. Returns the source that delivered the last bytes (`nil` if `part` was
    /// already complete). A disk or write error comes out as `PippaError.notEnoughSpace` or `.writeFailed`, a transfer
    /// that keeps failing as `.downloadFailed`.
    @discardableResult
    func download(from sources: [Source], to part: URL, size: Int64, onBytes: @escaping (Int64) -> Void) async throws -> Source? {
        precondition(!sources.isEmpty)
        var attempts = 0
        var finished: Source?
        // After two failures the file stays on one connection: slower, and it works wherever a download works at all.
        var parallelFailures = 0
        while true {
            try Task.checkCancellation()
            let have = max(0, ModelDownloader.fileSize(part))
            if have >= size { return finished }
            let source = sources[attempts % sources.count]
            if connections > 1, parallelFailures < 2, size - have >= parallelMinimum {
                do {
                    defer { if ModelDownloader.fileSize(part) > have { finished = source } }
                    try await fetchParallel(source, to: part, from: have, size: size, onBytes: onBytes)
                    continue
                } catch let failure as WriteFailure {
                    throw ModelDownloader.writeFailure(failure.underlying, remaining: size - max(0, ModelDownloader.fileSize(part)), in: directory)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    parallelFailures += 1
                    DiagnosticsLog.shared.event("download-parallel-fehler", ["versuch": String(parallelFailures)])
                    continue
                }
            }
            do {
                guard let segment = source.segment(at: have, size: size) else {
                    throw PippaError.downloadFailed("Quelle ohne Teil ab \(have).")
                }
                defer { if ModelDownloader.fileSize(part) > have { finished = source } }
                try await fetch(segment.url, to: part, from: have, segment: segment.start..<segment.end, onBytes: onBytes)
                // Response without new bytes (server silently aborts): counts as a failed attempt, else endless loop.
                if ModelDownloader.fileSize(part) <= have { throw PippaError.downloadFailed("Keine neuen Daten.") }
            } catch let failure as WriteFailure {
                // Disk full or write error: retrying doesn't help, and it isn't the network either.
                throw ModelDownloader.writeFailure(failure.underlying, remaining: size - max(0, ModelDownloader.fileSize(part)), in: directory)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // All bytes are in even though the attempt failed (for example the connection dropped after the last byte).
                if ModelDownloader.fileSize(part) >= size { continue }
                attempts += 1
                if attempts > 8 {
                    DiagnosticsLog.shared.event("download-aufgegeben", ["versuche": String(attempts)])
                    throw PippaError.downloadFailed("Bitte Internetverbindung prüfen. Es geht dort weiter, wo es aufgehört hat.")
                }
                if sources.count > 1 {
                    DiagnosticsLog.shared.event("download-quellenwechsel", ["nach": sources[attempts % sources.count].name, "versuch": String(attempts)])
                }
                // The first switch to a source not tried yet goes straight on; back at a source that already failed, wait.
                if attempts >= sources.count { try await Task.sleep(for: .seconds(Double(attempts) * 3)) }
            }
        }
    }

    /// Brings `part` from `offset` to `size` over `connections` connections: pieces of `pieceSize` bytes, fetched ahead
    /// by at most two pieces per connection and written in order. Throws on the first piece that fails; what is
    /// written by then stays, and the caller goes on from the file's size.
    private func fetchParallel(_ source: Source, to part: URL, from offset: Int64, size: Int64, onBytes: @escaping (Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let fh: FileHandle
        do { fh = try FileHandle(forWritingTo: part); try fh.seekToEnd() } catch { throw WriteFailure(underlying: error) }
        defer { try? fh.close() }
        var free = (0..<connections).map { _ in PieceConnection() }
        let all = free
        defer { all.forEach { $0.invalidate() } }
        let step = max(1, pieceSize), window = step * Int64(connections) * 2
        var next = offset, written = offset, sinceCheck: Int64 = 0
        var waiting: [Int64: Data] = [:]
        try await withThrowingTaskGroup(of: (Int64, PieceConnection, Data).self) { group in
            while true {
                while next < size, next - written < window, let connection = free.popLast() {
                    guard let segment = source.segment(at: next, size: size) else { throw PippaError.downloadFailed("Quelle ohne Teil ab \(next).") }
                    let start = next, end = min(start + step, segment.end)
                    next = end
                    group.addTask {
                        (start, connection, try await connection.fetch(segment.url, bytes: (start - segment.start)..<(end - segment.start)))
                    }
                }
                guard let (start, connection, data) = try await group.next() else { break }
                free.append(connection)
                waiting[start] = data
                while let data = waiting.removeValue(forKey: written) {
                    do { try fh.write(contentsOf: data) } catch { throw WriteFailure(underlying: error) }
                    written += Int64(data.count)
                    sinceCheck += Int64(data.count)
                    onBytes(written)
                }
                if sinceCheck >= 256 << 20 {
                    sinceCheck = 0
                    if let space = ModelDownloader.availableSpace(at: directory), space < ModelDownloader.spaceFloor {
                        throw WriteFailure(underlying: PippaError.notEnoughSpace(bytes: ModelDownloader.spaceBuffer))
                    }
                }
            }
        }
    }

    /// One request for the piece of the file at `url` that covers `segment` (byte offsets in the file), from `offset` on.
    private func fetch(_ url: URL, to part: URL, from offset: Int64, segment: Range<Int64>, onBytes: @escaping (Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let fh: FileHandle
        do { fh = try FileHandle(forWritingTo: part) } catch { throw WriteFailure(underlying: error) }
        var request = URLRequest(url: url)
        request.setValue("Pippa/\(Pippa.version)", forHTTPHeaderField: "User-Agent")
        if offset > segment.lowerBound { request.setValue("bytes=\(offset - segment.lowerBound)-", forHTTPHeaderField: "Range") }
        request.timeoutInterval = 60
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        defer {
            try? fh.close()
            lock.withLock { handle = nil; onData = nil; activeTask = nil }
        }
        lock.withLock {
            handle = fh; received = offset; segmentStart = segment.lowerBound; expected = segment.upperBound; onData = onBytes
            transferCancelled = false; writeError = nil; sinceSpaceCheck = 0; lastActivity = Date()
        }
        // Never wait forever for URLSession: a transfer without bytes or completion for `stallTimeout` ends the attempt.
        let stall = stallTimeout
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(5, stall / 4)))
                guard let self, !Task.isCancelled else { return }
                let cont: CheckedContinuation<Int, Error>? = self.lock.withLock {
                    guard self.continuation != nil, Date().timeIntervalSince(self.lastActivity) > stall else { return nil }
                    self.activeTask?.cancel(); self.activeTask = nil
                    defer { self.continuation = nil }
                    return self.continuation
                }
                if let cont {
                    DiagnosticsLog.shared.event("download-haengt")
                    cont.resume(throwing: PippaError.downloadFailed("Der Download kam nicht weiter."))
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        _ = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
                lock.withLock {
                    if transferCancelled { cont.resume(throwing: CancellationError()); return }
                    continuation = cont
                    let task = session.dataTask(with: request)
                    activeTask = task
                    task.resume()
                }
            }
        } onCancel: {
            self.lock.withLock { self.transferCancelled = true; self.activeTask?.cancel() }
        }
    }

    /// Takes the waiting continuation exactly once and detaches the task, so its later callbacks change nothing. Call with `lock` held.
    private func takeContinuation() -> CheckedContinuation<Int, Error>? {
        let cont = continuation
        continuation = nil; activeTask = nil
        return cont
    }

    // Each attempt has its own URLSession but shares this delegate: callbacks of an older, cancelled task are ignored,
    // so they can neither write into the new attempt's file nor end its wait.

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock()
        guard dataTask === activeTask else { lock.unlock(); completionHandler(.cancel); return }
        lastActivity = Date()
        var failure: Error?
        do {
            if status == 200 {
                // Server ignores Range (or none was sent): the piece starts over at its beginning.
                do { try handle?.truncate(atOffset: UInt64(segmentStart)); try handle?.seek(toOffset: UInt64(segmentStart)) }
                catch { throw WriteFailure(underlying: error) }
                received = segmentStart
            } else if status == 206 {
                let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(received - segmentStart)-") else { throw PippaError.downloadFailed("Der Download konnte nicht fortgesetzt werden.") }
                do { _ = try handle?.seekToEnd() } catch { throw WriteFailure(underlying: error) }
            } else {
                throw PippaError.downloadFailed("Antwort \(status)")
            }
        } catch { failure = error }
        let cont = failure == nil ? nil : takeContinuation()
        lock.unlock()
        if let failure {
            completionHandler(.cancel)
            cont?.resume(throwing: failure)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard dataTask === activeTask else { lock.unlock(); return }
        lastActivity = Date()
        // Never write past the end of the piece: extra bytes would only spoil a complete file or the next piece.
        let room = expected > 0 ? max(0, expected - received) : Int64(data.count)
        let chunk = Int64(data.count) > room ? data.prefix(Int(room)) : data
        do { try handle?.write(contentsOf: chunk) }
        catch { writeError = WriteFailure(underlying: error); activeTask?.cancel(); lock.unlock(); return }
        received += Int64(chunk.count)
        sinceSpaceCheck += Int64(chunk.count)
        if sinceSpaceCheck >= 256 << 20 {
            sinceSpaceCheck = 0
            // Other programs may be filling the disk right now: better to stop beforehand than fill the Mac completely.
            if let free = ModelDownloader.availableSpace(at: directory), free < ModelDownloader.spaceFloor {
                writeError = WriteFailure(underlying: PippaError.notEnoughSpace(bytes: ModelDownloader.spaceBuffer))
                activeTask?.cancel(); lock.unlock(); return
            }
        }
        // All bytes of the piece are in: done, whether or not URLSession ever reports completion (it did not, after a reset at the end).
        var done: CheckedContinuation<Int, Error>?
        if expected > 0, received >= expected { dataTask.cancel(); done = takeContinuation() }
        let r = received, cb = onData
        lock.unlock()
        cb?(r)
        done?.resume(returning: 0)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard task === activeTask else { lock.unlock(); return }
        let failure = writeError
        let cont = takeContinuation()
        lock.unlock()
        if let failure { cont?.resume(throwing: failure) }
        else if let error { cont?.resume(throwing: error) } else { cont?.resume(returning: 0) }
    }
}

/// One connection of a parallel download: its own URLSession (so pieces really travel over separate connections, not
/// as streams of one), fetching one piece at a time into memory. Only a `206` for exactly the bytes asked for counts;
/// a server that ignores `Range` would send the whole file.
private final class PieceConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var data = Data()
    private var first: Int64 = 0
    private var count = 0
    private var failure: Error?
    private var cancelled = false

    func invalidate() { lock.withLock { session }?.invalidateAndCancel() }

    func fetch(_ url: URL, bytes: Range<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Pippa/\(Pippa.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(bytes.lowerBound)-\(bytes.upperBound - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 60
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                lock.withLock {
                    if cancelled { cont.resume(throwing: CancellationError()); return }
                    if session == nil { session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil) }
                    continuation = cont
                    data = Data(); first = bytes.lowerBound; count = bytes.count; failure = nil
                    task = session?.dataTask(with: request)
                    task?.resume()
                }
            }
        } onCancel: {
            lock.withLock { cancelled = true; task?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let range = http?.value(forHTTPHeaderField: "Content-Range") ?? ""
        let fits = lock.withLock {
            let fits = http?.statusCode == 206 && range.hasPrefix("bytes \(first)-\(first + Int64(count) - 1)/")
            if !fits { failure = PippaError.downloadFailed("Antwort \(http?.statusCode ?? 0) auf ein Teilstück") }
            return fits
        }
        completionHandler(fits ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > count { failure = PippaError.downloadFailed("Teilstück zu lang"); dataTask.cancel() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (cont, result): (CheckedContinuation<Data, Error>?, Result<Data, Error>) = lock.withLock {
            let cont = continuation
            continuation = nil; self.task = nil
            let piece = data
            data = Data()
            if let failure { return (cont, .failure(failure)) }
            if let error { return (cont, .failure(error)) }
            return (cont, piece.count == count ? .success(piece) : .failure(PippaError.downloadFailed("Teilstück unvollständig")))
        }
        cont?.resume(with: result)
    }
}
