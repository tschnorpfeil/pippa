import CryptoKit
import Network
import Foundation
import PippaCore

/// Optional local HTTP checks; scripts/check-downloads.sh supplies the fixture.
func runDownloadChecks() async {
    let payload = Data((0..<524_288).map { UInt8($0 % 256) })
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    func model(_ route: String, hash: String) throws -> CatalogModel {
        let json: [String: Any] = [
            "key": route, "label": route, "repo": "fixture/\(route)", "quant": "test",
            "memGiB": 1, "ctx": 1024, "rank": 1,
            "pinned": ["revision": "test", "files": [["path": "model.gguf", "size": payload.count, "sha256": hash]]]
        ]
        return try JSONDecoder().decode(CatalogModel.self, from: JSONSerialization.data(withJSONObject: json))
    }
    await checkAsync("Download: cancel stays fast and resume verifies SHA256") {
        let directory = dir("download-cancel")
        let downloader = ModelDownloader(directory: directory)
        let selected = try model("slow", hash: hash)
        let task = Task { try await downloader.download(selected) { _, _ in } }
        let part = directory.appendingPathComponent("model.gguf.part")
        for _ in 0..<100 {
            if ModelDownloader.fileSize(part) >= 8_192 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let started = Date()
        task.cancel()
        do { try await task.value; return false } catch is CancellationError { }
        let size = ModelDownloader.fileSize(part)
        guard Date().timeIntervalSince(started) < 1, size > 0, size < payload.count, !downloader.isInstalled(selected) else { return false }
        try await downloader.download(selected) { _, _ in }
        let downloaded = try Data(contentsOf: directory.appendingPathComponent("model.gguf"))
        return downloader.isInstalled(selected) && downloaded == payload
    }
    await checkAsync("Download: ignored Range restarts cleanly from the beginning") {
        let directory = dir("download-full-response")
        try payload.prefix(12_345).write(to: directory.appendingPathComponent("model.gguf.part"))
        let downloader = ModelDownloader(directory: directory)
        let selected = try model("ignore-range", hash: hash)
        try await downloader.download(selected) { _, _ in }
        let downloaded = try Data(contentsOf: directory.appendingPathComponent("model.gguf"))
        return downloader.isInstalled(selected) && downloaded == payload
    }
    await checkAsync("Download: wrong checksum is never installed") {
        let directory = dir("download-corrupt")
        let downloader = ModelDownloader(directory: directory)
        let selected = try model("fast", hash: String(repeating: "0", count: 64))
        do { try await downloader.download(selected) { _, _ in }; return false }
        catch PippaError.checksumMismatch {
            return !downloader.isInstalled(selected) && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.gguf.part").path)
        }
    }
}

/// Loopback HTTP fixture inside the run (no network): serves a payload and then misbehaves the way flaky connections do.
/// `end`: all bytes, then the connection stays open without completing (Content-Length promises more).
/// `mid`: the first request stops halfway and stays silent; a resumed request (Range) gets the rest.
private final class StallingServer: @unchecked Sendable {
    let listener: NWListener
    let payload: Data
    private var held: [NWConnection] = []
    private let lock = NSLock()

    init(payload: Data) throws {
        self.payload = payload
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [self] data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                let offset = head.range(of: #"(?i)range: bytes=(\d+)-"#, options: .regularExpression)
                    .flatMap { Int(head[$0].split(separator: "=").last!.dropLast()) } ?? 0
                let rest = payload.dropFirst(offset)
                var reply: Data
                if head.contains("/stall-end/") {
                    reply = Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count + 16)\r\n\r\n".utf8) + payload
                } else if offset == 0 {
                    reply = Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\n\r\n".utf8) + payload.prefix(payload.count / 2)
                } else {
                    reply = Data(("HTTP/1.1 206 Partial Content\r\nContent-Length: \(rest.count)\r\n"
                        + "Content-Range: bytes \(offset)-\(payload.count - 1)/\(payload.count)\r\nConnection: close\r\n\r\n").utf8) + rest
                }
                lock.withLock { held.append(c) } // never closed by the server while the check runs
                c.send(content: reply, completion: .contentProcessed { _ in })
            }
        }
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            if listener.state == .setup { listener.start(queue: .global()) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PippaError.downloadFailed("fixture")
    }

    func stop() {
        listener.cancel()
        lock.withLock { held.forEach { $0.cancel() }; held = [] }
    }
}

func runDownloadHangChecks() async {
    let payload = Data((0..<300_000).map { UInt8(($0 * 7) % 251) })
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    func model(_ route: String) throws -> CatalogModel {
        let json: [String: Any] = [
            "key": route, "label": route, "repo": "fixture/\(route)", "quant": "test",
            "memGiB": 1, "ctx": 1024, "rank": 1,
            "pinned": ["revision": "test", "files": [["path": "model.gguf", "size": payload.count, "sha256": hash]]]
        ]
        return try JSONDecoder().decode(CatalogModel.self, from: JSONSerialization.data(withJSONObject: json))
    }
    await checkAsync("Download: all bytes in but no completion still verifies and installs (no hang at 100 %)") {
        let server = try StallingServer(payload: payload)
        defer { server.stop() }
        let port = try await server.start()
        let downloader = ModelDownloader(directory: dir("download-stall-end"))
        downloader.source = "http://127.0.0.1:\(port)"
        let selected = try model("stall-end")
        let started = Date()
        try await downloader.download(selected) { _, _ in }
        // URLSession's own idle timeout is 60 s; finishing well before it shows the size, not a timeout, ended the wait.
        return downloader.isInstalled(selected) && Date().timeIntervalSince(started) < 10
    }
    await checkAsync("Download: a silent connection ends by the watchdog and resumes") {
        let server = try StallingServer(payload: payload)
        defer { server.stop() }
        let port = try await server.start()
        let downloader = ModelDownloader(directory: dir("download-stall-mid"))
        downloader.source = "http://127.0.0.1:\(port)"
        downloader.stallTimeout = 0.5
        let selected = try model("stall-mid")
        let started = Date()
        try await downloader.download(selected) { _, _ in }
        let downloaded = try Data(contentsOf: downloader.localURL(selected.pinned!.files[0]))
        // Watchdog (0.5 s) plus one retry pause (3 s), far below URLSession's 60 s idle timeout.
        return downloader.isInstalled(selected) && downloaded == payload && Date().timeIntervalSince(started) < 20
    }
}
