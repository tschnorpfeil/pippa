import CryptoKit
import Network
import Foundation
import PippaCore

/// Optional local HTTP checks; scripts/check-downloads.sh supplies the fixture.
func runDownloadChecks() async {
    let payload = Data((0..<524_288).map { UInt8($0 % 256) })
    let hash = SHA256.hash(data: payload).hexString
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
    await runMirrorDownloadChecks()
}

/// Hugging Face failing in the ways it does (refused, connection gone, broken off), with the catalog's mirror on the same
/// fixture (`/mirror/<route>/<partSize>/`, see scripts/check-downloads.sh); routes `mx-*` serve bytes without a period.
func runMirrorDownloadChecks() async {
    let payload = Data((0..<16_384).flatMap { i in SHA256.hash(data: withUnsafeBytes(of: UInt32(i).bigEndian) { Data($0) }).map { $0 } })
    let hash = SHA256.hash(data: payload).hexString
    func model(_ route: String, partSize: Int, hash: String = hash) throws -> CatalogModel {
        let json: [String: Any] = [
            "key": route, "label": route, "repo": "fixture/\(route)", "ctx": 1024, "license": "test",
            "mirror": ["url": "\(ModelDownloader.endpoint)/mirror/\(route)/\(partSize)/", "partSize": partSize],
            "pinned": ["revision": "test", "files": [["path": "weights/model.gguf", "size": payload.count, "sha256": hash]]]
        ]
        return try JSONDecoder().decode(CatalogModel.self, from: JSONSerialization.data(withJSONObject: json))
    }
    /// What the fixture saw for a route, in order: source (`hf`, `mirror`), asset name and the Range offset (`nil`: none).
    func requests(_ route: String) async throws -> [(source: String, name: String, range: Int?)] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(ModelDownloader.endpoint)/log/\(route)")!)
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return list.map { ($0["source"] as? String ?? "", $0["name"] as? String ?? "", $0["range"] as? Int) }
    }
    /// Downloads `selected` and returns the source the diagnostics log names for the finished file.
    func download(_ downloader: ModelDownloader, _ selected: CatalogModel) async throws -> String? {
        DiagnosticsLog.shared.flush()
        let before = (try? String(contentsOf: DiagnosticsLog.shared.fileURL, encoding: .utf8))?.count ?? 0
        try await downloader.download(selected) { _, _ in }
        DiagnosticsLog.shared.flush()
        let log = (try? String(contentsOf: DiagnosticsLog.shared.fileURL, encoding: .utf8)) ?? ""
        let line = log.dropFirst(before).split(separator: "\n").last { $0.contains(" download-fertig ") }
        return line?.split(separator: " ").first { $0.hasPrefix("quelle=") }.map { String($0.dropFirst(7)) }
    }
    func installed(_ downloader: ModelDownloader, _ selected: CatalogModel) throws -> Bool {
        guard downloader.isInstalled(selected) else { return false }
        return try Data(contentsOf: downloader.localURL(selected.pinned!.files[0])) == payload
    }
    let parts = (0..<6).map { "weights--model.gguf.part-\($0)" }

    await checkAsync("Download: Hugging Face refuses (403), the mirror delivers the file in parts, SHA-256 verified") {
        let downloader = ModelDownloader(directory: dir("download-mirror-403"))
        let selected = try model("mx-403", partSize: 100_000)
        let started = Date()
        let source = try await download(downloader, selected)
        let seen = try await requests("mx-403")
        return try installed(downloader, selected) && source == "spiegel" && Date().timeIntervalSince(started) < 5
            && seen.filter { $0.source == "hf" }.count == 1
            && seen.filter { $0.source == "mirror" }.map(\.name) == parts && seen.allSatisfy { $0.range == nil }
    }
    await checkAsync("Download: Hugging Face drops the connection, the mirror delivers the file in one piece") {
        let downloader = ModelDownloader(directory: dir("download-mirror-drop"))
        let selected = try model("mx-drop", partSize: 1_000_000)
        let source = try await download(downloader, selected)
        let seen = try await requests("mx-drop")
        return try installed(downloader, selected) && source == "spiegel"
            && seen.filter { $0.source == "mirror" }.map(\.name) == ["weights--model.gguf"]
    }
    await checkAsync("Download: Hugging Face breaks off at 40 %, the mirror resumes in the middle of part 1") {
        let downloader = ModelDownloader(directory: dir("download-mirror-40"))
        let selected = try model("mx-40", partSize: 150_000)
        let source = try await download(downloader, selected)
        let mirror = try await requests("mx-40").filter { $0.source == "mirror" }
        let cut = payload.count * 4 / 10
        return try installed(downloader, selected) && source == "spiegel" && mirror.count == 3
            && mirror[0].name == parts[1] && mirror[0].range == cut - 150_000
            && mirror[1].name == parts[2] && mirror[1].range == nil && mirror[2].name == parts[3] && mirror[2].range == nil
    }
    await checkAsync("Download: the mirror breaks off in part 1, Hugging Face resumes where it stopped") {
        let downloader = ModelDownloader(directory: dir("download-mirror-mdrop"))
        let selected = try model("mx-mdrop", partSize: 150_000)
        let source = try await download(downloader, selected)
        let seen = try await requests("mx-mdrop")
        let hf = seen.filter { $0.source == "hf" }, mirror = seen.filter { $0.source == "mirror" }
        return try installed(downloader, selected) && source == "huggingface"
            && hf.count == 2 && hf[0].range == nil && hf[1].range == 150_000 + 75_000
            && mirror.map(\.name) == [parts[0], parts[1]]
    }
    await checkAsync("Download: wrong bytes from the mirror are never installed") {
        let directory = dir("download-mirror-bad")
        let downloader = ModelDownloader(directory: directory)
        let selected = try model("mx-bad", partSize: 100_000)
        do { try await downloader.download(selected) { _, _ in }; return false }
        catch PippaError.checksumMismatch {
            let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return !downloader.isInstalled(selected) && !left.contains { $0.hasPrefix("model.gguf") }
        }
    }
    await checkAsync("Download: while Hugging Face works the mirror is never asked") {
        let downloader = ModelDownloader(directory: dir("download-mirror-unused"))
        let selected = try model("mx-ok", partSize: 100_000)
        let source = try await download(downloader, selected)
        let seen = try await requests("mx-ok")
        return try installed(downloader, selected) && source == "huggingface"
            && seen.filter { $0.source == "mirror" }.isEmpty && seen.count == 1
    }
    await checkAsync("Download: cancel stays fast during a mirror request, and the mirror resumes with Range") {
        let directory = dir("download-mirror-cancel")
        let downloader = ModelDownloader(directory: directory)
        let selected = try model("mx-slow", partSize: 100_000)
        let task = Task { try await downloader.download(selected) { _, _ in } }
        let part = directory.appendingPathComponent("model.gguf.part")
        for _ in 0..<200 {
            if ModelDownloader.fileSize(part) >= 8_192 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let asked = try await requests("mx-slow").contains { $0.source == "mirror" }
        let started = Date()
        task.cancel()
        do { try await task.value; return false } catch is CancellationError { }
        let size = ModelDownloader.fileSize(part)
        guard asked, Date().timeIntervalSince(started) < 1, size > 0, size < payload.count, !downloader.isInstalled(selected) else { return false }
        try await downloader.download(selected) { _, _ in }
        let resumed = try await requests("mx-slow").contains { $0.source == "mirror" && $0.range == Int(size) % 100_000 }
        return try installed(downloader, selected) && resumed
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
    check("Download: mirror asset names (path with / as --, parts above partSize) and the catalog's mirror") {
        let mirror = CatalogModel.Mirror(url: "https://github.com/tschnorpfeil/pippa/releases/download/model-x-abc1234/", partSize: 2_000_000_000)
        let whole = ModelDownloader.mirrorURLs(mirror, path: "sub/dir/config.json", size: 2_000_000_000)?.map(\.absoluteString)
        let split = ModelDownloader.mirrorURLs(mirror, path: "model.safetensors", size: 5_038_161_163)?.map(\.lastPathComponent)
        let bundled = ModelCatalog.bundled().models.first
        return whole == ["https://github.com/tschnorpfeil/pippa/releases/download/model-x-abc1234/sub--dir--config.json"]
            && split == ["model.safetensors.part-0", "model.safetensors.part-1", "model.safetensors.part-2"]
            && ModelDownloader.mirrorURLs(CatalogModel.Mirror(url: "not a url", partSize: 1), path: "a", size: 1) == nil
            && ModelDownloader.mirrorURLs(CatalogModel.Mirror(url: mirror.url, partSize: 0), path: "a", size: 1) == nil
            && bundled?.mirror?.partSize == 2_000_000_000 && bundled?.license?.isEmpty == false
            && bundled?.pinned?.files.allSatisfy { ModelDownloader.mirrorURLs(bundled!.mirror!, path: $0.path, size: $0.size) != nil } == true
    }
    let payload = Data((0..<300_000).map { UInt8(($0 * 7) % 251) })
    let hash = SHA256.hash(data: payload).hexString
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
    await checkAsync("Download: the runtime archive uses the same downloader (all bytes in without completion, then verified and unpacked)") {
        let base = dir("download-runtime")
        let archive = try Data(contentsOf: fakeRuntimeArchive(in: base, padding: 300_000))
        let server = try StallingServer(payload: archive)
        defer { server.stop() }
        let port = try await server.start()
        let archiveHash = SHA256.hash(data: archive).hexString
        let manifest = fakeRuntimeManifest(size: Int64(archive.count), sha256: archiveHash, url: "http://127.0.0.1:\(port)/stall-end/runtime.tar.gz")
        let runtime = MLXRuntime(support: base.appendingPathComponent("support"), environment: [:], manifest: manifest)!
        let started = Date()
        try await runtime.install { _ in }
        return runtime.isInstalled && Date().timeIntervalSince(started) < 10
    }
}
