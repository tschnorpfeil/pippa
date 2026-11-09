import Foundation

/// One file over HTTPS into a `.part` file, resumed with `Range` after every break: the transfer behind model and runtime
/// downloads. A transfer with no bytes and no completion for `stallTimeout` ends the attempt, a failed attempt is
/// retried (up to 8 times, with growing pauses), and a file that is complete counts as done even when URLSession never
/// reports the end. The caller verifies the SHA-256 and renames.
///
/// One instance per download: it holds the state of the running transfer.
final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Error writing the temporary file: not a network error, so no retry.
    struct WriteFailure: Error { let underlying: Error }

    /// A folder on the volume the file goes to, for the free-space checks.
    let directory: URL
    /// No bytes and no completion for this long ends the attempt (URLSession's own idle timeout is 60 s).
    var stallTimeout: TimeInterval = 90

    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Int, Error>?
    private var received: Int64 = 0
    /// Full size of the file being fetched: once that many bytes are written the transfer is done, completion or not.
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

    /// Brings `part` up to `size` bytes. `onBytes`: bytes of the file so far. A disk or write error comes out as
    /// `PippaError.notEnoughSpace` or `.writeFailed`, a transfer that keeps failing as `.downloadFailed`.
    func download(_ url: URL, to part: URL, size: Int64, onBytes: @escaping (Int64) -> Void) async throws {
        var attempts = 0
        while true {
            try Task.checkCancellation()
            let have = max(0, ModelDownloader.fileSize(part))
            if have >= size { return }
            do {
                try await fetch(url, to: part, from: have, size: size, onBytes: onBytes)
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
                try await Task.sleep(for: .seconds(Double(attempts) * 3))
            }
        }
    }

    private func fetch(_ url: URL, to part: URL, from offset: Int64, size: Int64, onBytes: @escaping (Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let fh: FileHandle
        do { fh = try FileHandle(forWritingTo: part) } catch { throw WriteFailure(underlying: error) }
        var request = URLRequest(url: url)
        request.setValue("Pippa/\(Pippa.version)", forHTTPHeaderField: "User-Agent")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        request.timeoutInterval = 60
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        defer {
            try? fh.close()
            lock.withLock { handle = nil; onData = nil; activeTask = nil }
        }
        lock.withLock {
            handle = fh; received = offset; expected = size; onData = onBytes
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
                // Server ignores Range: start from the beginning.
                do { try handle?.truncate(atOffset: 0); try handle?.seek(toOffset: 0) } catch { throw WriteFailure(underlying: error) }
                received = 0
            } else if status == 206 {
                let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(received)-") else { throw PippaError.downloadFailed("Der Download konnte nicht fortgesetzt werden.") }
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
        // Never write past the expected size: extra bytes would only spoil a complete file.
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
        // All bytes are in: done, whether or not URLSession ever reports completion (it did not, after a reset at the end).
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
