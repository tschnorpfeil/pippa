import CryptoKit
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
